`timescale 1ns/1ps

module tb_register_file;

    reg         clk;
    reg         rst;
    reg         en;
    reg  [4:0]  rs1;
    reg  [4:0]  rs2;
    reg  [4:0]  rd;
    reg  [31:0] data;

    wire [31:0] op_a;
    wire [31:0] op_b;

    integer errors;

    registerfile dut (
        .clk  (clk),
        .rst  (rst),
        .en   (en),
        .rs1  (rs1),
        .rs2  (rs2),
        .rd   (rd),
        .data (data),
        .op_a (op_a),
        .op_b (op_b)
    );

    always #5 clk = ~clk;

    task check;
        input [31:0] actual;
        input [31:0] expected;
        begin
            if (actual !== expected) begin
                $display("[FAIL] expected = %h, actual = %h",
                         expected, actual);
                errors = errors + 1;
            end
            else begin
                $display("[PASS] value = %h", actual);
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

        clk    = 1'b0;
        rst    = 1'b1;
        en     = 1'b0;

        rs1    = 5'd0;
        rs2    = 5'd0;
        rd     = 5'd0;
        data   = 32'd0;

        errors = 0;

        // Reset
        #2;
        rst = 1'b0;
        #8;
        rst = 1'b1;
        #2;

        $display("TEST 1: x0 after reset");

        rs1 = 5'd0;
        #1;

        check(op_a, 32'h00000000);


        $display("TEST 2: write/read x1");

        write_reg(
            5'd1,
            32'h12345678
        );

        rs1 = 5'd1;
        #1;

        check(
            op_a,
            32'h12345678
        );


        $display("TEST 3: write/read x31");

        write_reg(
            5'd31,
            32'hCAFEBABE
        );

        rs2 = 5'd31;
        #1;

        check(
            op_b,
            32'hCAFEBABE
        );


        $display("TEST 4: x0 must not be writable");

        write_reg(
            5'd0,
            32'hDEADBEEF
        );

        rs1 = 5'd0;
        #1;

        check(
            op_a,
            32'h00000000
        );


        $display("TEST 5: dual read");

        rs1 = 5'd1;
        rs2 = 5'd31;
        #1;

        check(
            op_a,
            32'h12345678
        );

        check(
            op_b,
            32'hCAFEBABE
        );


        $display("TEST 6: en = 0 must not write");

        @(negedge clk);

        en   = 1'b0;
        rd   = 5'd2;
        data = 32'hFFFFFFFF;

        @(posedge clk);
        #1;

        rs1 = 5'd2;
        #1;

        check(
            op_a,
            32'h00000000
        );


        if (errors == 0) begin
            $display("");
            $display("REGISTER_FILE_TEST_PASS");
        end
        else begin
            $display("");
            $display(
                "REGISTER_FILE_TEST_FAIL: %0d errors",
                errors
            );
        end

        $finish;

    end

endmodule
