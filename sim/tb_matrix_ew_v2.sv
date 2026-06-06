`timescale 1ns/1ps

module tb_matrix_ew_v2;
    `include "matrix_core_v2_tb_common.svh"

    initial begin
        $dumpfile("sim/tb_matrix_ew_v2.vcd");
        $dumpvars(0, tb_matrix_ew_v2);

        reset_dut();

        issue_matrix(enc_cfg_reg(4'b0010), 32'd4, 32'd0);
        issue_matrix(enc_cfg_reg(4'b0011), 32'd4, 32'd0);

        for (int r = 0; r < 4; r++) begin
            for (int b = 0; b < 4; b++) begin
                host_write(3'd4, r[2:0], b[2:0], 32'(r * 10 + b + 1));
                host_write(3'd5, r[2:0], b[2:0], 32'(100 + r * 10 + b + 1));
            end
        end

        issue_matrix(enc_ew(4'b0000, 3'b111, 3'd4, 3'd5, 3'd6), 32'd0, 32'd0); // madd.w.mm acc2, acc0, acc1

        for (int r = 0; r < 4; r++) begin
            for (int b = 0; b < 4; b++) begin
                host_expect(3'd6, r[2:0], b[2:0], 32'(102 + 2 * (r * 10 + b)));
            end
        end

        if (errors == 0) $display("MATRIX_EW_V2_TEST_PASS");
        else $display("MATRIX_EW_V2_TEST_FAIL errors=%0d", errors);
        $finish;
    end
endmodule
