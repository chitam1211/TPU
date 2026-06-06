`timescale 1ns/1ps

module tb_matrix_load_store_v2;
    `include "matrix_core_v2_tb_common.svh"

    localparam int SRC_BASE_WORD = 32'h40 >> 2;
    localparam int DST_BASE_WORD = 32'h80 >> 2;
    localparam int STRIDE_WORDS  = 32'h10 >> 2;

    initial begin
        $dumpfile("sim/tb_matrix_load_store_v2.vcd");
        $dumpvars(0, tb_matrix_load_store_v2);

        reset_dut();

        issue_matrix(enc_cfg_reg(4'b0010), 32'd2, 32'd0); // M = 2 rows
        issue_matrix(enc_cfg_reg(4'b0011), 32'd4, 32'd0); // N unused for A
        issue_matrix(enc_cfg_reg(4'b0001), 32'd5, 32'd0); // K = 5 bytes per row

        dmem[SRC_BASE_WORD + 0 * STRIDE_WORDS + 0] = 32'h04030201;
        dmem[SRC_BASE_WORD + 0 * STRIDE_WORDS + 1] = 32'h08070605;
        dmem[SRC_BASE_WORD + 1 * STRIDE_WORDS + 0] = 32'h14131211;
        dmem[SRC_BASE_WORD + 1 * STRIDE_WORDS + 1] = 32'h18171615;

        dmem[DST_BASE_WORD + 0 * STRIDE_WORDS + 0] = 32'hDEADBEEF;
        dmem[DST_BASE_WORD + 0 * STRIDE_WORDS + 1] = 32'hDEADBEEF;
        dmem[DST_BASE_WORD + 1 * STRIDE_WORDS + 0] = 32'hDEADBEEF;
        dmem[DST_BASE_WORD + 1 * STRIDE_WORDS + 1] = 32'hDEADBEEF;

        issue_matrix(enc_ls(4'b0000, 1'b0, 2'b00, 3'd0), 32'h40, 32'h10); // mlae8 tr0

        host_expect(3'd0, 3'd0, 3'd0, 32'h04030201);
        host_expect(3'd0, 3'd0, 3'd1, 32'h08070605);
        host_expect(3'd0, 3'd1, 3'd0, 32'h14131211);
        host_expect(3'd0, 3'd1, 3'd1, 32'h18171615);

        issue_matrix(enc_ls(4'b0000, 1'b1, 2'b00, 3'd0), 32'h80, 32'h10); // msae8 tr0

        mem_expect(DST_BASE_WORD + 0 * STRIDE_WORDS + 0, 32'h04030201);
        mem_expect(DST_BASE_WORD + 0 * STRIDE_WORDS + 1, 32'hDEADBE05);
        mem_expect(DST_BASE_WORD + 1 * STRIDE_WORDS + 0, 32'h14131211);
        mem_expect(DST_BASE_WORD + 1 * STRIDE_WORDS + 1, 32'hDEADBE15);

        if (errors == 0) $display("MATRIX_LOAD_STORE_V2_TEST_PASS");
        else $display("MATRIX_LOAD_STORE_V2_TEST_FAIL errors=%0d", errors);
        $finish;
    end
endmodule
