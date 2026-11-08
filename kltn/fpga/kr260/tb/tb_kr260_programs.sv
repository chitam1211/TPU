`timescale 1ns / 1ps
// =============================================================================
// tb_kr260_programs: kiem tra wrapper FPGA (rv32if_matrix_axi -> rv32if_matrix_soc ->
// core_matrix) CHI qua bus AXI4-Lite, giong cach PS tren KR260 dieu khien:
//   nap IMEM (ca 256 word, phan duoi chuong trinh = 0x00000000 nhu BRAM sau khi nap
//   bitstream) + DMEM -> CTRL.RUN = 1 -> cho irq -> doc CYCLES / MDONE_CNT / MTILE* /
//   MREG -> CTRL.RUN = 0 -> doc DMEM, so voi gia tri tinh trong testbench.
// Kich ban:
//   P1 GEMM int8 4x4x16, 5 bo du lieu ngau nhien (moi lan nap lai DMEM, chay lai)
//   P2 GEMM FP32 4x4x4 (mfmacc.s) + mfadd.s.mm + lenh F scalar
//   P3 GEMM int8 K = 64 (4 khoi trong vong lap) + madd.w.mm
//   P4 Chuong trinh scalar RV32I + RV32F, ket qua ghi ra DMEM
//   P5 Giao thuc AXI: W truoc AW, AW/W cung luc, BREADY/RREADY tre, WSTRB tung byte,
//      DMEM/IMEM bi khoa khi RUN = 1, ID
//   P6 Chuong trinh khong dung (vong lap vo han): halted = 0, CTRL = 0 dung duoc core
//   P7 s_axi_aresetn giua luc chay, sau do chay lai binh thuong
//   P8 MREG: ghi khi RUN = 0 khong co tac dung (thanh ghi ma tran reset cung core),
//      ghi/doc khi RUN = 1, chi so ngoai pham vi doc ra 0
// Ket qua: tb/build/programs.log, dong cuoi "RESULT: PASS" / "RESULT: FAIL".
// =============================================================================
module tb_kr260_programs;
    import tb_matrix_pkg::*;

    localparam logic [13:0] CTRL = 14'h0000, STATUS = 14'h0004, CYCLES = 14'h0008, PC = 14'h000C;
    localparam logic [13:0] MTILEM = 14'h0010, MTILEN = 14'h0014, MTILEK = 14'h0018, MDONE = 14'h001C;
    localparam logic [13:0] MSEL = 14'h0020, MDATA = 14'h0024, ID = 14'h0028;
    localparam logic [13:0] IMEM_BASE = 14'h1000, DMEM_BASE = 14'h2000;
    localparam logic [31:0] JAL_SELF = 32'h0000_006F;

    logic clk = 0, aresetn = 0;
    always #5 clk = ~clk;                 // 100 MHz (pl_clk0)

    logic [13:0] awaddr = 0, araddr = 0;
    logic        awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    logic [31:0] wdata = 0;
    logic [3:0]  wstrb = 0;
    wire         awready, wready, bvalid, arready, rvalid, irq;
    wire  [1:0]  bresp, rresp;
    wire  [31:0] rdata;

    rv32if_matrix_axi dut (
        .s_axi_aclk(clk), .s_axi_aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .irq(irq)
    );

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
            $fdisplay(logf, "    [PASS] %-36s = 0x%08h", what, got);
        end else begin
            n_fail++; t_fail++;
            logln($sformatf("    [FAIL] %-36s got=0x%08h exp=0x%08h", what, got, exp));
        end
    endtask
    task automatic start_test(input string name);
        cur = name; t_pass = 0; t_fail = 0;
        logln(""); logln($sformatf("==== %s ====", name));
    endtask
    task automatic end_test();
        logln($sformatf("    -> %s : %0d PASS / %0d FAIL", cur, t_pass, t_fail));
        if (t_fail) failed.push_back(cur);
    endtask

    // ---------------------------------------------------------------------
    // AXI4-Lite BFM. mode: 0 = AW va W cung luc, 1 = AW truoc, 2 = W truoc.
    // bdly / rdly: so chu ky tre truoc khi dua BREADY / RREADY.
    // ---------------------------------------------------------------------
    int wr_mode = 0, bdly = 0, rdly = 0;
    int axi_timeout = 0;

    task automatic axi_write(input logic [13:0] a, input logic [31:0] d, input logic [3:0] s = 4'hF);
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

    task automatic axi_read(input logic [13:0] a, output logic [31:0] d);
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

    `include "rv32if_asm.svh"

    // ---------------------------------------------------------------------
    // Chuong trinh / du lieu (giong tb_top)
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
    // Thao tac muc host (giong rvm_host.py)
    // ---------------------------------------------------------------------
    task automatic host_load(input logic [31:0] tail);
        // chuong trinh + "jal x0, 0" (dung) + phan con lai = tail
        for (int i = 0; i < 256; i++)
            axi_write(IMEM_BASE + 14'(i * 4), (i < nprog) ? prog[i] : (i == nprog) ? JAL_SELF : tail);
        for (int i = 0; i < 256; i++) axi_write(DMEM_BASE + 14'(i * 4), dinit[i]);
    endtask

    // RUN = 1, cho irq. Tra ve so chu ky cho (0 = timeout)
    task automatic host_run(input int max_cyc, output int waited);
        axi_write(CTRL, 32'h1);
        waited = 0;
        while (!irq && waited < max_cyc) begin @(posedge clk); waited++; end
        if (!irq) waited = 0;
    endtask

    task automatic host_stop(); axi_write(CTRL, 32'h0); endtask

    task automatic dmem_rd(input int byte_addr, output logic [31:0] v);
        axi_read(DMEM_BASE + 14'(byte_addr), v);
    endtask
    task automatic mreg_rd(input logic [2:0] id, input int row, input int beat, output logic [31:0] v);
        axi_write(MSEL, {13'b0, 3'(beat), 5'b0, 3'(row), 5'b0, id});
        axi_read(MDATA, v);
    endtask
    task automatic mreg_wr(input logic [2:0] id, input int row, input int beat, input logic [31:0] v);
        axi_write(MSEL, {13'b0, 3'(beat), 5'b0, 3'(row), 5'b0, id});
        axi_write(MDATA, v);
    endtask

    // Chay chuong trinh da dung: nap, RUN, kiem tra halt + thanh ghi trang thai
    task automatic run_prog(input logic [31:0] tail, input int expect_mdone);
        int w;
        logic [31:0] v;
        host_stop();
        host_load(tail);
        host_run(200_000, w);
        check("irq/halted (khong timeout)", w != 0, 1);
        axi_read(STATUS, v);
        check("STATUS running|halted", v[1:0], 2'b11);
        check("STATUS matrix_busy = 0", v[2], 0);
        axi_read(CYCLES, v);
        logln($sformatf("    CYCLES = %0d (gom %0d chu ky phat hien dung)", v, 64));
        check("CYCLES > 0", v > 0, 1);
        axi_read(MDONE, v);
        check("MDONE_CNT", v, expect_mdone);
        axi_read(PC, v);
        check("PC tai lenh jal x0,0 (+0..8)", (v - nprog * 4) <= 8, 1);
    endtask

    // =====================================================================
    localparam int A_AD = 32'h000, B_AD = 32'h040, C_AD = 32'h080, D_AD = 32'h0C0;

    task automatic p1_gemm_int8(input int n_seed);
        logic [31:0] v;
        start_test($sformatf("P1 GEMM int8 4x4x16 qua AXI, bo du lieu %0d", n_seed));
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
        put(e_lw(20, 13, 0));                       // lw ngay sau msce32
        put(e_addi(20, 20, 1));
        put(e_sw(20, 0, 32'h3F0));
        run_prog(32'h0, n_mx);                      // duoi IMEM = 0 (BRAM sau nap bitstream)
        axi_read(MTILEM, v); check("MTILEM", v, 4);
        axi_read(MTILEN, v); check("MTILEN", v, 4);
        axi_read(MTILEK, v); check("MTILEK", v, 16);
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) begin
                mreg_rd(ACC0, i, j, v);
                check($sformatf("acc0[%0d][%0d] (MREG)", i, j), v, Cexp[i][j]);
            end
        axi_read(DMEM_BASE, v);
        check("DMEM khoa khi RUN = 1 (0xDEADBEEF)", v, 32'hDEAD_BEEF);
        host_stop();
        axi_read(STATUS, v); check("STATUS sau stop", v, 0);
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
        start_test("P2 GEMM FP32 4x4x4 + mfadd.s.mm + lenh F qua AXI");
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
        run_prog(32'h0, n_mx);
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
        start_test("P3 GEMM int8 K=64 (vong lap 4 khoi) + madd.w.mm qua AXI");
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
        run_prog(32'h0, n_mx);
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
        // fibonacci 20 so (x1, x2), tong (x3)
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
        put(e_sh(3, 0, 32'h306));                  // nua cao cua word 0x304
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
        start_test("P5 Giao thuc AXI4-Lite + khoa bo nho");
        host_stop();
        axi_read(ID, v); check("ID = KLTN", v, 32'h4B4C_544E);
        for (int m = 0; m < 3; m++) begin
            wr_mode = m; bdly = m * 3; rdly = 5 - m * 2;
            axi_write(DMEM_BASE + 14'h3E0 + 14'(m * 4), 32'h1111_0000 + m);
            axi_read(DMEM_BASE + 14'h3E0 + 14'(m * 4), v);
            check($sformatf("ghi/doc mode %0d (bdly %0d, rdly %0d)", m, bdly, rdly), v, 32'h1111_0000 + m);
        end
        wr_mode = 0; bdly = 0; rdly = 0;
        axi_write(DMEM_BASE + 14'h3EC, 32'h0);
        axi_write(DMEM_BASE + 14'h3EC, 32'hAABB_CCDD, 4'b0101);
        axi_read (DMEM_BASE + 14'h3EC, v); check("WSTRB 0101", v, 32'h00BB_00DD);
        axi_write(DMEM_BASE + 14'h3EC, 32'h1122_3344, 4'b1000);
        axi_read (DMEM_BASE + 14'h3EC, v); check("WSTRB 1000", v, 32'h11BB_00DD);
        axi_write(IMEM_BASE + 14'h3FC, 32'h1234_5678);
        axi_read (IMEM_BASE + 14'h3FC, v); check("IMEM ghi/doc", v, 32'h1234_5678);
        // chuong trinh ngan, RUN, thu ghi bo nho khi dang chay
        prog_clear();
        put(e_addi(1, 0, 5));
        put(e_sw(1, 0, 32'h3F8));
        host_load(32'h0);
        begin int w; host_run(10_000, w); check("chuong trinh ngan dung", w != 0, 1); end
        axi_write(DMEM_BASE + 14'h3F8, 32'hBAD0_BAD0);   // phai bi bo qua
        axi_write(IMEM_BASE + 14'h000, 32'hBAD0_BAD0);
        axi_read (IMEM_BASE + 14'h000, v); check("IMEM khoa khi RUN (0xDEADBEEF)", v, 32'hDEAD_BEEF);
        host_stop();
        dmem_rd(32'h3F8, v); check("ghi DMEM khi RUN bi bo qua", v, 5);
        axi_read(IMEM_BASE, v); check("ghi IMEM khi RUN bi bo qua", v, prog[0]);
        axi_read(14'h0FC, v); check("offset thanh ghi khong dung = 0", v, 0);
        check("khong co giao dich AXI timeout / loi resp", axi_timeout, 0);
        end_test();
    endtask

    task automatic p6_runaway();
        logic [31:0] v;
        int w;
        start_test("P6 Chuong trinh khong dung, host dung bang CTRL");
        prog_clear();
        put(e_addi(1, 1, 1));
        put(j_t(-4, 0));                           // vong lap vo han (khong phai jal x0,0)
        host_stop();
        host_load(32'h0);
        host_run(5_000, w);
        check("khong bao halted", w, 0);
        axi_read(STATUS, v); check("STATUS running, chua halted", v[1:0], 2'b01);
        axi_read(CYCLES, v); check("CYCLES dang dem", v > 4000, 1);
        host_stop();
        axi_read(STATUS, v); check("STATUS = 0 sau stop", v, 0);
        end_test();
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
        axi_read(STATUS, v); check("STATUS = 0 sau aresetn", v, 0);
        axi_read(CTRL, v);   check("CTRL = 0 sau aresetn", v, 0);
        // bo nho khong bi xoa boi reset: chay lai luon
        host_run(200_000, w);
        check("chay lai sau aresetn", w != 0, 1);
        axi_read(MDONE, v); check("MDONE_CNT chay lai", v, n_mx);
        host_stop();
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) begin
                dmem_rd(D_AD + 16 * i + 4 * j, v);
                check($sformatf("D[%0d][%0d] sau aresetn", i, j), v, Cexp[i][j]);
            end
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
        // xoa vung ket qua
        for (int i = 0; i < 16; i++) axi_write(DMEM_BASE + 14'(D_AD + 4 * i), 32'h0);
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
        host_load(32'h0);                          // chuong trinh rong: chi jal x0,0
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
        host_stop();
        end_test();
    endtask

    // =====================================================================
    initial begin
        logf = $fopen("programs.log", "w");
        logln("tb_kr260_programs: rv32if_matrix_axi (wrapper FPGA KR260), chi qua AXI4-Lite");
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
        logln("");
        logln($sformatf("TONG: %0d PASS / %0d FAIL", n_pass, n_fail));
        foreach (failed[i]) logln($sformatf("  kich ban FAIL: %s", failed[i]));
        logln((n_fail == 0) ? "RESULT: PASS" : "RESULT: FAIL");
        $fclose(logf);
        $finish;
    end

    initial begin
        #200_000_000;
        logln("[FATAL] watchdog");
        logln("RESULT: FAIL");
        $fclose(logf);
        $finish;
    end
endmodule
