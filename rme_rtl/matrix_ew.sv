`timescale 1ns / 1ps

module matrix_ew #(
    parameter int MATRIX_DIM = 4,
    parameter int BEATS_PER_ROW = 4
)(
    input  logic        clk,
    input  logic        resetn,

    input  logic        start_ew,
    input  logic [31:0] matrix_insn,
    input  logic        out_xmsaten,
    input  logic [31:0] out_mtilem,
    input  logic [31:0] out_mtilen,

    output logic        ew_done,

    // Regfile write port
    output logic        ew_reg_we,
    output logic [2:0]  ew_reg_id,
    output logic [2:0]  ew_reg_row_idx,
    output logic [2:0]  ew_reg_beat_idx,
    output logic [31:0] ew_reg_wdata,

    // Regfile read ports
    output logic [2:0]  read_id_A,
    output logic [2:0]  read_row_A,
    output logic [2:0]  read_beat_A,
    input  logic [31:0] read_data_A,

    output logic [2:0]  read_id_B,
    output logic [2:0]  read_row_B,
    output logic [2:0]  read_beat_B,
    input  logic [31:0] read_data_B
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

    localparam logic [2:0] MATRIX_DIM_L     = MATRIX_DIM;
    localparam logic [2:0] BEATS_PER_ROW_L  = BEATS_PER_ROW;
    localparam logic [31:0] INT32_MAX       = 32'h7FFF_FFFF;
    localparam logic [31:0] INT32_MIN       = 32'h8000_0000;
    localparam logic signed [63:0] INT32_MAX_S64 = 64'sh0000_0000_7FFF_FFFF;
    localparam logic signed [63:0] INT32_MIN_S64 = -64'sh0000_0000_8000_0000;

    // Latched decode/config fields
    logic [3:0] func4;
    logic [1:0] uop;
    logic [2:0] ctrl;
    logic [1:0] s_size;
    logic [1:0] d_size;
    logic [2:0] ms1_id;
    logic [2:0] ms2_id;
    logic [2:0] md_id;
    logic [2:0] active_M;
    logic [2:0] active_N;
    logic       sat_en_q;

    // Loop and pipeline registers
    logic [2:0] row_cnt;
    logic [2:0] col_cnt;
    logic [2:0] op_row_q;
    logic [2:0] op_col_q;
    logic [31:0] op_a_q;
    logic [31:0] op_b_q;
    logic [31:0] result_q;
    logic [31:0] vector_snapshot [0:BEATS_PER_ROW-1];

    // Combinational helpers
    logic [2:0] cfg_M;
    logic [2:0] cfg_N;
    logic       is_matrix_vector;
    logic [31:0] alu_res;
    logic signed [63:0] op_a_s64;
    logic signed [63:0] op_b_s64;
    logic signed [63:0] alu_s64;
    logic               alu_can_saturate;

    function automatic logic [2:0] clamp_tile(
        input logic [31:0] value,
        input logic [2:0]  limit
    );
        begin
            if (value == 32'd0) begin
                clamp_tile = 3'd0;
            end else if (value > {29'b0, limit}) begin
                clamp_tile = limit;
            end else begin
                clamp_tile = value[2:0];
            end
        end
    endfunction

    always_comb begin
        cfg_M = clamp_tile(out_mtilem, MATRIX_DIM_L);
        cfg_N = clamp_tile(out_mtilen, BEATS_PER_ROW_L);
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
            read_row_A  = ctrl;
            read_beat_A = col_cnt;
            read_id_B   = 3'b0;
            read_row_B  = 3'b0;
            read_beat_B = 3'b0;
        end else if (state == ST_READ && is_matrix_vector) begin
            read_id_A   = 3'b0;
            read_row_A  = 3'b0;
            read_beat_A = 3'b0;
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
                alu_s64 = op_b_s64 - op_a_s64; // msub
                alu_res = alu_s64[31:0];
                alu_can_saturate = 1'b1;
            end
            4'b0010: begin
                alu_s64 = op_b_s64 * op_a_s64; // mmul
                alu_res = alu_s64[31:0];
                alu_can_saturate = 1'b1;
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
            ew_reg_we   <= 1'b0;
            ew_reg_id   <= '0;
            ew_reg_row_idx  <= '0;
            ew_reg_beat_idx <= '0;
            ew_reg_wdata    <= '0;

            func4       <= '0;
            uop         <= '0;
            ctrl        <= '0;
            s_size      <= '0;
            d_size      <= '0;
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
                        uop      <= matrix_insn[27:26];
                        ctrl     <= matrix_insn[25:23];
                        ms2_id   <= matrix_insn[22:20];
                        s_size   <= matrix_insn[19:18];
                        ms1_id   <= matrix_insn[17:15];
                        d_size   <= matrix_insn[11:10];
                        md_id    <= matrix_insn[9:7];
                        active_M <= cfg_M;
                        active_N <= cfg_N;
                        sat_en_q <= out_xmsaten;

                        if (cfg_M != 3'd0 && cfg_N != 3'd0 &&
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

                    if (col_cnt == active_N - 3'd1) begin
                        col_cnt <= '0;
                        row_cnt <= '0;
                        state   <= ST_READ;
                    end else begin
                        col_cnt <= col_cnt + 3'd1;
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
                    ew_done <= 1'b1;
                    state   <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
