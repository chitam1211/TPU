`timescale 1ns/1ps

module tb_matrix_config_v2;
    `include "matrix_core_v2_tb_common.svh"

    initial begin
        $dumpfile("rv32i-pipeline-processor/sim/tb_matrix_config_v2.vcd");
        $dumpvars(0, tb_matrix_config_v2);

        reset_dut();

        issue_matrix(enc_cfg_reg(4'b0010), 32'd7, 32'd0);  // msettilem, clamps to 4
        if (debug_mtilem !== 32'd4) begin
            $display("ERROR mtilem got %0d expected 4", debug_mtilem);
            errors++;
        end

        issue_matrix(enc_cfg_reg(4'b0011), 32'd3, 32'd0);  // msettilen
        if (debug_mtilen !== 32'd3) begin
            $display("ERROR mtilen got %0d expected 3", debug_mtilen);
            errors++;
        end

        issue_matrix(enc_cfg_reg(4'b0001), 32'd20, 32'd0); // msettilek, clamps to 16
        if (debug_mtilek !== 32'd16) begin
            $display("ERROR mtilek got %0d expected 16", debug_mtilek);
            errors++;
        end

        if (errors == 0) $display("MATRIX_CONFIG_V2_TEST_PASS");
        else $display("MATRIX_CONFIG_V2_TEST_FAIL errors=%0d", errors);
        $finish;
    end
endmodule
