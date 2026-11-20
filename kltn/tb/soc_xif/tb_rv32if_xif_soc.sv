`timescale 1ns / 1ps
// =============================================================================
// tb_rv32if_xif_soc: SoC rtl/core_matrix_xif/rv32if_xif_soc.v with two true dual-port BRAMs
// (bram_tdp_model.v), driven the way the PS drives it on the board:
//   - port A of IMEM / DMEM: the AXI BRAM Controllers (modelled by the tasks imem_wr / dmem_wr /
//     dmem_rd, one word per access),
//   - s_axi: the control registers (AXI4-Lite BFM below),
//   - irq: pl_ps_irq0.
// P1-P8 come from fpga/kr260/tb/tb_kr260_programs.sv (partner's wrapper), changed where the SoC
// differs: memories through BRAM port A and never locked, interrupt cleared by IRQ_STATUS,
// CYCLES / MDONE_CNT kept after RUN = 0. P9-P12 check what is new:
//   P9  interrupt: IRQ_EN, IRQ_STATUS (W1C), no interrupt storm, RUN 0 -> 1 clears
//   P10 watchdog MAX_CYCLES
//   P11 TOHOST -> EXIT_CODE
//   P12 ID, CONFIG, unused offsets
// Every run also checks CYCLES = (cycle in which halted rises) - DRAIN_CYCLES, i.e. CYCLES
// stops when the program ends and does not include the detector delay.
// Result: build/soc_xif.log, last line "RESULT: PASS" / "RESULT: FAIL".
// +define+BRAM_NO_CHANGE: BRAM port output kept during writes (default: WRITE_FIRST).
// =============================================================================
module tb_rv32if_xif_soc;
    import tb_matrix_pkg::*;

    localparam logic [11:0] CTRL = 12'h000, STATUS = 12'h004, CYCLES = 12'h008, PC = 12'h00C;
    localparam logic [11:0] MTILEM = 12'h010, MTILEN = 12'h014, MTILEK = 12'h018, MDONE = 12'h01C;
    localparam logic [11:0] MSEL = 12'h020, MDATA = 12'h024, ID = 12'h028;
    localparam logic [11:0] IRQ_EN = 12'h02C, IRQ_STATUS = 12'h030, EXIT_CODE = 12'h034;
    localparam logic [11:0] MAXC = 12'h038, CONFIG = 12'h03C;
    localparam logic [31:0] JAL_SELF = 32'h0000_006F;
    localparam int          DRAIN = 3;
    localparam int          IMEM_AW = 14, DMEM_AW = 16;
`ifdef BRAM_NO_CHANGE
    localparam int          WF = 0;
