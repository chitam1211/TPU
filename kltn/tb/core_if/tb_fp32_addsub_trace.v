`timescale 1ns/1ps

// Observation-only testbench: all arithmetic comes from the existing RTL.
module tb_fp32_addsub_trace;
    reg clk = 0;
    reg rst = 0;
    reg start = 0;
    reg sub = 0;
    reg [31:0] a = 0;
    reg [31:0] b = 0;
    reg [2:0] rm = 0;
    wire busy;
    wire done;
    wire [31:0] result;
    wire [4:0] flags;
    wire illegal_rm;
    integer cycle = 0;

    fp32_addsub dut (
        .clk(clk), .rst(rst), .start(start), .sub(sub), .a(a), .b(b),
        .rm(rm), .busy(busy), .done(done), .result(result),
        .flags(flags), .illegal_rm(illegal_rm)
    );

    always #5 clk = ~clk;
    always @(posedge clk) if (rst) cycle <= cycle + 1;

    // Sample after the preceding rising edge has updated the state registers.
    always @(negedge clk) begin
        if (rst) begin
            if (done) begin
                $display("TRACE state=DONE cycle=%0d result=%08h flags=%02h illegal=%0d",
                         cycle, result, flags, illegal_rm);
            end else case (dut.state)
                1: $display("TRACE state=CLASSIFY cycle=%0d a=%08h b=%08h sign_b=%0d exp_a=%0d exp_b=%0d mant_a=%07h mant_b=%07h nan_a=%0d nan_b=%0d inf_a=%0d inf_b=%0d mode=%0d",
                            cycle, dut.aa, dut.bb, dut.sign_b, dut.exp_a, dut.exp_b,
                            dut.mant_a, dut.mant_b, dut.nan_a, dut.nan_b,
                            dut.inf_a, dut.inf_b, dut.mode);
                2: $display("TRACE state=ALIGN cycle=%0d large=%07h small=%07h distance=%0d exponent=%0d same_sign=%0d sign_big=%0d",
                            cycle, dut.large_m, dut.small_m, dut.distance,
                            dut.exponent, dut.same_sign, dut.sign_big);
                3: $display("TRACE state=ADD cycle=%0d large=%07h small=%07h same_sign=%0d exponent=%0d",
                            cycle, dut.large_m, dut.small_m, dut.same_sign, dut.exponent);
                4: $display("TRACE state=NORMALIZE cycle=%0d sum=%07h exponent=%0d carry=%0d leading=%0d",
                            cycle, dut.sum, dut.exponent, dut.sum[27], dut.sum[26]);
                5: $display("TRACE state=ROUND cycle=%0d sum=%07h exponent=%0d guard=%0d round=%0d sticky=%0d increment=%0d rounded_mant=%06h rounded_exp=%0d inexact=%0d",
                            cycle, dut.sum, dut.exponent, dut.sum[2], dut.sum[1],
                            dut.sum[0], dut.increment, dut.rounded_mant,
                            dut.rounded_exp, dut.inexact);
            endcase
        end
    end

    initial begin
        if (!$value$plusargs("a=%h", a) || !$value$plusargs("b=%h", b) ||
            !$value$plusargs("sub=%d", sub) || !$value$plusargs("rm=%d", rm))
            $fatal(1, "Required: +a=<hex> +b=<hex> +sub=<0|1> +rm=<0..4>");
        repeat (2) @(negedge clk);
        rst = 1;
        start = 1;
        @(negedge clk);
        start = 0;
        wait (done);
        @(negedge clk);
        #1 $finish;
    end

    initial begin
        repeat (100) @(posedge clk);
        $fatal(1, "Trace timed out");
    end
endmodule
