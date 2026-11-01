`timescale 1ns/1ps
module tb_fp32_minmax;
    reg [31:0] a, b, expected_min, expected_max;
    reg [2:0] operation;
    reg [4:0] expected_flags;
    wire [31:0] min_result, max_result;
    wire [4:0] minmax_flags;
    reg [2047:0] vector_path;
    integer fd, status, count=0;
    fp32_compare dut(.a(a), .b(b), .operation(operation), .result(), .flags(),
        .min_result(min_result), .max_result(max_result), .minmax_flags(minmax_flags));
    initial begin
        if (!$value$plusargs("vectors=%s", vector_path)) $fatal(1,"Missing vectors");
        fd=$fopen(vector_path,"r");
        if (!fd) $fatal(1,"Cannot open vectors");
        while (!$feof(fd)) begin
            status=$fscanf(fd,"%h %h %h %h %h\n",a,b,expected_min,expected_max,expected_flags);
            if (status != 5) $fatal(1,"Malformed vector %0d",count);
            operation=count[2:0]; // Min/max must not depend on compare funct3.
            #1;
            if (min_result !== expected_min || max_result !== expected_max || minmax_flags !== expected_flags)
                $fatal(1,"a=%h b=%h got=%h/%h/%h expected=%h/%h/%h",
                    a,b,min_result,max_result,minmax_flags,expected_min,expected_max,expected_flags);
            count=count+1;
        end
        $fclose(fd);
        if (count < 20000) $fatal(1,"Incomplete vectors: %0d",count);
        $display("FP32_MINMAX_TEST_PASS pairs=%0d results=%0d",count,2*count);
        $finish;
    end
endmodule
