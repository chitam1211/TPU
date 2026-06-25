`timescale 1ns/1ps

module tb_matrix_ew_v2;
    `include "matrix_core_v2_tb_common.svh"

    logic [31:0] iss_insn [0:19];
    logic [31:0] src_a [0:15];
    logic [31:0] src_b [0:15];
    logic [31:0] iss_expected [0:319];
    logic [31:0] rtl_word;

    function automatic logic [3:0] ew_func4(input int idx);
        case (idx)
            0: ew_func4 = 4'b0000; // madd
            1: ew_func4 = 4'b0001; // msub
            2: ew_func4 = 4'b0010; // mmul
            3: ew_func4 = 4'b0100; // mmax
            4: ew_func4 = 4'b0101; // mumax
            5: ew_func4 = 4'b0110; // mmin
            6: ew_func4 = 4'b0111; // mumin
            7: ew_func4 = 4'b1000; // msrl
            8: ew_func4 = 4'b1001; // msll
            default: ew_func4 = 4'b1010; // msra
        endcase
    endfunction

    function automatic string ew_name(input int idx);
        case (idx)
            0: ew_name = "madd";
            1: ew_name = "msub";
            2: ew_name = "mmul";
            3: ew_name = "mmax";
            4: ew_name = "mumax";
            5: ew_name = "mmin";
            6: ew_name = "mumin";
            7: ew_name = "msrl";
            8: ew_name = "msll";
            default: ew_name = "msra";
        endcase
    endfunction

    task automatic preload_sources;
        begin
            for (int r = 0; r < 4; r++) begin
                for (int b = 0; b < 4; b++) begin
                    host_write(3'd4, r[2:0], b[2:0], src_a[r * 4 + b]); // acc0 = A/source vector
                    host_write(3'd5, r[2:0], b[2:0], src_b[r * 4 + b]); // acc1 = B/matrix
                end
            end
        end
    endtask

    task automatic check_dest_matrix(input int expected_base);
        begin
            for (int r = 0; r < 4; r++) begin
                for (int b = 0; b < 4; b++) begin
                    host_expect(3'd6, r[2:0], b[2:0], iss_expected[expected_base + r * 4 + b]);
                end
            end
        end
    endtask

    task automatic print_ew_compare(input string label, input int expected_base);
        logic [31:0] hw;
        logic [31:0] exp;
        begin
            $display("  %s", label);
            $display("    row beat | HW after write | ISS expected | status");
            for (int r = 0; r < 4; r++) begin
                for (int b = 0; b < 4; b++) begin
                    host_read_word(3'd6, r[2:0], b[2:0], hw);
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
        $dumpfile("sim/tb_matrix_ew_v2.vcd");
        $dumpvars(0, tb_matrix_ew_v2);
        $readmemh("sim/golden/ew_insn.mem", iss_insn);
        $readmemh("sim/golden/ew_src_a.mem", src_a);
        $readmemh("sim/golden/ew_src_b.mem", src_b);
        $readmemh("sim/golden/ew_expected.mem", iss_expected);

        reset_dut();

        for (int i = 0; i < 10; i++) begin
            word_expect("assembler ew .mm", enc_ew(ew_func4(i), 3'b111, 3'd4, 3'd5, 3'd6), iss_insn[i]);
            word_expect("assembler ew .mv", enc_ew(ew_func4(i), 3'd2, 3'd4, 3'd5, 3'd6), iss_insn[10 + i]);
        end

        issue_matrix(enc_cfg_reg(4'b0010), 32'd4, 32'd0); // M = 4
        issue_matrix(enc_cfg_reg(4'b0011), 32'd4, 32'd0); // N = 4
        preload_sources();

        if (verbose_data) begin
            $display("");
            $display("EW verbose data path:");
            $display("  source A/vector in acc0");
            for (int r = 0; r < 4; r++) begin
                $display("    [%0d] %08x %08x %08x %08x",
                         r, src_a[r * 4 + 0], src_a[r * 4 + 1], src_a[r * 4 + 2], src_a[r * 4 + 3]);
            end
            $display("  source B/matrix in acc1");
            for (int r = 0; r < 4; r++) begin
                $display("    [%0d] %08x %08x %08x %08x",
                         r, src_b[r * 4 + 0], src_b[r * 4 + 1], src_b[r * 4 + 2], src_b[r * 4 + 3]);
            end
            $display("  .mm uses A[row][beat] with B[row][beat]");
            $display("  .mv snapshots A[vector_row=2][beat] and reuses it for all rows of B");
        end

        for (int i = 0; i < 10; i++) begin
            issue_matrix(iss_insn[i], 32'd0, 32'd0);
            check_dest_matrix(i * 16);
            if (verbose_data) begin
                $display("  BEFORE %s.mm: source A/B are read row-by-row from acc0/acc1", ew_name(i));
                print_ew_compare($sformatf("%s.mm AFTER: acc2 result vs ISS", ew_name(i)), i * 16);
            end
        end

        for (int i = 0; i < 10; i++) begin
            issue_matrix(iss_insn[10 + i], 32'd0, 32'd0);
            check_dest_matrix((10 + i) * 16);
            if (verbose_data) begin
                $display("  BEFORE %s.mv: vector source is acc0[row=2], reused for all rows of acc1", ew_name(i));
                print_ew_compare($sformatf("%s.mv AFTER: acc2 result vs ISS", ew_name(i)), (10 + i) * 16);
            end
        end

        $display("");
        $display("EW all supported instructions checked: 10 .mm + 10 .mv");
        host_read_word(3'd6, 3'd0, 3'd0, rtl_word);
        print_compare_word("last msra.mv[0][0]", rtl_word, iss_expected[19 * 16 + 0]);
        host_read_word(3'd6, 3'd3, 3'd3, rtl_word);
        print_compare_word("last msra.mv[3][3]", rtl_word, iss_expected[19 * 16 + 15]);

        if (errors == 0) $display("MATRIX_EW_V2_TEST_PASS");
        else $display("MATRIX_EW_V2_TEST_FAIL errors=%0d", errors);
        $finish;
    end
endmodule
