`timescale 1ns/1ps
module tb_fp32_convert;
    reg clk=0, rst=0, start=0, to_float=0, unsigned_mode=0;
    reg [31:0] a=0;
    reg [2:0] rm=0;
    wire busy, done, illegal_rm;
    wire [31:0] result;
    wire [4:0] flags;
    fp32_convert dut(.*);
    always #5 clk=~clk;
    reg [1023:0] path;
    integer fd, status, count=0, cycles;
    reg [31:0] expected;
    reg [4:0] expected_flags;
    reg expected_illegal;
    initial begin
        if (!$value$plusargs("vectors=%s",path)) $fatal(1,"Need +vectors=path");
        fd=$fopen(path,"r");
        if (!fd) $fatal(1,"Cannot open vectors: %0s",path);
        repeat(2) @(negedge clk);
        rst=1;
        while (!$feof(fd)) begin
            status=$fscanf(fd,"%h %h %h %h %h %h %h\n",a,to_float,unsigned_mode,rm,
                           expected,expected_flags,expected_illegal);
            if (status != 7) $fatal(1,"Malformed vector %0d fields=%0d",count,status);
            start=1;
            @(negedge clk); start=0;
            a=32'hdeadbeef; to_float=~to_float; unsigned_mode=~unsigned_mode; rm=6;
            cycles=0;
            while (!done && cycles<8) begin
                start=(cycles==0);
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
        $display("FP32_CONVERT_TEST_PASS vectors=%0d",count);
        $finish;
    end
    initial begin #30000000; $fatal(1,"Global timeout"); end
endmodule
