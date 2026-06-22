`timescale 1ns/1ps

module tb_matrix_misc_v2;
    `include "matrix_core_v2_tb_common.svh"

    logic [31:0] iss_insn [0:8];
    logic [31:0] src_words [0:15];
    logic [31:0] iss_expected [0:128];
    logic [31:0] rtl_word;
    logic wb_we;
    logic [4:0] wb_rd;
    logic [31:0] wb_data;

    task automatic preload_reg(input logic [2:0] reg_id);
        begin
            for (int r = 0; r < 4; r++) begin
                for (int b = 0; b < 4; b++) begin
                    host_write(reg_id, r[2:0], b[2:0], src_words[r * 4 + b]);
                end
            end
        end
    endtask

    task automatic check_reg(input logic [2:0] reg_id, input int expected_base);
        begin
            for (int r = 0; r < 4; r++) begin
                for (int b = 0; b < 4; b++) begin
                    host_expect(reg_id, r[2:0], b[2:0], iss_expected[expected_base + r * 4 + b]);
                end
            end
        end
    endtask

    task automatic print_misc_compare(input string label, input logic [2:0] reg_id, input int expected_base);
        logic [31:0] hw;
        logic [31:0] exp;
        begin
            $display("  %s", label);
            $display("    row beat | HW after write | ISS expected | status");
            for (int r = 0; r < 4; r++) begin
                for (int b = 0; b < 4; b++) begin
                    host_read_word(reg_id, r[2:0], b[2:0], hw);
                    exp = iss_expected[expected_base + r * 4 + b];
                    if (hw === exp) begin
                        $display("    %0d   %0d   | 0x%08x     | 0x%08x   | OK", r, b, hw, exp);
                    end else begin
                        $display("    %0d   %0d   | 0x%08x     | 0x%08x   | DIFF", r, b, hw, exp);
                    end
                end
            end
        end
    endtask

    initial begin
        $dumpfile("sim/tb_matrix_misc_v2.vcd");
        $dumpvars(0, tb_matrix_misc_v2);
        $readmemh("sim/golden/misc_insn.mem", iss_insn);
        $readmemh("sim/golden/misc_source.mem", src_words);
        $readmemh("sim/golden/misc_expected.mem", iss_expected);

        reset_dut();

        word_expect("assembler mdupw.m.x",      enc_misc(4'b0011, 3'b000, 3'd0, 3'd0, 2'b00, 2'b10, 3'd2), iss_insn[0]);
        word_expect("assembler mmov.mm",        enc_misc(4'b0001, 3'b000, 3'd2, 3'd0, 2'b00, 2'b00, 3'd3), iss_insn[1]);
        word_expect("assembler mmovw.m.x",      enc_misc(4'b0011, 3'b100, 3'd6, 3'd5, 2'b00, 2'b10, 3'd0), iss_insn[2]);
        word_expect("assembler mmovw.x.m",      enc_misc_rd(4'b0010, 3'b010, 3'd5, 3'd0, 2'b00, 5'd10), iss_insn[3]);
        word_expect("assembler mzero",          enc_misc(4'b0000, 3'b000, 3'd0, 3'd0, 2'b00, 2'b00, 3'd4), iss_insn[4]);
        word_expect("assembler mrslidedown",    enc_misc(4'b0101, 3'd1, 3'd0, 3'd0, 2'b00, 2'b00, 3'd1), iss_insn[5]);
        word_expect("assembler mcslidedown.w",  enc_misc(4'b0111, 3'd2, 3'd4, 3'd0, 2'b10, 2'b10, 3'd5), iss_insn[6]);
        word_expect("assembler mrslideup",      enc_misc(4'b0110, 3'd1, 3'd0, 3'd0, 2'b00, 2'b00, 3'd2), iss_insn[7]);
        word_expect("assembler mcslideup.w",    enc_misc(4'b1000, 3'd2, 3'd4, 3'd0, 2'b10, 2'b10, 3'd6), iss_insn[8]);

        if (verbose_data) begin
            $display("");
            $display("MISC verbose data path:");
            $display("  source matrix used for slide tests");
            for (int r = 0; r < 4; r++) begin
                $display("    [%0d] %08x %08x %08x %08x",
                         r,
                         src_words[r * 4 + 0],
                         src_words[r * 4 + 1],
                         src_words[r * 4 + 2],
                         src_words[r * 4 + 3]);
            end
            $display("  slide semantics follow spec: out-of-bound rows/beats are zero-filled, not wrapped");
        end

        if (verbose_data) $display("  BEFORE mdupw.m.x: scalar rs2 = 0x11223344, every beat in tr2 should receive this word");
        issue_matrix(iss_insn[0], 32'd0, 32'h11223344); // mdupw.m.x tr2, x0
        check_reg(3'd2, 0);
        if (verbose_data) print_misc_compare("AFTER mdupw.m.x: tr2 beat-by-beat", 3'd2, 0);

        if (verbose_data) print_reg_matrix4("BEFORE mmov.mm: source tr2", 3'd2);
        issue_matrix(iss_insn[1], 32'd0, 32'd0); // mmov.mm tr3, tr2
        check_reg(3'd3, 16);
        if (verbose_data) print_misc_compare("AFTER mmov.mm: destination tr3", 3'd3, 16);

        if (verbose_data) print_reg_matrix4("BEFORE mmovw.m.x: destination tr0 before indexed write", 3'd0);
        issue_matrix(iss_insn[2], 32'd6, 32'hA5A55A5A); // mmovw.m.x tr0[index=6] <- rs2
        check_reg(3'd0, 32);
        if (verbose_data) print_misc_compare("AFTER mmovw.m.x: tr0 with index 6 updated", 3'd0, 32);

        issue_matrix_capture_wb(iss_insn[3], 32'd6, 32'd0, wb_we, wb_rd, wb_data); // mmovw.x.m x10 <- tr0[index=6]
        if (wb_we !== 1'b1 || wb_rd !== 5'd10 || wb_data !== iss_expected[48]) begin
            $display("ERROR mmovw.x.m wb_we=%0b rd=%0d data=0x%08x expected rd=10 data=0x%08x",
                     wb_we, wb_rd, wb_data, iss_expected[48]);
            errors++;
        end
        if (verbose_data) begin
            $display("  mmovw.x.m compare");
            $display("    source tr0 index=6 | HW x10 after read | ISS expected | status");
            if (wb_data === iss_expected[48]) begin
                $display("    0x%08x           | 0x%08x          | 0x%08x   | OK", iss_expected[48], wb_data, iss_expected[48]);
            end else begin
                $display("    0x%08x           | 0x%08x          | 0x%08x   | DIFF", iss_expected[48], wb_data, iss_expected[48]);
            end
        end

        host_write(3'd4, 3'd1, 3'd2, 32'hCAFE_BABE);
        if (verbose_data) print_reg_matrix4("BEFORE mzero: acc0 contains one non-zero beat", 3'd4);
        issue_matrix(iss_insn[4], 32'd0, 32'd0); // mzero acc0
        check_reg(3'd4, 49);
        if (verbose_data) print_misc_compare("AFTER mzero: acc0 cleared", 3'd4, 49);

        preload_reg(3'd0);
        if (verbose_data) print_reg_matrix4("BEFORE mrslidedown: source tr0", 3'd0);
        issue_matrix(iss_insn[5], 32'd0, 32'd0); // mrslidedown tr1, tr0, 1
        check_reg(3'd1, 65);
        if (verbose_data) print_misc_compare("AFTER mrslidedown: destination tr1", 3'd1, 65);

        preload_reg(3'd4);
        if (verbose_data) print_reg_matrix4("BEFORE mcslidedown.w: source acc0", 3'd4);
        issue_matrix(iss_insn[6], 32'd0, 32'd0); // mcslidedown.w acc1, acc0, 2
        check_reg(3'd5, 81);
        if (verbose_data) print_misc_compare("AFTER mcslidedown.w: destination acc1", 3'd5, 81);

        preload_reg(3'd0);
        if (verbose_data) print_reg_matrix4("BEFORE mrslideup: source tr0", 3'd0);
        issue_matrix(iss_insn[7], 32'd0, 32'd0); // mrslideup tr2, tr0, 1
        check_reg(3'd2, 97);
        if (verbose_data) print_misc_compare("AFTER mrslideup: destination tr2", 3'd2, 97);

        preload_reg(3'd4);
        if (verbose_data) print_reg_matrix4("BEFORE mcslideup.w: source acc0", 3'd4);
        issue_matrix(iss_insn[8], 32'd0, 32'd0); // mcslideup.w acc2, acc0, 2
        check_reg(3'd6, 113);
        if (verbose_data) print_misc_compare("AFTER mcslideup.w: destination acc2", 3'd6, 113);

        expect_unsupported_matrix(
            "mrslidedown cross-bank tr<-acc",
            enc_misc(4'b0101, 3'd1, 3'd4, 3'd0, 2'b00, 2'b00, 3'd1)
        );
        expect_unsupported_matrix(
            "mcslidedown.w cross-bank acc<-tr",
            enc_misc(4'b0111, 3'd2, 3'd0, 3'd0, 2'b10, 2'b10, 3'd5)
        );
        expect_unsupported_matrix(
            "mrslideup cross-bank tr<-acc",
            enc_misc(4'b0110, 3'd1, 3'd4, 3'd0, 2'b00, 2'b00, 3'd2)
        );
        expect_unsupported_matrix(
            "mcslideup.w cross-bank acc<-tr",
            enc_misc(4'b1000, 3'd2, 3'd0, 3'd0, 2'b10, 2'b10, 3'd6)
        );

        $display("");
        $display("MISC all supported instructions checked: mzero, mmov, mmovw x/m, mdup, row/col slide up/down");
        $display("  cross-bank slide reject checked: tr<-acc and acc<-tr are unsupported");
        host_read_word(3'd5, 3'd0, 3'd0, rtl_word);
        print_compare_word("acc1 slide[0][0]", rtl_word, iss_expected[81]);
        host_read_word(3'd6, 3'd0, 3'd0, rtl_word);
        print_compare_word("acc2 slideup[0][0]", rtl_word, iss_expected[113]);
        print_compare_word("mmovw.x.m x10", wb_data, iss_expected[48]);

        if (errors == 0) $display("MATRIX_MISC_V2_TEST_PASS");
        else $display("MATRIX_MISC_V2_TEST_FAIL errors=%0d", errors);
        $finish;
    end
endmodule
