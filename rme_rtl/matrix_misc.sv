`timescale 1ns / 1ps

module matrix_misc #(
    parameter int MATRIX_DIM = 4,
    parameter int BEATS_PER_ROW = 4
)(
    input  logic        clk,
    input  logic        resetn,

    input  logic        start_misc,
    input  logic [31:0] matrix_insn,
    input  logic [31:0] matrix_rs1,
    input  logic [31:0] matrix_rs2,

    output logic        misc_done,

    // Regfile write port
    output logic        misc_reg_we,
    output logic [2:0]  misc_reg_id,
    output logic [2:0]  misc_reg_row_idx,
    output logic [2:0]  misc_reg_beat_idx,
    output logic [31:0] misc_reg_wdata,

    // Regfile read port
    output logic [2:0]  read_id_A,
    output logic [2:0]  read_row_A,
    output logic [2:0]  read_beat_A,
    input  logic [31:0] read_data_A,

    // GPR writeback (mmovw.x.m)
    output logic        misc_gpr_we,
    output logic [31:0] misc_gpr_wdata
);

    typedef enum logic [2:0] {
        ST_IDLE   = 3'd0,
        ST_LOOP   = 3'd1,
        ST_SINGLE = 3'd2,
        ST_SNAPSHOT = 3'd3,
        ST_DONE   = 3'd4
    } fsm_state_t;

    fsm_state_t state;

    // Latched decode fields
    logic [3:0] func4;
    logic [1:0] uop;
    logic [2:0] ctrl_imm3;
    logic       ctrl_bit25;
    logic [1:0] ctrl_size_xm;
    logic [1:0] s_size;
    logic [1:0] d_size;
    logic [2:0] ms1_id;
    logic [2:0] ms2_id;
    logic [2:0] md_id;
    logic [31:0] rs1_val;
    logic [31:0] rs2_val;

    // Loop counters
    logic [2:0] row_cnt;
    logic [2:0] beat_cnt;

    // Operation flags (latched)
    logic op_mzero;
    logic op_mmov_mm;
    logic op_mmov_x_m;
    logic op_mmov_m_x;
    logic op_mdupw_m_x;
    logic op_mrslidedown;
    logic op_mcslidedown_w;
    logic op_mrslideup;
    logic op_mcslideup_w;

    // Operation flags (current instruction)
    logic op_mzero_insn;
    logic op_mmov_mm_insn;
    logic op_mmov_x_m_insn;
    logic op_mmov_m_x_insn;
    logic op_mdupw_m_x_insn;
    logic op_mrslidedown_insn;
    logic op_mcslidedown_w_insn;
    logic op_mrslideup_insn;
    logic op_mcslideup_w_insn;

    // Helpers
    logic [2:0] row_idx_single;
    logic [2:0] beat_idx_single;
    logic [2:0] src_row_idx;
    logic [2:0] src_beat_idx;
    logic       row_slide_oob;
    logic       beat_slide_oob;
    logic [31:0] slide_snapshot [0:MATRIX_DIM-1][0:BEATS_PER_ROW-1];

    function automatic logic same_reg_type(
        input logic [2:0] reg_a,
        input logic [2:0] reg_b
    );
        begin
            same_reg_type = ((reg_a < 3'd4) && (reg_b < 3'd4)) ||
                            ((reg_a >= 3'd4) && (reg_b >= 3'd4));
        end
    endfunction

    always_comb begin
        op_mzero         = (func4 == 4'b0000) && (uop == 2'b11) && (ctrl_imm3 == 3'b000);
        op_mmov_mm       = (func4 == 4'b0001) && (uop == 2'b11);
        op_mmov_x_m      = (func4 == 4'b0010) && (uop == 2'b11) && (ctrl_size_xm == 2'b10);
        op_mmov_m_x      = (func4 == 4'b0011) && (uop == 2'b11) && (ctrl_bit25 == 1'b1) && (d_size == 2'b10);
        op_mdupw_m_x      = (func4 == 4'b0011) && (uop == 2'b11) && (ctrl_bit25 == 1'b0) && (d_size == 2'b10);
        op_mrslidedown   = (func4 == 4'b0101) && (uop == 2'b11) && (s_size == 2'b00) && (d_size == 2'b00) && same_reg_type(md_id, ms1_id);
        op_mcslidedown_w = (func4 == 4'b0111) && (uop == 2'b11) && (s_size == 2'b10) && (d_size == 2'b10) && same_reg_type(md_id, ms1_id);
        op_mrslideup     = (func4 == 4'b0110) && (uop == 2'b11) && (s_size == 2'b00) && (d_size == 2'b00) && same_reg_type(md_id, ms1_id);
        op_mcslideup_w   = (func4 == 4'b1000) && (uop == 2'b11) && (s_size == 2'b10) && (d_size == 2'b10) && same_reg_type(md_id, ms1_id);
    end

    always_comb begin
        op_mzero_insn         = (matrix_insn[31:28] == 4'b0000) && (matrix_insn[27:26] == 2'b11) && (matrix_insn[25:23] == 3'b000);
        op_mmov_mm_insn       = (matrix_insn[31:28] == 4'b0001) && (matrix_insn[27:26] == 2'b11);
        op_mmov_x_m_insn      = (matrix_insn[31:28] == 4'b0010) && (matrix_insn[27:26] == 2'b11) && (matrix_insn[24:23] == 2'b10);
        op_mmov_m_x_insn      = (matrix_insn[31:28] == 4'b0011) && (matrix_insn[27:26] == 2'b11) && (matrix_insn[25] == 1'b1) && (matrix_insn[11:10] == 2'b10);
        op_mdupw_m_x_insn      = (matrix_insn[31:28] == 4'b0011) && (matrix_insn[27:26] == 2'b11) && (matrix_insn[25] == 1'b0) && (matrix_insn[11:10] == 2'b10);
        op_mrslidedown_insn   = (matrix_insn[31:28] == 4'b0101) && (matrix_insn[27:26] == 2'b11) && (matrix_insn[19:18] == 2'b00) && (matrix_insn[11:10] == 2'b00) && same_reg_type(matrix_insn[9:7], matrix_insn[17:15]);
        op_mcslidedown_w_insn = (matrix_insn[31:28] == 4'b0111) && (matrix_insn[27:26] == 2'b11) && (matrix_insn[19:18] == 2'b10) && (matrix_insn[11:10] == 2'b10) && same_reg_type(matrix_insn[9:7], matrix_insn[17:15]);
        op_mrslideup_insn     = (matrix_insn[31:28] == 4'b0110) && (matrix_insn[27:26] == 2'b11) && (matrix_insn[19:18] == 2'b00) && (matrix_insn[11:10] == 2'b00) && same_reg_type(matrix_insn[9:7], matrix_insn[17:15]);
        op_mcslideup_w_insn   = (matrix_insn[31:28] == 4'b1000) && (matrix_insn[27:26] == 2'b11) && (matrix_insn[19:18] == 2'b10) && (matrix_insn[11:10] == 2'b10) && same_reg_type(matrix_insn[9:7], matrix_insn[17:15]);
    end

    always_comb begin
        row_idx_single  = rs1_val[31:0] / BEATS_PER_ROW;
        beat_idx_single = rs1_val[31:0] % BEATS_PER_ROW;
    end

    always_comb begin
        src_row_idx  = row_cnt;
        src_beat_idx = beat_cnt;
        row_slide_oob = 1'b0;
        beat_slide_oob = 1'b0;

        if (op_mrslidedown) begin
            if ((row_cnt + ctrl_imm3) < MATRIX_DIM) begin
                src_row_idx = row_cnt + ctrl_imm3;
            end else begin
                row_slide_oob = 1'b1;
            end
        end else if (op_mrslideup) begin
            if (row_cnt >= ctrl_imm3) begin
                src_row_idx = row_cnt - ctrl_imm3;
            end else begin
                row_slide_oob = 1'b1;
            end
        end else if (op_mcslidedown_w) begin
            if ((beat_cnt + ctrl_imm3) < BEATS_PER_ROW) begin
                src_beat_idx = beat_cnt + ctrl_imm3;
            end else begin
                beat_slide_oob = 1'b1;
            end
        end else if (op_mcslideup_w) begin
            if (beat_cnt >= ctrl_imm3) begin
                src_beat_idx = beat_cnt - ctrl_imm3;
            end else begin
                beat_slide_oob = 1'b1;
            end
        end
    end

    // Read addressing
    always_comb begin
        read_id_A   = ms1_id;
        read_row_A  = row_cnt;
        read_beat_A = beat_cnt;

        if (op_mmov_x_m) begin
            read_id_A   = ms2_id;
            read_row_A  = row_idx_single;
            read_beat_A = beat_idx_single;
        end else if (op_mmov_mm ||
                    ((op_mrslidedown || op_mcslidedown_w || op_mrslideup || op_mcslideup_w) && (state != ST_SNAPSHOT))) begin
            read_id_A   = ms1_id;
            read_row_A  = src_row_idx;
            read_beat_A = src_beat_idx;
        end
    end

    always_ff @(posedge clk) begin
        if (!resetn) begin
            state         <= ST_IDLE;
            row_cnt       <= '0;
            beat_cnt      <= '0;
            misc_done     <= 1'b0;
            misc_reg_we   <= 1'b0;
            misc_reg_id   <= '0;
            misc_reg_row_idx <= '0;
            misc_reg_beat_idx<= '0;
            misc_reg_wdata<= '0;
            misc_gpr_we   <= 1'b0;
            misc_gpr_wdata<= '0;

            func4         <= '0;
            uop           <= '0;
            ctrl_imm3     <= '0;
            ctrl_bit25    <= 1'b0;
            ctrl_size_xm  <= '0;
            s_size        <= '0;
            d_size        <= '0;
            ms1_id        <= '0;
            ms2_id        <= '0;
            md_id         <= '0;
            rs1_val       <= '0;
            rs2_val       <= '0;
        end else begin
            misc_done   <= 1'b0;
            misc_reg_we <= 1'b0;
            misc_gpr_we <= 1'b0;

            case (state)
                ST_IDLE: begin
                    row_cnt  <= '0;
                    beat_cnt <= '0;

                    if (start_misc) begin
                        func4        <= matrix_insn[31:28];
                        uop          <= matrix_insn[27:26];
                        ctrl_imm3    <= matrix_insn[25:23];
                        ctrl_bit25   <= matrix_insn[25];
                        ctrl_size_xm <= matrix_insn[24:23];
                        ms2_id       <= matrix_insn[22:20];
                        s_size       <= matrix_insn[19:18];
                        ms1_id       <= matrix_insn[17:15];
                        d_size       <= matrix_insn[11:10];
                        md_id        <= matrix_insn[9:7];
                        rs1_val      <= matrix_rs1;
                        rs2_val      <= matrix_rs2;

                        if (op_mmov_x_m_insn || op_mmov_m_x_insn || op_mdupw_m_x_insn) begin
                            state <= ST_SINGLE;
                        end else if (op_mrslidedown_insn || op_mcslidedown_w_insn || op_mrslideup_insn || op_mcslideup_w_insn) begin
                            state <= ST_SNAPSHOT;
                        end else if (op_mzero_insn || op_mmov_mm_insn) begin
                            state <= ST_LOOP;
                        end else begin
                            state <= ST_DONE;
                        end
                    end
                end

                ST_SNAPSHOT: begin
                    slide_snapshot[row_cnt][beat_cnt] <= read_data_A;

                    if (beat_cnt == BEATS_PER_ROW - 1) begin
                        beat_cnt <= '0;
                        if (row_cnt == MATRIX_DIM - 1) begin
                            row_cnt <= '0;
                            state   <= ST_LOOP;
                        end else begin
                            row_cnt <= row_cnt + 3'd1;
                        end
                    end else begin
                        beat_cnt <= beat_cnt + 3'd1;
                    end
                end

                ST_SINGLE: begin
                    if (op_mmov_x_m) begin
                        misc_gpr_we    <= 1'b1;
                        misc_gpr_wdata <= read_data_A;
                        state <= ST_DONE;
                    end else if (op_mmov_m_x) begin
                        misc_reg_we      <= 1'b1;
                        misc_reg_id      <= md_id;
                        misc_reg_row_idx <= row_idx_single;
                        misc_reg_beat_idx<= beat_idx_single;
                        misc_reg_wdata   <= rs2_val;
                        state <= ST_DONE;
                    end else if (op_mdupw_m_x) begin
                        misc_reg_we      <= 1'b1;
                        misc_reg_id      <= md_id;
                        misc_reg_row_idx <= row_cnt;
                        misc_reg_beat_idx<= beat_cnt;
                        misc_reg_wdata   <= rs2_val;
                        state <= ST_LOOP;
                    end else begin
                        state <= ST_DONE;
                    end
                end

                ST_LOOP: begin
                    misc_reg_we      <= 1'b1;
                    misc_reg_id      <= md_id;
                    misc_reg_row_idx <= row_cnt;
                    misc_reg_beat_idx<= beat_cnt;

                    if (op_mzero) begin
                        misc_reg_wdata <= 32'b0;
                    end else if (op_mmov_mm) begin
                        misc_reg_wdata <= read_data_A;
                    end else if ((op_mrslidedown || op_mrslideup) && row_slide_oob) begin
                        misc_reg_wdata <= 32'b0;
                    end else if ((op_mcslidedown_w || op_mcslideup_w) && beat_slide_oob) begin
                        misc_reg_wdata <= 32'b0;
                    end else if (op_mrslidedown || op_mcslidedown_w || op_mrslideup || op_mcslideup_w) begin
                        misc_reg_wdata <= slide_snapshot[src_row_idx][src_beat_idx];
                    end else if (op_mdupw_m_x) begin
                        misc_reg_wdata <= rs2_val;
                    end else begin
                        misc_reg_wdata <= 32'b0;
                    end

                    if (beat_cnt == BEATS_PER_ROW - 1) begin
                        beat_cnt <= '0;
                        if (row_cnt == MATRIX_DIM - 1) begin
                            state <= ST_DONE;
                        end else begin
                            row_cnt <= row_cnt + 3'd1;
                        end
                    end else begin
                        beat_cnt <= beat_cnt + 3'd1;
                    end
                end

                ST_DONE: begin
                    misc_done <= 1'b1;
                    state     <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
