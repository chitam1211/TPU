`timescale 1ns/1ps

module tb_matrix_load_store_v2;
    `include "matrix_core_v2_tb_common.svh"

    localparam int A_SRC_WORD = 32'h040 >> 2;
    localparam int A_DST_WORD = 32'h0C0 >> 2;
    localparam int B_SRC_WORD = 32'h140 >> 2;
    localparam int B_DST_WORD = 32'h200 >> 2;
    localparam int C_SRC_WORD = 32'h280 >> 2;
    localparam int C_DST_WORD = 32'h340 >> 2;
    localparam int STRIDE_WORDS = 32'h20 >> 2;

    logic [31:0] iss_insn [0:5];
    logic [31:0] iss_expected_reg [0:15];
    logic [31:0] iss_expected_mem [0:15];
    logic [31:0] rtl_word;

    task automatic init_dead_region(input int base_word, input int rows, input int beats);
        begin
            for (int r = 0; r < rows; r++) begin
                for (int b = 0; b < beats; b++) begin
                    dmem[base_word + r * STRIDE_WORDS + b] = 32'hDEADBEEF;
                end
            end
        end
    endtask

    task automatic check_reg_words(input logic [2:0] reg_id, input int rows, input int beats, input int expected_base);
        begin
            for (int r = 0; r < rows; r++) begin
                for (int b = 0; b < beats; b++) begin
                    host_expect(reg_id, r[2:0], b[2:0], iss_expected_reg[expected_base + r * beats + b]);
                end
            end
        end
    endtask

    task automatic check_mem_words(input int base_word, input int rows, input int beats, input int expected_base);
        begin
            for (int r = 0; r < rows; r++) begin
                for (int b = 0; b < beats; b++) begin
                    mem_expect(base_word + r * STRIDE_WORDS + b, iss_expected_mem[expected_base + r * beats + b]);
                end
            end
        end
    endtask

    task automatic print_ls_reg_compare(
        input string label,
        input logic [2:0] reg_id,
        input int rows,
        input int beats,
        input int expected_base
    );
        logic [31:0] hw;
        logic [31:0] exp;
        begin
            $display("  %s", label);
            $display("    row beat | HW after write | ISS expected | status");
            for (int r = 0; r < rows; r++) begin
                for (int b = 0; b < beats; b++) begin
                    host_read_word(reg_id, r[2:0], b[2:0], hw);
                    exp = iss_expected_reg[expected_base + r * beats + b];
                    if (hw === exp) begin
                        $display("    %0d   %0d   | 0x%08x     | 0x%08x   | OK", r, b, hw, exp);
                    end else begin
                        $display("    %0d   %0d   | 0x%08x     | 0x%08x   | DIFF", r, b, hw, exp);
                    end
                end
            end
        end
    endtask

    task automatic print_ls_mem_compare(
        input string label,
        input int base_word,
        input int rows,
        input int beats,
        input int expected_base
    );
        logic [31:0] hw;
        logic [31:0] exp;
        begin
            $display("  %s", label);
            $display("    row beat | HW memory after write | ISS expected | status");
            for (int r = 0; r < rows; r++) begin
                for (int b = 0; b < beats; b++) begin
                    hw = dmem[base_word + r * STRIDE_WORDS + b];
                    exp = iss_expected_mem[expected_base + r * beats + b];
                    if (hw === exp) begin
                        $display("    %0d   %0d   | 0x%08x            | 0x%08x   | OK", r, b, hw, exp);
                    end else begin
                        $display("    %0d   %0d   | 0x%08x            | 0x%08x   | DIFF", r, b, hw, exp);
                    end
                end
            end
        end
    endtask

    initial begin
        $dumpfile("sim/tb_matrix_load_store_v2.vcd");
        $dumpvars(0, tb_matrix_load_store_v2);
        $readmemh("sim/golden/ls_insn.mem", iss_insn);
        $readmemh("sim/golden/ls_expected_reg.mem", iss_expected_reg);
        $readmemh("sim/golden/ls_expected_mem.mem", iss_expected_mem);

        reset_dut();

        word_expect("assembler mlae8",  enc_ls(4'b0000, 1'b0, 2'b00, 3'd0), iss_insn[0]);
        word_expect("assembler msae8",  enc_ls(4'b0000, 1'b1, 2'b00, 3'd0), iss_insn[1]);
        word_expect("assembler mlbe8",  enc_ls(4'b0001, 1'b0, 2'b00, 3'd1), iss_insn[2]);
        word_expect("assembler msbe8",  enc_ls(4'b0001, 1'b1, 2'b00, 3'd1), iss_insn[3]);
        word_expect("assembler mlce32", enc_ls(4'b0010, 1'b0, 2'b10, 3'd4), iss_insn[4]);
        word_expect("assembler msce32", enc_ls(4'b0010, 1'b1, 2'b10, 3'd4), iss_insn[5]);

        issue_matrix(enc_cfg_reg(4'b0010), 32'd2, 32'd0); // M = 2
        issue_matrix(enc_cfg_reg(4'b0011), 32'd3, 32'd0); // N = 3
        issue_matrix(enc_cfg_reg(4'b0001), 32'd5, 32'd0); // K = 5 bytes

        // A tile source: 2 rows x ceil(5 bytes / 4) = 2 beats.
        dmem[A_SRC_WORD + 0 * STRIDE_WORDS + 0] = iss_expected_reg[0];
        dmem[A_SRC_WORD + 0 * STRIDE_WORDS + 1] = iss_expected_reg[1];
        dmem[A_SRC_WORD + 1 * STRIDE_WORDS + 0] = iss_expected_reg[2];
        dmem[A_SRC_WORD + 1 * STRIDE_WORDS + 1] = iss_expected_reg[3];
        init_dead_region(A_DST_WORD, 2, 2);

        if (verbose_data) begin
            $display("");
            $display("LOAD/STORE verbose data path:");
            $display("  A tile: M=2, K=5 bytes, beats/row=ceil(5/4)=2");
            print_dmem_tile("A source memory before mlae8", A_SRC_WORD, 2, 2, STRIDE_WORDS);
        end

        issue_matrix(iss_insn[0], 32'h040, 32'h20); // mlae8 tr0
        check_reg_words(3'd0, 2, 2, 0);
        if (verbose_data) print_ls_reg_compare("AFTER mlae8: tr0 loaded from A memory", 3'd0, 2, 2, 0);
        if (verbose_data) print_reg_matrix4("BEFORE msae8: tr0 source for store", 3'd0);
        issue_matrix(iss_insn[1], 32'h0C0, 32'h20); // msae8 tr0
        check_mem_words(A_DST_WORD, 2, 2, 0);
        if (verbose_data) print_ls_mem_compare("AFTER msae8: A destination memory", A_DST_WORD, 2, 2, 0);

        // B tile source is stored transposed: N=3 rows, K=5 bytes per row.
        for (int r = 0; r < 3; r++) begin
            for (int b = 0; b < 2; b++) begin
                dmem[B_SRC_WORD + r * STRIDE_WORDS + b] = iss_expected_reg[4 + r * 2 + b];
            end
        end
        init_dead_region(B_DST_WORD, 3, 2);

        if (verbose_data) begin
            $display("  B tile: N=3 transposed rows, K=5 bytes, beats/row=2");
            print_dmem_tile("B source memory before mlbe8", B_SRC_WORD, 3, 2, STRIDE_WORDS);
        end

        issue_matrix(iss_insn[2], 32'h140, 32'h20); // mlbe8 tr1
        check_reg_words(3'd1, 3, 2, 4);
        if (verbose_data) print_ls_reg_compare("AFTER mlbe8: tr1 loaded from B memory", 3'd1, 3, 2, 4);
        if (verbose_data) print_reg_matrix4("BEFORE msbe8: tr1 source for store", 3'd1);
        issue_matrix(iss_insn[3], 32'h200, 32'h20); // msbe8 tr1
        check_mem_words(B_DST_WORD, 3, 2, 4);
        if (verbose_data) print_ls_mem_compare("AFTER msbe8: B destination memory", B_DST_WORD, 3, 2, 4);

        // C tile source: M=2 rows, N=3 32-bit words per row.
        for (int r = 0; r < 2; r++) begin
            for (int b = 0; b < 3; b++) begin
                dmem[C_SRC_WORD + r * STRIDE_WORDS + b] = iss_expected_reg[10 + r * 3 + b];
            end
        end
        init_dead_region(C_DST_WORD, 2, 3);

        if (verbose_data) begin
            $display("  C tile: M=2, N=3 32-bit accumulator words");
            print_dmem_tile("C source memory before mlce32", C_SRC_WORD, 2, 3, STRIDE_WORDS);
        end

        issue_matrix(iss_insn[4], 32'h280, 32'h20); // mlce32 acc0
        check_reg_words(3'd4, 2, 3, 10);
        if (verbose_data) print_ls_reg_compare("AFTER mlce32: acc0 loaded from C memory", 3'd4, 2, 3, 10);
        if (verbose_data) print_reg_matrix4("BEFORE msce32: acc0 source for store", 3'd4);
        issue_matrix(iss_insn[5], 32'h340, 32'h20); // msce32 acc0
        check_mem_words(C_DST_WORD, 2, 3, 10);
        if (verbose_data) print_ls_mem_compare("AFTER msce32: C destination memory", C_DST_WORD, 2, 3, 10);

        $display("");
        $display("LOAD/STORE all supported instructions checked: A/B int8 and C int32");
        host_read_word(3'd1, 3'd2, 3'd1, rtl_word);
        print_compare_word("tr1 B row2 beat1", rtl_word, iss_expected_reg[9]);
        print_compare_word("C dmem row1 beat2", dmem[C_DST_WORD + 1 * STRIDE_WORDS + 2], iss_expected_mem[15]);

        if (errors == 0) $display("MATRIX_LOAD_STORE_V2_TEST_PASS");
        else $display("MATRIX_LOAD_STORE_V2_TEST_FAIL errors=%0d", errors);
        $finish;
    end
endmodule
