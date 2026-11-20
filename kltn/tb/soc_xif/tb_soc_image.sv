// One run of rv32if_xif_soc for tb/soc_xif/host_sim.py, which drives fpga/soc_xif/sw/soc_host.py
// against the RTL instead of the board.
//   +imem=<file> +dmem=<file>  initial BRAM contents, one 32-bit hex word per line (the words the
//                              PS would write through the AXI BRAM Controllers)
//   +max_cycles=<n>            MAX_CYCLES (watchdog), as soc_host.py writes it
//   +sim_cap=<n>               give up after n cycles without done/timeout (default 4000000)
//   +out=<file>                snapshot for host_sim.py
// Sequence = Soc.run() of soc_host.py: CTRL = 0, IRQ_EN = 0, MAX_CYCLES, CTRL = 1, poll IRQ_STATUS,
// W1C; then the snapshot: every register, every matrix register beat (MREG), DMEM; CTRL = 0 and
// every register again.
//   IRQ <value before W1C>
//   REG pre|post <offset> <value>
//   MREG <id> <row> <beat> <value>
//   DMEM <word index> <value>      (non-zero words only)
//   END ok|nodone
`timescale 1ns / 1ps
module tb_soc_image;
    localparam int IMEM_AW = 14, DMEM_AW = 16;
    localparam logic [11:0] CTRL = 12'h000, MSEL = 12'h020, MDATA = 12'h024, IRQ_EN = 12'h02C,
                            IRQ_STATUS = 12'h030, MAXC = 12'h038;

    logic clk = 0, aresetn = 0;
    always #5 clk = ~clk;

    logic [11:0] awaddr = 0, araddr = 0;
    logic        awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    logic [31:0] wdata = 0;
    logic [3:0]  wstrb = 0;
    wire         awready, wready, bvalid, arready, rvalid, irq;
    wire  [1:0]  bresp, rresp;
    wire  [31:0] rdata;
    wire         imem_clk, imem_rst, imem_en, dmem_clk, dmem_rst, dmem_en;
    wire  [3:0]  imem_we, dmem_we;
    wire  [31:0] imem_addr, imem_din, imem_dout, dmem_addr, dmem_din, dmem_dout;

    rv32if_xif_soc #(.IMEM_AW(IMEM_AW), .DMEM_AW(DMEM_AW)) dut (
        .s_axi_aclk(clk), .s_axi_aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .irq(irq),
        .imem_clk(imem_clk), .imem_rst(imem_rst), .imem_en(imem_en), .imem_we(imem_we),
        .imem_addr(imem_addr), .imem_din(imem_din), .imem_dout(imem_dout),
        .dmem_clk(dmem_clk), .dmem_rst(dmem_rst), .dmem_en(dmem_en), .dmem_we(dmem_we),
        .dmem_addr(dmem_addr), .dmem_din(dmem_din), .dmem_dout(dmem_dout)
    );
    wire [31:0] unused_a, unused_b;
    bram_tdp_model #(.AW(IMEM_AW)) u_imem (
        .clka(clk), .ena(1'b0), .wea(4'b0), .addra(32'b0), .dina(32'b0), .douta(unused_a),
        .clkb(imem_clk), .enb(imem_en), .web(imem_we), .addrb(imem_addr), .dinb(imem_din), .doutb(imem_dout));
    bram_tdp_model #(.AW(DMEM_AW)) u_dmem (
        .clka(clk), .ena(1'b0), .wea(4'b0), .addra(32'b0), .dina(32'b0), .douta(unused_b),
        .clkb(dmem_clk), .enb(dmem_en), .web(dmem_we), .addrb(dmem_addr), .dinb(dmem_din), .doutb(dmem_dout));

    task automatic axi_write(input logic [11:0] a, input logic [31:0] d);
        @(posedge clk);
        awaddr <= a; awvalid <= 1; wdata <= d; wstrb <= 4'hF; wvalid <= 1;
        do @(posedge clk); while (!(awready && wready));
        awvalid <= 0; wvalid <= 0; bready <= 1;
        do @(posedge clk); while (!bvalid);
        bready <= 0;
    endtask
    task automatic axi_read(input logic [11:0] a, output logic [31:0] d);
        @(posedge clk);
        araddr <= a; arvalid <= 1;
        do @(posedge clk); while (!arready);
        arvalid <= 0; rready <= 1;
        do @(posedge clk); while (!rvalid);
        d = rdata;
        @(posedge clk);
        rready <= 0;
    endtask

    string imem_f, dmem_f, out_f;
    int max_cycles = 0, sim_cap = 4_000_000, fd, n;
    logic [31:0] v, st;

    initial begin
        if (!$value$plusargs("imem=%s", imem_f) || !$value$plusargs("dmem=%s", dmem_f) ||
            !$value$plusargs("out=%s", out_f)) $fatal(1, "need +imem= +dmem= +out=");
        if ($value$plusargs("max_cycles=%d", max_cycles)) begin end
        if ($value$plusargs("sim_cap=%d", sim_cap)) begin end
        #1;                                  // after the models' initial blocks
        $readmemh(imem_f, u_imem.mem);
        $readmemh(dmem_f, u_dmem.mem);
        fd = $fopen(out_f, "w");
        repeat (5) @(posedge clk);
        aresetn <= 1;
        repeat (2) @(posedge clk);

        axi_write(CTRL, 0);
        axi_write(IRQ_EN, 0);
        axi_write(MAXC, max_cycles);
        axi_write(CTRL, 1);
        n = 0;
        do begin axi_read(IRQ_STATUS, st); n += 10; end while (st == 0 && n < sim_cap);
        if (st == 0) begin
            $fdisplay(fd, "END nodone");
            $fclose(fd);
            $finish;
        end
        $fdisplay(fd, "IRQ %0d", st);
        axi_write(IRQ_STATUS, st);
        for (int a = 0; a < 64; a += 4) begin axi_read(a, v); $fdisplay(fd, "REG pre %0d %0d", a, v); end
        for (int id = 0; id < 8; id++)
            for (int r = 0; r < 4; r++)
                for (int b = 0; b < 4; b++) begin
                    axi_write(MSEL, (b << 16) | (r << 8) | id);
                    axi_read(MDATA, v);
                    $fdisplay(fd, "MREG %0d %0d %0d %0d", id, r, b, v);
                end
        for (int i = 0; i < (1 << (DMEM_AW - 2)); i++)
            if (u_dmem.mem[i] != 0) $fdisplay(fd, "DMEM %0d %0d", i, u_dmem.mem[i]);
        axi_write(CTRL, 0);
        for (int a = 0; a < 64; a += 4) begin axi_read(a, v); $fdisplay(fd, "REG post %0d %0d", a, v); end
        $fdisplay(fd, "END ok");
        $fclose(fd);
        $finish;
    end
endmodule
