`timescale 1ns / 1ps

// FP32 element-wise unit (matrix-matrix form only):
//   mfadd.s.mm  md = ms2 + ms1      func4 = 0000
//   mfsub.s.mm  md = ms2 - ms1      func4 = 0001
//   mfmul.s.mm  md = ms2 * ms1      func4 = 0010
//   mfmax.s.mm  md = max(ms2, ms1)  func4 = 0011
//   mfmin.s.mm  md = min(ms2, ms1)  func4 = 0100
// Encoding: func4 | uop=10 | imm3=111 | ms2 | s_size=10 | ms1 | func3=001 | d_size=10 | md | opcode
//
// Structure follows matrix_ew.sv (one element per pass, same FSM/port style)
// and the datapath stages of matrix_fp_mac.sv. The FP arithmetic is NOT rewritten:
// add/sub/mul all run through the same fp32_fma_pkg functions (unpack, specials,
// align_add, round_pack_fast) with a single shared 24x24 multiplier:
//   add : fma( ms1 , 1.0 , ms2 )          -> ms1*1.0 + ms2      (exact product)
//   sub : fma(-ms1 , 1.0 , ms2 )          -> -ms1*1.0 + ms2
//   mul : fma( ms1 , ms2 , +/-0 )         -> ms1*ms2 + 0, zero sign = sign(product)
// The zero addend carries the product sign so that +/-0 results stay correct in
// every rounding mode (incl. RDN). Rounding mode = xmfrm, flags = NV DZ OF UF NX.
// max/min bypass the FMA pipeline (RISC-V F semantics: one NaN -> the other operand,
// both NaN -> canonical NaN, -0 < +0, sNaN raises NV).
module matrix_ew_fp #(
    parameter int MATRIX_DIM = 4,
    parameter int BEATS_PER_ROW = 4
)(
    input  logic        clk,
    input  logic        resetn,

    input  logic        start_fp_ew,
    input  logic [31:0] matrix_insn,
    input  logic [2:0]  out_xmfrm,
    input  logic [31:0] out_mtilem,
    input  logic [31:0] out_mtilen,

    output logic        fp_ew_done,
    output logic        fp_ew_illegal,
    output logic [4:0]  fp_ew_fflags,

    // Regfile write port
    output logic        fp_ew_reg_we,
    output logic [2:0]  fp_ew_reg_id,
    output logic [2:0]  fp_ew_reg_row_idx,
    output logic [2:0]  fp_ew_reg_beat_idx,
    output logic [31:0] fp_ew_reg_wdata,

    // Regfile read ports (combinational read, same as matrix_ew)
    output logic [2:0]  read_id_A,
    output logic [2:0]  read_row_A,
    output logic [2:0]  read_beat_A,
    input  logic [31:0] read_data_A,

    output logic [2:0]  read_id_B,
    output logic [2:0]  read_row_B,
    output logic [2:0]  read_beat_B,
    input  logic [31:0] read_data_B
);

    import fp32_fma_pkg::*;

    typedef enum logic [2:0] {
        ST_IDLE      = 3'd0,
        ST_READ      = 3'd1,
        ST_UNPACK    = 3'd2,
        ST_MULTIPLY  = 3'd3,
        ST_ALIGN_ADD = 3'd4,
        ST_ROUND     = 3'd5,
        ST_WRITE     = 3'd6,
        ST_DONE      = 3'd7
    } fsm_state_t;

    fsm_state_t state;

    localparam logic [3:0]  FUNC_FADD = 4'b0000;
    localparam logic [3:0]  FUNC_FSUB = 4'b0001;
    localparam logic [3:0]  FUNC_FMUL = 4'b0010;
    localparam logic [3:0]  FUNC_FMAX = 4'b0011;
    localparam logic [3:0]  FUNC_FMIN = 4'b0100;
    localparam logic [31:0] FP32_ONE  = 32'h3F80_0000;

    localparam logic [2:0] MATRIX_DIM_L    = MATRIX_DIM;
    localparam logic [2:0] BEATS_PER_ROW_L = BEATS_PER_ROW;

    // Latched decode/config fields
    logic [3:0] func4;
    logic [2:0] ms1_id, ms2_id, md_id;
    logic [2:0] active_M, active_N;
    logic [2:0] rm;

    // Loop counters
    logic [2:0] row_cnt, col_cnt;

    // FMA operand registers (raw FP32 words, already muxed per instruction).
    // For max/min: fma_a_q = ms1 (y), fma_c_q = ms2 (x).
    logic [31:0] fma_a_q, fma_b_q, fma_c_q;
    logic [31:0] nxt_a, nxt_b, nxt_c;

    // FMA pipeline registers (same stages as matrix_fp_mac)
    unpack_t  ua, ub, uc;
    unpack_t  ua_n, ub_n, uc_n;
    special_t special;
    logic [47:0] product;
    sum_t     sum;
    result_t  rounded;
    result_t  mm_res;

    // Result registers: separate FMA / min-max so the round path has no extra mux.
    logic [31:0] fma_bits_q, mm_bits_q;
    logic [4:0]  fma_flags_q, mm_flags_q;

    logic [2:0] cfg_M, cfg_N;
    logic       is_minmax_insn, is_minmax, insn_legal;

    // -------------------------------------------------------------------------
    // Min/max helpers (the package has no compare logic)
    // -------------------------------------------------------------------------
    function automatic logic fp_is_nan(input logic [31:0] v);
        return (v[30:23] == 8'hff) && (v[22:0] != 23'b0);
    endfunction

    function automatic logic fp_is_snan(input logic [31:0] v);
        return fp_is_nan(v) && !v[22];
    endfunction

    // Strict a < b for non-NaN inputs, with -0 < +0.
    function automatic logic fp_lt(input logic [31:0] a, input logic [31:0] b);
        if (a[31] != b[31])  return a[31];
        else if (!a[31])     return (a[30:0] < b[30:0]);
        else                 return (a[30:0] > b[30:0]);
    endfunction

    function automatic result_t fp_minmax(
        input logic [31:0] x,
        input logic [31:0] y,
        input logic        is_max
    );
        result_t r;
        logic    pick_y;
        r = '0;
        r.flags[4] = fp_is_snan(x) | fp_is_snan(y);
        if (fp_is_nan(x) && fp_is_nan(y)) begin
            r.bits = 32'h7fc00000;
        end else if (fp_is_nan(x)) begin
            r.bits = y;
        end else if (fp_is_nan(y)) begin
            r.bits = x;
        end else begin
            pick_y = is_max ? fp_lt(x, y) : fp_lt(y, x);
            r.bits = pick_y ? y : x;
        end
        return r;
    endfunction

    // -------------------------------------------------------------------------
    // Combinational decode / datapath
    // -------------------------------------------------------------------------
    always_comb begin
        cfg_M = (out_mtilem > {29'b0, MATRIX_DIM_L})    ? MATRIX_DIM_L    : out_mtilem[2:0];
        cfg_N = (out_mtilen > {29'b0, BEATS_PER_ROW_L}) ? BEATS_PER_ROW_L : out_mtilen[2:0];

        is_minmax_insn = (matrix_insn[31:28] == FUNC_FMAX) || (matrix_insn[31:28] == FUNC_FMIN);
        insn_legal = (matrix_insn[31:28] <= FUNC_FMIN) &&
                     (matrix_insn[27:26] == 2'b10)     &&
                     (matrix_insn[25:23] == 3'b111)    &&  // .mm only
                     (matrix_insn[19:18] == 2'b10)     &&  // .s source
                     (matrix_insn[11:10] == 2'b10)     &&  // .s dest
                     (is_minmax_insn || (out_xmfrm <= 3'd4));

        is_minmax = (func4 == FUNC_FMAX) || (func4 == FUNC_FMIN);
    end

    // ms1 -> port A, ms2 -> port B (same as matrix_ew: op_a = ms1, op_b = ms2)
    assign read_id_A   = ms1_id;
    assign read_row_A  = row_cnt;
    assign read_beat_A = col_cnt;
    assign read_id_B   = ms2_id;
    assign read_row_B  = row_cnt;
    assign read_beat_B = col_cnt;

    // Operand routing into the shared FMA (y = ms1 = read_data_A, x = ms2 = read_data_B)
    always_comb begin
        nxt_a = read_data_A;
        nxt_b = FP32_ONE;
        nxt_c = read_data_B;
        case (func4)
            FUNC_FSUB: nxt_a = {~read_data_A[31], read_data_A[30:0]};
            FUNC_FMUL: begin
                nxt_b = read_data_B;
                nxt_c = {read_data_A[31] ^ read_data_B[31], 31'b0};
            end
            default: begin end
        endcase
    end

    // Shared unpack wires (avoid duplicating unpack inside specials())
    always_comb begin
        ua_n = unpack(fma_a_q);
        ub_n = unpack(fma_b_q);
        uc_n = unpack(fma_c_q);
    end

    assign rounded = round_pack_fast(sum, special, rm);
    assign mm_res  = fp_minmax(fma_c_q, fma_a_q, func4 == FUNC_FMAX);

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!resetn) begin
            state         <= ST_IDLE;
            row_cnt       <= '0;
            col_cnt       <= '0;
            fp_ew_done    <= 1'b0;
            fp_ew_illegal <= 1'b0;
            fp_ew_fflags  <= '0;
            fp_ew_reg_we       <= 1'b0;
            fp_ew_reg_id       <= '0;
            fp_ew_reg_row_idx  <= '0;
            fp_ew_reg_beat_idx <= '0;
            fp_ew_reg_wdata    <= '0;

            func4    <= '0;
            ms1_id   <= '0;
            ms2_id   <= '0;
            md_id    <= '0;
            active_M <= '0;
            active_N <= '0;
            rm       <= '0;

            fma_a_q <= '0; fma_b_q <= '0; fma_c_q <= '0;
            ua <= '0; ub <= '0; uc <= '0;
            special <= '0; product <= '0; sum <= '0;
            fma_bits_q <= '0; mm_bits_q <= '0;
            fma_flags_q <= '0; mm_flags_q <= '0;
        end 
        else begin
            fp_ew_done   <= 1'b0;
            fp_ew_reg_we <= 1'b0;

            case (state)
                ST_IDLE: begin
                    row_cnt <= '0;
                    col_cnt <= '0;

                    if (start_fp_ew) begin
                        func4    <= matrix_insn[31:28];
                        ms2_id   <= matrix_insn[22:20];
                        ms1_id   <= matrix_insn[17:15];
                        md_id    <= matrix_insn[9:7];
                        active_M <= cfg_M;
                        active_N <= cfg_N;
                        rm       <= out_xmfrm;
                        fp_ew_fflags  <= '0;
                        fp_ew_illegal <= 1'b0;

                        if (!insn_legal) begin
                            fp_ew_illegal <= 1'b1;
                            state <= ST_DONE;
                        end else if (cfg_M == 3'd0 || cfg_N == 3'd0) begin
                            state <= ST_DONE; // No writes; md and flags unchanged.
                        end else begin
                            state <= ST_READ;
                        end
                    end
                end

                ST_READ: begin
                    fma_a_q <= nxt_a;
                    fma_b_q <= nxt_b;
                    fma_c_q <= nxt_c;
                    state   <= is_minmax ? ST_ROUND : ST_UNPACK;
                end

                ST_UNPACK: begin
                    ua      <= ua_n;
                    ub      <= ub_n;
                    uc      <= uc_n;
                    special <= specials(ua_n, ub_n, uc_n);
                    state   <= ST_MULTIPLY;
                end

                ST_MULTIPLY: begin
                    product <= ua.sig * ub.sig;
                    state   <= ST_ALIGN_ADD;
                end

                ST_ALIGN_ADD: begin
                    sum   <= align_add(product, ua, ub, uc, rm);
                    state <= ST_ROUND;
                end

                ST_ROUND: begin
                    if (is_minmax) begin
                        mm_bits_q  <= mm_res.bits;
                        mm_flags_q <= mm_res.flags;
                    end else begin
                        fma_bits_q  <= rounded.bits;
                        fma_flags_q <= rounded.flags;
                    end
                    state <= ST_WRITE;
                end

                ST_WRITE: begin
                    fp_ew_reg_we       <= 1'b1;
                    fp_ew_reg_id       <= md_id;
                    fp_ew_reg_row_idx  <= row_cnt;
                    fp_ew_reg_beat_idx <= col_cnt;
                    fp_ew_reg_wdata    <= is_minmax ? mm_bits_q : fma_bits_q;
                    fp_ew_fflags       <= fp_ew_fflags | (is_minmax ? mm_flags_q : fma_flags_q);

                    if (col_cnt == active_N - 3'd1) begin
                        col_cnt <= '0;
                        if (row_cnt == active_M - 3'd1) begin
                            state <= ST_DONE;
                        end else begin
                            row_cnt <= row_cnt + 3'd1;
                            state   <= ST_READ;
                        end
                    end else begin
                        col_cnt <= col_cnt + 3'd1;
                        state   <= ST_READ;
                    end
                end

                ST_DONE: begin
                    fp_ew_done <= 1'b1;
                    state      <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
