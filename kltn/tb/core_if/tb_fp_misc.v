`timescale 1ns/1ps
module tb_fp_misc;
    reg [31:0] a,b;
    reg [2:0] operation;
    wire [31:0] result;
    fp_misc dut(.*);
    reg [31:0] edges[0:19];
    reg [31:0] expected_class[0:19];
    reg [31:0] rng=32'h23521387;
    integer i,j,k,n=0;
    task check;
        input [31:0] expected;
        begin
            #1;
            if(result !== expected) $fatal(1,"Misc op=%0d a=%h b=%h got=%h expected=%h",operation,a,b,result,expected);
            n=n+1;
        end
    endtask
    task bitops;
        begin
            operation=0; check(a);
            operation=1; check((a & 32'h7fffffff) | (b & 32'h80000000));
            operation=2; check((a & 32'h7fffffff) | ((~b) & 32'h80000000));
            operation=3; check(a ^ (b & 32'h80000000));
        end
    endtask
    initial begin
        edges[0]=32'hff800000; expected_class[0]=1;
        edges[1]=32'hbf800000; expected_class[1]=2;
        edges[2]=32'h80000001; expected_class[2]=4;
        edges[3]=32'h80000000; expected_class[3]=8;
        edges[4]=32'h00000000; expected_class[4]=16;
        edges[5]=32'h00000001; expected_class[5]=32;
        edges[6]=32'h3f800000; expected_class[6]=64;
        edges[7]=32'h7f800000; expected_class[7]=128;
        edges[8]=32'h7f800001; expected_class[8]=256;
        edges[9]=32'h7fc00000; expected_class[9]=512;
        edges[10]=32'h007fffff; expected_class[10]=32;
        edges[11]=32'h00800000; expected_class[11]=64;
        edges[12]=32'h807fffff; expected_class[12]=4;
        edges[13]=32'h80800000; expected_class[13]=2;
        edges[14]=32'h7f7fffff; expected_class[14]=64;
        edges[15]=32'hff7fffff; expected_class[15]=2;
        edges[16]=32'hffbfffff; expected_class[16]=256;
        edges[17]=32'hffc00001; expected_class[17]=512;
        edges[18]=32'h7fbfffff; expected_class[18]=256;
        edges[19]=32'h7fffffff; expected_class[19]=512;
        for(i=0;i<20;i=i+1) begin
            a=edges[i]; operation=4; check(expected_class[i]);
            for(j=0;j<20;j=j+1) begin b=edges[j]; bitops; end
        end
        for(k=0;k<10000;k=k+1) begin
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]}; a=rng;
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]}; b=rng;
            bitops;
        end
        operation=7; check(0);
        $display("FP_MISC_TEST_PASS cases=%0d",n); $finish;
    end
endmodule
