// =============================================================================
// tb_rv32if_matrix_axi: kiem tra wrapper AXI4-Lite cua RV32IF + matrix.
//   1. doc ID, kiem tra DMEM/IMEM bi khoa khi RUN = 1
//   2. nap chuong trinh (scalar + mmacc.w.b) va du lieu qua AXI
//   3. RUN = 1, cho STATUS.halted, kiem tra CYCLES/MDONE_CNT
//   4. doc ket qua DMEM va acc0 (MREG) so voi tinh tay; ghi/doc lai tr2 qua MREG
// =============================================================================
`timescale 1ns / 1ps

module tb_rv32if_matrix_axi;
    import tb_matrix_pkg::*;

    localparam CTRL = 14'h0000, STATUS = 14'h0004, CYCLES = 14'h0008, PC = 14'h000C;
    localparam MTILEM = 14'h0010, MTILEN = 14'h0014, MTILEK = 14'h0018, MDONE = 14'h001C;
    localparam MSEL = 14'h0020, MDATA = 14'h0024, ID = 14'h0028;
    localparam IMEM = 14'h1000, DMEM = 14'h2000;

    localparam logic [31:0] NOP = 32'h00000013, JAL_SELF = 32'h0000006F;

    logic clk = 0, aresetn = 0;
    always #5 clk = ~clk;

    logic [13:0] awaddr, araddr;
    logic        awvalid, wvalid, bready, arvalid, rready;
    logic [31:0] wdata;
    logic [3:0]  wstrb;
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

    int errors = 0;

    // ---------------- AXI4-Lite BFM ----------------
    // AW va W duoc dua ra lech nhau 1 chu ky de thu ca truong hop khong dong thoi.
    task automatic axi_write(input logic [13:0] a, input logic [31:0] d, input logic [3:0] s = 4'hF);
        @(posedge clk);
        awaddr <= a; awvalid <= 1'b1;
        @(posedge clk);
        wdata <= d; wstrb <= s; wvalid <= 1'b1;
        do @(posedge clk); while (!(awready && wready));
        awvalid <= 1'b0; wvalid <= 1'b0; bready <= 1'b1;
        do @(posedge clk); while (!bvalid);
        if (bresp !== 2'b00) begin errors++; $display("[FAIL] BRESP=%b @0x%04h", bresp, a); end
        bready <= 1'b0;
    endtask

    task automatic axi_read(input logic [13:0] a, output logic [31:0] d);
        @(posedge clk);
        araddr <= a; arvalid <= 1'b1;
        do @(posedge clk); while (!arready);
        arvalid <= 1'b0; rready <= 1'b1;
        do @(posedge clk); while (!rvalid);
        d = rdata;
        if (rresp !== 2'b00) begin errors++; $display("[FAIL] RRESP=%b @0x%04h", rresp, a); end
        rready <= 1'b0;
    endtask

    task automatic check(input string what, input logic [31:0] act, input logic [31:0] exp);
        if (act !== exp) begin
            errors++;
            $display("[FAIL] %-28s actual=0x%08h expected=0x%08h", what, act, exp);
        end
    endtask

    function automatic logic [31:0] e_addi(input int rd, input int rs1, input int imm);
        return {12'(imm), 5'(rs1), 3'b000, 5'(rd), 7'b0010011};
    endfunction
    function automatic logic [31:0] e_add(input int rd, input int rs1, input int rs2);
        return {7'b0, 5'(rs2), 5'(rs1), 3'b000, 5'(rd), 7'b0110011};
    endfunction
    function automatic logic [31:0] e_sw(input int rs2, input int rs1, input int imm);
        logic [11:0] i;
        i = 12'(imm);
        return {i[11:5], 5'(rs2), 5'(rs1), 3'b010, i[4:0], 7'b0100011};
    endfunction

    // ---------------- Chuong trinh ----------------
    logic [31:0] prog [$];
    task automatic emit(input logic [31:0] w); prog.push_back(w); endtask
    task automatic nops(input int n); repeat (n) prog.push_back(NOP); endtask

    // Du lieu: A int8 4x16 @0x000, B int8 4x16 @0x040, C int32 4x4 @0x080 (stride 16 byte)
    //          ket qua: C' @0x200, scalar @0x300
    logic signed [7:0]  A [4][16], B [4][16];
    logic signed [31:0] C [4][4];

    function automatic logic [31:0] pack8(input logic is_b, input int r, input int beat);
        if (is_b) return {B[r][beat*4+3], B[r][beat*4+2], B[r][beat*4+1], B[r][beat*4]};
        else      return {A[r][beat*4+3], A[r][beat*4+2], A[r][beat*4+1], A[r][beat*4]};
    endfunction

    logic [31:0] v, exp;
    int seed = 32'h1234;

    initial begin
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        awaddr = 0; araddr = 0; wdata = 0; wstrb = 0;
        repeat (10) @(posedge clk);
        aresetn = 1;
        repeat (5) @(posedge clk);

        // 1. ID, trang thai sau reset
        axi_read(ID, v);      check("ID", v, 32'h4B4C544E);
        axi_read(STATUS, v);  check("STATUS after reset", v, 32'h0);

        // 2. Chuong trinh
        emit(e_addi(1, 0, 'h000));                         // x1 = base A
        emit(e_addi(2, 0, 16));                            // x2 = stride
        emit(e_addi(3, 0, 'h040));                         // x3 = base B
        emit(e_addi(4, 0, 'h080));                         // x4 = base C
        emit(e_addi(9, 0, 'h200));                         // x9 = out C
        emit(e_addi(20, 0, 100));
        emit(e_addi(21, 0, 23));
        nops(3);
        emit(e_add(22, 20, 21));                           // x22 = 123
        nops(3);
        emit(e_sw(22, 0, 'h300));                          // mem[0x300] = 123
        emit(enc_cfg(4'b0010, 1'b0, 10'd4, 5'd0));         // msettilemi 4
        emit(enc_cfg(4'b0011, 1'b0, 10'd4, 5'd0));         // msettileni 4
        emit(enc_cfg(4'b0001, 1'b0, 10'd16, 5'd0));        // msettileki 16
        emit(enc_ls(4'b0000, 1'b0, 5'd2, 5'd1, 2'b00, TR0));   // mlae8  tr0, (x1), x2
        emit(enc_ls(4'b0001, 1'b0, 5'd2, 5'd3, 2'b00, TR1));   // mlbe8  tr1, (x3), x2
        emit(enc_ls(4'b0010, 1'b0, 5'd2, 5'd4, 2'b10, ACC0));  // mlce32 acc0, (x4), x2
        emit(enc_mma(4'b0001, 3'b011, TR1, 2'b00, TR0, 2'b10, ACC0)); // mmacc.w.b acc0, tr1, tr0
        emit(enc_ls(4'b0010, 1'b1, 5'd2, 5'd9, 2'b10, ACC0));  // msce32 acc0, (x9), x2
        nops(2);
        emit(JAL_SELF);

        for (int i = 0; i < 256; i++)
            axi_write(IMEM + 14'(i * 4), (i < prog.size()) ? prog[i] : NOP);
        for (int i = 0; i < prog.size(); i++) begin
            axi_read(IMEM + 14'(i * 4), v);
            check($sformatf("IMEM[%0d] readback", i), v, prog[i]);
        end

        // Du lieu
        for (int r = 0; r < 4; r++)
            for (int k = 0; k < 16; k++) begin
                seed = seed * 1103515245 + 12345; A[r][k] = 8'(seed >>> 16);
                seed = seed * 1103515245 + 12345; B[r][k] = 8'(seed >>> 16);
            end
        for (int r = 0; r < 4; r++)
            for (int c = 0; c < 4; c++) begin
                seed = seed * 1103515245 + 12345; C[r][c] = 32'(seed >>> 8);
            end
        for (int r = 0; r < 4; r++)
            for (int b = 0; b < 4; b++) begin
                axi_write(DMEM + 14'('h000 + r * 16 + b * 4), pack8(1'b0, r, b));
                axi_write(DMEM + 14'('h040 + r * 16 + b * 4), pack8(1'b1, r, b));
                axi_write(DMEM + 14'('h080 + r * 16 + b * 4), C[r][b]);
            end
        for (int i = 'h200 / 4; i < 'h400 / 4; i++) axi_write(DMEM + 14'(i * 4), 32'hA5A5A5A5);

        // Ghi tung byte (WSTRB) roi doc lai
        axi_write(DMEM + 14'h3FC, 32'h11223344, 4'b0101);
        axi_read(DMEM + 14'h3FC, v); check("DMEM wstrb 0101", v, 32'hA522A544);

        // 3. Chay
        axi_write(CTRL, 32'h1);
        axi_read(DMEM, v);    check("DMEM read while RUN", v, 32'hDEADBEEF);
        begin
            int polls = 0;
            do begin axi_read(STATUS, v); polls++; end while (!v[1] && polls < 2000);
        end
        check("STATUS running|halted|done", v & 32'hB, 32'hB);
        check("irq", {31'b0, irq}, 32'h1);
        axi_read(MDONE, v);   check("MDONE_CNT", v, 32'd8);
        axi_read(MTILEM, v);  check("MTILEM", v, 4);
        axi_read(MTILEN, v);  check("MTILEN", v, 4);
        axi_read(MTILEK, v);  check("MTILEK", v, 16);
        axi_read(PC, v);      $display("PC at halt     = 0x%08h (jal x0,0 at 0x%03h)", v, (prog.size() - 1) * 4);
        axi_read(CYCLES, v);  $display("CYCLES         = %0d", v);
        if (v == 0 || v > 1000) begin errors++; $display("[FAIL] CYCLES out of range"); end

        // acc0 qua cong MREG (con RUN = 1: thanh ghi ma tran khong bi reset)
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) begin
                exp = C[i][j];
                for (int k = 0; k < 16; k++) exp = exp + 32'(A[i][k]) * 32'(B[j][k]);
                axi_write(MSEL, {13'b0, 3'(j), 5'b0, 3'(i), 5'b0, ACC0});
                axi_read(MDATA, v);
                check($sformatf("acc0[%0d][%0d] via MREG", i, j), v, exp);
            end

        // Ghi/doc lai tr2 qua MREG
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) begin
                axi_write(MSEL, {13'b0, 3'(j), 5'b0, 3'(i), 5'b0, TR2});
                axi_write(MDATA, 32'hC0DE0000 | (i << 4) | j);
            end
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) begin
                axi_write(MSEL, {13'b0, 3'(j), 5'b0, 3'(i), 5'b0, TR2});
                axi_read(MDATA, v);
                check($sformatf("tr2[%0d][%0d] write/read", i, j), v, 32'hC0DE0000 | (i << 4) | j);
            end

        // 4. Dung core, doc DMEM
        axi_write(CTRL, 32'h0);
        axi_read(STATUS, v);  check("STATUS after stop", v, 32'h0);
        axi_read(DMEM + 14'h300, v); check("mem[0x300] scalar", v, 32'd123);
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) begin
                exp = C[i][j];
                for (int k = 0; k < 16; k++) exp = exp + 32'(A[i][k]) * 32'(B[j][k]);
                axi_read(DMEM + 14'('h200 + i * 16 + j * 4), v);
                check($sformatf("C'[%0d][%0d] in DMEM", i, j), v, exp);
            end

        // Chay lai lan 2: bo dem phai bat dau lai tu 0
        axi_write(CTRL, 32'h1);
        do axi_read(STATUS, v); while (!v[1]);
        axi_read(MDONE, v);   check("MDONE_CNT (2nd run)", v, 32'd8);

        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("RESULT: FAIL (timeout)");
        $finish;
    end
endmodule
