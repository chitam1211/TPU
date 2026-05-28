`timescale 1ns / 1ps

module matrix_core #(
    parameter int REG_ROWS = 4,
    parameter int REG_BEATS_PER_ROW = 4,
    parameter int COMPUTE_ROWS = 4,
    parameter int COMPUTE_COLS = 4,
    parameter int MAX_K_INT8 = 16
)(
    input  logic        clk,
    input  logic        resetn,

    // =========================================================================
    // 1. GIAO TIẾP VỚI PICORV32 (Bus PCPI)
    // =========================================================================
    input  logic        pcpi_valid, 
    input  logic [31:0] pcpi_insn,  
    input  logic [31:0] pcpi_rs1,   
    input  logic [31:0] pcpi_rs2,   
    output logic        pcpi_wr,    
    output logic [31:0] pcpi_rd,    
    output logic        pcpi_wait,  
    output logic        pcpi_ready,

    // =========================================================================
    // 2. GIAO TIẾP VỚI BỘ NHỚ RAM (Bus AXI4 Full Master)
    // =========================================================================
    output logic [31:0] m_axi_awaddr,
    output logic [7:0]  m_axi_awlen,
    output logic [2:0]  m_axi_awsize,
    output logic [1:0]  m_axi_awburst,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,
    
    output logic [31:0] m_axi_wdata,
    output logic [3:0]  m_axi_wstrb,
    output logic        m_axi_wlast,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,
    
    input  logic [1:0]  m_axi_bresp,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,
    
    output logic [31:0] m_axi_araddr,
    output logic [7:0]  m_axi_arlen,
    output logic [2:0]  m_axi_arsize,
    output logic [1:0]  m_axi_arburst,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,
    
    input  logic [31:0] m_axi_rdata,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rlast,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready
);

    // =========================================================================
    // DÂY KẾT NỐI NỘI BỘ (Internal Wires)
    // =========================================================================
    
    // Dây từ PCPI (Giải mã lệnh)
    logic start_mld, start_matmul, start_mst, start_cfg, start_misc, start_ew;
    logic [2:0] ms1_reg_id, ms2_reg_id, md_tr_id, md_acc_id;
    
    // Dây GHI của DMA
    logic        dma_reg_we;
    logic [2:0]  dma_reg_id;
    logic [2:0]  dma_reg_row_idx;
    logic [2:0]  dma_reg_beat_idx;
    logic [31:0] dma_reg_wdata;
    logic [31:0] reg_dma_rdata; // Dây DMA đọc (Store ra RAM)

    // Dây GHI của MAC
    logic        mac_reg_we;
    logic [2:0]  mac_reg_id;
    logic [2:0]  mac_reg_row_idx;
    logic [2:0]  mac_reg_beat_idx;
    logic [63:0] mac_reg_wdata; // ACC yêu cầu 64-bit

    // Dây GHI của MISC/EW
    logic        misc_reg_we;
    logic [2:0]  misc_reg_id;
    logic [2:0]  misc_reg_row_idx;
    logic [2:0]  misc_reg_beat_idx;
    logic [31:0] misc_reg_wdata;

    logic        ew_reg_we;
    logic [2:0]  ew_reg_id;
    logic [2:0]  ew_reg_row_idx;
    logic [2:0]  ew_reg_beat_idx;
    logic [31:0] ew_reg_wdata;

    // Dây ĐỌC của MAC
    logic [2:0]  mac_read_id_A, mac_read_id_B, mac_read_id_C;
    logic [2:0]  mac_read_row_A, mac_read_row_B, mac_read_row_C;
    logic [2:0]  mac_read_beat_A, mac_read_beat_B, mac_read_beat_C;
    logic [31:0] reg_mac_rdata_A, reg_mac_rdata_B;
    logic [63:0] reg_mac_rdata_C;
    logic [2:0]   mac_vec_read_id_A, mac_vec_read_id_B;
    logic [11:0]  mac_vec_read_beats_A, mac_vec_read_beats_B;
    logic [127:0] reg_mac_vec_rdata_A, reg_mac_vec_rdata_B;

    // Dây ĐỌC của MISC/EW
    logic [2:0]  misc_read_id_A, misc_read_row_A, misc_read_beat_A;
    logic [2:0]  ew_read_id_A, ew_read_row_A, ew_read_beat_A;
    logic [2:0]  ew_read_id_B, ew_read_row_B, ew_read_beat_B;

    // MUX địa chỉ đọc chung
    logic [2:0]  core_read_id_A, core_read_row_A, core_read_beat_A;
    logic [2:0]  core_read_id_B, core_read_row_B, core_read_beat_B;
    logic [2:0]  core_read_id_C, core_read_row_C, core_read_beat_C;

    // Dây nối CSR (Cấu hình)
    logic [31:0] csr_rdata;
    logic [31:0] out_mtilem, out_mtilek, out_mtilen;
    logic [1:0]  out_xmxrm;
    logic [2:0]  out_xmfrm;
    logic        out_xmsat, out_xmsaten;

    // Quản lý hoàn tất lệnh
    logic dma_done, mac_done, misc_done, ew_done, core_done;

    // GPR writeback từ MISC
    logic misc_gpr_we;
    logic [31:0] misc_gpr_wdata;

    // Config CSR write
    logic        cfg_we;
    logic [11:0] cfg_addr;
    logic [31:0] cfg_wdata;

    // Active flags for read mux
    logic mac_active, misc_active, ew_active;

    // =========================================================================
    // MẠCH ĐIỀU PHỐI LOGIC (Dispatcher & Arbiter)
    // =========================================================================
    
    // 1. Mạch tạo cờ Hoàn tất (core_done)
    always_ff @(posedge clk) begin
        if (!resetn) begin
            core_done <= 1'b0;
        end else begin
            // Lệnh Load/Store chờ dma_done. Lệnh Matmul chờ mac_done.
            // Lệnh Config báo xong ngay (1 chu kỳ), MISC/EW chờ done.
            core_done <= dma_done | mac_done | misc_done | ew_done | start_cfg;
        end
    end

    // 1.5. Theo dõi active op để MUX cổng đọc
    always_ff @(posedge clk) begin
        if (!resetn) begin
            mac_active  <= 1'b0;
            misc_active <= 1'b0;
            ew_active   <= 1'b0;
        end else begin
            if (start_matmul) begin
                mac_active <= 1'b1;
            end else if (mac_done) begin
                mac_active <= 1'b0;
            end

            if (start_misc) begin
                misc_active <= 1'b1;
            end else if (misc_done) begin
                misc_active <= 1'b0;
            end

            if (start_ew) begin
                ew_active <= 1'b1;
            end else if (ew_done) begin
                ew_active <= 1'b0;
            end
        end
    end

    // 2. MUX định tuyến thanh ghi đích cho DMA 
    // Nếu lệnh thao tác với ma trận C (func4 == 0010: mlce/msce), DMA phải trỏ vào thanh ghi ACC.
    // Ngược lại, trỏ vào thanh ghi TR.
    logic [2:0] dma_target_reg;
    logic       is_matrix_c_ls;
    
    assign is_matrix_c_ls = (pcpi_insn[31:28] == 4'b0010); 
    assign dma_target_reg = is_matrix_c_ls ? md_acc_id : md_tr_id;

    // 2.5. Config write decode (msettile* / mrelease)
    always_comb begin
        cfg_we    = 1'b0;
        cfg_addr  = 12'h000;
        cfg_wdata = 32'b0;

        if (start_cfg) begin
            unique case (pcpi_insn[31:28])
                4'b0000: begin
                    // mrelease: no CSR write in RTL (state tracking only)
                    cfg_we = 1'b0;
                end
                4'b0001: begin
                    cfg_we   = 1'b1;
                    cfg_addr = 12'h805; // mtilek
                    cfg_wdata = pcpi_insn[25] ? pcpi_rs1 : {22'b0, pcpi_insn[24:15]};
                end
                4'b0010: begin
                    cfg_we   = 1'b1;
                    cfg_addr = 12'h803; // mtilem
                    cfg_wdata = pcpi_insn[25] ? pcpi_rs1 : {22'b0, pcpi_insn[24:15]};
                end
                4'b0011: begin
                    cfg_we   = 1'b1;
                    cfg_addr = 12'h804; // mtilen
                    cfg_wdata = pcpi_insn[25] ? pcpi_rs1 : {22'b0, pcpi_insn[24:15]};
                end
                default: begin
                    cfg_we = 1'b0;
                end
            endcase
        end
    end

    // 3. MẠCH GỘP CỔNG GHI VÀO REGFILE (Local Arbiter / MUX)
    // Cấp quyền Ghi cho MAC hoặc DMA (Dựa trên cờ We). 
    // Do PCPI là blocking, MAC và DMA sẽ không bao giờ chạy cùng 1 lúc.
    logic        core_reg_we;
    logic [2:0]  core_reg_id;
    logic [2:0]  core_reg_row_idx;
    logic [2:0]  core_reg_beat_idx;
    logic [31:0] core_reg_wdata;

    assign core_reg_we       = mac_reg_we | ew_reg_we | misc_reg_we | dma_reg_we;
    assign core_reg_id       = mac_reg_we  ? mac_reg_id  :
                               ew_reg_we   ? ew_reg_id   :
                               misc_reg_we ? misc_reg_id : dma_reg_id;
    assign core_reg_row_idx  = mac_reg_we  ? mac_reg_row_idx  :
                               ew_reg_we   ? ew_reg_row_idx   :
                               misc_reg_we ? misc_reg_row_idx : dma_reg_row_idx;
    assign core_reg_beat_idx = mac_reg_we  ? mac_reg_beat_idx  :
                               ew_reg_we   ? ew_reg_beat_idx   :
                               misc_reg_we ? misc_reg_beat_idx : dma_reg_beat_idx;
    
    // Xử lý kích thước dữ liệu (MAC xuất 64-bit cho ACC, nhưng DMA/MISC/EW chỉ ghi 32-bit mỗi nhịp)
    // Lưu ý: Tùy thiết kế cụ thể bên trong regfile mà bạn tinh chỉnh đường truyền 64-bit này.
    assign core_reg_wdata    = mac_reg_we  ? mac_reg_wdata[31:0] :
                               ew_reg_we   ? ew_reg_wdata :
                               misc_reg_we ? misc_reg_wdata : dma_reg_wdata;

    // 3.1. MUX địa chỉ đọc cho Regfile (MAC > EW > MISC)
    always_comb begin
        core_read_id_A   = mac_read_id_A;
        core_read_row_A  = mac_read_row_A;
        core_read_beat_A = mac_read_beat_A;

        core_read_id_B   = mac_read_id_B;
        core_read_row_B  = mac_read_row_B;
        core_read_beat_B = mac_read_beat_B;

        core_read_id_C   = mac_read_id_C;
        core_read_row_C  = mac_read_row_C;
        core_read_beat_C = mac_read_beat_C;

        if (!mac_active && ew_active) begin
            core_read_id_A   = ew_read_id_A;
            core_read_row_A  = ew_read_row_A;
            core_read_beat_A = ew_read_beat_A;

            core_read_id_B   = ew_read_id_B;
            core_read_row_B  = ew_read_row_B;
            core_read_beat_B = ew_read_beat_B;

            core_read_id_C   = 3'b0;
            core_read_row_C  = 3'b0;
            core_read_beat_C = 3'b0;
        end else if (!mac_active && !ew_active && misc_active) begin
            core_read_id_A   = misc_read_id_A;
            core_read_row_A  = misc_read_row_A;
            core_read_beat_A = misc_read_beat_A;

            core_read_id_B   = 3'b0;
            core_read_row_B  = 3'b0;
            core_read_beat_B = 3'b0;

            core_read_id_C   = 3'b0;
            core_read_row_C  = 3'b0;
            core_read_beat_C = 3'b0;
        end
    end


    // =========================================================================
    // KHỞI TẠO CÁC MODULE CON (Sub-system Instantiations)
    // =========================================================================

    // 1. BỘ GIẢI MÃ LỆNH (PCPI Decoder)
    matrix_pcpi #(
        .MATRIX_DIM(REG_ROWS)
    ) u_pcpi (
        .clk(clk), 
        .resetn(resetn),
        .pcpi_valid(pcpi_valid), 
        .pcpi_insn(pcpi_insn),
        .pcpi_rs1(pcpi_rs1), 
        .pcpi_rs2(pcpi_rs2),
        .pcpi_wr(pcpi_wr), 
        .pcpi_rd(pcpi_rd),
        .pcpi_wait(pcpi_wait), 
        .pcpi_ready(pcpi_ready),
        
        .start_mld(start_mld), 
        .start_matmul(start_matmul), 
        .start_mst(start_mst),
        .start_cfg(start_cfg), 
        .start_misc(start_misc), 
        .start_ew(start_ew),
        
        .ms1_reg_id(ms1_reg_id), 
        .ms2_reg_id(ms2_reg_id),
        .md_tr_id(md_tr_id), 
        .md_acc_id(md_acc_id),
        
        .core_done(core_done), 
        .csr_rdata(csr_rdata),
        .misc_gpr_we(misc_gpr_we),
        .misc_gpr_wdata(misc_gpr_wdata)
    );

    // 2. BỘ VẬN CHUYỂN DỮ LIỆU (DMA AXI4 Full)
    matrix_dma #(
        .AXI_ADDR_WIDTH(32), 
        .AXI_DATA_WIDTH(32), 
        .MATRIX_DIM(REG_ROWS),
        .REG_BEATS_PER_ROW(REG_BEATS_PER_ROW)
    ) u_dma (
        .clk(clk), 
        .resetn(resetn),
        
        .start_ls(start_mld | start_mst),
        .is_store(start_mst),
        .target_matrix_id(dma_target_reg), 
        .base_addr(pcpi_rs1),
        .row_stride(pcpi_rs2),
        .elem_size(pcpi_insn[11:10]),
        .matrix_sel(pcpi_insn[31:28]),
        .tile_m(out_mtilem),
        .tile_n(out_mtilen),
        .tile_k(out_mtilek),
        .dma_done(dma_done),
        
        .reg_we(dma_reg_we), 
        .reg_id(dma_reg_id),
        .reg_row_idx(dma_reg_row_idx), 
        .reg_beat_idx(dma_reg_beat_idx),
        .reg_wdata(dma_reg_wdata), 
        .reg_rdata(reg_dma_rdata), // Không cần qua MUX vì DMA có cổng đọc riêng
        
        // Cổng AXI4 nối thẳng ra Bo mạch chủ (soc_top.v)
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );

    // 3. KHỐI TÍNH TOÁN MA TRẬN (MAC Array)
    matrix_mac #(
        .COMPUTE_ROWS(COMPUTE_ROWS),
        .COMPUTE_COLS(COMPUTE_COLS),
        .MAX_K_INT8(MAX_K_INT8)
    ) u_mac (
        .clk(clk), 
        .resetn(resetn),
        
        .start_matmul(start_matmul),
        .pcpi_insn(pcpi_insn),
        .ms1_reg_id(ms1_reg_id),
        .ms2_reg_id(ms2_reg_id),
        .md_acc_id(md_acc_id),
        .mac_done(mac_done),
        
        .out_mtilem(out_mtilem), 
        .out_mtilen(out_mtilen), 
        .out_mtilek(out_mtilek),
        .out_xmsaten(out_xmsaten),
        
        // Ghi kết quả vào Regfile (Thông qua đường MUX)
        .mac_reg_we(mac_reg_we),
        .mac_reg_id(mac_reg_id),
        .mac_reg_row_idx(mac_reg_row_idx),
        .mac_reg_beat_idx(mac_reg_beat_idx),
        .mac_reg_wdata(mac_reg_wdata),
        
        // Đọc nguyên liệu từ Regfile
        .read_id_A(mac_read_id_A), .read_row_A(mac_read_row_A), .read_beat_A(mac_read_beat_A),
        .read_data_A(reg_mac_rdata_A),
        
        .read_id_B(mac_read_id_B), .read_row_B(mac_read_row_B), .read_beat_B(mac_read_beat_B),
        .read_data_B(reg_mac_rdata_B),
        
        .read_id_C(mac_read_id_C), .read_row_C(mac_read_row_C), .read_beat_C(mac_read_beat_C),
        .read_data_C(reg_mac_rdata_C),

        .vec_read_id_A(mac_vec_read_id_A),
        .vec_read_beats_A(mac_vec_read_beats_A),
        .vec_read_data_A(reg_mac_vec_rdata_A),

        .vec_read_id_B(mac_vec_read_id_B),
        .vec_read_beats_B(mac_vec_read_beats_B),
        .vec_read_data_B(reg_mac_vec_rdata_B)
    );

    // 3.5. KHỐI MISC
    matrix_misc #(
        .MATRIX_DIM(REG_ROWS),
        .BEATS_PER_ROW(REG_BEATS_PER_ROW)
    ) u_misc (
        .clk(clk),
        .resetn(resetn),

        .start_misc(start_misc),
        .pcpi_insn(pcpi_insn),
        .pcpi_rs1(pcpi_rs1),
        .pcpi_rs2(pcpi_rs2),

        .misc_done(misc_done),

        .misc_reg_we(misc_reg_we),
        .misc_reg_id(misc_reg_id),
        .misc_reg_row_idx(misc_reg_row_idx),
        .misc_reg_beat_idx(misc_reg_beat_idx),
        .misc_reg_wdata(misc_reg_wdata),

        .read_id_A(misc_read_id_A),
        .read_row_A(misc_read_row_A),
        .read_beat_A(misc_read_beat_A),
        .read_data_A(reg_mac_rdata_A),

        .misc_gpr_we(misc_gpr_we),
        .misc_gpr_wdata(misc_gpr_wdata)
    );

    // 3.6. KHỐI ELEMENT-WISE (INTEGER)
    matrix_ew #(
        .MATRIX_DIM(REG_ROWS),
        .BEATS_PER_ROW(REG_BEATS_PER_ROW)
    ) u_ew (
        .clk(clk),
        .resetn(resetn),

        .start_ew(start_ew),
        .pcpi_insn(pcpi_insn),
        .out_xmsaten(out_xmsaten),
        .out_mtilem(out_mtilem),
        .out_mtilen(out_mtilen),

        .ew_done(ew_done),

        .ew_reg_we(ew_reg_we),
        .ew_reg_id(ew_reg_id),
        .ew_reg_row_idx(ew_reg_row_idx),
        .ew_reg_beat_idx(ew_reg_beat_idx),
        .ew_reg_wdata(ew_reg_wdata),

        .read_id_A(ew_read_id_A),
        .read_row_A(ew_read_row_A),
        .read_beat_A(ew_read_beat_A),
        .read_data_A(reg_mac_rdata_A),

        .read_id_B(ew_read_id_B),
        .read_row_B(ew_read_row_B),
        .read_beat_B(ew_read_beat_B),
        .read_data_B(reg_mac_rdata_B)
    );

    // 4. NHÀ KHO CHỨA DỮ LIỆU VÀ CẤU HÌNH (Regfile & CSR)
    matrix_regfile #(
        .MATRIX_DIM(REG_ROWS),
        .BEATS_PER_ROW(REG_BEATS_PER_ROW)
    ) u_regfile (
        .clk(clk), 
        .resetn(resetn),
        
        // CỔNG GHI (Đã được Arbiter cấp quyền cho DMA hoặc MAC)
        .reg_we(core_reg_we), 
        .reg_id(core_reg_id),
        .reg_row_idx(core_reg_row_idx), 
        .reg_beat_idx(core_reg_beat_idx),
        .reg_wdata(core_reg_wdata), 
        
        // CỔNG ĐỌC DÀNH CHO DMA (Phục vụ lệnh Store)
        .dma_read_id(dma_reg_id),
        .dma_read_row(dma_reg_row_idx),
        .dma_read_beat(dma_reg_beat_idx),
        .reg_rdata(reg_dma_rdata),
        
        // CÁC CỔNG ĐỌC DÀNH CHO MAC ARRAY (Đọc A, B và C)
        .mac_read_id_A(core_read_id_A), 
        .mac_read_row_A(core_read_row_A), 
        .mac_read_beat_A(core_read_beat_A),
        .reg_mac_rdata_A(reg_mac_rdata_A),
        
        .mac_read_id_B(core_read_id_B), 
        .mac_read_row_B(core_read_row_B), 
        .mac_read_beat_B(core_read_beat_B),
        .reg_mac_rdata_B(reg_mac_rdata_B),
        
        .mac_read_id_C(core_read_id_C), 
        .mac_read_row_C(core_read_row_C), 
        .mac_read_beat_C(core_read_beat_C),
        .reg_mac_rdata_C(reg_mac_rdata_C),

        .mac_vec_read_id_A(mac_vec_read_id_A),
        .mac_vec_read_beats_A(mac_vec_read_beats_A),
        .reg_mac_vec_rdata_A(reg_mac_vec_rdata_A),

        .mac_vec_read_id_B(mac_vec_read_id_B),
        .mac_vec_read_beats_B(mac_vec_read_beats_B),
        .reg_mac_vec_rdata_B(reg_mac_vec_rdata_B),
        
        // Cổng giao tiếp cấu hình CSR (PCPI)
        .csr_we(cfg_we),
        .csr_addr(cfg_addr),
        .csr_wdata(cfg_wdata),
        .csr_rdata(csr_rdata),
        
        .out_mtilem(out_mtilem), 
        .out_mtilen(out_mtilen), 
        .out_mtilek(out_mtilek),
        .out_xmxrm(out_xmxrm), 
        .out_xmsat(out_xmsat), 
        .out_xmfrm(out_xmfrm), 
        .out_xmsaten(out_xmsaten)
    );

endmodule
