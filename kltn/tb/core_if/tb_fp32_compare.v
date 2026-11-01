`timescale 1ns/1ps
module tb_fp32_compare;
    reg [31:0] a, b, expected;
    reg [2:0] operation;
    reg [4:0] expected_flags;
    wire [31:0] result;
    wire [4:0] flags;
    reg [2047:0] vector_path;
    integer fd, status, count=0;
    fp32_compare dut(.a(a), .b(b), .operation(operation), .result(result), .flags(flags),
                     .min_result(), .max_result(), .minmax_flags());
    initial begin
        if (!$value$plusargs("vectors=%s", vector_path)) $fatal(1,"Missing vectors");
        fd=$fopen(vector_path,"r");
        if (!fd) $fatal(1,"Cannot open vectors");
        while (!$feof(fd)) begin
            status=$fscanf(fd,"%h %h %h %h %h\n",a,b,operation,expected,expected_flags);
            if (status != 5) $fatal(1,"Malformed vector %0d",count);
            #1;
            if (result !== expected || flags !== expected_flags)
                $fatal(1,"a=%h b=%h op=%d got=%h/%h expected=%h/%h",
                    a,b,operation,result,flags,expected,expected_flags);
            count=count+1;
        end
        $fclose(fd);
        if (count < 30000) $fatal(1,"Incomplete vectors: %0d",count);
        $display("FP32_COMPARE_TEST_PASS cases=%0d",count);
        $finish;
    end
endmodule
