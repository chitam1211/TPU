// Halt detector check on the forwarding core (rtl/core_if_xif, XIF = 0).
// Three programs, each ending in jal x0, 0, run side by side:
//   basic      addi x1,5 / sw x1,0(x0) / jal x0,0 / addi x2,1 (wrong path, must not run)
//   wrongpath  beq x0,x0,+12 jumps over two jal x0,0 that fetch reads ahead (wrong path);
//              then a 20-iteration loop, sw x3,4(x0), jal x0,0. halt_hint must not fire early.
//   fdiv       fdiv.s f3,f1,f2 (7/2) right before jal x0,0: halted must come after f3 is written.
// For each: halt_hint must first fire with the final state already correct except MEM/WB,
// and halted must see that state. The old detector (instruction memory output equal to
// 0x6F for 64 cycles in a row) is modelled alongside: on this core it never fires.
`timescale 1ns/1ps
module halt_case #(
    parameter PROG = "",
    parameter NAME = "case",
    parameter integer KIND = 0          // 0 basic, 1 wrongpath, 2 fdiv
)(
    input  wire clk,
    input  wire rst,
    output reg  done,
    output reg  pass
);
    microprocessor #(.IMEM_FILE(PROG)) dut(.clk(clk), .rst(rst), .instruction(32'h0));

    wire halted;
    halt_detect #(.DRAIN_CYCLES(3)) u_hd(
        .clk(clk), .rst_n(rst), .halt_hint(dut.u_core.halt_hint), .busy(1'b0), .halted(halted));

    // Old detector from fpga/kr260/rtl/rv32if_matrix_soc.v, for comparison.
    reg [7:0] old_cnt; reg old_halted;
    always @(posedge clk or negedge rst)
        if (!rst) begin old_cnt <= 0; old_halted <= 0; end
        else if (dut.instruction_data == 32'h0000006F) begin
            if (old_cnt == 8'd63) old_halted <= 1; else old_cnt <= old_cnt + 1;
        end else old_cnt <= 0;

    function [31:0] xreg(input integer i); xreg = dut.u_core.u_decodestage.u_regfile0.register[i]; endfunction
    function [31:0] freg(input integer i); freg = dut.u_core.u_decodestage.u_fp_regfile0.register[i]; endfunction
    function [31:0] dmem(input integer i); dmem = dut.u_data_memory.u_memory.mem[i]; endfunction

    integer cyc = 0, hint_cyc = -1, halt_cyc = -1;
    reg ok, early = 0;
    always @(posedge clk) if (rst) cyc <= cyc + 1;

    initial begin
        done = 0; pass = 0;
        wait (rst);
        while (!halted && cyc < 400) begin
            @(negedge clk);
            if (dut.u_core.halt_hint && hint_cyc < 0) begin
                hint_cyc = cyc;
                // First hint: the jal is in EX, so every older instruction has left EX.
                if (KIND == 1 && !(xreg(4) == 0 && xreg(3) == 7)) begin
                    early = 1;
                    $display("[%0s] FAIL: halt_hint before the loop finished (x4=%0d)", NAME, xreg(4));
                end
            end
        end
        halt_cyc = cyc;
        ok = halted;
        case (KIND)
            0: ok = ok && xreg(1) == 5 && dmem(0) == 5 && xreg(2) == 0;
            1: ok = ok && xreg(1) == 1 && xreg(3) == 7 && xreg(4) == 0 && dmem(1) == 7;
            2: ok = ok && freg(3) == 32'h40600000;
        endcase
        ok = ok && !early;
        $display("[%0s] halt_hint first at cycle %0d, halted at cycle %0d | old detector: %0s | %0s",
                 NAME, hint_cyc, halt_cyc, old_halted ? "fired" : "never fired",
                 ok ? "PASS" : "FAIL");
        if (!ok) begin
            $display("    x1=%0d x2=%0d x3=%0d x4=%0d dmem0=%0d dmem1=%0d f3=%08h",
                     xreg(1), xreg(2), xreg(3), xreg(4), dmem(0), dmem(1), freg(3));
        end
        pass = ok; done = 1;
    end
endmodule

module tb_halt_detect;
    reg clk = 0, rst = 0;
    always #5 clk = ~clk;
    wire d0, d1, d2, p0, p1, p2;
    halt_case #(.PROG("prog_basic.hex"),     .NAME("basic"),     .KIND(0)) c0(clk, rst, d0, p0);
    halt_case #(.PROG("prog_wrongpath.hex"), .NAME("wrongpath"), .KIND(1)) c1(clk, rst, d1, p1);
    halt_case #(.PROG("prog_fdiv.hex"),      .NAME("fdiv"),      .KIND(2)) c2(clk, rst, d2, p2);
    initial begin
        repeat (2) @(negedge clk);
        rst = 1;
        wait (d0 && d1 && d2);
        if (p0 && p1 && p2) $display("HALT_DETECT_ALL_PASS");
        else                $display("HALT_DETECT_FAIL");
        $finish;
    end
endmodule
