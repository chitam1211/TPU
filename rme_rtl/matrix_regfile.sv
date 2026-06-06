module matrix_regfile #(
    parameter int MATRIX_DIM = 4,
    parameter int BEATS_PER_ROW = 4,
    // Giá trị cấu hình mẫu cho xmisa: Hỗ trợ INT8 (mmi8i32) và FP16 (mmf16f16)
    parameter logic [31:0] ISA_FEATURE = 32'h0000_0002
)(
    input  logic clk,
    input  logic resetn,

    // =========================================================================
    // 1. Giao tiếp Dữ liệu ma trận (DMA & MAC Array truy cập)
    // =========================================================================
    input  logic        reg_we,
    input  logic [2:0]  reg_id,       // 0-3: Tile (tr0-tr3), 4-7: Acc (acc0-acc3)
    input  logic [2:0]  reg_row_idx,
    input  logic [2:0]  reg_beat_idx,
    input  logic [31:0] reg_wdata,

    input  logic [2:0]  dma_read_id,
    input  logic [2:0]  dma_read_row,
    input  logic [2:0]  dma_read_beat,
    output logic [31:0] reg_rdata,

    // MAC/EW/MISC read ports
    input  logic [2:0]  mac_read_id_A,
    input  logic [2:0]  mac_read_row_A,
    input  logic [2:0]  mac_read_beat_A,
    output logic [31:0] reg_mac_rdata_A,

    input  logic [2:0]  mac_read_id_B,
    input  logic [2:0]  mac_read_row_B,
    input  logic [2:0]  mac_read_beat_B,
    output logic [31:0] reg_mac_rdata_B,

    input  logic [2:0]  mac_read_id_C,
    input  logic [2:0]  mac_read_row_C,
    input  logic [2:0]  mac_read_beat_C,
    output logic [63:0] reg_mac_rdata_C,

    // Systolic MAC boundary read ports. Packed output order is
    // {row3_word, row2_word, row1_word, row0_word}.
    input  logic [2:0]   mac_vec_read_id_A,
    input  logic [11:0]  mac_vec_read_beats_A,
    output logic [127:0] reg_mac_vec_rdata_A,

    input  logic [2:0]   mac_vec_read_id_B,
    input  logic [11:0]  mac_vec_read_beats_B,
    output logic [127:0] reg_mac_vec_rdata_B,

    // =========================================================================
    // 2. Giao tiếp điều khiển CSR (CPU matrix issue truy cập)
    // =========================================================================
    input  logic        csr_we,
    input  logic [11:0] csr_addr,     // Địa chỉ 12-bit chuẩn của RISC-V CSR
    input  logic [31:0] csr_wdata,
    output logic [31:0] csr_rdata,

    // =========================================================================
    // 3. Tín hiệu cấu hình xuất ra cho các module khác (DMA, MAC)
    // =========================================================================
    output logic [31:0] out_mtilem,
    output logic [31:0] out_mtilen,
    output logic [31:0] out_mtilek,
    output logic [1:0]  out_xmxrm,    // Chế độ làm tròn số nguyên/fixed-point
    output logic        out_xmsat,    // Cờ bão hòa
    output logic [2:0]  out_xmfrm,    // Chế độ làm tròn số thực
    output logic        out_xmsaten   // Bật/tắt chế độ bão hòa
);

    // =========================================================================
    // LÕI LƯU TRỮ MA TRẬN (Architectural Matrix Registers)
    // =========================================================================
    // Cấu trúc 3D: [8 thanh ghi] x [MATRIX_DIM hàng] x [4 beats 32-bit (128-bit/hàng)]
    logic [31:0] matrix_regs [0:7][0:MATRIX_DIM-1][0:BEATS_PER_ROW-1];

    always_ff @(posedge clk) begin
        if (!resetn) begin
            // Reset toàn bộ 8 thanh ghi ma trận
            for (int i = 0; i < 8; i++) begin
                for (int r = 0; r < MATRIX_DIM; r++) begin
                    for (int b = 0; b < BEATS_PER_ROW; b++) begin
                        matrix_regs[i][r][b] <= '0;
                    end
                end
            end
        end else if (reg_we) begin
            if (reg_id < 8 && reg_row_idx < MATRIX_DIM && reg_beat_idx < BEATS_PER_ROW) begin
                matrix_regs[reg_id][reg_row_idx][reg_beat_idx] <= reg_wdata;
            end
        end
    end

    // Combinational read data
    assign reg_rdata = (dma_read_id < 8 && dma_read_row < MATRIX_DIM && dma_read_beat < BEATS_PER_ROW)
                     ? matrix_regs[dma_read_id][dma_read_row][dma_read_beat]
                     : '0;

    assign reg_mac_rdata_A = (mac_read_id_A < 8 && mac_read_row_A < MATRIX_DIM && mac_read_beat_A < BEATS_PER_ROW)
                           ? matrix_regs[mac_read_id_A][mac_read_row_A][mac_read_beat_A]
                           : '0;

    assign reg_mac_rdata_B = (mac_read_id_B < 8 && mac_read_row_B < MATRIX_DIM && mac_read_beat_B < BEATS_PER_ROW)
                           ? matrix_regs[mac_read_id_B][mac_read_row_B][mac_read_beat_B]
                           : '0;

    assign reg_mac_rdata_C = (mac_read_id_C < 8 && mac_read_row_C < MATRIX_DIM && mac_read_beat_C < BEATS_PER_ROW)
                           ? {32'b0, matrix_regs[mac_read_id_C][mac_read_row_C][mac_read_beat_C]}
                           : 64'b0;

    assign reg_mac_vec_rdata_A[31:0] =
        (mac_vec_read_id_A < 8 && 3'd0 < MATRIX_DIM && mac_vec_read_beats_A[2:0] < BEATS_PER_ROW)
        ? matrix_regs[mac_vec_read_id_A][0][mac_vec_read_beats_A[2:0]] : 32'b0;
    assign reg_mac_vec_rdata_A[63:32] =
        (mac_vec_read_id_A < 8 && 3'd1 < MATRIX_DIM && mac_vec_read_beats_A[5:3] < BEATS_PER_ROW)
        ? matrix_regs[mac_vec_read_id_A][1][mac_vec_read_beats_A[5:3]] : 32'b0;
    assign reg_mac_vec_rdata_A[95:64] =
        (mac_vec_read_id_A < 8 && 3'd2 < MATRIX_DIM && mac_vec_read_beats_A[8:6] < BEATS_PER_ROW)
        ? matrix_regs[mac_vec_read_id_A][2][mac_vec_read_beats_A[8:6]] : 32'b0;
    assign reg_mac_vec_rdata_A[127:96] =
        (mac_vec_read_id_A < 8 && 3'd3 < MATRIX_DIM && mac_vec_read_beats_A[11:9] < BEATS_PER_ROW)
        ? matrix_regs[mac_vec_read_id_A][3][mac_vec_read_beats_A[11:9]] : 32'b0;

    assign reg_mac_vec_rdata_B[31:0] =
        (mac_vec_read_id_B < 8 && 3'd0 < MATRIX_DIM && mac_vec_read_beats_B[2:0] < BEATS_PER_ROW)
        ? matrix_regs[mac_vec_read_id_B][0][mac_vec_read_beats_B[2:0]] : 32'b0;
    assign reg_mac_vec_rdata_B[63:32] =
        (mac_vec_read_id_B < 8 && 3'd1 < MATRIX_DIM && mac_vec_read_beats_B[5:3] < BEATS_PER_ROW)
        ? matrix_regs[mac_vec_read_id_B][1][mac_vec_read_beats_B[5:3]] : 32'b0;
    assign reg_mac_vec_rdata_B[95:64] =
        (mac_vec_read_id_B < 8 && 3'd2 < MATRIX_DIM && mac_vec_read_beats_B[8:6] < BEATS_PER_ROW)
        ? matrix_regs[mac_vec_read_id_B][2][mac_vec_read_beats_B[8:6]] : 32'b0;
    assign reg_mac_vec_rdata_B[127:96] =
        (mac_vec_read_id_B < 8 && 3'd3 < MATRIX_DIM && mac_vec_read_beats_B[11:9] < BEATS_PER_ROW)
        ? matrix_regs[mac_vec_read_id_B][3][mac_vec_read_beats_B[11:9]] : 32'b0;


    // =========================================================================
    // LÕI LƯU TRỮ CSR (Control and Status Registers)
    // =========================================================================
    // Khai báo các thanh ghi nội bộ theo chuẩn tài liệu
    localparam logic [31:0] MAX_M_TILE = MATRIX_DIM;
    localparam logic [31:0] MAX_N_TILE = MATRIX_DIM;
    localparam logic [31:0] MAX_K_TILE = 32'd16;

    logic [31:0] csr_mtilem;
    logic [31:0] csr_mtilen;
    logic [31:0] csr_mtilek;
    
    // Các cờ và chế độ hoạt động (Tách ra từ xmcsr)
    logic [4:0]  csr_xmfflags; 
    logic [2:0]  csr_xmfrm;    
    logic [1:0]  csr_xmxrm;    
    logic        csr_xmsat;    
    logic        csr_xmsaten;  

    // Nối tín hiệu ra ngoài để DMA/MAC sử dụng
    assign out_mtilem  = csr_mtilem;
    assign out_mtilen  = csr_mtilen;
    assign out_mtilek  = csr_mtilek;
    assign out_xmxrm   = csr_xmxrm;
    assign out_xmsat   = csr_xmsat;
    assign out_xmfrm   = csr_xmfrm;
    assign out_xmsaten = csr_xmsaten;

    // Ghi vào CSR (CPU cấu hình qua matrix issue)
    always_ff @(posedge clk) begin
        if (!resetn) begin
            csr_mtilem   <= '0;
            csr_mtilen   <= '0;
            csr_mtilek   <= '0;
            csr_xmfflags <= '0;
            csr_xmfrm    <= '0;
            csr_xmxrm    <= '0;
            csr_xmsat    <= '0;
            csr_xmsaten  <= '0;
        end else if (csr_we) begin
            case (csr_addr)
                12'h802: begin // Ghi toàn bộ xmcsr
                    csr_xmsaten  <= csr_wdata[11];
                    csr_xmfrm    <= csr_wdata[10:8];
                    csr_xmfflags <= csr_wdata[7:3];
                    csr_xmsat    <= csr_wdata[2];
                    csr_xmxrm    <= csr_wdata[1:0];
                end
                12'h803: csr_mtilem  <= (csr_wdata > MAX_M_TILE) ? MAX_M_TILE : csr_wdata;
                12'h804: csr_mtilen  <= (csr_wdata > MAX_N_TILE) ? MAX_N_TILE : csr_wdata;
                12'h805: csr_mtilek  <= (csr_wdata > MAX_K_TILE) ? MAX_K_TILE : csr_wdata;
                // Các thanh ghi cho phép truy cập độc lập các trường của xmcsr
                12'h806: csr_xmxrm   <= csr_wdata[1:0];
                12'h807: csr_xmsat   <= csr_wdata[0];
                12'h808: csr_xmfflags<= csr_wdata[4:0];
                12'h809: csr_xmfrm   <= csr_wdata[2:0];
                12'h80A: csr_xmsaten <= csr_wdata[0];
                default: ; // Bỏ qua nếu địa chỉ không hợp lệ
            endcase
        end
    end

    // Đọc từ CSR (CPU lấy trạng thái về)
    always_comb begin
        case (csr_addr)
            12'h802: csr_rdata = {20'b0, csr_xmsaten, csr_xmfrm, csr_xmfflags, csr_xmsat, csr_xmxrm};
            12'h803: csr_rdata = csr_mtilem;
            12'h804: csr_rdata = csr_mtilen;
            12'h805: csr_rdata = csr_mtilek;
            12'h806: csr_rdata = {30'b0, csr_xmxrm};
            12'h807: csr_rdata = {31'b0, csr_xmsat};
            12'h808: csr_rdata = {27'b0, csr_xmfflags};
            12'h809: csr_rdata = {29'b0, csr_xmfrm};
            12'h80A: csr_rdata = {31'b0, csr_xmsaten};
            
            // Các thanh ghi Read-Only (Hardware Info) báo cáo năng lực hệ thống
            12'hCC0: csr_rdata = ISA_FEATURE;          // xmisa
            12'hCC1: csr_rdata = MATRIX_DIM * BEATS_PER_ROW * 4; // xtlenb
            12'hCC2: csr_rdata = BEATS_PER_ROW * 4;              // xtrlenb
            12'hCC3: csr_rdata = MATRIX_DIM * BEATS_PER_ROW * 4; // xalenb
            
            default: csr_rdata = '0;
        endcase
    end

endmodule
