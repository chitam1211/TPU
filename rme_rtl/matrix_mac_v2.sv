`timescale 1ns / 1ps

// DiP-style matrix MAC for the RV32I matrix-core experiment.
//
// This module keeps the same external contract as matrix_mac.sv, but replaces
// the MAC datapath with a Diagonal-Input / Permutated weight-stationary flow:
//
//   1. B is loaded into a local PE weight array after column-dependent
//      permutation:
//          weight_pe[pr][c] = B[k_base + ((c + pr) mod 4)][c]
//
//   2. A rows enter the first PE row as a 4-lane vector. When the vector moves
//      to the next PE row, it rotates left by one lane. Therefore PE row pr and
//      column c see A[k_base + ((c + pr) mod 4)].
//
//   3. Partial sums move vertically down each column. The result is accumulated
//      into pe_acc only when the partial sum exits the bottom PE row.
//
// For active_K > 4, the K dimension is tiled into 4-wide DiP chunks. Each chunk
// reloads a permuted 4x4 weight tile and accumulates into the same C tile.
module matrix_mac_v2 #(
    parameter int COMPUTE_ROWS = 4,
    parameter int COMPUTE_COLS = 4,
    parameter int MAX_K_INT8 = 16
)(
    input  logic        clk,
    input  logic        resetn,

    // Control
    input  logic        start_matmul,
    input  logic [31:0] matrix_insn,
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

    // Legacy scalar read ports. They are kept for compatibility and debug.
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

    // Vector ports: packed order is row3,row2,row1,row0 in matrix_regfile.
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

    typedef enum logic [2:0] {
        ST_IDLE       = 3'd0,
        ST_INIT_C     = 3'd1,
        ST_LOAD_W     = 3'd2,
        ST_CLEAR_PIPE = 3'd3,
        ST_DIP_RUN    = 3'd4,
        ST_WRITE      = 3'd5
    } fsm_state_t;

    fsm_state_t state;

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
    logic [2:0] chunk_idx;
    logic [2:0] num_chunks;
    logic [5:0] dip_cycle;
    logic [5:0] dip_last_cycle;

    logic signed [31:0] pe_acc    [0:3][0:3];
    logic signed [31:0] weight_pe [0:3][0:3];
    logic signed [31:0] a_pipe    [0:3][0:3];
    logic signed [31:0] psum_pipe [0:3][0:3];
    logic               pipe_valid[0:3];
    logic [2:0]         pipe_row  [0:3];

    logic signed [31:0] inject_a [0:3];
    logic [2:0]         a_read_row;
    logic               inject_valid;

    // Debug aliases used by existing waveform print snippets.
    logic [2:0] m_idx;
    logic [2:0] n_idx;
    logic [4:0] k_idx;
    logic [1:0] byte_sel_A;
    logic [1:0] byte_sel_B;
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
        is_supported_matmul = is_mmaccu_w_b || is_mmaccus_w_b || is_mmaccsu_w_b || is_mmacc_w_b;
    end

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

    function automatic logic [2:0] ceil_div4_5b(input logic [4:0] value);
        ceil_div4_5b = value[4:2] + ((value[1:0] != 2'b00) ? 3'd1 : 3'd0);
    endfunction

    function automatic logic [1:0] add_mod4(
        input logic [1:0] a,
        input logic [1:0] b
    );
        add_mod4 = a + b;
    endfunction

    always_comb begin
        num_chunks = ceil_div4_5b(active_K);
        dip_last_cycle = {3'b0, active_M} + 6'd3;
        a_read_row = dip_cycle[2:0];
        inject_valid = (dip_cycle < {3'b0, active_M});

        vec_read_id_A    = latched_ms1_reg_id;
        vec_read_beats_A = {chunk_idx, chunk_idx, chunk_idx, chunk_idx};

        vec_read_id_B    = latched_ms2_reg_id;
        vec_read_beats_B = {chunk_idx, chunk_idx, chunk_idx, chunk_idx};

        for (int lane = 0; lane < 4; lane++) begin
            inject_a[lane] = widen_int8_to_i32(
                extract_int8_from_word(vec_word(vec_read_data_A, a_read_row[1:0]), lane[1:0]),
                latched_mmaccu_w_b || latched_mmaccus_w_b
            );
        end

        read_id_A   = latched_ms1_reg_id;
        read_row_A  = a_read_row;
        read_beat_A = chunk_idx;
        read_id_B   = latched_ms2_reg_id;
        read_row_B  = 3'd0;
        read_beat_B = chunk_idx;

        read_id_C   = latched_md_acc_id;
        read_row_C  = init_row;
        read_beat_C = init_col;

        m_idx      = (state == ST_WRITE) ? write_row : a_read_row;
        n_idx      = (state == ST_WRITE) ? write_col : 3'd0;
        k_idx      = {chunk_idx, 2'b00};
        byte_sel_A = 2'd0;
        byte_sel_B = 2'd0;
        a_byte     = extract_int8_from_word(vec_word(vec_read_data_A, a_read_row[1:0]), 2'd0);
        b_byte     = extract_int8_from_word(vec_word(vec_read_data_B, 2'd0), 2'd0);
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
            mac_reg_we       <= 1'b0;
            mac_reg_id       <= '0;
            mac_reg_row_idx  <= '0;
            mac_reg_beat_idx <= '0;
            mac_reg_wdata    <= '0;
            latched_mmaccu_w_b  <= 1'b0;
            latched_mmaccus_w_b <= 1'b0;
            latched_mmaccsu_w_b <= 1'b0;
            latched_mmacc_w_b   <= 1'b0;
            latched_ms1_reg_id  <= '0;
            latched_ms2_reg_id  <= '0;
            latched_md_acc_id   <= '0;

            for (int r = 0; r < 4; r++) begin
                pipe_valid[r] <= 1'b0;
                pipe_row[r]   <= '0;
                for (int c = 0; c < 4; c++) begin
                    pe_acc[r][c]    <= '0;
                    weight_pe[r][c] <= '0;
                    a_pipe[r][c]    <= '0;
                    psum_pipe[r][c] <= '0;
                end
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
                    chunk_idx <= '0;
                    dip_cycle <= '0;

                    for (int r = 0; r < 4; r++) begin
                        pipe_valid[r] <= 1'b0;
                        pipe_row[r]   <= '0;
                        for (int c = 0; c < 4; c++) begin
                            pe_acc[r][c]    <= '0;
                            weight_pe[r][c] <= '0;
                            a_pipe[r][c]    <= '0;
                            psum_pipe[r][c] <= '0;
                        end
                    end

                    if (start_matmul && is_supported_matmul) begin
                        latched_mmaccu_w_b  <= is_mmaccu_w_b;
                        latched_mmaccus_w_b <= is_mmaccus_w_b;
                        latched_mmaccsu_w_b <= is_mmaccsu_w_b;
                        latched_mmacc_w_b   <= is_mmacc_w_b;
                        latched_ms1_reg_id  <= ms1_reg_id;
                        latched_ms2_reg_id  <= ms2_reg_id;
                        latched_md_acc_id   <= md_acc_id;
                        active_M            <= M;
                        active_N            <= N;
                        active_K            <= K;

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
                            chunk_idx <= '0;
                            state     <= ST_LOAD_W;
                        end else begin
                            init_row <= init_row + 3'd1;
                        end
                    end else begin
                        init_col <= init_col + 3'd1;
                    end
                end

                ST_LOAD_W: begin
                    // Runtime version of the DiP weight permutation. The paper
                    // can do this in software; here we do it while loading B.
                    for (int pr = 0; pr < 4; pr++) begin
                        for (int c = 0; c < 4; c++) begin
                            logic [1:0] k_local;
                            logic [4:0] k_global;
                            k_local  = add_mod4(c[1:0], pr[1:0]);
                            k_global = {chunk_idx, 2'b00} + {3'b0, k_local};

                            if ((c[2:0] < active_N) && (k_global < active_K)) begin
                                weight_pe[pr][c] <= widen_int8_to_i32(
                                    extract_int8_from_word(vec_word(vec_read_data_B, c[1:0]), k_local),
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
                    for (int r = 0; r < 4; r++) begin
                        pipe_valid[r] <= 1'b0;
                        pipe_row[r]   <= '0;
                        for (int c = 0; c < 4; c++) begin
                            a_pipe[r][c]    <= '0;
                            psum_pipe[r][c] <= '0;
                        end
                    end
                    state <= ST_DIP_RUN;
                end

                ST_DIP_RUN: begin
                    // Bottom row drains a completed partial sum into C.
                    if (pipe_valid[3]) begin
                        for (int c = 0; c < 4; c++) begin
                            if (c[2:0] < active_N) begin
                                pe_acc[pipe_row[3]][c] <= pe_acc[pipe_row[3]][c]
                                    + psum_pipe[3][c]
                                    + (a_pipe[3][c] * weight_pe[3][c]);
                            end
                        end
                    end

                    // Vertical psum flow and diagonal/rotating input movement.
                    for (int r = 3; r > 0; r--) begin
                        pipe_valid[r] <= pipe_valid[r-1];
                        pipe_row[r]   <= pipe_row[r-1];
                        for (int c = 0; c < 4; c++) begin
                            if (pipe_valid[r-1]) begin
                                psum_pipe[r][c] <= psum_pipe[r-1][c]
                                    + (a_pipe[r-1][c] * weight_pe[r-1][c]);
                            end else begin
                                psum_pipe[r][c] <= '0;
                            end
                            a_pipe[r][c] <= a_pipe[r-1][add_mod4(c[1:0], 2'd1)];
                        end
                    end

                    // Top row injection. Each input row enters unrotated; the
                    // diagonal links rotate it between PE rows.
                    pipe_valid[0] <= inject_valid;
                    pipe_row[0]   <= a_read_row;
                    for (int c = 0; c < 4; c++) begin
                        a_pipe[0][c]    <= inject_valid ? inject_a[c] : '0;
                        psum_pipe[0][c] <= '0;
                    end

                    if (dip_cycle == dip_last_cycle) begin
                        if (chunk_idx == num_chunks - 3'd1) begin
                            write_row <= '0;
                            write_col <= '0;
                            state     <= ST_WRITE;
                        end else begin
                            chunk_idx <= chunk_idx + 3'd1;
                            state     <= ST_LOAD_W;
                        end
                    end else begin
                        dip_cycle <= dip_cycle + 6'd1;
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
