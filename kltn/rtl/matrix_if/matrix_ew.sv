`timescale 1ns / 1ps

module matrix_ew
    import matrix_cfg_pkg::*;
#(
    parameter int MATRIX_DIM = ROWNUM,
    parameter int BEATS_PER_ROW = TR_BEATS,
    localparam int RF_ROW_W  = idx_w(MATRIX_DIM),
    localparam int RF_BEAT_W = idx_w(BEATS_PER_ROW)
)(
    input  logic        clk,
    input  logic        resetn,

    input  logic        start_ew,
    input  logic [31:0] matrix_insn,
    input  logic        out_xmsaten,
    input  logic [31:0] out_mtilem,
    input  logic [31:0] out_mtilen,

    output logic        ew_done,
    output logic        ew_illegal,

    // Regfile write port
    output logic                 ew_reg_we,
    output logic [REG_ID_W-1:0]  ew_reg_id,
    output logic [RF_ROW_W-1:0]  ew_reg_row_idx,
    output logic [RF_BEAT_W-1:0] ew_reg_beat_idx,
    output logic [31:0]          ew_reg_wdata,

    // Regfile read ports
    output logic [REG_ID_W-1:0]  read_id_A,
    output logic [RF_ROW_W-1:0]  read_row_A,
    output logic [RF_BEAT_W-1:0] read_beat_A,
    input  logic [31:0]          read_data_A,

    output logic [REG_ID_W-1:0]  read_id_B,
    output logic [RF_ROW_W-1:0]  read_row_B,
    output logic [RF_BEAT_W-1:0] read_beat_B,
    input  logic [31:0]          read_data_B
);

    typedef enum logic [2:0] {
        ST_IDLE     = 3'd0,
        ST_SNAPSHOT = 3'd1,
        ST_READ     = 3'd2,
        ST_EXEC     = 3'd3,
        ST_WRITE    = 3'd4,
        ST_DONE     = 3'd5
    } fsm_state_t;

    fsm_state_t state;

    // active_M/active_N hold 0..MATRIX_DIM / 0..BEATS_PER_ROW, so one bit
    // wider than the row/beat index.
    localparam int M_W = cnt_w(MATRIX_DIM);
    localparam int N_W = cnt_w(BEATS_PER_ROW);
    localparam logic [31:0] INT32_MAX       = 32'h7FFF_FFFF;
    localparam logic [31:0] INT32_MIN       = 32'h8000_0000;
    localparam logic signed [63:0] INT32_MAX_S64 = 64'sh0000_0000_7FFF_FFFF;
    localparam logic signed [63:0] INT32_MIN_S64 = -64'sh0000_0000_8000_0000;

    // Latched decode/config fields
    logic [3:0] func4;
    logic [2:0] ctrl;
    logic [REG_ID_W-1:0] ms1_id;
    logic [REG_ID_W-1:0] ms2_id;
    logic [REG_ID_W-1:0] md_id;
    logic [M_W-1:0] active_M;
    logic [N_W-1:0] active_N;
    logic       sat_en_q;

    // Loop and pipeline registers
    logic [RF_ROW_W-1:0]  row_cnt;
    logic [RF_BEAT_W-1:0] col_cnt;
    logic [RF_ROW_W-1:0]  op_row_q;
    logic [RF_BEAT_W-1:0] op_col_q;
    logic [31:0] op_a_q;
    logic [31:0] op_b_q;
    logic [31:0] result_q;
    logic [31:0] vector_snapshot [0:BEATS_PER_ROW-1];

    // Combinational helpers
    logic [M_W-1:0] cfg_M;
    logic [N_W-1:0] cfg_N;
    logic       shape_illegal;
    logic       is_matrix_vector;
    logic [31:0] alu_res;
    logic signed [63:0] op_a_s64;
    logic signed [63:0] op_b_s64;
    logic signed [63:0] alu_s64;
    logic               alu_can_saturate;

    // Proposal 5.5.1: legal shape is mtilem <= ALEN/ARLEN, mtilen <= ARLEN/32.
    // A larger tile is an illegal instruction (no clamp, no register write).
    always_comb begin
        shape_illegal = (out_mtilem > MATRIX_DIM) ||
                        (out_mtilen > BEATS_PER_ROW);
        cfg_M = out_mtilem[M_W-1:0];
        cfg_N = out_mtilen[N_W-1:0];
    end

    always_comb begin
        is_matrix_vector = (ctrl != 3'b111);

        read_id_A   = ms1_id;
        read_row_A  = row_cnt;
        read_beat_A = col_cnt;

        read_id_B   = ms2_id;
        read_row_B  = row_cnt;
        read_beat_B = col_cnt;

        if (state == ST_SNAPSHOT) begin
            read_id_A   = ms1_id;
            read_row_A  = RF_ROW_W'(ctrl) & RF_ROW_W'(MATRIX_DIM - 1); // only log2(ROWNUM) bits of imm3
            read_beat_A = col_cnt;
            read_id_B   = '0;
            read_row_B  = '0;
            read_beat_B = '0;
        end else if (state == ST_READ && is_matrix_vector) begin
            read_id_A   = '0;
            read_row_A  = '0;
            read_beat_A = '0;
        end
    end

    always_comb begin
        op_a_s64 = {{32{op_a_q[31]}}, op_a_q};
        op_b_s64 = {{32{op_b_q[31]}}, op_b_q};

        alu_res = 32'b0;
        alu_s64 = 64'sd0;
        alu_can_saturate = 1'b0;

        unique case (func4)
            4'b0000: begin
                alu_s64 = op_b_s64 + op_a_s64; // madd
                alu_res = alu_s64[31:0];
                alu_can_saturate = 1'b1;
            end
            4'b0001: begin
                alu_s64 = op_a_s64 - op_b_s64; // msub: ms1 - ms2 (proposal 5.5.1)
                alu_res = alu_s64[31:0];
                alu_can_saturate = 1'b1;
            end
            4'b0010: begin
                alu_s64 = op_b_s64 * op_a_s64; // mmul
                alu_res = alu_s64[31:0];
                alu_can_saturate = 1'b1;
            end
            4'b0011: begin
                alu_s64 = op_b_s64 * op_a_s64; // mmulh
                alu_res = alu_s64[63:32];
            end
            4'b0100: begin
                alu_res = ($signed(op_a_q) > $signed(op_b_q)) ? op_a_q : op_b_q; // mmax
                alu_s64 = {{32{alu_res[31]}}, alu_res};
            end
            4'b0101: begin
                alu_res = (op_a_q > op_b_q) ? op_a_q : op_b_q; // mumax
                alu_s64 = {{32{alu_res[31]}}, alu_res};
            end
            4'b0110: begin
                alu_res = ($signed(op_a_q) < $signed(op_b_q)) ? op_a_q : op_b_q; // mmin
                alu_s64 = {{32{alu_res[31]}}, alu_res};
            end
            4'b0111: begin
                alu_res = (op_a_q < op_b_q) ? op_a_q : op_b_q; // mumin
                alu_s64 = {{32{alu_res[31]}}, alu_res};
            end
            4'b1000: begin
                alu_res = op_b_q >> op_a_q[4:0]; // msrl
                alu_s64 = {{32{alu_res[31]}}, alu_res};
            end
            4'b1001: begin
                alu_res = op_b_q << op_a_q[4:0]; // msll
                alu_s64 = {{32{alu_res[31]}}, alu_res};
            end
            4'b1010: begin
                alu_res = $signed(op_b_q) >>> op_a_q[4:0]; // msra
                alu_s64 = {{32{alu_res[31]}}, alu_res};
            end
            default: begin
                alu_res = 32'b0;
                alu_s64 = 64'sd0;
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (!resetn) begin
            state       <= ST_IDLE;
            row_cnt     <= '0;
            col_cnt     <= '0;
            op_row_q    <= '0;
            op_col_q    <= '0;
            op_a_q      <= '0;
            op_b_q      <= '0;
            result_q    <= '0;
            ew_done     <= 1'b0;
            ew_illegal  <= 1'b0;
            ew_reg_we   <= 1'b0;
            ew_reg_id   <= '0;
            ew_reg_row_idx  <= '0;
            ew_reg_beat_idx <= '0;
            ew_reg_wdata    <= '0;

            func4       <= '0;
            ctrl        <= '0;
            ms1_id      <= '0;
            ms2_id      <= '0;
            md_id       <= '0;
            active_M    <= '0;
            active_N    <= '0;
            sat_en_q    <= 1'b0;

            for (int i = 0; i < BEATS_PER_ROW; i++) begin
                vector_snapshot[i] <= '0;
            end
        end else begin
            ew_done   <= 1'b0;
            ew_reg_we <= 1'b0;

            unique case (state)
                ST_IDLE: begin
                    row_cnt <= '0;
                    col_cnt <= '0;

                    if (start_ew) begin
                        func4    <= matrix_insn[31:28];
                        ctrl     <= matrix_insn[25:23];
                        ms2_id   <= matrix_insn[22:20];
                        ms1_id   <= matrix_insn[17:15];
                        md_id    <= matrix_insn[9:7];
                        active_M <= cfg_M;
                        active_N <= cfg_N;
                        sat_en_q <= out_xmsaten;
                        ew_illegal <= shape_illegal;

                        if (shape_illegal) begin
                            state <= ST_DONE;
                        end else if (cfg_M != '0 && cfg_N != '0 &&
                            matrix_insn[27:26] == 2'b01 &&
                            matrix_insn[19:18] != 2'b11 &&
                            matrix_insn[11:10] != 2'b11) begin
                            if (matrix_insn[25:23] == 3'b111) begin
                                state <= ST_READ;
                            end else begin
                                state <= ST_SNAPSHOT;
                            end
                        end else begin
                            state <= ST_DONE;
                        end
                    end
                end

                ST_SNAPSHOT: begin
                    vector_snapshot[col_cnt] <= read_data_A;

                    if (col_cnt == active_N - 1'b1) begin
                        col_cnt <= '0;
                        row_cnt <= '0;
                        state   <= ST_READ;
                    end else begin
                        col_cnt <= col_cnt + 1'b1;
                    end
                end

                ST_READ: begin
                    op_a_q   <= is_matrix_vector ? vector_snapshot[col_cnt] : read_data_A;
                    op_b_q   <= read_data_B;
                    op_row_q <= row_cnt;
                    op_col_q <= col_cnt;
                    state    <= ST_EXEC;
                end

                ST_EXEC: begin
                    if (sat_en_q && alu_can_saturate) begin
                        if (alu_s64 > INT32_MAX_S64) begin
                            result_q <= INT32_MAX;
                        end else if (alu_s64 < INT32_MIN_S64) begin
                            result_q <= INT32_MIN;
                        end else begin
                            result_q <= alu_s64[31:0];
                        end
                    end else begin
                        result_q <= alu_res;
                    end
                    state <= ST_WRITE;
                end

                ST_WRITE: begin
                    ew_reg_we       <= 1'b1;
                    ew_reg_id       <= md_id;
                    ew_reg_row_idx  <= op_row_q;
                    ew_reg_beat_idx <= op_col_q;
                    ew_reg_wdata    <= result_q;

                    if (col_cnt == active_N - 1'b1) begin
                        col_cnt <= '0;
                        if (row_cnt == active_M - 1'b1) begin
                            state <= ST_DONE;
                        end else begin
                            row_cnt <= row_cnt + 1'b1;
                            state   <= ST_READ;
                        end
                    end else begin
                        col_cnt <= col_cnt + 1'b1;
                        state   <= ST_READ;
                    end
                end

                ST_DONE: begin
                    ew_done <= 1'b1;
                    state   <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
