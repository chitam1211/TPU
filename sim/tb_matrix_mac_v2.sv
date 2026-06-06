`timescale 1ns/1ps

module tb_matrix_mac_v2;
    `include "matrix_core_v2_tb_common.svh"

    initial begin
        $dumpfile("rv32i-pipeline-processor/sim/tb_matrix_mac_v2.vcd");
        $dumpvars(0, tb_matrix_mac_v2);

        reset_dut();

        issue_matrix(enc_cfg_reg(4'b0010), 32'd4, 32'd0);
        issue_matrix(enc_cfg_reg(4'b0011), 32'd4, 32'd0);
        issue_matrix(enc_cfg_reg(4'b0001), 32'd4, 32'd0);

        // A is row-major 4x4 in tr0, one packed INT8 word per row.
        host_write(3'd0, 3'd0, 3'd0, 32'h04030201);
        host_write(3'd0, 3'd1, 3'd0, 32'h08070605);
        host_write(3'd0, 3'd2, 3'd0, 32'h0c0b0a09);
        host_write(3'd0, 3'd3, 3'd0, 32'h100f0e0d);

        // B is stored transposed in tr1: each row is one original B column.
        host_write(3'd1, 3'd0, 3'd0, 32'h0d090501);
        host_write(3'd1, 3'd1, 3'd0, 32'h0e0a0602);
        host_write(3'd1, 3'd2, 3'd0, 32'h0f0b0703);
        host_write(3'd1, 3'd3, 3'd0, 32'h100c0804);

        issue_matrix(enc_misc(4'b0000, 3'b000, 3'd0, 3'd0, 2'b00, 2'b00, 3'd4),
                     32'd0, 32'd0); // mzero acc0
        issue_matrix(enc_matmul(3'b000, 3'd0, 3'd1, 3'd4), 32'd0, 32'd0); // mmaccu.w.b acc0,tr0,tr1

        host_expect(3'd4, 3'd0, 3'd0, 32'd90);
        host_expect(3'd4, 3'd0, 3'd1, 32'd100);
        host_expect(3'd4, 3'd0, 3'd2, 32'd110);
        host_expect(3'd4, 3'd0, 3'd3, 32'd120);
        host_expect(3'd4, 3'd1, 3'd0, 32'd202);
        host_expect(3'd4, 3'd1, 3'd1, 32'd228);
        host_expect(3'd4, 3'd1, 3'd2, 32'd254);
        host_expect(3'd4, 3'd1, 3'd3, 32'd280);
        host_expect(3'd4, 3'd2, 3'd0, 32'd314);
        host_expect(3'd4, 3'd2, 3'd1, 32'd356);
        host_expect(3'd4, 3'd2, 3'd2, 32'd398);
        host_expect(3'd4, 3'd2, 3'd3, 32'd440);
        host_expect(3'd4, 3'd3, 3'd0, 32'd426);
        host_expect(3'd4, 3'd3, 3'd1, 32'd484);
        host_expect(3'd4, 3'd3, 3'd2, 32'd542);
        host_expect(3'd4, 3'd3, 3'd3, 32'd600);

        if (errors == 0) $display("MATRIX_MAC_V2_TEST_PASS");
        else $display("MATRIX_MAC_V2_TEST_FAIL errors=%0d", errors);
        $finish;
    end
endmodule
