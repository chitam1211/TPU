// Halt detector for programs that end in "jal x0, 0" (0x0000006F, a jump to itself).
//
// halt_hint comes from the core (Core.v): that jal is executing in EX. Only correct-path
// instructions reach EX (decode does not issue in a redirect cycle, and a redirect drops
// every younger fetched instruction), so a wrong-path jal x0,0 fetched after a branch never
// raises halt_hint. This is why the detector does not depend on how far fetch runs ahead,
// unlike watching the instruction memory output.
//
// Once the jal reaches EX the program can never leave the loop, so the hint is latched.
// Older instructions are then only in MEM/WB: a multi-cycle FP operation or an offloaded
// matrix instruction holds EX until it completes, so it cannot still be running behind the
// jal. DRAIN_CYCLES (>= 2) lets MEM/WB finish and an outstanding store be acknowledged.
// busy (optional, tie to 0) holds the count, e.g. while a coprocessor reports activity.
// halted stays set until rst_n.
module halt_detect #(
    parameter DRAIN_CYCLES = 3
)(
    input  wire clk,
    input  wire rst_n,
    input  wire halt_hint,
    input  wire busy,
    output reg  halted
);
    reg       seen;
    reg [3:0] drain_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seen      <= 1'b0;
            drain_cnt <= 4'd0;
            halted    <= 1'b0;
        end else begin
            if (halt_hint)
                seen <= 1'b1;
            if (seen && !halted && !busy) begin
                if (drain_cnt == DRAIN_CYCLES - 1)
                    halted <= 1'b1;
                else
                    drain_cnt <= drain_cnt + 4'd1;
            end
        end
    end
endmodule
