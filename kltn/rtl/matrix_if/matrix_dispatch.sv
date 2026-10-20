`timescale 1ns / 1ps

module matrix_dispatch #(
    parameter int MATRIX_DIM = 4,
    parameter bit ENABLE_LS = 1'b0
)(
    input  logic        clk,
    input  logic        resetn,

    // RV32I pipeline matrix dispatch interface.
    input  logic        matrix_valid,
    input  logic [31:0] matrix_insn,
    input  logic [31:0] matrix_rs1,
    input  logic [31:0] matrix_rs2,

    output logic        matrix_supported,
    output logic        matrix_busy,
    output logic        matrix_done,
    output logic        matrix_wb_we,
    output logic [4:0]  matrix_wb_rd,
    output logic [31:0] matrix_wb_data,

    // Matrix functional-unit start pulses.
    output logic        start_mld,
    output logic        start_matmul,
    output logic        start_fp_matmul,
    output logic        start_mst,
    output logic        start_cfg,
    output logic        start_misc,
    output logic        start_ew,
    output logic        start_fp_ew,

    output logic [2:0]  ms1_reg_id,
    output logic [2:0]  ms2_reg_id,
    output logic [2:0]  md_tr_id,
    output logic [2:0]  md_acc_id,

    input  logic        core_done,
    input  logic [31:0] csr_rdata,
    input  logic        misc_gpr_we,
    input  logic [31:0] misc_gpr_wdata
);

    localparam logic [6:0] OPCODE_MATRIX = 7'b0101011;

    logic [6:0] opcode;
    logic [2:0] func3;
    logic [3:0] func4;
    logic [1:0] uop;
    logic [2:0] ctrl_imm3;
    logic       ctrl_bit25;
    logic [1:0] ctrl_size_xm;
    logic [1:0] ms2;
    logic [2:0] ms1, md;
    logic [1:0] s_size, d_size;
    logic [4:0] rd;
    logic       ls;

    logic is_matrix_opcode, is_group_cfg, is_group_ls, is_group_matmul;
    logic is_group_misc, is_group_ew;
    logic is_supported_cfg, is_supported_ls, is_supported_matmul;
    logic is_supported_misc, is_supported_ew;
    logic is_size_b, is_size_w, is_size_bw;
    logic is_cfg_mrelease, is_cfg_msettilek, is_cfg_msettileki;
    logic is_cfg_msettilem, is_cfg_msettilemi, is_cfg_msettilen, is_cfg_msettileni;
    logic is_misc_mzero, is_misc_mmov_mm, is_misc_mmovw_x_m, is_misc_mmovw_m_x;
    logic is_misc_mdupw_m_x, is_misc_mrslidedown, is_misc_mcslidedown_w;
    logic is_misc_mrslideup, is_misc_mcslideup_w;
    logic is_misc_slide_same_bank;
    logic [2:0] size_sup;
    logic is_mmaccu_w_b, is_mmaccus_w_b, is_mmaccsu_w_b, is_mmacc_w_b;
    logic is_mfmacc_s;
    logic is_ls_mlae, is_ls_msae, is_ls_mlbe, is_ls_msbe, is_ls_mlce, is_ls_msce;
    logic is_ew_int, is_ew_mm, is_ew_mv;
    logic is_supported_fp_ew;
    logic is_ew_madd_w_mm, is_ew_madd_w_mv, is_ew_msub_w_mm, is_ew_msub_w_mv;
    logic is_ew_mmul_w_mm, is_ew_mmul_w_mv, is_ew_mmulh_w_mm, is_ew_mmulh_w_mv;
    logic is_ew_mmax_w_mm, is_ew_mmax_w_mv;
    logic is_ew_mumax_w_mm, is_ew_mumax_w_mv, is_ew_mmin_w_mm, is_ew_mmin_w_mv;
    logic is_ew_mumin_w_mm, is_ew_mumin_w_mv, is_ew_msrl_w_mm, is_ew_msrl_w_mv;
    logic is_ew_msll_w_mm, is_ew_msll_w_mv, is_ew_msra_w_mm, is_ew_msra_w_mv;

    logic instr_active;
    logic accept_block;
    logic [31:0] accept_block_insn;
    logic can_accept;
    logic active_is_cfg;
    logic active_is_misc;
    logic [4:0] active_rd;
    logic misc_gpr_pending;
    logic [31:0] misc_gpr_pending_data;

    always_comb begin
        opcode       = matrix_insn[6:0];
        func3        = matrix_insn[14:12];
        func4        = matrix_insn[31:28];
        uop          = matrix_insn[27:26];
        ctrl_imm3    = matrix_insn[25:23];
        ctrl_bit25   = matrix_insn[25];
        ctrl_size_xm = matrix_insn[24:23];
        ms2          = matrix_insn[21:20];
        s_size       = matrix_insn[19:18];
        ms1          = matrix_insn[17:15];
        md           = matrix_insn[9:7];
        rd           = matrix_insn[11:7];
        d_size       = matrix_insn[11:10];
        ls           = ctrl_bit25;

        ms1_reg_id = {1'b0, ms1[1:0]};
        ms2_reg_id = {1'b0, ms2};
        md_tr_id   = {1'b0, md[1:0]};
        md_acc_id  = {1'b1, md[1:0]};

        is_matrix_opcode = (opcode == OPCODE_MATRIX);
        is_group_cfg     = is_matrix_opcode && (func3 == 3'b000) && (uop == 2'b00);
        is_group_ls      = is_matrix_opcode && (func3 == 3'b000) && (uop == 2'b01);
        is_group_matmul  = is_matrix_opcode && (func3 == 3'b000) && (uop == 2'b10);
        is_group_misc    = is_matrix_opcode && (func3 == 3'b000) && (uop == 2'b11);
        is_group_ew      = is_matrix_opcode && (func3 == 3'b001) && (uop != 2'b11);

        is_size_b = (d_size == 2'b00);
        is_size_w = (d_size == 2'b10);
        is_size_bw = is_size_b | is_size_w; // A/B tiles: 8-bit (INT8) or 32-bit (FP32)

        // Cac truong co dinh theo encoding cua proposal (Chuong 8) phai dung gia tri,
        // neu khong la ma reserved -> khong chap nhan.
        //   mrelease          : 0000 00 0 0000000000 000 00000
        //   msettile{k,m,n}i  : func4 00 0 uimm10     000 00000   (rd [11:7] = 0)
        //   msettile{k,m,n}   : func4 00 1 00000 rs1  000 00000   ([24:20] = 0, rd = 0)
        is_cfg_mrelease   = is_group_cfg && (func4 == 4'b0000) && (matrix_insn[25:15] == 11'b0) && (rd == 5'b0);
        is_cfg_msettilek  = is_group_cfg && (func4 == 4'b0001) &&  ctrl_bit25 && (matrix_insn[24:20] == 5'b0) && (rd == 5'b0);
        is_cfg_msettileki = is_group_cfg && (func4 == 4'b0001) && !ctrl_bit25 && (rd == 5'b0);
        is_cfg_msettilem  = is_group_cfg && (func4 == 4'b0010) &&  ctrl_bit25 && (matrix_insn[24:20] == 5'b0) && (rd == 5'b0);
        is_cfg_msettilemi = is_group_cfg && (func4 == 4'b0010) && !ctrl_bit25 && (rd == 5'b0);
        is_cfg_msettilen  = is_group_cfg && (func4 == 4'b0011) &&  ctrl_bit25 && (matrix_insn[24:20] == 5'b0) && (rd == 5'b0);
        is_cfg_msettileni = is_group_cfg && (func4 == 4'b0011) && !ctrl_bit25 && (rd == 5'b0);
        is_supported_cfg  = is_cfg_mrelease | is_cfg_msettilek | is_cfg_msettileki |
                            is_cfg_msettilem | is_cfg_msettilemi |
                            is_cfg_msettilen | is_cfg_msettileni;

        size_sup = ctrl_imm3;
        is_mmaccu_w_b  = is_group_matmul && (func4 == 4'b0001) && (s_size == 2'b00) && (d_size == 2'b10) && (size_sup == 3'b000);
        is_mmaccus_w_b = is_group_matmul && (func4 == 4'b0001) && (s_size == 2'b00) && (d_size == 2'b10) && (size_sup == 3'b001);
        is_mmaccsu_w_b = is_group_matmul && (func4 == 4'b0001) && (s_size == 2'b00) && (d_size == 2'b10) && (size_sup == 3'b010);
        is_mmacc_w_b   = is_group_matmul && (func4 == 4'b0001) && (s_size == 2'b00) && (d_size == 2'b10) && (size_sup == 3'b011);
        is_supported_matmul = is_mmaccu_w_b | is_mmaccus_w_b | is_mmaccsu_w_b | is_mmacc_w_b;
        is_mfmacc_s = is_group_matmul && (func4 == 4'b0000) &&
                      (s_size == 2'b10) && (d_size == 2'b10) && (size_sup == 3'b000);

        // Encoding MISC (proposal Chuong 8), cac truong khong dung phai = 0:
        //   mzero      : 0000 11 uimm3 000 00 000 000 00 md     (ms2, s_size, ms1, d_size = 0)
        //   mmov.mm    : 0001 11 000 000 00 ms1 000 00 md       ([25:18] = 0, d_size = 0)
        //   mmovw.x.m  : 0010 11 0 10 ms2 rs1 000 rd            (bit 25 = 0)
        //   mmovw.m.x  : 0011 11 1 rs2 rs1 000 10 md
        //   mdupw.m.x  : 0011 11 0 rs2 00000 000 10 md          (rs1 [19:15] = 0)
        //   m{r,c}slide: func4 11 uimm3 000 ss ms1 000 dd md   (ms2 [22:20] = 0)
        is_misc_mzero         = is_group_misc && (func4 == 4'b0000) && (ctrl_imm3 == 3'b000) &&
                                (matrix_insn[22:15] == 8'b0) && (d_size == 2'b00);
        is_misc_mmov_mm       = is_group_misc && (func4 == 4'b0001) &&
                                (matrix_insn[25:18] == 8'b0) && (d_size == 2'b00);
        is_misc_mmovw_x_m     = is_group_misc && (func4 == 4'b0010) && !ctrl_bit25 && (ctrl_size_xm == 2'b10);
        is_misc_mmovw_m_x     = is_group_misc && (func4 == 4'b0011) && ctrl_bit25 && is_size_w;
        is_misc_mdupw_m_x     = is_group_misc && (func4 == 4'b0011) && !ctrl_bit25 && is_size_w &&
                                (matrix_insn[19:15] == 5'b0);
        is_misc_slide_same_bank = (md[2] == ms1[2]);
        is_misc_mrslidedown   = is_group_misc && (func4 == 4'b0101) && (s_size == 2'b00) && is_size_b &&
                                (matrix_insn[22:20] == 3'b000) && is_misc_slide_same_bank;
        is_misc_mrslideup     = is_group_misc && (func4 == 4'b0110) && (s_size == 2'b00) && is_size_b &&
                                (matrix_insn[22:20] == 3'b000) && is_misc_slide_same_bank;
        is_misc_mcslidedown_w = is_group_misc && (func4 == 4'b0111) && (s_size == 2'b10) && is_size_w &&
                                (matrix_insn[22:20] == 3'b000) && is_misc_slide_same_bank;
        is_misc_mcslideup_w   = is_group_misc && (func4 == 4'b1000) && (s_size == 2'b10) && is_size_w &&
                                (matrix_insn[22:20] == 3'b000) && is_misc_slide_same_bank;
        is_supported_misc = is_misc_mzero | is_misc_mmov_mm | is_misc_mmovw_x_m |
                            is_misc_mmovw_m_x | is_misc_mdupw_m_x |
                            is_misc_mrslidedown | is_misc_mrslideup |
                            is_misc_mcslidedown_w | is_misc_mcslideup_w;

        is_ls_mlae = is_group_ls && (func4 == 4'b0000) && !ls && is_size_bw;
        is_ls_msae = is_group_ls && (func4 == 4'b0000) &&  ls && is_size_bw;
        is_ls_mlbe = is_group_ls && (func4 == 4'b0001) && !ls && is_size_bw;
        is_ls_msbe = is_group_ls && (func4 == 4'b0001) &&  ls && is_size_bw;
        is_ls_mlce = is_group_ls && (func4 == 4'b0010) && !ls && is_size_w;
        is_ls_msce = is_group_ls && (func4 == 4'b0010) &&  ls && is_size_w;
        is_supported_ls = ENABLE_LS && (is_ls_mlae | is_ls_msae | is_ls_mlbe |
                                        is_ls_msbe | is_ls_mlce | is_ls_msce);

        is_ew_int = is_group_ew && (uop == 2'b01) && (s_size == 2'b10) && (d_size == 2'b10);
        is_ew_mm  = is_ew_int && (ctrl_imm3 == 3'b111);
        is_ew_mv  = is_ew_int && (ctrl_imm3 != 3'b111) && (ctrl_imm3 < MATRIX_DIM);
        is_ew_madd_w_mm  = is_ew_mm && (func4 == 4'b0000);
        is_ew_madd_w_mv  = is_ew_mv && (func4 == 4'b0000);
        is_ew_msub_w_mm  = is_ew_mm && (func4 == 4'b0001);
        is_ew_msub_w_mv  = is_ew_mv && (func4 == 4'b0001);
        is_ew_mmul_w_mm  = is_ew_mm && (func4 == 4'b0010);
        is_ew_mmul_w_mv  = is_ew_mv && (func4 == 4'b0010);
        is_ew_mmulh_w_mm = is_ew_mm && (func4 == 4'b0011);
        is_ew_mmulh_w_mv = is_ew_mv && (func4 == 4'b0011);
        is_ew_mmax_w_mm  = is_ew_mm && (func4 == 4'b0100);
        is_ew_mmax_w_mv  = is_ew_mv && (func4 == 4'b0100);
        is_ew_mumax_w_mm = is_ew_mm && (func4 == 4'b0101);
        is_ew_mumax_w_mv = is_ew_mv && (func4 == 4'b0101);
        is_ew_mmin_w_mm  = is_ew_mm && (func4 == 4'b0110);
        is_ew_mmin_w_mv  = is_ew_mv && (func4 == 4'b0110);
        is_ew_mumin_w_mm = is_ew_mm && (func4 == 4'b0111);
        is_ew_mumin_w_mv = is_ew_mv && (func4 == 4'b0111);
        is_ew_msrl_w_mm  = is_ew_mm && (func4 == 4'b1000);
        is_ew_msrl_w_mv  = is_ew_mv && (func4 == 4'b1000);
        is_ew_msll_w_mm  = is_ew_mm && (func4 == 4'b1001);
        is_ew_msll_w_mv  = is_ew_mv && (func4 == 4'b1001);
        is_ew_msra_w_mm  = is_ew_mm && (func4 == 4'b1010);
        is_ew_msra_w_mv  = is_ew_mv && (func4 == 4'b1010);
        is_supported_ew = is_ew_madd_w_mm | is_ew_madd_w_mv |
                           is_ew_msub_w_mm | is_ew_msub_w_mv |
                           is_ew_mmul_w_mm | is_ew_mmul_w_mv |
                           is_ew_mmulh_w_mm | is_ew_mmulh_w_mv |
                           is_ew_mmax_w_mm | is_ew_mmax_w_mv |
                          is_ew_mumax_w_mm | is_ew_mumax_w_mv |
                          is_ew_mmin_w_mm | is_ew_mmin_w_mv |
                          is_ew_mumin_w_mm | is_ew_mumin_w_mv |
                          is_ew_msrl_w_mm | is_ew_msrl_w_mv |
                          is_ew_msll_w_mm | is_ew_msll_w_mv |
                          is_ew_msra_w_mm | is_ew_msra_w_mv;

        // FP32 matrix-matrix only; vector and other formats remain unsupported.
        is_supported_fp_ew = is_group_ew && (uop == 2'b10) &&
                             (s_size == 2'b10) && (d_size == 2'b10) &&
                             (ctrl_imm3 == 3'b111) && (func4 <= 4'd4);

        matrix_supported = is_supported_cfg | is_supported_ls | is_supported_matmul | is_mfmacc_s |
                           is_supported_misc | is_supported_ew | is_supported_fp_ew;
    end

    assign can_accept   = matrix_valid && matrix_supported && !instr_active && !accept_block;
    assign start_mld    = can_accept && is_supported_ls && !ls;
    assign start_mst    = can_accept && is_supported_ls &&  ls;
    assign start_matmul = can_accept && is_supported_matmul;
    assign start_fp_matmul = can_accept && is_mfmacc_s;
    assign start_cfg    = can_accept && is_supported_cfg;
    assign start_misc   = can_accept && is_supported_misc;
    assign start_fp_ew  = can_accept && is_supported_fp_ew;
    assign start_ew     = can_accept && is_supported_ew;
    assign matrix_busy  = instr_active;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            matrix_done <= 1'b0;
            matrix_wb_we <= 1'b0;
            matrix_wb_rd <= 5'b0;
            matrix_wb_data <= 32'b0;
            instr_active <= 1'b0;
            accept_block <= 1'b0;
            accept_block_insn <= 32'b0;
            active_is_cfg <= 1'b0;
            active_is_misc <= 1'b0;
            active_rd <= 5'b0;
            misc_gpr_pending <= 1'b0;
            misc_gpr_pending_data <= 32'b0;
        end else begin
            matrix_done  <= 1'b0;
            matrix_wb_we <= 1'b0;

            if (!matrix_valid || (matrix_insn != accept_block_insn)) begin
                accept_block <= 1'b0;
            end

            if (can_accept) begin
                instr_active   <= 1'b1;
                active_is_cfg  <= is_supported_cfg;
                active_is_misc <= is_supported_misc;
                active_rd      <= rd;
                misc_gpr_pending <= 1'b0;
                misc_gpr_pending_data <= 32'b0;
            end

            if (instr_active && active_is_misc && misc_gpr_we) begin
                misc_gpr_pending <= 1'b1;
                misc_gpr_pending_data <= misc_gpr_wdata;
            end

            if (instr_active && core_done) begin
                matrix_done  <= 1'b1;
                instr_active <= 1'b0;
                accept_block <= 1'b1;
                accept_block_insn <= matrix_insn;

                if (active_is_cfg && (active_rd != 5'b0)) begin
                    matrix_wb_we   <= 1'b1;
                    matrix_wb_rd   <= active_rd;
                    matrix_wb_data <= csr_rdata;
                end else if (active_is_misc && (misc_gpr_we || misc_gpr_pending) && (active_rd != 5'b0)) begin
                    matrix_wb_we   <= 1'b1;
                    matrix_wb_rd   <= active_rd;
                    matrix_wb_data <= misc_gpr_we ? misc_gpr_wdata : misc_gpr_pending_data;
                end

                misc_gpr_pending <= 1'b0;
                misc_gpr_pending_data <= 32'b0;
            end
        end
    end

endmodule