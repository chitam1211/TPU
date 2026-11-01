`timescale 1ns / 1ps

// DiP-style matrix MAC for the RV32I matrix-core experiment.
//
// This module keeps the same external contract as matrix_mac.sv, but replaces
// the MAC datapath with a Diagonal-Input / Permutated weight-stationary flow
// (KC = int8 elements per 32-bit beat):
//
//   1. B is loaded into a local PE weight array after column-dependent
//      permutation:
//          weight_pe[pr][c] = B[k_base + ((c + pr) mod KC)][c]
//
//   2. A rows enter the first PE row as a KC-lane vector. When the vector moves
//      to the next PE row, it rotates left by one lane. Therefore PE row pr and
//      column c see A[k_base + ((c + pr) mod KC)].
//
//   3. Partial sums move vertically down each column. The result is accumulated
//      into pe_acc only when the partial sum exits the bottom PE row.
//
// For active_K > KC (int8 elements per 32-bit beat), the K dimension is tiled
// into KC-wide DiP chunks. Each chunk reloads a permuted KC x N weight tile and
// accumulates into the same C tile.
module matrix_mac_int
    import matrix_cfg_pkg::*;
#(
    parameter int COMPUTE_ROWS = TMMAX,
    parameter int COMPUTE_COLS = TNMAX,
    parameter int MAX_K_INT8 = TKMAX_INT8,
    localparam int KC        = INT8_PER_WORD,                  // DiP chunk = PE rows
    localparam int K_CHUNKS  = (MAX_K_INT8 + KC - 1) / KC,     // A/B beats per row
    localparam int LOAD_ROWS = max2(COMPUTE_ROWS, COMPUTE_COLS),
    localparam int RF_ROW_W  = idx_w(LOAD_ROWS),
    localparam int RF_BEAT_W = idx_w(max2(COMPUTE_COLS, K_CHUNKS))
)(
    input  logic        clk,
    input  logic        resetn,

    // Control
    input  logic                 start_matmul,
    input  logic [31:0]          matrix_insn,
    input  logic [REG_ID_W-1:0]  ms1_reg_id,
    input  logic [REG_ID_W-1:0]  ms2_reg_id,
    input  logic [REG_ID_W-1:0]  md_acc_id,
    output logic                 mac_done,
    output logic                 mac_illegal,

    // CSR config
    input  logic [31:0] out_mtilem,
    input  logic [31:0] out_mtilen,
    input  logic [31:0] out_mtilek,
    input  logic        out_xmsaten,

    // Write-back to regfile
    output logic                 mac_reg_we,
    output logic [REG_ID_W-1:0]  mac_reg_id,
    output logic [RF_ROW_W-1:0]  mac_reg_row_idx,
    output logic [RF_BEAT_W-1:0] mac_reg_beat_idx,
    output logic [31:0]          mac_reg_wdata,

    // Legacy scalar read ports. They are kept for compatibility and debug.
    output logic [REG_ID_W-1:0]  read_id_A,
    output logic [RF_ROW_W-1:0]  read_row_A,
    output logic [RF_BEAT_W-1:0] read_beat_A,
    input  logic [31:0]          read_data_A,

    output logic [REG_ID_W-1:0]  read_id_B,
    output logic [RF_ROW_W-1:0]  read_row_B,
    output logic [RF_BEAT_W-1:0] read_beat_B,
    input  logic [31:0]          read_data_B,

    output logic [REG_ID_W-1:0]  read_id_C,
    output logic [RF_ROW_W-1:0]  read_row_C,
    output logic [RF_BEAT_W-1:0] read_beat_C,
    input  logic [31:0]          read_data_C,

    // Vector ports: every register row is read at the same beat (chunk_idx).
    // Packed data order is {row(LOAD_ROWS-1), ..., row1, row0} as in matrix_regfile.
    output logic [REG_ID_W-1:0]      vec_read_id_A,
    output logic [RF_BEAT_W-1:0]     vec_read_beat_A,
    input  logic [LOAD_ROWS*32-1:0]  vec_read_data_A,

    output logic [REG_ID_W-1:0]      vec_read_id_B,
    output logic [RF_BEAT_W-1:0]     vec_read_beat_B,
    input  logic [LOAD_ROWS*32-1:0]  vec_read_data_B
);

    typedef enum logic [2:0] {
        ST_IDLE       = 3'd0,
        ST_INIT_C     = 3'd1,
        ST_LOAD_W     = 3'd2,
        ST_CLEAR_PIPE = 3'd3,
        ST_DIP_RUN    = 3'd4,
        ST_WRITE      = 3'd5,
        ST_DONE       = 3'd6
    } fsm_state_t;

    fsm_state_t state;

    // active_* hold 0..COMPUTE_ROWS/COLS/MAX_K_INT8; *_I_W index below them.
    localparam int M_W      = cnt_w(COMPUTE_ROWS);
    localparam int N_W      = cnt_w(COMPUTE_COLS);
    localparam int K_W      = cnt_w(MAX_K_INT8);
    localparam int M_I_W    = idx_w(COMPUTE_ROWS);
    localparam int N_I_W    = idx_w(COMPUTE_COLS);
    localparam int K_I_W    = idx_w(MAX_K_INT8);
    localparam int CHUNK_W  = idx_w(K_CHUNKS);
    localparam int NCHUNK_W = cnt_w(K_CHUNKS);
    localparam int LANE_W   = idx_w(KC);
    // dip_cycle runs 0..active_M + KC - 1 (inject M rows, drain KC PE rows).
    localparam int CYCLE_W  = cnt_w(COMPUTE_ROWS + KC - 1);

    logic [3:0] func4;
    logic [2:0] size_sup;
    logic [1:0] s_size;
    logic [1:0] d_size;
    logic       is_mmaccu_w_b;
    logic       is_mmaccus_w_b;
    logic       is_mmaccsu_w_b;
    logic       is_mmacc_w_b;
    logic       illegal_inst;

    logic                latched_mmaccu_w_b;
    logic                latched_mmaccus_w_b;
    logic                latched_mmaccsu_w_b;
    logic [REG_ID_W-1:0] latched_ms1_reg_id;
    logic [REG_ID_W-1:0] latched_ms2_reg_id;
    logic [REG_ID_W-1:0] latched_md_acc_id;

    logic [M_W-1:0] active_M;
    logic [N_W-1:0] active_N;
    logic [K_W-1:0] active_K;

    logic [M_I_W-1:0]    init_row;
    logic [N_I_W-1:0]    init_col;
    logic [M_I_W-1:0]    write_row;
    logic [N_I_W-1:0]    write_col;
    logic [CHUNK_W-1:0]  chunk_idx;
    logic [NCHUNK_W-1:0] num_chunks;
    logic [CYCLE_W-1:0]  dip_cycle;
    logic [CYCLE_W-1:0]  dip_last_cycle;

    // PE array: KC rows (one K lane each) x COMPUTE_COLS columns.
    logic signed [31:0] pe_acc    [0:COMPUTE_ROWS-1][0:COMPUTE_COLS-1];
    logic signed [31:0] weight_pe [0:KC-1][0:COMPUTE_COLS-1];
    logic signed [31:0] a_pipe    [0:KC-1][0:KC-1];
    logic signed [31:0] psum_pipe [0:KC-1][0:COMPUTE_COLS-1];
    logic               pipe_valid[0:KC-1];
    logic [M_I_W-1:0]   pipe_row  [0:KC-1];

    logic signed [31:0] inject_a [0:KC-1];
    logic [M_I_W-1:0]   a_read_row;
    logic               inject_valid;

    // Debug aliases used by existing waveform print snippets.
    logic [M_I_W-1:0]  m_idx;
    logic [N_I_W-1:0]  n_idx;
    logic [K_I_W-1:0]  k_idx;
    logic [LANE_W-1:0] byte_sel_A;
    logic [LANE_W-1:0] byte_sel_B;
    logic [7:0] a_byte;
    logic [7:0] b_byte;

    always_comb begin
        func4    = matrix_insn[31:28];
        size_sup = matrix_insn[25:23];
        s_size   = matrix_insn[19:18];
        d_size   = matrix_insn[11:10];

        is_mmaccu_w_b  = (func4 == 4'b0001) && (s_size == 2'b00) && (d_size == 2'b10) && (size_sup == 3'b000);
        is_mmaccus_w_b = (func4 == 4'b0001) && (s_size == 2'b00) && (d_size == 2'b10) && (size_sup == 3'b001);
        is_mmaccsu_w_b = (func4 == 4'b0001) && (s_size == 2'b00) && (d_size == 2'b10) && (size_sup == 3'b010);
        is_mmacc_w_b   = (func4 == 4'b0001) && (s_size == 2'b00) && (d_size == 2'b10) && (size_sup == 3'b011);
    end

    // Validate each decoded instruction family before narrowing CSR values.
    // New instructions with different operand rules belong in separate branches.
    always_comb begin
        illegal_inst = 1'b1;
        case (1'b1)
            is_mmaccu_w_b,
            is_mmaccus_w_b,
            is_mmaccsu_w_b,
            is_mmacc_w_b: begin
                illegal_inst =
                    (out_mtilem > COMPUTE_ROWS) ||
                    (out_mtilen > COMPUTE_COLS) ||
                    (out_mtilek > MAX_K_INT8) ||
                    ms1_reg_id[REG_ID_W-1] || ms2_reg_id[REG_ID_W-1] || !md_acc_id[REG_ID_W-1];
            end
            default: illegal_inst = 1'b1;
        endcase
    end

    function automatic logic [7:0] extract_int8_from_word(
        input logic [31:0]       word,
        input logic [LANE_W-1:0] byte_idx
    );
        extract_int8_from_word = word[byte_idx*8 +: 8];
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
        input logic [LOAD_ROWS*32-1:0] vec,
        input int                      idx
    );
        vec_word = vec[idx*32 +: 32];
    endfunction

    always_comb begin
        num_chunks     = NCHUNK_W'((int'(active_K) + KC - 1) / KC);
        dip_last_cycle = CYCLE_W'(int'(active_M) + KC - 1);
        a_read_row     = M_I_W'(dip_cycle);
        inject_valid   = (dip_cycle < active_M);

        vec_read_id_A   = latched_ms1_reg_id;
        vec_read_beat_A = RF_BEAT_W'(chunk_idx);

        vec_read_id_B   = latched_ms2_reg_id;
        vec_read_beat_B = RF_BEAT_W'(chunk_idx);

        for (int lane = 0; lane < KC; lane++) begin
            inject_a[lane] = widen_int8_to_i32(
                extract_int8_from_word(vec_word(vec_read_data_A, a_read_row), LANE_W'(lane)),
                latched_mmaccu_w_b || latched_mmaccus_w_b
            );
        end

        read_id_A   = latched_ms1_reg_id;
        read_row_A  = RF_ROW_W'(a_read_row);
        read_beat_A = RF_BEAT_W'(chunk_idx);
        read_id_B   = latched_ms2_reg_id;
        read_row_B  = '0;
        read_beat_B = RF_BEAT_W'(chunk_idx);

        read_id_C   = latched_md_acc_id;
        read_row_C  = RF_ROW_W'(init_row);
        read_beat_C = RF_BEAT_W'(init_col);

        m_idx      = (state == ST_WRITE) ? write_row : a_read_row;
        n_idx      = (state == ST_WRITE) ? write_col : '0;
        k_idx      = K_I_W'(chunk_idx * KC);
        byte_sel_A = '0;
        byte_sel_B = '0;
        a_byte     = extract_int8_from_word(vec_word(vec_read_data_A, a_read_row), '0);
        b_byte     = extract_int8_from_word(vec_word(vec_read_data_B, 0), '0);
    end

    always_ff @(posedge clk) begin
        if (!resetn) begin
            state            <= ST_IDLE;
            active_M         <= '0;
            active_N         <= '0;
            active_K         <= '0;
            init_row         <= '0;
            init_col         <= '0;
            write_row        <= '0;
            write_col        <= '0;
            chunk_idx        <= '0;
            dip_cycle        <= '0;
            mac_done         <= 1'b0;
            mac_illegal      <= 1'b0;
            mac_reg_we       <= 1'b0;
            mac_reg_id       <= '0;
            mac_reg_row_idx  <= '0;
            mac_reg_beat_idx <= '0;
            mac_reg_wdata    <= '0;
            latched_mmaccu_w_b  <= 1'b0;
            latched_mmaccus_w_b <= 1'b0;
            latched_mmaccsu_w_b <= 1'b0;
            latched_ms1_reg_id  <= '0;
            latched_ms2_reg_id  <= '0;
            latched_md_acc_id   <= '0;

            for (int r = 0; r < COMPUTE_ROWS; r++) begin
                for (int c = 0; c < COMPUTE_COLS; c++) begin
                    pe_acc[r][c] <= '0;
                end
            end
            for (int r = 0; r < KC; r++) begin
                pipe_valid[r] <= 1'b0;
                pipe_row[r]   <= '0;
                for (int c = 0; c < COMPUTE_COLS; c++) begin
                    weight_pe[r][c] <= '0;
                    psum_pipe[r][c] <= '0;
                end
                for (int l = 0; l < KC; l++) begin
                    a_pipe[r][l] <= '0;
                end
            end
        end
        else begin
            mac_done   <= 1'b0;
            mac_reg_we <= 1'b0;

            case (state)
                ST_IDLE: begin
                    init_row  <= '0;
                    init_col  <= '0;
                    write_row <= '0;
                    write_col <= '0;
                    chunk_idx <= '0;
                    dip_cycle <= '0;

                    for (int r = 0; r < COMPUTE_ROWS; r++) begin
                        for (int c = 0; c < COMPUTE_COLS; c++) begin
                            pe_acc[r][c] <= '0;
                        end
                    end
                    for (int r = 0; r < KC; r++) begin
                        pipe_valid[r] <= 1'b0;
                        pipe_row[r]   <= '0;
                        for (int c = 0; c < COMPUTE_COLS; c++) begin
                            weight_pe[r][c] <= '0;
                            psum_pipe[r][c] <= '0;
                        end
                        for (int l = 0; l < KC; l++) begin
                            a_pipe[r][l] <= '0;
                        end
                    end

                    if (start_matmul) begin
                        mac_illegal <= 1'b0;
                        latched_mmaccu_w_b  <= is_mmaccu_w_b;
                        latched_mmaccus_w_b <= is_mmaccus_w_b;
                        latched_mmaccsu_w_b <= is_mmaccsu_w_b;
                        latched_ms1_reg_id  <= ms1_reg_id;
                        latched_ms2_reg_id  <= ms2_reg_id;
                        latched_md_acc_id   <= md_acc_id;
                        if (illegal_inst) begin
                            mac_illegal <= 1'b1;
                            state <= ST_DONE;
                        end else if ((out_mtilem == 0) || (out_mtilen == 0) ||
                                     (out_mtilek == 0)) begin
                            state <= ST_DONE;
                        end
                        else begin
                            active_M <= out_mtilem[M_W-1:0];
                            active_N <= out_mtilen[N_W-1:0];
                            active_K <= out_mtilek[K_W-1:0];
                            state <= ST_INIT_C;
                        end
                    end
                end

                ST_INIT_C: begin
                    pe_acc[init_row][init_col] <= read_data_C[31:0];

                    if (init_col == active_N - 1'b1) begin
                        init_col <= '0;
                        if (init_row == active_M - 1'b1) begin
                            init_row  <= '0;
                            chunk_idx <= '0;
                            state     <= ST_LOAD_W;
                        end else begin
                            init_row <= init_row + 1'b1;
                        end
                    end else begin
                        init_col <= init_col + 1'b1;
                    end
                end

                ST_LOAD_W: begin
                    // Runtime version of the DiP weight permutation. The paper
                    // can do this in software; here we do it while loading B.
                    for (int pr = 0; pr < KC; pr++) begin
                        for (int c = 0; c < COMPUTE_COLS; c++) begin
                            int k_local;
                            int k_global;
                            k_local  = (c + pr) % KC;
                            k_global = int'(chunk_idx) * KC + k_local;

                            if ((c < active_N) && (k_global < active_K)) begin
                                weight_pe[pr][c] <= widen_int8_to_i32(
                                    extract_int8_from_word(vec_word(vec_read_data_B, c), LANE_W'(k_local)),
                                    latched_mmaccu_w_b || latched_mmaccsu_w_b
                                );
                            end else begin
                                weight_pe[pr][c] <= '0;
                            end
                        end
                    end
                    state <= ST_CLEAR_PIPE;
                end

                ST_CLEAR_PIPE: begin
                    dip_cycle <= '0;
                    for (int r = 0; r < KC; r++) begin
                        pipe_valid[r] <= 1'b0;
                        pipe_row[r]   <= '0;
                        for (int c = 0; c < COMPUTE_COLS; c++) begin
                            psum_pipe[r][c] <= '0;
                        end
                        for (int l = 0; l < KC; l++) begin
                            a_pipe[r][l] <= '0;
                        end
                    end
                    state <= ST_DIP_RUN;
                end

                ST_DIP_RUN: begin
                    // PE (pr, c) multiplies A lane (c mod KC) by its weight:
                    // both hold element k_base + ((c + pr) mod KC).
                    // Bottom row drains a completed partial sum into C.
                    if (pipe_valid[KC-1]) begin
                        for (int c = 0; c < COMPUTE_COLS; c++) begin
                            if (c < active_N) begin
                                pe_acc[pipe_row[KC-1]][c] <= pe_acc[pipe_row[KC-1]][c]
                                    + psum_pipe[KC-1][c]
                                    + (a_pipe[KC-1][c % KC] * weight_pe[KC-1][c]);
                            end
                        end
                    end

                    // Vertical psum flow and diagonal/rotating input movement.
                    for (int r = KC-1; r > 0; r--) begin
                        pipe_valid[r] <= pipe_valid[r-1];
                        pipe_row[r]   <= pipe_row[r-1];
                        for (int c = 0; c < COMPUTE_COLS; c++) begin
                            if (pipe_valid[r-1]) begin
                                psum_pipe[r][c] <= psum_pipe[r-1][c]
                                    + (a_pipe[r-1][c % KC] * weight_pe[r-1][c]);
                            end else begin
                                psum_pipe[r][c] <= '0;
                            end
                        end
                        for (int l = 0; l < KC; l++) begin
                            a_pipe[r][l] <= a_pipe[r-1][(l + 1) % KC];
                        end
                    end

                    // Top row injection. Each input row enters unrotated; the
                    // diagonal links rotate it between PE rows.
                    pipe_valid[0] <= inject_valid;
                    pipe_row[0]   <= a_read_row;
                    for (int c = 0; c < COMPUTE_COLS; c++) begin
                        psum_pipe[0][c] <= '0;
                    end
                    for (int l = 0; l < KC; l++) begin
                        a_pipe[0][l] <= inject_valid ? inject_a[l] : '0;
                    end

                    if (dip_cycle == dip_last_cycle) begin
                        if (chunk_idx == num_chunks - 1'b1) begin
                            write_row <= '0;
                            write_col <= '0;
                            state     <= ST_WRITE;
                        end else begin
                            chunk_idx <= chunk_idx + 1'b1;
                            state     <= ST_LOAD_W;
                        end
                    end else begin
                        dip_cycle <= dip_cycle + 1'b1;
                    end
                end

                ST_WRITE: begin
                    mac_reg_we       <= 1'b1;
                    mac_reg_id       <= latched_md_acc_id;
                    mac_reg_row_idx  <= RF_ROW_W'(write_row);
                    mac_reg_beat_idx <= RF_BEAT_W'(write_col);
                    mac_reg_wdata    <= pe_acc[write_row][write_col];

                    if (write_col == active_N - 1'b1) begin
                        write_col <= '0;
                        if (write_row == active_M - 1'b1) begin
                            mac_done <= 1'b1;
                            state    <= ST_IDLE;
                        end else begin
                            write_row <= write_row + 1'b1;
                        end
                    end else begin
                        write_col <= write_col + 1'b1;
                    end
                end

                ST_DONE: begin
                    mac_done <= 1'b1;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
