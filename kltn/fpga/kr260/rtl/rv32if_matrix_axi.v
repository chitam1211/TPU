// =============================================================================
// rv32if_matrix_axi: AXI4-Lite slave boc rv32if_matrix_soc de PS (Zynq MPSoC) dieu khien.
//
// Ban do dia chi (offset byte, moi thanh ghi 32 bit):
//   0x0000 CTRL      RW  [0] RUN: 1 = nha reset core (chay tu PC = 0), 0 = giu reset.
//                        Canh len cua RUN xoa CYCLES va MDONE_CNT.
//   0x0004 STATUS    RO  [0] running  [1] halted  [2] matrix_busy  [3] matrix_done (da xay ra)
//   0x0008 CYCLES    RO  so chu ky tu khi RUN = 1 toi khi halted
//   0x000C PC        RO  pc_address cua core
//   0x0010 MTILEM    RO
//   0x0014 MTILEN    RO
//   0x0018 MTILEK    RO
//   0x001C MDONE_CNT RO  so lenh ma tran da xong (so xung matrix_done)
//   0x0020 MREG_SEL  RW  [2:0] reg id, [10:8] row, [18:16] beat (32 bit/beat)
//   0x0024 MREG_DATA RW  ghi: ghi 1 beat vao thanh ghi ma tran MREG_SEL; doc: beat do
//   0x0028 ID        RO  0x4B4C544E ("KLTN")
//   0x1000-0x13FF    IMEM 256 word  } chi truy cap duoc khi RUN = 0;
//   0x2000-0x23FF    DMEM 256 word  } khi RUN = 1: ghi bi bo qua, doc tra ve 0xDEADBEEF
// Moi giao dich deu tra BRESP/RRESP = OKAY. irq = halted (muc).
// =============================================================================
module rv32if_matrix_axi #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 14,
    parameter HALT_CYCLES        = 64
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire                            s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                            s_axi_aresetn,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]   s_axi_awaddr,
    input  wire [2:0]                      s_axi_awprot,
    input  wire                            s_axi_awvalid,
    output wire                            s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]   s_axi_wdata,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0] s_axi_wstrb,
    input  wire                            s_axi_wvalid,
    output wire                            s_axi_wready,
    output wire [1:0]                      s_axi_bresp,
    output reg                             s_axi_bvalid,
    input  wire                            s_axi_bready,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]   s_axi_araddr,
    input  wire [2:0]                      s_axi_arprot,
    input  wire                            s_axi_arvalid,
    output wire                            s_axi_arready,
    output reg  [C_S_AXI_DATA_WIDTH-1:0]   s_axi_rdata,
    output wire [1:0]                      s_axi_rresp,
    output reg                             s_axi_rvalid,
    input  wire                            s_axi_rready,

    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "SENSITIVITY LEVEL_HIGH" *)
    output wire                            irq
    );

    localparam [31:0] ID_VALUE = 32'h4B4C544E;
    localparam [31:0] BUSY_RD  = 32'hDEADBEEF;

    localparam [2:0] S_IDLE    = 3'd0,
                     S_WR_EXEC = 3'd1,
                     S_WR_RESP = 3'd2,
                     S_RD_EXEC = 3'd3,
                     S_RD_CAPT = 3'd4,
                     S_RD_RESP = 3'd5;

    localparam [1:0] RGN_REG = 2'd0, RGN_IMEM = 2'd1, RGN_DMEM = 2'd2;

    reg  [2:0]  state;
    reg  [13:0] addr;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;

    reg         run;
    reg         core_rst_n;
    reg  [31:0] cycles;
    reg  [31:0] mdone_cnt;
    reg         mdone_seen;
    reg  [2:0]  msel_id, msel_row, msel_beat;

    wire [1:0]  region = addr[13:12];
    wire [7:0]  word   = addr[9:2];

    wire        halted, matrix_busy, matrix_done;
    wire [31:0] pc_address, mtilem, mtilen, mtilek, mreg_rdata;
    wire [31:0] imem_rdata, dmem_rdata;

    // ---------------- AXI handshake ----------------
    // Ghi uu tien hon doc; mot giao dich tai mot thoi diem.
    wire wr_go = (state == S_IDLE) && s_axi_awvalid && s_axi_wvalid;
    wire rd_go = (state == S_IDLE) && !wr_go && s_axi_arvalid;

    assign s_axi_awready = wr_go;
    assign s_axi_wready  = wr_go;
    assign s_axi_arready = rd_go;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_rresp   = 2'b00;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            state        <= S_IDLE;
            s_axi_bvalid <= 1'b0;
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= 32'h0;
            addr         <= 14'h0;
            wdata        <= 32'h0;
            wstrb        <= 4'h0;
        end
        else begin
            case (state)
                S_IDLE: begin
                    if (wr_go) begin
                        addr  <= s_axi_awaddr[13:0];
                        wdata <= s_axi_wdata;
                        wstrb <= s_axi_wstrb;
                        state <= S_WR_EXEC;
                    end
                    else if (rd_go) begin
                        addr  <= s_axi_araddr[13:0];
                        state <= S_RD_EXEC;
                    end
                end
                S_WR_EXEC: begin
                    s_axi_bvalid <= 1'b1;
                    state        <= S_WR_RESP;
                end
                S_WR_RESP: begin
                    if (s_axi_bready) begin
                        s_axi_bvalid <= 1'b0;
                        state        <= S_IDLE;
                    end
                end
                S_RD_EXEC: begin
                    // bo nho dong bo: data_out co o chu ky sau
                    state <= S_RD_CAPT;
                end
                S_RD_CAPT: begin
                    s_axi_rdata  <= read_mux(region, addr[7:2]);
                    s_axi_rvalid <= 1'b1;
                    state        <= S_RD_RESP;
                end
                S_RD_RESP: begin
                    if (s_axi_rready) begin
                        s_axi_rvalid <= 1'b0;
                        state        <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    function [31:0] read_mux(input [1:0] rgn, input [5:0] reg_idx);
        begin
            case (rgn)
                RGN_IMEM: read_mux = run ? BUSY_RD : imem_rdata;
                RGN_DMEM: read_mux = run ? BUSY_RD : dmem_rdata;
                RGN_REG: begin
                    case (reg_idx)
                        6'h00: read_mux = {31'b0, run};
                        6'h01: read_mux = {28'b0, mdone_seen, matrix_busy, halted, core_rst_n};
                        6'h02: read_mux = cycles;
                        6'h03: read_mux = pc_address;
                        6'h04: read_mux = mtilem;
                        6'h05: read_mux = mtilen;
                        6'h06: read_mux = mtilek;
                        6'h07: read_mux = mdone_cnt;
                        6'h08: read_mux = {13'b0, msel_beat, 5'b0, msel_row, 5'b0, msel_id};
                        6'h09: read_mux = mreg_rdata;
                        6'h0A: read_mux = ID_VALUE;
                        default: read_mux = 32'h0;
                    endcase
                end
                default: read_mux = 32'h0;
            endcase
        end
    endfunction

    // ---------------- Thanh ghi dieu khien ----------------
    wire wr_exec  = (state == S_WR_EXEC);
    wire wr_reg   = wr_exec && region == RGN_REG;
    wire wr_ctrl  = wr_reg && addr[7:2] == 6'h00 && wstrb[0];
    wire wr_msel  = wr_reg && addr[7:2] == 6'h08;
    wire wr_mdata = wr_reg && addr[7:2] == 6'h09;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            run        <= 1'b0;
            core_rst_n <= 1'b0;
            msel_id    <= 3'd0;
            msel_row   <= 3'd0;
            msel_beat  <= 3'd0;
        end
        else begin
            if (wr_ctrl) run <= wdata[0];
            core_rst_n <= run;           // reset core duoc dang ky, nha sau RUN 1 chu ky
            if (wr_msel) begin
                if (wstrb[0]) msel_id   <= wdata[2:0];
                if (wstrb[1]) msel_row  <= wdata[10:8];
                if (wstrb[2]) msel_beat <= wdata[18:16];
            end
        end
    end

    // Bo dem: xoa khi core dang reset (tuc la ngay truoc canh len cua RUN)
    always @(posedge s_axi_aclk) begin
        if (!core_rst_n) begin
            cycles     <= 32'd0;
            mdone_cnt  <= 32'd0;
            mdone_seen <= 1'b0;
        end
        else begin
            if (!halted) cycles <= cycles + 32'd1;
            if (matrix_done) begin
                mdone_cnt  <= mdone_cnt + 32'd1;
                mdone_seen <= 1'b1;
            end
        end
    end

    assign irq = halted;

    // ---------------- SoC ----------------
    // Chi khi core da that su o reset (core_rst_n tre RUN 1 chu ky): SoC moi chuyen
    // bo nho sang host (host_mode = !core_rst_n).
    wire host_mem_cycle = !run && !core_rst_n && ((state == S_WR_EXEC) || (state == S_RD_EXEC));

    rv32if_matrix_soc #(
        .HALT_CYCLES(HALT_CYCLES)
    ) u_soc (
        .clk(s_axi_aclk),
        .core_rst_n(core_rst_n),

        .host_imem_req(host_mem_cycle && region == RGN_IMEM),
        .host_dmem_req(host_mem_cycle && region == RGN_DMEM),
        .host_we(wr_exec),
        .host_wstrb(wstrb),
        .host_word_addr(word),
        .host_wdata(wdata),
        .host_imem_rdata(imem_rdata),
        .host_dmem_rdata(dmem_rdata),

        .matrix_host_reg_we(wr_mdata),
        .matrix_host_reg_id(msel_id),
        .matrix_host_reg_row_idx(msel_row),
        .matrix_host_reg_beat_idx(msel_beat),
        .matrix_host_reg_wdata(wdata),
        .matrix_host_read_id(msel_id),
        .matrix_host_read_row(msel_row),
        .matrix_host_read_beat(msel_beat),
        .matrix_host_reg_rdata(mreg_rdata),
        .matrix_debug_mtilem(mtilem),
        .matrix_debug_mtilen(mtilen),
        .matrix_debug_mtilek(mtilek),
        .matrix_busy(matrix_busy),
        .matrix_done(matrix_done),

        .pc_address(pc_address),
        .halted(halted)
    );
endmodule
