`timescale 1ns / 1ps

module matrix_mac #(
    parameter int COMPUTE_ROWS = 4,
    parameter int COMPUTE_COLS = 4,
    parameter int MAX_K_INT8 = 16
)(
    input  logic        clk,
    input  logic        resetn,

    // Control
    input  logic        start_matmul,
    input  logic [31:0] pcpi_insn,
    input  logic [2:0]  ms1_reg_id,
    input  logic [2:0]  ms2_reg_id,
    input  logic [2:0]  md_acc_id,
    output logic        mac_done,

    // CSR config
    input  logic [31:0] out_mtilem,
    input  logic [31:0] out_mtilen,
    input  logic [31:0] out_mtilek,
    input  logic        out_xmsaten,

    // Write-back to regfile
    output logic        mac_reg_we,
    output logic [2:0]  mac_reg_id,
    output logic [2:0]  mac_reg_row_idx,
    output logic [2:0]  mac_reg_beat_idx,
    output logic [63:0] mac_reg_wdata,

    // Legacy scalar read ports. The systolic datapath only uses C here; A/B
    // are kept for the shared regfile read mux and waveform/debug visibility.
    output logic [2:0]  read_id_A,
    output logic [2:0]  read_row_A,
    output logic [2:0]  read_beat_A,
    input  logic [31:0] read_data_A,

    output logic [2:0]  read_id_B,
    output logic [2:0]  read_row_B,
    output logic [2:0]  read_beat_B,
    input  logic [31:0] read_data_B,

    output logic [2:0]  read_id_C,
    output logic [2:0]  read_row_C,
    output logic [2:0]  read_beat_C,
    input  logic [63:0] read_data_C,

    // Systolic boundary vector ports. A packs rows 0..3, B packs transposed-B
    // rows 0..3, where B row j holds logical B[k][j].
    output logic [2:0]   vec_read_id_A,
    output logic [11:0]  vec_read_beats_A,
    input  logic [127:0] vec_read_data_A,

    output logic [2:0]   vec_read_id_B,
    output logic [11:0]  vec_read_beats_B,
    input  logic [127:0] vec_read_data_B
);

    localparam logic [2:0] COMPUTE_ROWS_L = COMPUTE_ROWS[2:0];
    localparam logic [2:0] COMPUTE_COLS_L = COMPUTE_COLS[2:0];
    localparam logic [4:0] MAX_K_INT8_L   = MAX_K_INT8[4:0];

    // ---------------------------------------------------------------------
    // Decode only the supported packed-lite INT8->INT32 matmul variants.
    // ---------------------------------------------------------------------
    logic [3:0] func4;
    logic [2:0] size_sup;
    logic [1:0] s_size;
    logic [1:0] d_size;
    logic       is_mmaccu_w_b;
    logic       is_mmaccus_w_b;
    logic       is_mmaccsu_w_b;
    logic       is_mmacc_w_b;
    logic       is_supported_matmul;

    logic       latched_mmaccu_w_b;
    logic       latched_mmaccus_w_b;
    logic       latched_mmaccsu_w_b;
    logic       latched_mmacc_w_b;

    logic [2:0] latched_ms1_reg_id;
    logic [2:0] latched_ms2_reg_id;
    logic [2:0] latched_md_acc_id;

    always_comb begin
        func4    = pcpi_insn[31:28];
        size_sup = pcpi_insn[25:23];
        s_size   = pcpi_insn[19:18];
        d_size   = pcpi_insn[11:10];

        is_mmaccu_w_b  = (func4 == 4'b0001) && (s_size == 2'b00) && (d_size == 2'b10) && (size_sup == 3'b000);
        is_mmaccus_w_b = (func4 == 4'b0001) && (s_size == 2'b00) && (d_size == 2'b10) && (size_sup == 3'b001);
        is_mmaccsu_w_b = (func4 == 4'b0001) && (s_size == 2'b00) && (d_size == 2'b10) && (size_sup == 3'b010);
        is_mmacc_w_b   = (func4 == 4'b0001) && (s_size == 2'b00) && (d_size == 2'b10) && (size_sup == 3'b011);
        is_supported_matmul = is_mmaccu_w_b || is_mmaccus_w_b || is_mmaccsu_w_b || is_mmacc_w_b;
    end

    // ---------------------------------------------------------------------
    // Systolic 4x4 PE array.
    // A values move left-to-right, B values move top-to-bottom. Inputs are
    // skewed so A[i][k] and B[k][j] meet at PE[i][j] in the same cycle.
    // ---------------------------------------------------------------------
    typedef enum logic [2:0] {
        ST_IDLE    = 3'd0,
        ST_INIT_C  = 3'd1,
        ST_FEED    = 3'd2,
        ST_COMPUTE = 3'd3,
        ST_WRITE   = 3'd4
    } fsm_state_t;

    fsm_state_t state;

    logic [2:0] active_M;
    logic [2:0] active_N;
    logic [4:0] active_K;

    logic [2:0] M;
    logic [2:0] N;
    logic [4:0] K;

    logic [2:0] init_row;
    logic [2:0] init_col;
    logic [2:0] write_row;
    logic [2:0] write_col;
    logic [5:0] cycle_idx;
    logic [5:0] last_compute_cycle;

    logic signed [31:0] pe_acc [0:3][0:3];
    logic signed [31:0] pe_a   [0:3][0:3];
    logic signed [31:0] pe_b   [0:3][0:3];
    logic               pe_va  [0:3][0:3];
    logic               pe_vb  [0:3][0:3];

    logic signed [31:0] a_in [0:3];
    logic signed [31:0] b_in [0:3];
    logic               a_valid [0:3];
    logic               b_valid [0:3];
    logic signed [31:0] a_in_q [0:3];
    logic signed [31:0] b_in_q [0:3];
    logic               a_valid_q [0:3];
    logic               b_valid_q [0:3];

    logic [4:0] a_k0, a_k1, a_k2, a_k3;
    logic [4:0] b_k0, b_k1, b_k2, b_k3;
    logic [2:0] a_beat0, a_beat1, a_beat2, a_beat3;
    logic [2:0] b_beat0, b_beat1, b_beat2, b_beat3;

    // Debug aliases kept so the existing testbench waveform prints still
    // compile after replacing the sequential MAC.
    logic [2:0] m_idx;
    logic [2:0] n_idx;
    logic [4:0] k_idx;
    logic [1:0] byte_sel_A;
    logic [1:0] byte_sel_B;
    logic [7:0] a_byte;
    logic [7:0] b_byte;

    always_comb begin
        M = (out_mtilem == 32'd0) ? 3'd0 :
            (out_mtilem > {29'b0, COMPUTE_ROWS_L}) ? COMPUTE_ROWS_L : out_mtilem[2:0];
        N = (out_mtilen == 32'd0) ? 3'd0 :
            (out_mtilen > {29'b0, COMPUTE_COLS_L}) ? COMPUTE_COLS_L : out_mtilen[2:0];
        K = (out_mtilek == 32'd0) ? 5'd0 :
            (out_mtilek > {27'b0, MAX_K_INT8_L}) ? MAX_K_INT8_L : out_mtilek[4:0];
    end

    function automatic logic [7:0] extract_int8_from_word(
        input logic [31:0] word,
        input logic [1:0]  byte_idx
    );
        case (byte_idx)
            2'd0: extract_int8_from_word = word[7:0];
            2'd1: extract_int8_from_word = word[15:8];
            2'd2: extract_int8_from_word = word[23:16];
            default: extract_int8_from_word = word[31:24];
        endcase
    endfunction

    function automatic logic signed [31:0] widen_int8_to_i32(
        input logic [7:0] elem,
        input logic       is_unsigned
    );
        if (is_unsigned) begin
            widen_int8_to_i32 = {24'b0, elem};
        end else begin
            widen_int8_to_i32 = {{24{elem[7]}}, elem};
        end
    endfunction

    function automatic logic [31:0] vec_word(
        input logic [127:0] vec,
        input logic [1:0]   idx
    );
        case (idx)
            2'd0: vec_word = vec[31:0];
            2'd1: vec_word = vec[63:32];
            2'd2: vec_word = vec[95:64];
            default: vec_word = vec[127:96];
        endcase
    endfunction

    always_comb begin
        last_compute_cycle = {1'b0, active_K} + {3'b0, active_M} + {3'b0, active_N} - 6'd3;

        a_k0 = cycle_idx[4:0];
        a_k1 = cycle_idx[4:0] - 5'd1;
        a_k2 = cycle_idx[4:0] - 5'd2;
        a_k3 = cycle_idx[4:0] - 5'd3;
        b_k0 = cycle_idx[4:0];
        b_k1 = cycle_idx[4:0] - 5'd1;
        b_k2 = cycle_idx[4:0] - 5'd2;
        b_k3 = cycle_idx[4:0] - 5'd3;

        a_valid[0] = (active_M > 3'd0) && (a_k0 < active_K);
        a_valid[1] = (active_M > 3'd1) && (cycle_idx >= 6'd1) && (a_k1 < active_K);
        a_valid[2] = (active_M > 3'd2) && (cycle_idx >= 6'd2) && (a_k2 < active_K);
        a_valid[3] = (active_M > 3'd3) && (cycle_idx >= 6'd3) && (a_k3 < active_K);

        b_valid[0] = (active_N > 3'd0) && (b_k0 < active_K);
        b_valid[1] = (active_N > 3'd1) && (cycle_idx >= 6'd1) && (b_k1 < active_K);
        b_valid[2] = (active_N > 3'd2) && (cycle_idx >= 6'd2) && (b_k2 < active_K);
        b_valid[3] = (active_N > 3'd3) && (cycle_idx >= 6'd3) && (b_k3 < active_K);

        a_beat0 = a_valid[0] ? a_k0[4:2] : 3'd0;
        a_beat1 = a_valid[1] ? a_k1[4:2] : 3'd0;
        a_beat2 = a_valid[2] ? a_k2[4:2] : 3'd0;
        a_beat3 = a_valid[3] ? a_k3[4:2] : 3'd0;
        b_beat0 = b_valid[0] ? b_k0[4:2] : 3'd0;
        b_beat1 = b_valid[1] ? b_k1[4:2] : 3'd0;
        b_beat2 = b_valid[2] ? b_k2[4:2] : 3'd0;
        b_beat3 = b_valid[3] ? b_k3[4:2] : 3'd0;

        vec_read_id_A     = latched_ms1_reg_id;
        vec_read_beats_A  = {a_beat3, a_beat2, a_beat1, a_beat0};
        vec_read_id_B     = latched_ms2_reg_id;
        vec_read_beats_B  = {b_beat3, b_beat2, b_beat1, b_beat0};

        a_in[0] = widen_int8_to_i32(extract_int8_from_word(vec_word(vec_read_data_A, 2'd0), a_k0[1:0]),
                                    latched_mmaccu_w_b || latched_mmaccus_w_b);
        a_in[1] = widen_int8_to_i32(extract_int8_from_word(vec_word(vec_read_data_A, 2'd1), a_k1[1:0]),
                                    latched_mmaccu_w_b || latched_mmaccus_w_b);
        a_in[2] = widen_int8_to_i32(extract_int8_from_word(vec_word(vec_read_data_A, 2'd2), a_k2[1:0]),
                                    latched_mmaccu_w_b || latched_mmaccus_w_b);
        a_in[3] = widen_int8_to_i32(extract_int8_from_word(vec_word(vec_read_data_A, 2'd3), a_k3[1:0]),
                                    latched_mmaccu_w_b || latched_mmaccus_w_b);

        b_in[0] = widen_int8_to_i32(extract_int8_from_word(vec_word(vec_read_data_B, 2'd0), b_k0[1:0]),
                                    latched_mmaccu_w_b || latched_mmaccsu_w_b);
        b_in[1] = widen_int8_to_i32(extract_int8_from_word(vec_word(vec_read_data_B, 2'd1), b_k1[1:0]),
                                    latched_mmaccu_w_b || latched_mmaccsu_w_b);
        b_in[2] = widen_int8_to_i32(extract_int8_from_word(vec_word(vec_read_data_B, 2'd2), b_k2[1:0]),
                                    latched_mmaccu_w_b || latched_mmaccsu_w_b);
        b_in[3] = widen_int8_to_i32(extract_int8_from_word(vec_word(vec_read_data_B, 2'd3), b_k3[1:0]),
                                    latched_mmaccu_w_b || latched_mmaccsu_w_b);

        byte_sel_A = a_k0[1:0];
        byte_sel_B = b_k0[1:0];
        a_byte = extract_int8_from_word(vec_word(vec_read_data_A, 2'd0), byte_sel_A);
        b_byte = extract_int8_from_word(vec_word(vec_read_data_B, 2'd0), byte_sel_B);

        read_id_A   = latched_ms1_reg_id;
        read_row_A  = 3'd0;
        read_beat_A = a_beat0;
        read_id_B   = latched_ms2_reg_id;
        read_row_B  = 3'd0;
        read_beat_B = b_beat0;

        read_id_C   = latched_md_acc_id;
        read_row_C  = init_row;
        read_beat_C = init_col;

        m_idx = (state == ST_WRITE) ? write_row : init_row;
        n_idx = (state == ST_WRITE) ? write_col : init_col;
        k_idx = cycle_idx[4:0];
    end

    always_ff @(posedge clk) begin
        if (!resetn) begin
            state          <= ST_IDLE;
            active_M       <= '0;
            active_N       <= '0;
            active_K       <= '0;
            init_row       <= '0;
            init_col       <= '0;
            write_row      <= '0;
            write_col      <= '0;
            cycle_idx      <= '0;
            mac_done       <= 1'b0;
            mac_reg_we     <= 1'b0;
            mac_reg_id     <= '0;
            mac_reg_row_idx<= '0;
            mac_reg_beat_idx<= '0;
            mac_reg_wdata  <= '0;
            latched_mmaccu_w_b  <= 1'b0;
            latched_mmaccus_w_b <= 1'b0;
            latched_mmaccsu_w_b <= 1'b0;
            latched_mmacc_w_b   <= 1'b0;
            latched_ms1_reg_id  <= '0;
            latched_ms2_reg_id  <= '0;
            latched_md_acc_id   <= '0;

            for (int r = 0; r < 4; r++) begin
                for (int c = 0; c < 4; c++) begin
                    pe_acc[r][c] <= '0;
                    pe_a[r][c]   <= '0;
                            pe_b[r][c]   <= '0;
                            pe_va[r][c]  <= 1'b0;
                            pe_vb[r][c]  <= 1'b0;
                        end
                        a_in_q[r]     <= '0;
                        b_in_q[r]     <= '0;
                        a_valid_q[r]  <= 1'b0;
                        b_valid_q[r]  <= 1'b0;
                    end
                end else begin
            mac_done   <= 1'b0;
            mac_reg_we <= 1'b0;

            case (state)
                ST_IDLE: begin
                    init_row  <= '0;
                    init_col  <= '0;
                    write_row <= '0;
                    write_col <= '0;
                    cycle_idx <= '0;

                    for (int r = 0; r < 4; r++) begin
                        for (int c = 0; c < 4; c++) begin
                            pe_acc[r][c] <= '0;
                            pe_a[r][c]   <= '0;
                            pe_b[r][c]   <= '0;
                            pe_va[r][c]  <= 1'b0;
                            pe_vb[r][c]  <= 1'b0;
                        end
                        a_in_q[r]     <= '0;
                        b_in_q[r]     <= '0;
                        a_valid_q[r]  <= 1'b0;
                        b_valid_q[r]  <= 1'b0;
                    end

                    if (start_matmul && is_supported_matmul) begin
                        latched_mmaccu_w_b  <= is_mmaccu_w_b;
                        latched_mmaccus_w_b <= is_mmaccus_w_b;
                        latched_mmaccsu_w_b <= is_mmaccsu_w_b;
                        latched_mmacc_w_b   <= is_mmacc_w_b;
                        latched_ms1_reg_id  <= ms1_reg_id;
                        latched_ms2_reg_id  <= ms2_reg_id;
                        latched_md_acc_id   <= md_acc_id;
                        active_M <= M;
                        active_N <= N;
                        active_K <= K;

                        if ((M == 0) || (N == 0) || (K == 0)) begin
                            mac_done <= 1'b1;
                        end else begin
                            state <= ST_INIT_C;
                        end
                    end else if (start_matmul) begin
                        mac_done <= 1'b1;
                    end
                end

                ST_INIT_C: begin
                    pe_acc[init_row][init_col] <= read_data_C[31:0];

                    if (init_col == active_N - 3'd1) begin
                        init_col <= '0;
                        if (init_row == active_M - 3'd1) begin
                            init_row  <= '0;
                            cycle_idx <= '0;
                            state     <= ST_FEED;
                        end else begin
                            init_row <= init_row + 3'd1;
                        end
                    end else begin
                        init_col <= init_col + 3'd1;
                    end
                end

                ST_FEED: begin
                    for (int i = 0; i < 4; i++) begin
                        a_in_q[i]    <= a_in[i];
                        b_in_q[i]    <= b_in[i];
                        a_valid_q[i] <= a_valid[i];
                        b_valid_q[i] <= b_valid[i];
                    end
                    state <= ST_COMPUTE;
                end

                ST_COMPUTE: begin
                    for (int r = 0; r < 4; r++) begin
                        for (int c = 0; c < 4; c++) begin
                            logic signed [31:0] next_a;
                            logic signed [31:0] next_b;
                            logic next_va;
                            logic next_vb;

                            if (c == 0) begin
                                next_a  = a_in_q[r];
                                next_va = a_valid_q[r];
                            end else begin
                                next_a  = pe_a[r][c-1];
                                next_va = pe_va[r][c-1];
                            end

                            if (r == 0) begin
                                next_b  = b_in_q[c];
                                next_vb = b_valid_q[c];
                            end else begin
                                next_b  = pe_b[r-1][c];
                                next_vb = pe_vb[r-1][c];
                            end

                            pe_a[r][c]  <= next_a;
                            pe_b[r][c]  <= next_b;
                            pe_va[r][c] <= next_va;
                            pe_vb[r][c] <= next_vb;

                            if (next_va && next_vb) begin
                                pe_acc[r][c] <= pe_acc[r][c] + (next_a * next_b);
                            end
                        end
                    end

                    if (cycle_idx == last_compute_cycle) begin
                        write_row <= '0;
                        write_col <= '0;
                        state     <= ST_WRITE;
                    end else begin
                        cycle_idx <= cycle_idx + 6'd1;
                        state     <= ST_FEED;
                    end
                end

                ST_WRITE: begin
                    mac_reg_we       <= 1'b1;
                    mac_reg_id       <= latched_md_acc_id;
                    mac_reg_row_idx  <= write_row;
                    mac_reg_beat_idx <= write_col;
                    mac_reg_wdata    <= {32'b0, pe_acc[write_row][write_col]};

                    if (write_col == active_N - 3'd1) begin
                        write_col <= '0;
                        if (write_row == active_M - 3'd1) begin
                            mac_done <= 1'b1;
                            state    <= ST_IDLE;
                        end else begin
                            write_row <= write_row + 3'd1;
                        end
                    end else begin
                        write_col <= write_col + 3'd1;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
