`timescale 1ns / 1ps

module matrix_pcpi #(
    parameter int MATRIX_DIM = 4
)(
    input  logic        clk,
    input  logic        resetn,

    // =========================================================================
    // 1. GIAO TIẾP VỚI PICORV32 CPU (PCPI Interface)
    // =========================================================================
    input  logic        pcpi_valid, // Cờ báo có lệnh mới
    input  logic [31:0] pcpi_insn,  // Mã lệnh 32-bit
    input  logic [31:0] pcpi_rs1,   // Giá trị từ thanh ghi rs1
    input  logic [31:0] pcpi_rs2,   // Giá trị từ thanh ghi rs2

    output logic        pcpi_wr,    // Cho phép ghi kết quả về CPU
    output logic [31:0] pcpi_rd,    // Dữ liệu ghi về CPU
    output logic        pcpi_wait,  // Báo CPU tạm dừng (Stall)
    output logic        pcpi_ready, // Báo lệnh đã hoàn thành

    // =========================================================================
    // 2. TÍN HIỆU ĐIỀU KHIỂN XUẤT CHO MATRIX CORE
    // =========================================================================
    output logic        start_mld,
    output logic        start_matmul,
    output logic        start_mst,
    output logic        start_cfg,
    output logic        start_misc,
    output logic        start_ew,

    // Tín hiệu định tuyến thanh ghi (Register Bit-slicing)
    output logic [2:0]  ms1_reg_id,
    output logic [2:0]  ms2_reg_id,
    output logic [2:0]  md_tr_id,
    output logic [2:0]  md_acc_id,

    // =========================================================================
    // 3. NHẬN BÁO CÁO TỪ MATRIX CORE
    // =========================================================================
    input  logic        core_done,  // Core báo cáo đã xử lý xong
    input  logic [31:0] csr_rdata,  // Dữ liệu đọc từ thanh ghi CSR
    input  logic        misc_gpr_we,
    input  logic [31:0] misc_gpr_wdata
);

    // =========================================================================
    // PHẦN A: BÓC TÁCH TRƯỜNG LỆNH (INSTRUCTION BIT-SLICING)
    // =========================================================================
    logic [6:0] opcode; 
    logic [2:0] func3;  
    logic [3:0] func4;  
    logic [1:0] uop;    
    logic [2:0] ctrl_imm3;
    logic       ctrl_bit25;
    logic [1:0] ctrl_size_xm;
    logic [2:0] ms2, ms1, md;
    logic [1:0] s_size, d_size;
    logic [4:0] rs1, rs2, rd;
    logic       ls;

    always_comb begin
        // Common decode fields
        opcode       = pcpi_insn[6:0];
        func3        = pcpi_insn[14:12];
        func4        = pcpi_insn[31:28];
        uop          = pcpi_insn[27:26];
        
        // MISC/CONFIG control fields
        ctrl_imm3    = pcpi_insn[25:23];
        ctrl_bit25   = pcpi_insn[25];
        ctrl_size_xm = pcpi_insn[24:23];
        
        // Matrix register fields
        ms2          = pcpi_insn[22:20];
        s_size       = pcpi_insn[19:18];
        ms1          = pcpi_insn[17:15];
        md           = pcpi_insn[9:7];
        
        // GPR fields
        rs1          = pcpi_insn[19:15];
        rs2          = pcpi_insn[24:20];
        rd           = pcpi_insn[11:7];
        
        // Size fields
        d_size       = pcpi_insn[11:10];
        ls           = ctrl_bit25;
    end

    // =========================================================================
    // PHẦN B: ĐỊNH TUYẾN THANH GHI VÀO REGFILE (CROSSBAR ROUTING)
    // =========================================================================
    always_comb begin
        // Nhóm Tile (tr0-tr3) có ID 0-3 (Thêm bit 0 ở MSB)
        ms1_reg_id = {1'b0, ms1[1:0]}; 
        ms2_reg_id = {1'b0, ms2[1:0]}; 
        md_tr_id   = {1'b0, md[1:0]};  
        
        // Nhóm Accumulator (acc0-acc3) có ID 4-7 (Ép bit MSB = 1)
        md_acc_id  = {1'b1, md[1:0]};  
    end

    // =========================================================================
    // PHẦN C: LOGIC GIẢI MÃ CHI TIẾT (FULL DECODE LOGIC)
    // =========================================================================
    localparam logic [6:0] OPCODE_MATRIX = 7'b0101011;

    // Các cờ phân nhóm (Group Decode)
    logic is_matrix_opcode, is_group_cfg, is_group_ls, is_group_matmul, is_group_misc, is_group_ew;
    logic is_supported_cfg, is_supported_ls, is_supported_matmul, is_supported_misc, is_supported_ew;
    logic is_supported_matrix;
    
    // Các cờ kích thước (Size Helpers)
    logic is_size_b, is_size_h, is_size_w, is_size_bhw;
    logic is_s_size_b, is_s_size_h, is_s_size_w, is_s_size_bhw;

    // Các cờ cấu hình (Config Decode - Table 2.10)
    logic is_cfg_mrelease, is_cfg_msettilek, is_cfg_msettileki, is_cfg_msettilem;
    logic is_cfg_msettilemi, is_cfg_msettilen, is_cfg_msettileni;

    // Các cờ lệnh phụ trợ (Misc Decode - Table 2.11)
    logic is_misc_mzero, is_misc_mmov_mm;
    logic is_misc_mmovb_x_m, is_misc_mmovh_x_m, is_misc_mmovw_x_m;
    logic is_misc_mmovb_m_x, is_misc_mmovh_m_x, is_misc_mmovw_m_x;
    logic is_misc_mdupb_m_x, is_misc_mduph_m_x, is_misc_mdupw_m_x;
    logic is_misc_mpack, is_misc_mpackhl, is_misc_mpackhh;
    logic is_misc_mrslidedown, is_misc_mrslideup;
    logic is_misc_mcslidedown_b, is_misc_mcslidedown_h, is_misc_mcslidedown_w;
    logic is_misc_mcslideup_b, is_misc_mcslideup_h, is_misc_mcslideup_w;
    logic is_misc_mrbc_mv_i, is_misc_mcbc_b, is_misc_mcbc_h, is_misc_mcbc_w;

    // Các cờ nhân ma trận (Matmul Decode - Table 2.12)
    logic [2:0] size_sup;
    logic is_mmaccu_w_b, is_mmaccus_w_b, is_mmaccsu_w_b, is_mmacc_w_b;

    // Các cờ Load/Store (Load/Store Decode - Table 2.13)
    logic is_ls_mlae, is_ls_msae, is_ls_mlbe, is_ls_msbe, is_ls_mlce, is_ls_msce;
    logic is_ls_mlme, is_ls_msme;
    logic is_ls_mlate, is_ls_msate, is_ls_mlbte, is_ls_msbte, is_ls_mlcte, is_ls_mscte;

    // Các cờ Element-Wise (Element-Wise Decode - Table 2.14)
    logic is_ew_int, is_ew_mm, is_ew_mv;
    logic is_ew_madd_w_mm, is_ew_madd_w_mv, is_ew_msub_w_mm, is_ew_msub_w_mv;
    logic is_ew_mmul_w_mm, is_ew_mmul_w_mv, is_ew_mmax_w_mm, is_ew_mmax_w_mv;
    logic is_ew_mumax_w_mm, is_ew_mumax_w_mv, is_ew_mmin_w_mm, is_ew_mmin_w_mv;
    logic is_ew_mumin_w_mm, is_ew_mumin_w_mv, is_ew_msrl_w_mm, is_ew_msrl_w_mv;
    logic is_ew_msll_w_mm, is_ew_msll_w_mv, is_ew_msra_w_mm, is_ew_msra_w_mv;

    always_comb begin
        // --- Group decode ---
        is_matrix_opcode = (opcode == OPCODE_MATRIX);
        is_group_cfg     = is_matrix_opcode && (func3 == 3'b000) && (uop == 2'b00);
        is_group_ls      = is_matrix_opcode && (func3 == 3'b000) && (uop == 2'b01);
        is_group_matmul  = is_matrix_opcode && (func3 == 3'b000) && (uop == 2'b10);
        is_group_misc    = is_matrix_opcode && (func3 == 3'b000) && (uop == 2'b11);
        is_group_ew      = is_matrix_opcode && (func3 == 3'b001) && (uop != 2'b11);

        // --- Size helpers ---
        is_size_b        = (d_size == 2'b00);
        is_size_h        = (d_size == 2'b01);
        is_size_w        = (d_size == 2'b10);
        is_size_bhw      = is_size_b || is_size_h || is_size_w;

        is_s_size_b      = (s_size == 2'b00);
        is_s_size_h      = (s_size == 2'b01);
        is_s_size_w      = (s_size == 2'b10);
        is_s_size_bhw    = is_s_size_b || is_s_size_h || is_s_size_w;

        // --- CONFIG decode ---
        is_cfg_mrelease   = is_group_cfg && (func4 == 4'b0000);
        is_cfg_msettilek  = is_group_cfg && (func4 == 4'b0001) && (ctrl_bit25 == 1'b1);
        is_cfg_msettileki = is_group_cfg && (func4 == 4'b0001) && (ctrl_bit25 == 1'b0);
        is_cfg_msettilem  = is_group_cfg && (func4 == 4'b0010) && (ctrl_bit25 == 1'b1);
        is_cfg_msettilemi = is_group_cfg && (func4 == 4'b0010) && (ctrl_bit25 == 1'b0);
        is_cfg_msettilen  = is_group_cfg && (func4 == 4'b0011) && (ctrl_bit25 == 1'b1);
        is_cfg_msettileni = is_group_cfg && (func4 == 4'b0011) && (ctrl_bit25 == 1'b0);

        // --- MISC decode ---
        is_misc_mzero         = is_group_misc && (func4 == 4'b0000) && (ctrl_imm3 == 3'b000);
        is_misc_mmov_mm       = is_group_misc && (func4 == 4'b0001);
        is_misc_mmovb_x_m     = is_group_misc && (func4 == 4'b0010) && (ctrl_size_xm == 2'b00);
        is_misc_mmovh_x_m     = is_group_misc && (func4 == 4'b0010) && (ctrl_size_xm == 2'b01);
        is_misc_mmovw_x_m     = is_group_misc && (func4 == 4'b0010) && (ctrl_size_xm == 2'b10);
        is_misc_mmovb_m_x     = is_group_misc && (func4 == 4'b0011) && (ctrl_bit25 == 1'b1) && (d_size == 2'b00);
        is_misc_mmovh_m_x     = is_group_misc && (func4 == 4'b0011) && (ctrl_bit25 == 1'b1) && (d_size == 2'b01);
        is_misc_mmovw_m_x     = is_group_misc && (func4 == 4'b0011) && (ctrl_bit25 == 1'b1) && (d_size == 2'b10);
        is_misc_mdupb_m_x     = is_group_misc && (func4 == 4'b0011) && (ctrl_bit25 == 1'b0) && (d_size == 2'b00);
        is_misc_mduph_m_x     = is_group_misc && (func4 == 4'b0011) && (ctrl_bit25 == 1'b0) && (d_size == 2'b01);
        is_misc_mdupw_m_x     = is_group_misc && (func4 == 4'b0011) && (ctrl_bit25 == 1'b0) && (d_size == 2'b10);
        is_misc_mpack         = is_group_misc && (func4 == 4'b0100) && (ctrl_bit25 == 1'b0) && (ctrl_size_xm == 2'b00);
        is_misc_mpackhl       = is_group_misc && (func4 == 4'b0100) && (ctrl_bit25 == 1'b0) && (ctrl_size_xm == 2'b10);
        is_misc_mpackhh       = is_group_misc && (func4 == 4'b0100) && (ctrl_bit25 == 1'b0) && (ctrl_size_xm == 2'b11);
        is_misc_mrslidedown   = is_group_misc && (func4 == 4'b0101) && (s_size == 2'b00) && (d_size == 2'b00);
        is_misc_mrslideup     = is_group_misc && (func4 == 4'b0110) && (s_size == 2'b00) && (d_size == 2'b00);
        is_misc_mcslidedown_b = is_group_misc && (func4 == 4'b0111) && (s_size == 2'b00) && (d_size == 2'b00);
        is_misc_mcslidedown_h = is_group_misc && (func4 == 4'b0111) && (s_size == 2'b01) && (d_size == 2'b01);
        is_misc_mcslidedown_w = is_group_misc && (func4 == 4'b0111) && (s_size == 2'b10) && (d_size == 2'b10);
        is_misc_mcslideup_b   = is_group_misc && (func4 == 4'b1000) && (s_size == 2'b00) && (d_size == 2'b00);
        is_misc_mcslideup_h   = is_group_misc && (func4 == 4'b1000) && (s_size == 2'b01) && (d_size == 2'b01);
        is_misc_mcslideup_w   = is_group_misc && (func4 == 4'b1000) && (s_size == 2'b10) && (d_size == 2'b10);
        is_misc_mrbc_mv_i     = is_matrix_opcode && (func3 == 3'b001) && (uop == 2'b10) && (func4 == 4'b0110);
        is_misc_mcbc_b        = is_group_misc && (func4 == 4'b1010) && (s_size == 2'b00) && (d_size == 2'b00);
        is_misc_mcbc_h        = is_group_misc && (func4 == 4'b1010) && (s_size == 2'b01) && (d_size == 2'b01);
        is_misc_mcbc_w        = is_group_misc && (func4 == 4'b1010) && (s_size == 2'b10) && (d_size == 2'b10);

        // --- MATMUL decode ---
        size_sup      = ctrl_imm3; 
        is_mmaccu_w_b = is_group_matmul && (func4 == 4'b0001) && (s_size == 2'b00) && (d_size == 2'b10) && (size_sup == 3'b000);
        is_mmaccus_w_b= is_group_matmul && (func4 == 4'b0001) && (s_size == 2'b00) && (d_size == 2'b10) && (size_sup == 3'b001);
        is_mmaccsu_w_b= is_group_matmul && (func4 == 4'b0001) && (s_size == 2'b00) && (d_size == 2'b10) && (size_sup == 3'b010);
        is_mmacc_w_b  = is_group_matmul && (func4 == 4'b0001) && (s_size == 2'b00) && (d_size == 2'b10) && (size_sup == 3'b011);

        // --- LOAD/STORE decode ---
        is_ls_mlae    = is_group_ls && (func4 == 4'b0000) && (ls == 1'b0) && is_size_bhw;
        is_ls_msae    = is_group_ls && (func4 == 4'b0000) && (ls == 1'b1) && is_size_bhw;
        is_ls_mlbe    = is_group_ls && (func4 == 4'b0001) && (ls == 1'b0) && is_size_bhw;
        is_ls_msbe    = is_group_ls && (func4 == 4'b0001) && (ls == 1'b1) && is_size_bhw;
        is_ls_mlce    = is_group_ls && (func4 == 4'b0010) && (ls == 1'b0) && is_size_bhw;
        is_ls_msce    = is_group_ls && (func4 == 4'b0010) && (ls == 1'b1) && is_size_bhw;
        is_ls_mlme    = is_group_ls && (func4 == 4'b0011) && (ls == 1'b0) && is_size_bhw;
        is_ls_msme    = is_group_ls && (func4 == 4'b0011) && (ls == 1'b1) && is_size_bhw;
        is_ls_mlate   = is_group_ls && (func4 == 4'b0100) && (ls == 1'b0) && is_size_bhw;
        is_ls_msate   = is_group_ls && (func4 == 4'b0100) && (ls == 1'b1) && is_size_bhw;
        is_ls_mlbte   = is_group_ls && (func4 == 4'b0101) && (ls == 1'b0) && is_size_bhw;
        is_ls_msbte   = is_group_ls && (func4 == 4'b0101) && (ls == 1'b1) && is_size_bhw;
        is_ls_mlcte   = is_group_ls && (func4 == 4'b0110) && (ls == 1'b0) && is_size_bhw;
        is_ls_mscte   = is_group_ls && (func4 == 4'b0110) && (ls == 1'b1) && is_size_bhw;

        // --- ELEMENT-WISE decode ---
        is_ew_int        = is_group_ew && (uop == 2'b01) && (s_size == 2'b10) && (d_size == 2'b10);
        is_ew_mm         = is_ew_int && (ctrl_imm3 == 3'b111);
        is_ew_mv         = is_ew_int && (ctrl_imm3 != 3'b111) && (ctrl_imm3 < MATRIX_DIM);
        is_ew_madd_w_mm  = is_ew_mm && (func4 == 4'b0000);
        is_ew_madd_w_mv  = is_ew_mv && (func4 == 4'b0000);
        is_ew_msub_w_mm  = is_ew_mm && (func4 == 4'b0001);
        is_ew_msub_w_mv  = is_ew_mv && (func4 == 4'b0001);
        is_ew_mmul_w_mm  = is_ew_mm && (func4 == 4'b0010);
        is_ew_mmul_w_mv  = is_ew_mv && (func4 == 4'b0010);
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

        // --- Supported subset gate ---
        // Keep PCPI aligned with the currently executed ISS subset.
        // Unsupported matrix opcodes are left unclaimed so PicoRV32 can treat them as illegal.
        is_supported_cfg = is_cfg_mrelease   |
                           is_cfg_msettilek  | is_cfg_msettileki |
                           is_cfg_msettilem  | is_cfg_msettilemi |
                           is_cfg_msettilen  | is_cfg_msettileni;

        // Current compute profile is int8 inputs widened into int32 accumulators:
        // A/B load-store byte rows, C/ACC load-store word rows.
        is_supported_ls = ((is_ls_mlae | is_ls_msae |
                            is_ls_mlbe | is_ls_msbe) && is_size_b) |
                          ((is_ls_mlce | is_ls_msce) && is_size_w);

        is_supported_matmul = is_mmaccu_w_b  |
                              is_mmaccus_w_b |
                              is_mmaccsu_w_b |
                              is_mmacc_w_b;

        is_supported_misc = is_misc_mzero       |
                            is_misc_mmov_mm     |
                            is_misc_mmovw_x_m   |
                            is_misc_mmovw_m_x   |
                            is_misc_mdupw_m_x   |
                            is_misc_mrslidedown |
                            is_misc_mcslidedown_w;

        is_supported_ew = is_ew_madd_w_mm  | is_ew_madd_w_mv  |
                          is_ew_msub_w_mm  | is_ew_msub_w_mv  |
                          is_ew_mmul_w_mm  | is_ew_mmul_w_mv  |
                          is_ew_mmax_w_mm  | is_ew_mmax_w_mv  |
                          is_ew_mumax_w_mm | is_ew_mumax_w_mv |
                          is_ew_mmin_w_mm  | is_ew_mmin_w_mv  |
                          is_ew_mumin_w_mm | is_ew_mumin_w_mv |
                          is_ew_msrl_w_mm  | is_ew_msrl_w_mv  |
                          is_ew_msll_w_mm  | is_ew_msll_w_mv  |
                          is_ew_msra_w_mm  | is_ew_msra_w_mv;

        is_supported_matrix = is_supported_cfg    |
                              is_supported_ls     |
                              is_supported_matmul |
                              is_supported_misc   |
                              is_supported_ew;
    end

    // =========================================================================
    // PHẦN D: FSM ĐIỀU KHIỂN & GIAO TIẾP (CONTROL STATE MACHINE)
    // =========================================================================
    logic instr_active; // Cờ báo đang bận xử lý lệnh

    // Bắn tín hiệu xuất phát (Start Pulses) xuống Core khi có lệnh mới
    logic accept_block; // Block re-accepting the same PCPI instruction.
    logic can_accept;
    logic active_is_cfg;
    logic active_is_misc;
    logic [4:0] active_rd;
    logic misc_gpr_pending;
    logic [31:0] misc_gpr_pending_data;

    assign can_accept = pcpi_valid && !instr_active && !accept_block;

    assign start_mld    = (can_accept && is_supported_ls     && !ls);
    assign start_mst    = (can_accept && is_supported_ls     &&  ls);
    assign start_matmul = (can_accept && is_supported_matmul);
    assign start_cfg    = (can_accept && is_supported_cfg);
    assign start_misc   = (can_accept && is_supported_misc);
    assign start_ew     = (can_accept && is_supported_ew);

    always_ff @(posedge clk) begin
        if (!resetn) begin
            pcpi_wait    <= 1'b0;
            pcpi_ready   <= 1'b0;
            pcpi_wr      <= 1'b0;
            pcpi_rd      <= '0;
            instr_active <= 1'b0;
            accept_block <= 1'b0;
            active_is_cfg  <= 1'b0;
            active_is_misc <= 1'b0;
            active_rd      <= 5'b0;
            misc_gpr_pending      <= 1'b0;
            misc_gpr_pending_data <= 32'b0;
        end else begin
            // Mặc định luôn tắt cờ ready và writeback
            pcpi_ready <= 1'b0;
            pcpi_wr    <= 1'b0;

            if (!pcpi_valid) begin
                accept_block <= 1'b0;
            end

            // BƯỚC 1: Nếu CPU ném lệnh Ma trận tới -> Kéo cờ Wait để bắt CPU đứng đợi
            if (can_accept && is_supported_matrix) begin
                pcpi_wait      <= 1'b1; 
                instr_active   <= 1'b1;
                active_is_cfg  <= is_supported_cfg;
                active_is_misc <= is_supported_misc;
                active_rd      <= rd;
                misc_gpr_pending      <= 1'b0;
                misc_gpr_pending_data <= 32'b0;
            end

            if (instr_active && active_is_misc && misc_gpr_we) begin
                misc_gpr_pending      <= 1'b1;
                misc_gpr_pending_data <= misc_gpr_wdata;
            end
            
            // BƯỚC 2: Khi phần cứng bên dưới (Core/DMA/MAC) làm xong
            if (instr_active && core_done) begin
                pcpi_wait    <= 1'b0; // Thả cho CPU chạy tiếp
                pcpi_ready   <= 1'b1; // Báo lệnh hoàn tất
                instr_active <= 1'b0; 
                accept_block <= 1'b1;
                
                // Nếu đây là lệnh Config đọc (Đọc trạng thái CSR về thanh ghi GPR của CPU)
                if (active_is_cfg && (active_rd != 5'b0)) begin
                    pcpi_wr <= 1'b1;      // Cho phép ghi vào GPR
                    pcpi_rd <= csr_rdata; // Đẩy dữ liệu từ CSR lên
                end else if (active_is_misc && (misc_gpr_we || misc_gpr_pending) && (active_rd != 5'b0)) begin
                    pcpi_wr <= 1'b1;
                    pcpi_rd <= misc_gpr_we ? misc_gpr_wdata : misc_gpr_pending_data;
                end

                misc_gpr_pending      <= 1'b0;
                misc_gpr_pending_data <= 32'b0;
            end
        end
    end

endmodule
