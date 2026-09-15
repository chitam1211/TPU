module tb_alu;

    reg  [31:0] a_i;
    reg  [31:0] b_i;
    reg  [3:0]  op_i;

    wire [31:0] res_o;

    integer errors;

    alu dut (
        .a_i   (a_i),
        .b_i   (b_i),
        .op_i  (op_i),
        .res_o (res_o)
    );

    task check;
        input [31:0] expected;
        begin
            #1;

            if (res_o !== expected) begin
                $display(
                    "[FAIL] op=%b a=%h b=%h expected=%h actual=%h",
                    op_i,
                    a_i,
                    b_i,
                    expected,
                    res_o
                );
                errors = errors + 1;
            end
            else begin
                $display(
                    "[PASS] op=%b result=%h",
                    op_i,
                    res_o
                );
            end
        end
    endtask

    initial begin

        errors = 0;

        // ADD
        a_i  = 32'd10;
        b_i  = 32'd20;
        op_i = 4'b0000;
        check(32'd30);

        // SUB
        a_i  = 32'd20;
        b_i  = 32'd7;
        op_i = 4'b0001;
        check(32'd13);

        // SLL
        a_i  = 32'h00000001;
        b_i  = 32'd4;
        op_i = 4'b0010;
        check(32'h00000010);

        // SLT signed: -1 < 1
        a_i  = 32'hFFFFFFFF;
        b_i  = 32'h00000001;
        op_i = 4'b0011;
        check(32'h00000001);

        // SLTU
        a_i  = 32'hFFFFFFFF;
        b_i  = 32'h00000001;
        op_i = 4'b0100;
        check(32'h00000000);

        // XOR
        a_i  = 32'hAAAAAAAA;
        b_i  = 32'h55555555;
        op_i = 4'b0101;
        check(32'hFFFFFFFF);

        // SRL
        a_i  = 32'h80000000;
        b_i  = 32'd4;
        op_i = 4'b0110;
        check(32'h08000000);

        // SRA
        a_i  = 32'h80000000;
        b_i  = 32'd4;
        op_i = 4'b0111;
        check(32'hF8000000);

        // OR
        a_i  = 32'hF0000000;
        b_i  = 32'h0F000000;
        op_i = 4'b1000;
        check(32'hFF000000);

        // AND
        a_i  = 32'hFF00FF00;
        b_i  = 32'h0F0F0F0F;
        op_i = 4'b1001;
        check(32'h0F000F00);

        // LUI path
        a_i  = 32'hAAAAAAAA;
        b_i  = 32'h12345000;
        op_i = 4'b1111;
        check(32'h12345000);

        // RV32 only uses b_i[4:0] as shift amount.
        // 36 -> lower 5 bits = 4.
        a_i  = 32'h00000001;
        b_i  = 32'd36;
        op_i = 4'b0010;
        check(32'h00000010);

        // Arithmetic right shift: -16 >>> 2 = -4
        a_i  = 32'hFFFFFFF0;
        b_i  = 32'd2;
        op_i = 4'b0111;
        check(32'hFFFFFFFC);

        if (errors == 0) begin
            $display("");
            $display("ALU_TEST_PASS");
        end
        else begin
            $display("");
            $display("ALU_TEST_FAIL: %0d errors", errors);
        end

        $finish;

    end

endmodule
