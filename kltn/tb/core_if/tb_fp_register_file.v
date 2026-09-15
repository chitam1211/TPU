`timescale 1ns/1ps

module tb_fp_register_file;

    reg         clk;
    reg         rst;
    reg         en;

    reg  [4:0]  rs1;
    reg  [4:0]  rs2;
    reg  [4:0]  rs3;
    reg  [4:0]  rd;

    reg  [31:0] data;

    wire [31:0] op_a;
    wire [31:0] op_b;
    wire [31:0] op_c;

    integer errors;

    fp_register_file dut (
        .clk  (clk),
        .rst  (rst),
        .en   (en),

        .rs1  (rs1),
        .rs2  (rs2),
        .rs3  (rs3),
        .rd   (rd),

        .data (data),

        .op_a (op_a),
        .op_b (op_b),
        .op_c (op_c)
    );

    always #5 clk = ~clk;

    task check;
        input [31:0] actual;
        input [31:0] expected;
        begin
            if (actual !== expected) begin
                $display(
                    "[FAIL] expected = %h, actual = %h",
                    expected,
                    actual
                );

                errors = errors + 1;
            end
            else begin
                $display(
                    "[PASS] value = %h",
                    actual
                );
            end
        end
    endtask

    task write_reg;
        input [4:0] addr;
        input [31:0] value;
        begin

            @(negedge clk);

            en   = 1'b1;
            rd   = addr;
            data = value;

            @(posedge clk);
            #1;

            @(negedge clk);
            en = 1'b0;

        end
    endtask

    initial begin

        clk = 1'b0;
        rst = 1'b1;
        en  = 1'b0;

        rs1 = 5'd0;
        rs2 = 5'd0;
        rs3 = 5'd0;

        rd   = 5'd0;
        data = 32'd0;

        errors = 0;


        // Reset
        #2;
        rst = 1'b0;
        #8;
        rst = 1'b1;
        #2;


        $display("TEST 1: all FPR reset to zero");

        rs1 = 5'd0;
        rs2 = 5'd1;
        rs3 = 5'd31;

        #1;

        check(op_a, 32'h00000000);
        check(op_b, 32'h00000000);
        check(op_c, 32'h00000000);


        $display("TEST 2: f0 is writable");

        // FP32 1.0
        write_reg(
            5'd0,
            32'h3F800000
        );

        rs1 = 5'd0;
        #1;

        check(
            op_a,
            32'h3F800000
        );


        $display("TEST 3: write f1");

        // FP32 2.0
        write_reg(
            5'd1,
            32'h40000000
        );

        rs1 = 5'd1;
        #1;

        check(
            op_a,
            32'h40000000
        );


        $display("TEST 4: write f2");

        // FP32 3.0
        write_reg(
            5'd2,
            32'h40400000
        );

        rs1 = 5'd2;
        #1;

        check(
            op_a,
            32'h40400000
        );


        $display("TEST 5: three simultaneous reads");

        rs1 = 5'd0;
        rs2 = 5'd1;
        rs3 = 5'd2;

        #1;

        check(
            op_a,
            32'h3F800000
        );

        check(
            op_b,
            32'h40000000
        );

        check(
            op_c,
            32'h40400000
        );


        $display("TEST 6: f31");

        // FP32 -1.0
        write_reg(
            5'd31,
            32'hBF800000
        );

        rs3 = 5'd31;
        #1;

        check(
            op_c,
            32'hBF800000
        );


        $display("TEST 7: en = 0 must not write");

        @(negedge clk);

        en   = 1'b0;
        rd   = 5'd3;
        data = 32'hDEADBEEF;

        @(posedge clk);
        #1;

        rs1 = 5'd3;
        #1;

        check(
            op_a,
            32'h00000000
        );


        if (errors == 0) begin
            $display("");
            $display("FP_REGISTER_FILE_TEST_PASS");
        end
        else begin
            $display("");
            $display(
                "FP_REGISTER_FILE_TEST_FAIL: %0d errors",
                errors
            );
        end

        $finish;

    end

endmodule
