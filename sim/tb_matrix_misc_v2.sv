`timescale 1ns/1ps

module tb_matrix_misc_v2;
    `include "matrix_core_v2_tb_common.svh"

    initial begin
        $dumpfile("rv32i-pipeline-processor/sim/tb_matrix_misc_v2.vcd");
        $dumpvars(0, tb_matrix_misc_v2);

        reset_dut();

        issue_matrix(enc_misc(4'b0011, 3'b000, 3'd0, 3'd0, 2'b00, 2'b10, 3'd2),
                     32'd0, 32'h11223344); // mdupw.m.x tr2, x

        for (int r = 0; r < 4; r++) begin
            for (int b = 0; b < 4; b++) begin
                host_expect(3'd2, r[2:0], b[2:0], 32'h11223344);
            end
        end

        issue_matrix(enc_misc(4'b0001, 3'b000, 3'd2, 3'd0, 2'b00, 2'b00, 3'd3),
                     32'd0, 32'd0); // mmov.mm tr3, tr2

        for (int r = 0; r < 4; r++) begin
            for (int b = 0; b < 4; b++) begin
                host_expect(3'd3, r[2:0], b[2:0], 32'h11223344);
            end
        end

        host_write(3'd4, 3'd1, 3'd2, 32'hCAFE_BABE);
        issue_matrix(enc_misc(4'b0000, 3'b000, 3'd0, 3'd0, 2'b00, 2'b00, 3'd4),
                     32'd0, 32'd0); // mzero acc0

        for (int r = 0; r < 4; r++) begin
            for (int b = 0; b < 4; b++) begin
                host_expect(3'd4, r[2:0], b[2:0], 32'h00000000);
            end
        end

        if (errors == 0) $display("MATRIX_MISC_V2_TEST_PASS");
        else $display("MATRIX_MISC_V2_TEST_FAIL errors=%0d", errors);
        $finish;
    end
endmodule
