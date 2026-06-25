module matrix_regfile #(
    parameter int MATRIX_DIM = 4,
    parameter int BEATS_PER_ROW = 4,      // Tile row beats: TRLEN / 32
    parameter int ACC_BEATS_PER_ROW = 8,  // Acc row beats: ARLEN / 32. Use 4 if ELEN=32, 8 if ELEN=64.
    // Giá trị cấu hình mẫu cho xmisa: Hỗ trợ INT8 (mmi8i32) và FP16 (mmf16f16)
    parameter logic [31:0] ISA_FEATURE = 32'h0000_0002
)(
    input  logic clk,
    input  logic resetn,

    // =========================================================================
    // 1. Giao tiếp dữ liệu ma trận (host/load-store + compute units truy cập)
    // =========================================================================
    input  logic        reg_we,
    input  logic [2:0]  reg_id,       // 0-3: Tile (tr0-tr3), 4-7: Acc (acc0-acc3)
    input  logic [2:0]  reg_row_idx,
    input  logic [2:0]  reg_beat_idx,
    input  logic [31:0] reg_wdata,

    input  logic [2:0]  host_read_id,
    input  logic [2:0]  host_read_row,
    input  logic [2:0]  host_read_beat,
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
    // 3. Tín hiệu cấu hình xuất ra cho các module khác (load/store, MAC, EW, MISC)
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
    // Split bank:
    //   tr_regs[0:3]  -> tr0-tr3, row width = BEATS_PER_ROW * 32 = TRLEN
    //   acc_regs[0:3] -> acc0-acc3, row width = ACC_BEATS_PER_ROW * 32 = ARLEN
    // reg_id[2] selects bank: 0 = tile, 1 = accumulator.
    // reg_id[1:0] selects index inside the bank.
    //
    // Physical storage is one 32-bit word per beat. Keeping beat as a real
    // array dimension avoids dynamic part-select races in simulation and maps
    // directly to the logical access pattern: register -> row -> beat.
    logic [31:0] tr_regs  [0:3][0:MATRIX_DIM-1][0:BEATS_PER_ROW-1];
    logic [31:0] acc_regs [0:3][0:MATRIX_DIM-1][0:ACC_BEATS_PER_ROW-1];

    logic       wr_is_acc;
    logic [1:0] wr_idx;
    logic       wr_tr_valid;
    logic       wr_acc_valid;
    logic [3:0] tr_wen_oh;
    logic [3:0] acc_wen_oh;

    assign wr_is_acc = reg_id[2];
    assign wr_idx    = reg_id[1:0];

    assign wr_tr_valid  = reg_we && !wr_is_acc &&
                          (reg_row_idx < MATRIX_DIM) &&
                          (reg_beat_idx < BEATS_PER_ROW);

    assign wr_acc_valid = reg_we && wr_is_acc &&
                          (reg_row_idx < MATRIX_DIM) &&
                          (reg_beat_idx < ACC_BEATS_PER_ROW);

    assign tr_wen_oh  = wr_tr_valid  ? (4'b0001 << wr_idx) : 4'b0000;
    assign acc_wen_oh = wr_acc_valid ? (4'b0001 << wr_idx) : 4'b0000;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            for (int i = 0; i < 4; i++) begin
                for (int r = 0; r < MATRIX_DIM; r++) begin
                    for (int b = 0; b < BEATS_PER_ROW; b++) begin
                        tr_regs[i][r][b] <= 32'b0;
                    end
                    for (int b = 0; b < ACC_BEATS_PER_ROW; b++) begin
                        acc_regs[i][r][b] <= 32'b0;
                    end
                end
            end
        end else begin
            for (int i = 0; i < 4; i++) begin
                if (tr_wen_oh[i]) begin
                    tr_regs[i][reg_row_idx][reg_beat_idx] <= reg_wdata;
                end

                if (acc_wen_oh[i]) begin
                    acc_regs[i][reg_row_idx][reg_beat_idx] <= reg_wdata;
                end
            end
        end
    end

    function automatic logic [31:0] read_word(
        input logic [2:0] id,
        input logic [2:0] row,
        input logic [2:0] beat
    );
        begin
            read_word = 32'b0;

            if (!id[2]) begin
                if ((row < MATRIX_DIM) && (beat < BEATS_PER_ROW)) begin
                    read_word = tr_regs[id[1:0]][row][beat];
                end
            end else begin
                if ((row < MATRIX_DIM) && (beat < ACC_BEATS_PER_ROW)) begin
                    read_word = acc_regs[id[1:0]][row][beat];
                end
            end
        end
    endfunction

    function automatic logic [63:0] read_dword(
        input logic [2:0] id,
        input logic [2:0] row,
        input logic [2:0] beat
    );
        logic [3:0] beat_next;
        logic [31:0] lo_word;
        logic [31:0] hi_word;
        begin
            beat_next = {1'b0, beat} + 4'd1;
            lo_word   = read_word(id, row, beat);
            hi_word   = 32'b0;

            if (!id[2]) begin
                if ((row < MATRIX_DIM) && (beat_next < BEATS_PER_ROW)) begin
                    hi_word = read_word(id, row, beat_next[2:0]);
                end
            end else begin
                if ((row < MATRIX_DIM) && (beat_next < ACC_BEATS_PER_ROW)) begin
                    hi_word = read_word(id, row, beat_next[2:0]);
                end
            end

            read_dword = {hi_word, lo_word};
        end
    endfunction

    always_comb begin
        reg_rdata       = read_word(host_read_id, host_read_row, host_read_beat);
        reg_mac_rdata_A = read_word(mac_read_id_A, mac_read_row_A, mac_read_beat_A);
        reg_mac_rdata_B = read_word(mac_read_id_B, mac_read_row_B, mac_read_beat_B);
        reg_mac_rdata_C = read_dword(mac_read_id_C, mac_read_row_C, mac_read_beat_C);

        reg_mac_vec_rdata_A[31:0] =
            read_word(mac_vec_read_id_A, 3'd0, mac_vec_read_beats_A[2:0]);
        reg_mac_vec_rdata_A[63:32] =
            read_word(mac_vec_read_id_A, 3'd1, mac_vec_read_beats_A[5:3]);
        reg_mac_vec_rdata_A[95:64] =
            read_word(mac_vec_read_id_A, 3'd2, mac_vec_read_beats_A[8:6]);
        reg_mac_vec_rdata_A[127:96] =
            read_word(mac_vec_read_id_A, 3'd3, mac_vec_read_beats_A[11:9]);

        reg_mac_vec_rdata_B[31:0] =
            read_word(mac_vec_read_id_B, 3'd0, mac_vec_read_beats_B[2:0]);
        reg_mac_vec_rdata_B[63:32] =
            read_word(mac_vec_read_id_B, 3'd1, mac_vec_read_beats_B[5:3]);
        reg_mac_vec_rdata_B[95:64] =
            read_word(mac_vec_read_id_B, 3'd2, mac_vec_read_beats_B[8:6]);
        reg_mac_vec_rdata_B[127:96] =
            read_word(mac_vec_read_id_B, 3'd3, mac_vec_read_beats_B[11:9]);
    end


    // =========================================================================
    // LÕI LƯU TRỮ CSR (Control and Status Registers)
    // =========================================================================
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

    assign out_mtilem  = csr_mtilem;
    assign out_mtilen  = csr_mtilen;
    assign out_mtilek  = csr_mtilek;
    assign out_xmxrm   = csr_xmxrm;
    assign out_xmsat   = csr_xmsat;
    assign out_xmfrm   = csr_xmfrm;
    assign out_xmsaten = csr_xmsaten;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            csr_mtilem   <= 32'b0;
            csr_mtilen   <= 32'b0;
            csr_mtilek   <= 32'b0;
            csr_xmfflags <= 5'b0;
            csr_xmfrm    <= 3'b0;
            csr_xmxrm    <= 2'b0;
            csr_xmsat    <= 1'b0;
            csr_xmsaten  <= 1'b0;
        end else if (csr_we) begin
            case (csr_addr)
                12'h802: begin // Ghi toàn bộ xmcsr
                    csr_xmsaten  <= csr_wdata[11];
                    csr_xmfrm    <= csr_wdata[10:8];
                    csr_xmfflags <= csr_wdata[7:3];
                    csr_xmsat    <= csr_wdata[2];
                    csr_xmxrm    <= csr_wdata[1:0];
                end
                12'h803: csr_mtilem   <= (csr_wdata > MAX_M_TILE) ? MAX_M_TILE : csr_wdata;
                12'h804: csr_mtilen   <= (csr_wdata > MAX_N_TILE) ? MAX_N_TILE : csr_wdata;
                12'h805: csr_mtilek   <= (csr_wdata > MAX_K_TILE) ? MAX_K_TILE : csr_wdata;
                12'h806: csr_xmxrm    <= csr_wdata[1:0];
                12'h807: csr_xmsat    <= csr_wdata[0];
                12'h808: csr_xmfflags <= csr_wdata[4:0];
                12'h809: csr_xmfrm    <= csr_wdata[2:0];
                12'h80A: csr_xmsaten  <= csr_wdata[0];
                default: ;
            endcase
        end
    end

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

            // Các thanh ghi Read-Only (Hardware Info)
            12'hCC0: csr_rdata = ISA_FEATURE;                       // xmisa
            12'hCC1: csr_rdata = MATRIX_DIM * BEATS_PER_ROW * 4;     // xtlenb
            12'hCC2: csr_rdata = BEATS_PER_ROW * 4;                  // xtrlenb
            12'hCC3: csr_rdata = MATRIX_DIM * ACC_BEATS_PER_ROW * 4; // xalenb

            default: csr_rdata = 32'b0;
        endcase
    end

endmodule
