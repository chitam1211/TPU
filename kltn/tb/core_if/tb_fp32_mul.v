`timescale 1ns/1ps
module tb_fp32_mul;
    reg clk=0, rst=0, start=0;
    reg [31:0] a=0, b=0;
    reg [2:0] rm=0;
    wire busy, done, illegal_rm;
    wire [31:0] result;
    wire [4:0] flags;
    fp32_mul dut(.*);
    always #5 clk=~clk;
    reg [1023:0] path;
    integer fd, status, count=0, cycles;
    reg [31:0] expected;
    reg [4:0] expected_flags;
    reg expected_illegal;
    initial begin
        if (!$value$plusargs("vectors=%s", path)) $fatal(1,"Need +vectors=path");
        fd=$fopen(path,"r");
        if (!fd) $fatal(1,"Cannot open vectors: %0s",path);
        repeat(2) @(negedge clk);
        rst=1;
        while (!$feof(fd)) begin
            status=$fscanf(fd,"%h %h %h %h %h %h\n",a,b,rm,expected,expected_flags,expected_illegal);
            if (status != 6) $fatal(1,"Malformed vector %0d fields=%0d",count,status);
            start=1;
            @(negedge clk); start=0;
            a=32'hdeadbeef; b=32'h12345678; rm=6;
            cycles=0;
            while (!done && cycles<10) begin
                start=(cycles==1);
                @(negedge clk); cycles=cycles+1;
            end
            start=0;
            if (!done || {result,flags,illegal_rm} !== {expected,expected_flags,expected_illegal})
                $fatal(1,"Vector %0d got=%h flags=%h illegal=%b expected=%h flags=%h illegal=%b cycles=%0d",
                       count,result,flags,illegal_rm,expected,expected_flags,expected_illegal,cycles);
            count=count+1;
            @(negedge clk);
            if (done || busy) $fatal(1,"Handshake did not return idle");
        end
        $fclose(fd);
        a=32'h3f800000; b=32'h40000000; rm=0; start=1;
        @(negedge clk); start=0;
        if (!busy) $fatal(1,"Expected busy before reset");
        rst=0; #1;
        if (busy || done || result || flags || illegal_rm) $fatal(1,"Reset failed");
        @(negedge clk); rst=1;
        repeat(10) @(negedge clk);
        if (done || busy) $fatal(1,"Stale completion after reset");
        $display("FP32_MUL_TEST_PASS vectors=%0d",count);
        $finish;
    end
    initial begin #30000000; $fatal(1,"Global timeout"); end
endmodule
