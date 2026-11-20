// =============================================================================
// rv32if_xif_soc: core_matrix_xif (RV32IF core + matrix coprocessor over CV-X-IF) for the
// Zynq UltraScale+ block design (KV260 / KR260, K26 SOM).
//
//   PS --M_AXI_HPM0--> SmartConnect --+--> s_axi (this module): control registers below
//                                     +--> AXI BRAM Controller --> IMEM BRAM port A
//                                     +--> AXI BRAM Controller --> DMEM BRAM port A
//   this module: imem_* --> IMEM BRAM port B (core fetch), dmem_* --> DMEM BRAM port B
//   irq --> pl_ps_irq0 (GIC SPI 121)
//
// The PS loads programs and data through the AXI BRAM Controllers (port A of the true dual-port
// BRAMs); the core uses port B. Unlike fpga/kr260/rtl/rv32if_matrix_axi.v there is no memory
// window in this register block and no memory lock: the PS may read the BRAMs at any time.
// Program image: the same file goes to IMEM and DMEM (code from 0, data / stack / TOHOST in the
// DMEM part of the address map, sw/matrix/link.ld). The core sees IMEM at pc[IMEM_AW-1:0] and
// DMEM at addr[DMEM_AW-1:0] (higher address bits ignored).
//
// Registers (byte offset, 32 bit). 0x00-0x28 as in rv32if_matrix_axi.v.
//   0x00 CTRL        RW  [0] RUN: 1 = release the core from reset (starts at PC 0), 0 = hold it.
//                        Writing RUN 0 -> 1 clears CYCLES, MDONE_CNT, IRQ_STATUS, EXIT_CODE and
//                        the sticky STATUS bits (they keep their value after RUN 1 -> 0).
//   0x04 STATUS      RO  [0] running (core out of reset) [1] halted [2] matrix_busy
//                        [3] matrix_done seen [4] timeout (CYCLES reached MAX_CYCLES)
//                        [5] EXIT_CODE written (store to TOHOST seen)
//   0x08 CYCLES      RO  cycles from reset release up to and including the cycle in which
//                        jal x0,0 executes with the coprocessor idle (no detector delay);
//                        saturates at 0xFFFFFFFF
//   0x0C PC          RO  core fetch address
//   0x10/14/18 MTILEM/N/K RO
//   0x1C MDONE_CNT   RO  completed matrix instructions (matrix_done pulses)
//   0x20 MREG_SEL    RW  [2:0] matrix register id, [10:8] row, [18:16] beat (32 bit / beat)
//   0x24 MREG_DATA   RW  write: one beat of register MREG_SEL; read: that beat. The matrix
//                        registers are reset with the core (writes while RUN = 0 are lost).
//   0x28 ID          RO  0x4B4C544E ("KLTN")
//   0x2C IRQ_EN      RW  [0] done, [1] timeout
//   0x30 IRQ_STATUS  R/W1C [0] done (set when halted rises), [1] timeout (set when the timeout
//                        flag rises). Write 1 to clear a bit; a new event in the same cycle wins.
//                        irq = |(IRQ_STATUS & IRQ_EN), from a flip-flop, level high.
//   0x34 EXIT_CODE   RO  data of the last store by the core to TOHOST_ADDR (use sw)
//   0x38 MAX_CYCLES  RW  watchdog: timeout when CYCLES >= MAX_CYCLES while running; 0 = off.
//                        The core keeps running; the PS stops it with RUN = 0.
//   0x3C CONFIG      RO  [7:0] version 2, [15:8] IMEM_AW, [23:16] DMEM_AW, [24] CV-X-IF
// Other offsets read 0, writes are ignored. Every response is OKAY.
//
// End of program: jal x0,0 (rtl/core_matrix_xif/halt_detect.v, from halt_hint in EX).
// docs/soc_xif_ngat_halt.pdf explains the interrupt / halt mechanisms and the PS flow.
// =============================================================================
module rv32if_xif_soc #(
    parameter        IMEM_AW            = 14,             // IMEM = 2**IMEM_AW bytes (16 KB)
    parameter        DMEM_AW            = 16,             // DMEM = 2**DMEM_AW bytes (64 KB)
    parameter [31:0] TOHOST_ADDR        = 32'h0000_3FF0,  // sw/matrix/start.S
    parameter        DRAIN_CYCLES       = 3,
    parameter        C_S_AXI_DATA_WIDTH = 32,
    parameter        C_S_AXI_ADDR_WIDTH = 12              // 4 KB register window
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
    output reg                             irq,

    // IMEM BRAM port B (Block Memory Generator in BRAM controller mode: byte address,
    // 4 write enables, read latency 1, no output register)
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 IMEM CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME IMEM, MASTER_TYPE BRAM_CTRL, MEM_WIDTH 32, MEM_ECC NONE, READ_WRITE_MODE READ_WRITE, READ_LATENCY 1" *)
    output wire                            imem_clk,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 IMEM RST" *)
    output wire                            imem_rst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 IMEM EN" *)
    output wire                            imem_en,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 IMEM WE" *)
    output wire [3:0]                      imem_we,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 IMEM ADDR" *)
    output wire [31:0]                     imem_addr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 IMEM DIN" *)
    output wire [31:0]                     imem_din,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 IMEM DOUT" *)
    input  wire [31:0]                     imem_dout,

    // DMEM BRAM port B
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 DMEM CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME DMEM, MASTER_TYPE BRAM_CTRL, MEM_WIDTH 32, MEM_ECC NONE, READ_WRITE_MODE READ_WRITE, READ_LATENCY 1" *)
    output wire                            dmem_clk,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 DMEM RST" *)
    output wire                            dmem_rst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 DMEM EN" *)
    output wire                            dmem_en,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 DMEM WE" *)
    output wire [3:0]                      dmem_we,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 DMEM ADDR" *)
    output wire [31:0]                     dmem_addr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 DMEM DIN" *)
    output wire [31:0]                     dmem_din,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 DMEM DOUT" *)
    input  wire [31:0]                     dmem_dout
);
    localparam [31:0] ID_VALUE = 32'h4B4C544E;
    localparam [7:0]  VERSION  = 8'd2;

    localparam [3:0] R_CTRL = 4'h0, R_STATUS = 4'h1, R_CYCLES = 4'h2, R_PC = 4'h3,
                     R_MTILEM = 4'h4, R_MTILEN = 4'h5, R_MTILEK = 4'h6, R_MDONE = 4'h7,
                     R_MSEL = 4'h8, R_MDATA = 4'h9, R_ID = 4'hA, R_IRQ_EN = 4'hB,
                     R_IRQ_STATUS = 4'hC, R_EXIT = 4'hD, R_MAXC = 4'hE, R_CONFIG = 4'hF;

    localparam [1:0] S_IDLE = 2'd0, S_WR_EXEC = 2'd1, S_WR_RESP = 2'd2, S_RD_RESP = 2'd3;

    wire clk = s_axi_aclk;

    // ---------------------------------------------------------------- AXI4-Lite slave
    // One transaction at a time; a write wins over a read in the same cycle.
    reg  [1:0]                    state;
    reg  [C_S_AXI_ADDR_WIDTH-1:0] addr;
    reg  [31:0]                   wdata;
    reg  [3:0]                    wstrb;

    wire wr_go = (state == S_IDLE) && s_axi_awvalid && s_axi_wvalid;
    wire rd_go = (state == S_IDLE) && !wr_go && s_axi_arvalid;

    assign s_axi_awready = wr_go;
    assign s_axi_wready  = wr_go;
    assign s_axi_arready = rd_go;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_rresp   = 2'b00;

    wire [C_S_AXI_ADDR_WIDTH-1:0] rd_a = s_axi_araddr;
    wire                          rd_in_regs = (rd_a >> 6) == 0;
    wire [31:0]                   rd_value;

    always @(posedge clk) begin
        if (!s_axi_aresetn) begin
            state        <= S_IDLE;
            s_axi_bvalid <= 1'b0;
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= 32'h0;
            addr         <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            wdata        <= 32'h0;
            wstrb        <= 4'h0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (wr_go) begin
                        addr  <= s_axi_awaddr;
                        wdata <= s_axi_wdata;
                        wstrb <= s_axi_wstrb;
                        state <= S_WR_EXEC;
                    end else if (rd_go) begin
                        s_axi_rdata  <= rd_value;     // registers only: no read latency
                        s_axi_rvalid <= 1'b1;
                        state        <= S_RD_RESP;
                    end
                end
                S_WR_EXEC: begin
                    s_axi_bvalid <= 1'b1;
                    state        <= S_WR_RESP;
                end
                S_WR_RESP: if (s_axi_bready) begin
                    s_axi_bvalid <= 1'b0;
                    state        <= S_IDLE;
                end
                S_RD_RESP: if (s_axi_rready) begin
                    s_axi_rvalid <= 1'b0;
                    state        <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------- register writes
    wire       wr_exec  = (state == S_WR_EXEC) && ((addr >> 6) == 0);
    wire [3:0] wr_idx   = addr[5:2];
    wire       wr_ctrl  = wr_exec && wr_idx == R_CTRL && wstrb[0];
    wire       wr_msel  = wr_exec && wr_idx == R_MSEL;
    wire       wr_mdata = wr_exec && wr_idx == R_MDATA;
    wire       wr_irqen = wr_exec && wr_idx == R_IRQ_EN && wstrb[0];
    wire       wr_irqst = wr_exec && wr_idx == R_IRQ_STATUS && wstrb[0];
    wire       wr_maxc  = wr_exec && wr_idx == R_MAXC;

    reg        run;
    reg        core_rst_n;        // core reset, released one cycle after RUN = 1
    reg  [2:0] msel_id, msel_row, msel_beat;
    reg  [1:0] irq_en;
    reg [31:0] max_cycles;
    wire       run_start = wr_ctrl && wdata[0] && !run;

    always @(posedge clk) begin
        if (!s_axi_aresetn) begin
            run        <= 1'b0;
            core_rst_n <= 1'b0;
            msel_id    <= 3'd0;
            msel_row   <= 3'd0;
            msel_beat  <= 3'd0;
            irq_en     <= 2'b00;
            max_cycles <= 32'd0;
        end else begin
            if (wr_ctrl) run <= wdata[0];
            core_rst_n <= run;
            if (wr_msel) begin
                if (wstrb[0]) msel_id   <= wdata[2:0];
                if (wstrb[1]) msel_row  <= wdata[10:8];
                if (wstrb[2]) msel_beat <= wdata[18:16];
            end
            if (wr_irqen) irq_en <= wdata[1:0];
            if (wr_maxc) begin
                if (wstrb[0]) max_cycles[7:0]   <= wdata[7:0];
                if (wstrb[1]) max_cycles[15:8]  <= wdata[15:8];
                if (wstrb[2]) max_cycles[23:16] <= wdata[23:16];
                if (wstrb[3]) max_cycles[31:24] <= wdata[31:24];
            end
        end
    end

    // ---------------------------------------------------------------- core + coprocessor
    wire [31:0] pc_address, alu_out_address, store_data, mtilem, mtilen, mtilek, mreg_rdata;
    wire [3:0]  dmask, imask;
    wire        imem_we_re, imem_req, dmem_we_re, dmem_req, load_signal;
    wire        matrix_busy, matrix_done, halt_hint, xif_idle;
    reg         imem_valid, dmem_valid;

    core_matrix_xif u_cm (
        .clk(clk),
        .rst(core_rst_n),
        .instruction(imem_dout),
        .load_data_in(dmem_dout),
        .mask_singal(dmask),
        .load_signal(load_signal),
        .instruc_mask_singal(imask),
        .instruction_mem_we_re(imem_we_re),
        .instruction_mem_request(imem_req),
        .data_mem_we_re(dmem_we_re),
        .data_mem_request(dmem_req),
        .instruc_mem_valid(imem_valid),
        .data_mem_valid(dmem_valid),
        .store_data_out(store_data),
        .pc_address(pc_address),
        .alu_out_address(alu_out_address),

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

        .halt_hint(halt_hint),
        .xif_idle(xif_idle)
    );

    // BRAM port B. A request is answered the next cycle (read latency 1), as by data_mem_top.
    assign imem_clk  = clk;
    assign imem_rst  = 1'b0;
    assign imem_en   = imem_req;
    assign imem_we   = 4'b0000;                              // the core never writes IMEM
    assign imem_addr = {{(32 - IMEM_AW){1'b0}}, pc_address[IMEM_AW-1:2], 2'b00};
    assign imem_din  = 32'h0;

    assign dmem_clk  = clk;
    assign dmem_rst  = 1'b0;
    assign dmem_en   = dmem_req;
    assign dmem_we   = dmem_we_re ? dmask : 4'b0000;
    assign dmem_addr = {{(32 - DMEM_AW){1'b0}}, alu_out_address[DMEM_AW-1:2], 2'b00};
    assign dmem_din  = store_data;

    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            imem_valid <= 1'b0;
            dmem_valid <= 1'b0;
        end else begin
            imem_valid <= imem_req;
            dmem_valid <= dmem_req;
        end
    end

    // ---------------------------------------------------------------- halt, counters
    wire halted, ended;
    halt_detect #(.DRAIN_CYCLES(DRAIN_CYCLES)) u_halt (
        .clk(clk),
        .rst_n(core_rst_n),
        .halt_hint(halt_hint),
        .busy(!xif_idle),
        .halted(halted),
        .ended(ended)
    );

    reg [31:0] cycles, mdone_cnt, exit_code;
    reg        mdone_seen, exit_seen, timeout;
    wire       tohost_wr = core_rst_n && dmem_req && dmem_we_re &&
                           alu_out_address[31:2] == TOHOST_ADDR[31:2];
    wire       counting  = core_rst_n && !ended;

    always @(posedge clk) begin
        if (!s_axi_aresetn || run_start) begin
            cycles     <= 32'd0;
            mdone_cnt  <= 32'd0;
            mdone_seen <= 1'b0;
            exit_code  <= 32'd0;
            exit_seen  <= 1'b0;
            timeout    <= 1'b0;
        end else begin
            if (counting && cycles != 32'hFFFF_FFFF) cycles <= cycles + 32'd1;
            if (core_rst_n && matrix_done) begin
                mdone_cnt  <= mdone_cnt + 32'd1;
                mdone_seen <= 1'b1;
            end
            if (tohost_wr) begin
                exit_code <= store_data;
                exit_seen <= 1'b1;
            end
            if (counting && max_cycles != 32'd0 && cycles >= max_cycles) timeout <= 1'b1;
        end
    end

    // ---------------------------------------------------------------- interrupt
    // irq is a flip-flop loaded with the next IRQ_STATUS / IRQ_EN, so it follows them in the
    // same cycle: a W1C (or IRQ_EN) write takes effect on irq before the write response.
    reg  [1:0] irq_status;
    reg        halted_q, timeout_q;
    wire [1:0] irq_event       = {timeout && !timeout_q, halted && !halted_q};
    wire [1:0] irq_clear       = wr_irqst ? wdata[1:0] : 2'b00;
    wire [1:0] irq_status_next = run_start ? 2'b00 : ((irq_status & ~irq_clear) | irq_event);
    wire [1:0] irq_en_next     = wr_irqen ? wdata[1:0] : irq_en;

    always @(posedge clk) begin
        if (!s_axi_aresetn) begin
            irq_status <= 2'b00;
            halted_q   <= 1'b0;
            timeout_q  <= 1'b0;
            irq        <= 1'b0;
        end else begin
            halted_q   <= halted;
            timeout_q  <= timeout;
            irq_status <= irq_status_next;
            irq        <= |(irq_status_next & irq_en_next);
        end
    end

    // ---------------------------------------------------------------- register reads
    reg [31:0] rd_mux;
    always @(*) begin
        case (rd_a[5:2])
            R_CTRL:       rd_mux = {31'b0, run};
            R_STATUS:     rd_mux = {26'b0, exit_seen, timeout, mdone_seen, matrix_busy, halted, core_rst_n};
            R_CYCLES:     rd_mux = cycles;
            R_PC:         rd_mux = pc_address;
            R_MTILEM:     rd_mux = mtilem;
            R_MTILEN:     rd_mux = mtilen;
            R_MTILEK:     rd_mux = mtilek;
            R_MDONE:      rd_mux = mdone_cnt;
            R_MSEL:       rd_mux = {13'b0, msel_beat, 5'b0, msel_row, 5'b0, msel_id};
            R_MDATA:      rd_mux = mreg_rdata;
            R_ID:         rd_mux = ID_VALUE;
            R_IRQ_EN:     rd_mux = {30'b0, irq_en};
            R_IRQ_STATUS: rd_mux = {30'b0, irq_status};
            R_EXIT:       rd_mux = exit_code;
            R_MAXC:       rd_mux = max_cycles;
            R_CONFIG:     rd_mux = {7'b0, 1'b1, DMEM_AW[7:0], IMEM_AW[7:0], VERSION};
            default:      rd_mux = 32'h0;
        endcase
    end
    assign rd_value = rd_in_regs ? rd_mux : 32'h0;
endmodule