`else
    localparam int          WF = 1;
`endif

    logic clk = 0, aresetn = 0;
    always #5 clk = ~clk;                 // 100 MHz (pl_clk0)

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

    // Port A = AXI BRAM Controller side (PS)
    logic        ia_en = 0, da_en = 0;
    logic [3:0]  ia_we = 0, da_we = 0;
    logic [31:0] ia_addr = 0, ia_din = 0, da_addr = 0, da_din = 0;
    wire  [31:0] ia_dout, da_dout;

    bram_tdp_model #(.AW(IMEM_AW), .WRITE_FIRST(WF)) u_imem (
        .clka(clk), .ena(ia_en), .wea(ia_we), .addra(ia_addr), .dina(ia_din), .douta(ia_dout),
        .clkb(imem_clk), .enb(imem_en), .web(imem_we), .addrb(imem_addr), .dinb(imem_din), .doutb(imem_dout));
    bram_tdp_model #(.AW(DMEM_AW), .WRITE_FIRST(WF)) u_dmem (
        .clka(clk), .ena(da_en), .wea(da_we), .addra(da_addr), .dina(da_din), .douta(da_dout),
        .clkb(dmem_clk), .enb(dmem_en), .web(dmem_we), .addrb(dmem_addr), .dinb(dmem_din), .doutb(dmem_dout));

    // ---------------------------------------------------------------------
    // Monitors: cycles since the core left reset, first halt_hint / halted, any irq
    // ---------------------------------------------------------------------
    int run_cyc = 0, hint_run_cyc = -1, halt_run_cyc = -1;
    logic irq_seen = 0;
    always @(posedge clk) begin
        if (!dut.core_rst_n) begin
            run_cyc <= 0; hint_run_cyc <= -1; halt_run_cyc <= -1;
        end else begin
            run_cyc <= run_cyc + 1;
            if (dut.halt_hint && hint_run_cyc < 0) hint_run_cyc <= run_cyc;
            if (dut.halted && halt_run_cyc < 0) halt_run_cyc <= run_cyc;
        end
        if (irq) irq_seen <= 1'b1;
    end
    // The core never writes IMEM through port B
    always @(posedge clk) if (imem_en && imem_we != 4'b0) begin
        $display("[FATAL] core wrote IMEM"); $finish;
    end

    // ---------------------------------------------------------------------
    // Log / check
    // ---------------------------------------------------------------------
    int logf;
    int n_pass = 0, n_fail = 0, t_pass, t_fail;
    string cur;
    string failed[$];

    task automatic logln(input string s);
        $display("%s", s);
        $fdisplay(logf, "%s", s);
    endtask
    task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) begin
            n_pass++; t_pass++;
            $fdisplay(logf, "    [PASS] %-44s = 0x%08h", what, got);
        end else begin
            n_fail++; t_fail++;
            logln($sformatf("    [FAIL] %-44s got=0x%08h exp=0x%08h", what, got, exp));
        end
    endtask
    task automatic start_test(input string name);
        cur = name; t_pass = 0; t_fail = 0;
        logln(""); logln($sformatf("==== %s ====", name));
    endtask
    task automatic end_test();
        logln($sformatf("    -> %s : %0d PASS / %0d FAIL", cur, t_pass, t_fail));
        if (t_fail) begin
            failed.push_back(cur);
            logln($sformatf("    KICH BAN FAIL: %s", cur));
        end
    endtask

    // ---------------------------------------------------------------------
    // AXI4-Lite BFM. mode: 0 = AW and W together, 1 = AW first, 2 = W first.
    // bdly / rdly: cycles before BREADY / RREADY.
    // ---------------------------------------------------------------------
    int wr_mode = 0, bdly = 0, rdly = 0;
    int axi_timeout = 0;

    task automatic axi_write(input logic [11:0] a, input logic [31:0] d, input logic [3:0] s = 4'hF);
        int g;
        @(posedge clk);
        case (wr_mode)
            1: begin awaddr <= a; awvalid <= 1; @(posedge clk); wdata <= d; wstrb <= s; wvalid <= 1; end
            2: begin wdata <= d; wstrb <= s; wvalid <= 1; @(posedge clk); awaddr <= a; awvalid <= 1; end
            default: begin awaddr <= a; awvalid <= 1; wdata <= d; wstrb <= s; wvalid <= 1; end
        endcase
        g = 0;
        do begin @(posedge clk); g++; end while (!(awready && wready) && g < 100);
        awvalid <= 0; wvalid <= 0;
        repeat (bdly) @(posedge clk);
        bready <= 1;
        g = 0;
        do begin @(posedge clk); g++; end while (!bvalid && g < 100);
        if (g >= 100) axi_timeout++;
        if (bresp !== 2'b00) axi_timeout++;
        bready <= 0;
    endtask

    task automatic axi_read(input logic [11:0] a, output logic [31:0] d);
        int g;
        @(posedge clk);
        araddr <= a; arvalid <= 1;
        g = 0;
        do begin @(posedge clk); g++; end while (!arready && g < 100);
        arvalid <= 0;
        repeat (rdly) @(posedge clk);
        rready <= 1;
        g = 0;
        do begin @(posedge clk); g++; end while (!rvalid && g < 100);
        if (g >= 100) axi_timeout++;
        if (rresp !== 2'b00) axi_timeout++;
        d = rdata;
        @(posedge clk);
        rready <= 0;
    endtask

    // ---------------------------------------------------------------------
    // PS access to the BRAMs (port A, as through the AXI BRAM Controllers)
    // ---------------------------------------------------------------------
    task automatic imem_wr(input int byte_addr, input logic [31:0] d);
        @(posedge clk); ia_en <= 1; ia_we <= 4'hF; ia_addr <= byte_addr; ia_din <= d;
        @(posedge clk); ia_en <= 0; ia_we <= 0;
    endtask
    task automatic dmem_wr(input int byte_addr, input logic [31:0] d, input logic [3:0] s = 4'hF);
        @(posedge clk); da_en <= 1; da_we <= s; da_addr <= byte_addr; da_din <= d;
        @(posedge clk); da_en <= 0; da_we <= 0;
    endtask
    task automatic dmem_rd(input int byte_addr, output logic [31:0] v);
        @(posedge clk); da_en <= 1; da_we <= 0; da_addr <= byte_addr;
        @(posedge clk); da_en <= 0;
        #1 v = da_dout;
    endtask
    task automatic imem_rd(input int byte_addr, output logic [31:0] v);
        @(posedge clk); ia_en <= 1; ia_we <= 0; ia_addr <= byte_addr;
        @(posedge clk); ia_en <= 0;
        #1 v = ia_dout;
    endtask

    `include "rv32if_asm.svh"

    // ---------------------------------------------------------------------
    // Programs / data (as in tb_kr260_programs.sv)
    // ---------------------------------------------------------------------
    logic [31:0] prog [0:255];
    int nprog, n_mx;
    logic [31:0] dinit [0:255];

    task automatic prog_clear(); nprog = 0; n_mx = 0; for (int i = 0; i < 256; i++) dinit[i] = 0; endtask
    task automatic put(input logic [31:0] insn); prog[nprog] = insn; nprog++; endtask
    task automatic putm(input logic [31:0] insn); put(insn); n_mx++; endtask
    task automatic li(input int rd, input logic [31:0] v);
        logic [31:0] hi;
        hi = v + 32'h800;
        put(e_lui(rd, hi[31:12]));
        put(e_addi(rd, rd, int'($signed(v[11:0]))));
    endtask
    function automatic int here(); return nprog; endfunction

    logic [7:0]  A8 [0:3][0:63];
    logic [7:0]  B8 [0:3][0:63];
    logic [31:0] C0 [0:3][0:3];
    logic [31:0] Cexp [0:3][0:3];
    logic [31:0] seed = 32'h0BAD_5EED;
    function automatic logic [31:0] rnd(); seed = lcg_next(seed); return seed; endfunction

    task automatic gen_int8(input int K);
        for (int r = 0; r < 4; r++)
            for (int k = 0; k < 64; k++) begin
                A8[r][k] = (k < K) ? rnd() >> 24 : 8'h0;
                B8[r][k] = (k < K) ? rnd() >> 24 : 8'h0;
            end
        for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) C0[i][j] = rnd() >> 8;
    endtask
    task automatic gemm_ref(input int K);
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) begin
                Cexp[i][j] = C0[i][j];
                for (int k = 0; k < K; k++)
                    Cexp[i][j] += $signed({{24{A8[i][k][7]}}, A8[i][k]}) * $signed({{24{B8[j][k][7]}}, B8[j][k]});
            end
    endtask
    task automatic put_bytes(input int which, input int base, input int stride, input int K);
        int a;
        for (int r = 0; r < 4; r++)
            for (int k = 0; k < K; k++) begin
                a = base + r * stride + k;
                dinit[a >> 2][8 * (a % 4) +: 8] = (which == 0) ? A8[r][k] : B8[r][k];
            end
    endtask

    // ---------------------------------------------------------------------
    // Host-level operations
    // ---------------------------------------------------------------------
    task automatic host_load(input logic [31:0] tail);
        // program + "jal x0, 0" (end) + the rest = tail
        for (int i = 0; i < 256; i++)
            imem_wr(i * 4, (i < nprog) ? prog[i] : (i == nprog) ? JAL_SELF : tail);
        for (int i = 0; i < 256; i++) dmem_wr(i * 4, dinit[i]);
    endtask

    // IRQ_EN = done | timeout, RUN = 1, wait for irq. Returns the cycles waited (0 = none).
    task automatic host_run(input int max_cyc, output int waited);
        axi_write(IRQ_EN, 32'h3);
        axi_write(CTRL, 32'h1);
        waited = 0;
        while (!irq && waited < max_cyc) begin @(posedge clk); waited++; end
        if (!irq) waited = 0;
    endtask

    task automatic host_stop(); axi_write(CTRL, 32'h0); endtask

    task automatic mreg_rd(input logic [2:0] id, input int row, input int beat, output logic [31:0] v);
        axi_write(MSEL, {13'b0, 3'(beat), 5'b0, 3'(row), 5'b0, id});
        axi_read(MDATA, v);
    endtask
    task automatic mreg_wr(input logic [2:0] id, input int row, input int beat, input logic [31:0] v);
        axi_write(MSEL, {13'b0, 3'(beat), 5'b0, 3'(row), 5'b0, id});
        axi_write(MDATA, v);
    endtask

    // CYCLES of the last run_prog
    logic [31:0] last_cycles;

    // CYCLES against the monitors: the counter stops DRAIN cycles before halted rises.
    task automatic check_cycles(input logic [31:0] c, input bit scalar_end);
        logln($sformatf("    CYCLES = %0d (jal in EX at core cycle %0d, halted at %0d)", c, hint_run_cyc, halt_run_cyc));
        check("CYCLES = chu ky halted - DRAIN", c, halt_run_cyc - DRAIN);
        if (scalar_end) check("CYCLES = chu ky jal o EX + 1", c, hint_run_cyc + 1);
    endtask

    // Load, run, wait for the done interrupt, check the status registers, clear the interrupt.
    task automatic run_prog(input logic [31:0] tail, input int expect_mdone, input bit scalar_end = 1);
        int w;
        logic [31:0] v, c;
        host_stop();
        host_load(tail);
        host_run(200_000, w);
        check("irq done (khong timeout)", w != 0, 1);
        axi_read(STATUS, v);
        check("STATUS running|halted", v[1:0], 2'b11);
        check("STATUS matrix_busy = 0", v[2], 0);
        check("STATUS timeout = 0", v[4], 0);
        axi_read(IRQ_STATUS, v); check("IRQ_STATUS = done", v, 1);
        axi_read(CYCLES, c);
        check_cycles(c, scalar_end);
        axi_write(IRQ_STATUS, 32'h1);
        axi_read(IRQ_STATUS, v); check("IRQ_STATUS = 0 sau W1C", v, 0);
        check("irq = 0 sau W1C", irq, 0);
        axi_read(CYCLES, v); check("CYCLES giu nguyen sau W1C", v, c);
        axi_read(MDONE, v); check("MDONE_CNT", v, expect_mdone);
        axi_read(PC, v); logln($sformatf("    PC = 0x%0h, jal x0,0 at 0x%0h", v, nprog * 4));
        // continuous fetch: while the jal loops, the fetch address runs up to 3 words ahead
        check("PC tai lenh jal x0,0 (+0..12)", (v - nprog * 4) <= 12, 1);
        last_cycles = c;
    endtask

    // =====================================================================
    localparam int A_AD = 32'h000, B_AD = 32'h040, C_AD = 32'h080, D_AD = 32'h0C0;

    task automatic p1_gemm_int8(input int n_seed);
        logic [31:0] v;
        start_test($sformatf("P1 GEMM int8 4x4x16, bo du lieu %0d", n_seed));
        prog_clear();
        gen_int8(16);
        A8[0][0] = 8'h80; B8[0][0] = 8'h80;
        put_bytes(0, A_AD, 16, 16);
        put_bytes(1, B_AD, 16, 16);
        for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) dinit[(C_AD >> 2) + i * 4 + j] = C0[i][j];
        gemm_ref(16);
        li(10, A_AD); li(11, B_AD); li(12, C_AD); li(13, D_AD);
        put(e_addi(14, 0, 16));
        putm(m_setm(4)); putm(m_setn(4)); putm(m_setk(16));
        putm(m_ld(4'b0000, 2'b00, TR0, 10, 14));
        putm(m_ld(4'b0001, 2'b00, TR1, 11, 14));
        putm(m_ld(4'b0010, 2'b10, ACC0, 12, 14));
        putm(m_mmacc(ACC0, TR1, TR0));
        putm(m_st(4'b0010, 2'b10, ACC0, 13, 14));
        put(e_lw(20, 13, 0));                       // lw right after the matrix store
        put(e_addi(20, 20, 1));
        put(e_sw(20, 0, 32'h3F0));
        run_prog(32'h0, n_mx, 0);                   // rest of IMEM = 0 (BRAM after configuration)
        axi_read(MTILEM, v); check("MTILEM", v, 4);
        axi_read(MTILEN, v); check("MTILEN", v, 4);
        axi_read(MTILEK, v); check("MTILEK", v, 16);
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) begin
                mreg_rd(ACC0, i, j, v);
                check($sformatf("acc0[%0d][%0d] (MREG)", i, j), v, Cexp[i][j]);
            end
        dmem_rd(D_AD, v);
        check("PS doc DMEM khi RUN = 1 (khong khoa)", v, Cexp[0][0]);
        host_stop();
        axi_read(STATUS, v);
        check("STATUS[2:0] = 0 sau stop", v[2:0], 0);
        check("STATUS matrix_done seen giu sau stop", v[3], 1);
        axi_read(CYCLES, v); check("CYCLES giu sau stop", v, last_cycles);
        check("irq = 0 sau stop", irq, 0);
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) begin
                dmem_rd(D_AD + 16 * i + 4 * j, v);
                check($sformatf("D[%0d][%0d] (DMEM)", i, j), v, Cexp[i][j]);
            end
        dmem_rd(32'h3F0, v); check("DMEM[0x3F0] = D[0][0] + 1", v, Cexp[0][0] + 1);
        end_test();
    endtask

    task automatic p2_gemm_fp();
        int af [0:3][0:3], bf [0:3][0:3], cs [0:3][0:3];
        logic [31:0] v;
        start_test("P2 GEMM FP32 4x4x4 + mfadd.s.mm + lenh F");
        prog_clear();
        for (int i = 0; i < 4; i++)
            for (int k = 0; k < 4; k++) begin
                af[i][k] = (i * 4 + k) - 7 + 2 * (k % 2);
                bf[i][k] = i - k + 5;
                dinit[(A_AD >> 2) + i * 4 + k] = fp_from_int(af[i][k]);
                dinit[(B_AD >> 2) + i * 4 + k] = fp_from_int(bf[i][k]);
            end
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) begin
                cs[i][j] = 0;
                for (int k = 0; k < 4; k++) cs[i][j] += af[i][k] * bf[j][k];
            end
        li(10, A_AD); li(11, B_AD); li(13, D_AD); li(15, 32'h180);
        put(e_addi(14, 0, 16));
        putm(m_setm(4)); putm(m_setn(4)); putm(m_setk(4));
        putm(m_ld(4'b0000, 2'b10, TR2, 10, 14));
        putm(m_ld(4'b0001, 2'b10, TR3, 11, 14));
        putm(m_zero(ACC1));
        putm(m_mfmacc(ACC1, TR3, TR2));
        putm(enc_ew(4'b0000, 2'b10, 3'd7, ACC1, ACC1, ACC2));
        putm(m_st(4'b0010, 2'b10, ACC1, 13, 14));
        putm(m_st(4'b0010, 2'b10, ACC2, 15, 14));
        put(e_flw(1, 13, 0));
        put(e_flw(2, 13, 60));
        put(e_fop(7'h08, 3, 1, 2, 3'b000));        // f3 = C00 * C33
        put(e_fsw(3, 0, 32'h200));
        run_prog(32'h0, n_mx, 0);
        mreg_rd(ACC1, 1, 2, v); check("acc1[1][2] (MREG)", v, fp_from_int(cs[1][2]));
        host_stop();
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) begin
                dmem_rd(D_AD + 16 * i + 4 * j, v);
                check($sformatf("C[%0d][%0d] mfmacc", i, j), v, fp_from_int(cs[i][j]));
                dmem_rd(32'h180 + 16 * i + 4 * j, v);
                check($sformatf("2C[%0d][%0d] mfadd", i, j), v, fp_from_int(2 * cs[i][j]));
            end
        dmem_rd(32'h200, v); check("fmul C00*C33 (fsw)", v, fp_from_int(cs[0][0] * cs[3][3]));
        end_test();
    endtask

    task automatic p3_tiled();
        int loop_top;
        logic [31:0] v;
        start_test("P3 GEMM int8 K=64 (vong lap 4 khoi) + madd.w.mm");
        prog_clear();
        gen_int8(64);
        for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) C0[i][j] = 0;
        put_bytes(0, 32'h000, 64, 64);
        put_bytes(1, 32'h100, 64, 64);
        gemm_ref(64);
        li(10, 32'h000); li(11, 32'h100); li(13, 32'h200); li(17, 32'h300);
        put(e_addi(14, 0, 64)); put(e_addi(16, 0, 16)); put(e_addi(9, 0, 4));
        putm(m_setm(4)); putm(m_setn(4)); putm(m_setk(16));
        putm(m_zero(ACC0));
        loop_top = here();
        put(m_ld(4'b0000, 2'b00, TR0, 10, 14));
        put(m_ld(4'b0001, 2'b00, TR1, 11, 14));
        put(m_mmacc(ACC0, TR1, TR0));
        put(e_addi(10, 10, 16));
        put(e_addi(11, 11, 16));
        put(e_addi(9, 9, -1));
        put(b_t((loop_top - here()) * 4, 0, 9, 3'b001));
        n_mx += 12;
        putm(m_st(4'b0010, 2'b10, ACC0, 13, 16));
        putm(enc_ew(4'b0000, 2'b01, 3'd7, ACC0, ACC0, ACC1));
        putm(m_st(4'b0010, 2'b10, ACC1, 17, 16));
        run_prog(32'h0, n_mx, 0);
        host_stop();
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) begin
                dmem_rd(32'h200 + 16 * i + 4 * j, v);
                check($sformatf("C[%0d][%0d] K=64", i, j), v, Cexp[i][j]);
                dmem_rd(32'h300 + 16 * i + 4 * j, v);
                check($sformatf("2C[%0d][%0d] madd", i, j), v, 2 * Cexp[i][j]);
            end
        end_test();
    endtask

    task automatic p4_scalar();
        int loop_top;
        logic [31:0] v;
        start_test("P4 Chuong trinh scalar RV32I + RV32F, ket qua ra DMEM");
        prog_clear();
        dinit[64] = 32'h3FC0_0000;  // 1.5
        dinit[65] = 32'h4010_0000;  // 2.25
        // 20 Fibonacci numbers (x1, x2), sum (x3)
        put(e_addi(1, 0, 0)); put(e_addi(2, 0, 1)); put(e_addi(3, 0, 0));
        put(e_addi(4, 0, 20)); li(5, 32'h200);
        loop_top = here();
        put(e_sw(1, 5, 0));
        put(e_add(3, 3, 1));
        put(e_add(6, 1, 2));
        put(e_addi(1, 2, 0));
        put(e_addi(2, 6, 0));
        put(e_addi(5, 5, 4));
        put(e_addi(4, 4, -1));
        put(b_t((loop_top - here()) * 4, 0, 4, 3'b001));
        put(e_sw(3, 0, 32'h300));
        put(e_sh(3, 0, 32'h306));                  // upper half of word 0x304
        put(e_sb(3, 0, 32'h308));
        li(7, 32'h100);
        put(e_flw(1, 7, 0)); put(e_flw(2, 7, 4));
        put(e_r4(7'h43, 3, 1, 2, 1));              // fmadd 1.5*2.25+1.5 = 4.875
        put(e_fop(7'h0C, 4, 3, 1, 3'b000));        // 4.875 / 1.5 = 3.25
        put(e_fsw(3, 0, 32'h310));
        put(e_fsw(4, 0, 32'h314));
        put(e_fop(7'h60, 8, 4, 0, 3'b001));        // (int) 3.25 = 3
        put(e_sw(8, 0, 32'h318));
        run_prog(32'h0, 0);
        host_stop();
        begin
            logic [31:0] a, b, t, s;
            a = 0; b = 1; s = 0;
            for (int i = 0; i < 20; i++) begin
                dmem_rd(32'h200 + 4 * i, v);
                check($sformatf("fib[%0d]", i), v, a);
                s += a; t = a + b; a = b; b = t;
            end
            dmem_rd(32'h300, v); check("tong fib (sw)", v, s);
            dmem_rd(32'h304, v); check("sh vao nua cao", v, {s[15:0], 16'h0});
            dmem_rd(32'h308, v); check("sb byte 0", v, {24'h0, s[7:0]});
        end
        dmem_rd(32'h310, v); check("fmadd 4.875", v, 32'h409C_0000);
        dmem_rd(32'h314, v); check("fdiv 3.25", v, 32'h4050_0000);
        dmem_rd(32'h318, v); check("fcvt.w.s 3", v, 3);
        end_test();
    endtask

    task automatic p5_axi_protocol();
        logic [31:0] v;
        int w, loop_top;
        start_test("P5 Giao thuc AXI4-Lite + PS va core dung chung DMEM khi dang chay");
        host_stop();
        axi_read(ID, v); check("ID = KLTN", v, 32'h4B4C_544E);
        for (int m = 0; m < 3; m++) begin
            wr_mode = m; bdly = m * 3; rdly = 5 - m * 2;
            axi_write(MAXC, 32'h1111_0000 + m);
            axi_read(MAXC, v);
            check($sformatf("ghi/doc mode %0d (bdly %0d, rdly %0d)", m, bdly, rdly), v, 32'h1111_0000 + m);
        end
        wr_mode = 0; bdly = 0; rdly = 0;
        axi_write(MAXC, 32'h0);
        axi_write(MAXC, 32'hAABB_CCDD, 4'b0101);
        axi_read (MAXC, v); check("WSTRB 0101", v, 32'h00BB_00DD);
        axi_write(MAXC, 32'h1122_3344, 4'b1000);
        axi_read (MAXC, v); check("WSTRB 1000", v, 32'h11BB_00DD);
        axi_write(MAXC, 32'h0);
        imem_wr(32'h3FFC, 32'h1234_5678);
        imem_rd(32'h3FFC, v); check("IMEM ghi/doc qua port A (word cuoi 16 KB)", v, 32'h1234_5678);
        dmem_wr(32'hFFFC, 32'h8765_4321);
        dmem_rd(32'hFFFC, v); check("DMEM ghi/doc qua port A (word cuoi 64 KB)", v, 32'h8765_4321);
        // The core waits for a flag that the PS writes into DMEM while it runs.
        prog_clear();
        loop_top = here();
        put(e_lw(5, 0, 32'h3F8));
        put(b_t((loop_top - here()) * 4, 0, 5, 3'b000));   // beq x5, x0: wait while 0
        put(e_addi(6, 5, 1));
        put(e_sw(6, 0, 32'h3FC));
        host_stop();
        host_load(32'h0);
        axi_write(IRQ_EN, 32'h1);
        axi_write(CTRL, 32'h1);
        repeat (300) @(posedge clk);
        axi_read(STATUS, v); check("core dang cho co (chua halted)", v[1:0], 2'b01);
        dmem_wr(32'h3F8, 32'h5);                           // PS writes the flag
        w = 0;
        while (!irq && w < 2000) begin @(posedge clk); w++; end
        check("core thay co cua PS va dung", irq, 1);
        dmem_rd(32'h3FC, v); check("core ghi co + 1", v, 6);
        axi_write(IRQ_STATUS, 32'h1);
        host_stop();
        axi_read(12'h0FC, v); check("offset thanh ghi khong dung = 0", v, 0);
        check("khong co giao dich AXI timeout / loi resp", axi_timeout, 0);
        end_test();
    endtask

    task automatic p6_runaway();
        logic [31:0] v;
        int w;
        start_test("P6 Chuong trinh khong dung, MAX_CYCLES = 0: khong irq, host dung bang CTRL");
        prog_clear();
        put(e_addi(1, 1, 1));
        put(j_t(-4, 0));                           // endless loop (not jal x0,0)
        host_stop();
        host_load(32'h0);
        axi_write(MAXC, 32'h0);
        irq_seen = 0;
        host_run(5_000, w);
        check("khong co irq", w, 0);
        check("irq khong bat lan nao", irq_seen, 0);
        axi_read(STATUS, v); check("STATUS running, chua halted", v[1:0], 2'b01);
        axi_read(CYCLES, v); check("CYCLES dang dem", v > 4000, 1);
        host_stop();
        axi_read(STATUS, v); check("STATUS = 0 sau stop", v, 0);
        end_test();
    endtask

    task automatic p1_body_for_reset();
        prog_clear();
        gen_int8(16);
        put_bytes(0, A_AD, 16, 16);
        put_bytes(1, B_AD, 16, 16);
        for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) dinit[(C_AD >> 2) + i * 4 + j] = C0[i][j];
        gemm_ref(16);
        li(10, A_AD); li(11, B_AD); li(12, C_AD); li(13, D_AD);
        put(e_addi(14, 0, 16));
        putm(m_setm(4)); putm(m_setn(4)); putm(m_setk(16));
        putm(m_ld(4'b0000, 2'b00, TR0, 10, 14));
        putm(m_ld(4'b0001, 2'b00, TR1, 11, 14));
        putm(m_ld(4'b0010, 2'b10, ACC0, 12, 14));
        putm(m_mmacc(ACC0, TR1, TR0));
        putm(m_st(4'b0010, 2'b10, ACC0, 13, 14));
        host_stop();
        host_load(32'h0);
        for (int i = 0; i < 16; i++) dmem_wr(D_AD + 4 * i, 32'h0);   // clear the result area
    endtask

    task automatic p7_aresetn();
        logic [31:0] v;
        int w;
        start_test("P7 s_axi_aresetn giua luc chay");
        p1_body_for_reset();
        axi_write(CTRL, 32'h1);
        repeat (150) @(posedge clk);
        aresetn = 0;
        repeat (10) @(posedge clk);
        check("trong aresetn: irq = 0", irq, 0);
        aresetn = 1;
        repeat (5) @(posedge clk);
        axi_read(STATUS, v);     check("STATUS = 0 sau aresetn", v, 0);
        axi_read(CTRL, v);       check("CTRL = 0 sau aresetn", v, 0);
        axi_read(IRQ_EN, v);     check("IRQ_EN = 0 sau aresetn", v, 0);
        axi_read(IRQ_STATUS, v); check("IRQ_STATUS = 0 sau aresetn", v, 0);
        // the BRAMs are not cleared by the reset: run again at once
        host_run(200_000, w);
        check("chay lai sau aresetn", w != 0, 1);
        axi_read(MDONE, v); check("MDONE_CNT chay lai", v, n_mx);
        axi_write(IRQ_STATUS, 32'h1);
        host_stop();
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) begin
                dmem_rd(D_AD + 16 * i + 4 * j, v);
                check($sformatf("D[%0d][%0d] sau aresetn", i, j), v, Cexp[i][j]);
            end
        end_test();
    endtask

    task automatic p8_mreg();
        logic [31:0] v;
        int w;
        start_test("P8 MREG (cong host thanh ghi ma tran)");
        host_stop();
        mreg_wr(TR2, 1, 1, 32'h5555_AAAA);
        mreg_rd(TR2, 1, 1, v);
        check("RUN = 0: ghi MREG khong tac dung (reset)", v, 0);
        prog_clear();
        host_load(32'h0);                          // empty program: only jal x0,0
        host_run(10_000, w);
        check("chuong trinh rong dung", w != 0, 1);
        for (int r = 0; r < 4; r++)
            for (int b = 0; b < 4; b++) mreg_wr(TR2, r, b, 32'hC0DE_0000 | (r << 4) | b);
        for (int r = 0; r < 4; r++)
            for (int b = 0; b < 4; b++) begin
                mreg_rd(TR2, r, b, v);
                check($sformatf("tr2[%0d][%0d] ghi/doc khi RUN = 1", r, b), v, 32'hC0DE_0000 | (r << 4) | b);
            end
        mreg_wr(ACC3, 2, 3, 32'h7777_8888);
        mreg_rd(ACC3, 2, 3, v); check("acc3[2][3] ghi/doc", v, 32'h7777_8888);
        mreg_rd(ACC3, 6, 0, v); check("hang ngoai pham vi doc = 0", v, 0);
        mreg_rd(ACC3, 0, 6, v); check("beat ngoai pham vi doc = 0", v, 0);
        axi_read(MSEL, v); check("MSEL doc lai", v, {13'b0, 3'd6, 5'b0, 3'd0, 5'b0, ACC3});
        axi_write(IRQ_STATUS, 32'h1);
        host_stop();
        end_test();
    endtask

    // A loop of 20 iterations, then x1 (= 0) to DMEM 0x3F8
    task automatic prog_count20();
        int loop_top;
        prog_clear();
        put(e_addi(1, 0, 20));
        loop_top = here();
        put(e_addi(1, 1, -1));
        put(b_t((loop_top - here()) * 4, 0, 1, 3'b001));   // bne x1, x0
        put(e_sw(1, 0, 32'h3F8));
    endtask

    task automatic p9_irq();
        logic [31:0] v, c1;
        int w, g;
        start_test("P9 Ngat: IRQ_EN, IRQ_STATUS (W1C), khong storm, RUN 0->1 xoa");
        prog_count20();
        host_stop();
        host_load(32'h0);
        // polling, interrupt off
        axi_write(IRQ_EN, 32'h0);
        irq_seen = 0;
        axi_write(CTRL, 32'h1);
        g = 0;
        do begin axi_read(STATUS, v); g++; end while (!v[1] && g < 1000);
        check("halted (polling STATUS)", v[1], 1);
        repeat (5) @(posedge clk);
        check("IRQ_EN = 0: khong co irq", irq_seen, 0);
        axi_read(IRQ_STATUS, v); check("IRQ_STATUS[0] van ghi nhan khi IRQ_EN = 0", v, 1);
        axi_write(IRQ_STATUS, 32'h0);
        axi_read(IRQ_STATUS, v); check("ghi 0 vao IRQ_STATUS: khong doi", v, 1);
        axi_write(IRQ_STATUS, 32'h2);
        axi_read(IRQ_STATUS, v); check("ghi 1 vao bit khac: bit 0 khong doi", v, 1);
        axi_write(IRQ_EN, 32'h1);
        repeat (2) @(posedge clk);
        check("bat IRQ_EN khi su kien dang cho: irq = 1", irq, 1);
        axi_read(CYCLES, c1);
        check_cycles(c1, 1);
        axi_write(IRQ_STATUS, 32'h1);
        axi_read(IRQ_STATUS, v); check("IRQ_STATUS = 0 sau W1C", v, 0);
        check("irq = 0 sau W1C", irq, 0);
        axi_read(STATUS, v); check("STATUS halted giu sau W1C", v[1], 1);
        irq_seen = 0;
        repeat (200) @(posedge clk);
        check("khong ngat lai sau W1C (khong storm)", irq_seen, 0);
        axi_read(CYCLES, v); check("CYCLES khong doi sau khi dung", v, c1);
        host_stop();
        axi_read(CYCLES, v); check("CYCLES giu sau RUN = 0", v, c1);
        axi_read(STATUS, v); check("STATUS[1:0] = 0 sau RUN = 0", v[1:0], 0);
        // second run: same cycle count (the counter is cleared by RUN 0 -> 1)
        host_run(10_000, w);
        check("chay lai: irq", w != 0, 1);
        axi_read(CYCLES, v); check("chay lai: CYCLES bang lan 1", v, c1);
        // leave the interrupt pending: RUN = 0 does not clear it, RUN 0 -> 1 does
        host_stop();
        repeat (2) @(posedge clk);
        check("RUN = 0 khong xoa IRQ_STATUS (irq van = 1)", irq, 1);
        axi_write(CTRL, 32'h1);
        axi_read(IRQ_STATUS, v); check("RUN 0->1 xoa IRQ_STATUS", v, 0);
        check("RUN 0->1: irq = 0", irq, 0);
        w = 0;
        while (!irq && w < 10_000) begin @(posedge clk); w++; end
        check("lan chay thu 3: irq", irq, 1);
        axi_write(IRQ_STATUS, 32'h1);
        host_stop();
        end_test();
    endtask

    task automatic p10_watchdog();
        logic [31:0] v, v2, c1;
        int w;
        start_test("P10 Watchdog MAX_CYCLES");
        prog_clear();
        put(e_addi(1, 1, 1));
        put(j_t(-4, 0));                           // endless loop
        host_stop();
        host_load(32'h0);
        axi_write(MAXC, 32'd3000);
        host_run(20_000, w);
        check("timeout -> irq", w != 0, 1);
        logln($sformatf("    irq %0d cycles after RUN = 1 (MAX_CYCLES = 3000)", w));
        check("irq sau ~MAX_CYCLES chu ky", (w >= 2990) && (w <= 3010), 1);
        axi_read(IRQ_STATUS, v); check("IRQ_STATUS = timeout", v, 2);
        axi_read(STATUS, v);
        check("STATUS timeout", v[4], 1);
        check("STATUS running, chua halted", v[1:0], 2'b01);
        axi_read(CYCLES, v); check("CYCLES >= MAX_CYCLES", v >= 3000, 1);
        axi_write(IRQ_STATUS, 32'h2);
        check("irq = 0 sau W1C", irq, 0);
        axi_read(CYCLES, v2); check("core van chay (CYCLES tang)", v2 > v, 1);
        host_stop();
        // timeout with IRQ_EN[1] = 0: recorded, no interrupt until enabled
        axi_write(MAXC, 32'd1000);
        axi_write(IRQ_EN, 32'h1);
        irq_seen = 0;
        axi_write(CTRL, 32'h1);
        repeat (3000) @(posedge clk);
        check("IRQ_EN[1] = 0: khong irq", irq_seen, 0);
        axi_read(IRQ_STATUS, v); check("IRQ_STATUS[1] van ghi nhan", v, 2);
        axi_write(IRQ_EN, 32'h3);
        repeat (2) @(posedge clk);
        check("bat IRQ_EN[1]: irq = 1", irq, 1);
        host_stop();
        axi_write(IRQ_STATUS, 32'h3);
        // a program that ends: the counter stops, so a later MAX_CYCLES is never reached
        prog_count20();
        axi_write(MAXC, 32'd0);
        run_prog(32'h0, 0);
        c1 = last_cycles;
        axi_write(MAXC, c1 + 5);
        host_stop();
        host_run(10_000, w);
        repeat (1000) @(posedge clk);
        axi_read(IRQ_STATUS, v); check("MAX_CYCLES = CYCLES + 5: chi done", v, 1);
        axi_read(STATUS, v); check("khong timeout sau khi chuong trinh dung", v[4], 0);
        axi_write(IRQ_STATUS, 32'h3);
        axi_write(MAXC, c1 - 5);
        host_stop();
        host_run(10_000, w);
        repeat (50) @(posedge clk);
        axi_read(IRQ_STATUS, v); check("MAX_CYCLES = CYCLES - 5: timeout + done", v, 3);
        axi_write(IRQ_STATUS, 32'h3);
        axi_write(MAXC, 32'd0);
        host_stop();
        end_test();
    endtask

    task automatic p11_tohost();
        logic [31:0] v;
        start_test("P11 TOHOST -> EXIT_CODE");
        prog_clear();
        li(5, 32'h3FF0); li(7, 32'h3FF4);
        put(e_addi(6, 0, 32'h11));
        put(e_sw(6, 5, 0));                        // first store to TOHOST
        put(e_addi(6, 0, 32'h55));
        put(e_sw(6, 5, 0));                        // the last one counts
        put(e_addi(8, 0, 32'h77));
        put(e_sw(8, 7, 0));                        // next word: not TOHOST
        run_prog(32'h0, 0);
        axi_read(EXIT_CODE, v); check("EXIT_CODE = store cuoi vao TOHOST", v, 32'h55);
        axi_read(STATUS, v); check("STATUS EXIT_CODE da ghi", v[5], 1);
        dmem_rd(32'h3FF0, v); check("DMEM[0x3FF0] (store van vao DMEM)", v, 32'h55);
        dmem_rd(32'h3FF4, v); check("DMEM[0x3FF4]", v, 32'h77);
        host_stop();
        axi_read(EXIT_CODE, v); check("EXIT_CODE giu sau RUN = 0", v, 32'h55);
        prog_count20();                            // no store to TOHOST
        run_prog(32'h0, 0);
        axi_read(EXIT_CODE, v); check("khong ghi TOHOST: EXIT_CODE = 0", v, 0);
        axi_read(STATUS, v); check("STATUS EXIT_CODE chua ghi", v[5], 0);
        host_stop();
        end_test();
    endtask

    task automatic p12_regs();
        logic [31:0] v;
        start_test("P12 ID, CONFIG, offset khong dung");
        axi_read(ID, v); check("ID", v, 32'h4B4C_544E);
        axi_read(CONFIG, v);
        check("CONFIG", v, {7'b0, 1'b1, 8'(DMEM_AW), 8'(IMEM_AW), 8'd2});
        axi_write(12'h040, 32'hFFFF_FFFF);
        axi_read(12'h040, v); check("0x040 = 0", v, 0);
        axi_read(12'hFFC, v); check("0xFFC = 0", v, 0);
        axi_read(CTRL, v); check("ghi offset khong dung: CTRL khong doi", v, 0);
        axi_read(MAXC, v); check("ghi offset khong dung: MAX_CYCLES khong doi", v, 0);
        check("khong co giao dich AXI timeout / loi resp", axi_timeout, 0);
        end_test();
    endtask

    // =====================================================================
    initial begin
        logf = $fopen("soc_xif.log", "w");
        logln($sformatf("tb_rv32if_xif_soc: rv32if_xif_soc + BRAM (%s), PS qua AXI4-Lite + BRAM port A",
                        WF ? "WRITE_FIRST" : "NO_CHANGE"));
        repeat (5) @(posedge clk);
        aresetn = 1;
        repeat (3) @(posedge clk);
        for (int s = 0; s < 5; s++) p1_gemm_int8(s);
        p2_gemm_fp();
        p3_tiled();
        p4_scalar();
        p5_axi_protocol();
        p6_runaway();
        p7_aresetn();
        p8_mreg();
        p9_irq();
        p10_watchdog();
        p11_tohost();
        p12_regs();
        logln("");
        logln($sformatf("TONG: %0d PASS / %0d FAIL", n_pass, n_fail));
        foreach (failed[i]) logln($sformatf("  kich ban FAIL: %s", failed[i]));
        logln((n_fail == 0) ? "RESULT: PASS" : "RESULT: FAIL");
        $fclose(logf);
        $finish;
    end

    initial begin
        #300_000_000;
        logln("[FATAL] watchdog");
        logln("RESULT: FAIL");
        $fclose(logf);
        $finish;
    end
endmodule
