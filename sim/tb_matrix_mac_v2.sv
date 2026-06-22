`timescale 1ns/1ps

module tb_matrix_mac_v2;
    `include "matrix_core_v2_tb_common.svh"

    logic [31:0] iss_insn [0:3];
    logic [31:0] a_rows [0:3];
    logic [31:0] b_cols [0:3];
    logic [31:0] c_init [0:15];
    logic [31:0] iss_expected [0:63];
    logic [31:0] rtl0, rtl1, rtl2, rtl3;

    task automatic check_acc(input logic [2:0] acc_id, input int expected_base);
        begin
            for (int r = 0; r < 4; r++) begin
                for (int b = 0; b < 4; b++) begin
                    host_expect(acc_id, r[2:0], b[2:0], iss_expected[expected_base + r * 4 + b]);
                end
            end
        end
    endtask

    task automatic print_mac_compare(input string label, input logic [2:0] acc_id, input int expected_base);
        logic [31:0] hw;
        logic [31:0] exp;
        begin
            $display("  %s", label);
            $display("    row col | HW after write | ISS expected | signed HW | signed ISS | status");
            for (int r = 0; r < 4; r++) begin
                for (int c = 0; c < 4; c++) begin
                    host_read_word(acc_id, r[2:0], c[2:0], hw);
                    exp = iss_expected[expected_base + r * 4 + c];
                    if (hw === exp) begin
                        $display("    %0d   %0d   | 0x%08x     | 0x%08x   | %0d       | %0d        | OK",
                                 r, c, hw, exp, $signed(hw), $signed(exp));
                    end else begin
                        $display("    %0d   %0d   | 0x%08x     | 0x%08x   | %0d       | %0d        | DIFF",
                                 r, c, hw, exp, $signed(hw), $signed(exp));
                    end
                end
            end
        end
    endtask

    initial begin
        $dumpfile("sim/tb_matrix_mac_v2.vcd");
        $dumpvars(0, tb_matrix_mac_v2);
        $readmemh("sim/golden/mac_insn.mem", iss_insn);
        $readmemh("sim/golden/mac_a_rows.mem", a_rows);
        $readmemh("sim/golden/mac_b_cols.mem", b_cols);
        $readmemh("sim/golden/mac_c_init.mem", c_init);
        $readmemh("sim/golden/mac_expected.mem", iss_expected);

        reset_dut();

        word_expect("assembler mmaccu.w.b",  enc_matmul(3'b000, 3'd0, 3'd1, 3'd4), iss_insn[0]);
        word_expect("assembler mmaccus.w.b", enc_matmul(3'b001, 3'd0, 3'd1, 3'd5), iss_insn[1]);
        word_expect("assembler mmaccsu.w.b", enc_matmul(3'b010, 3'd0, 3'd1, 3'd6), iss_insn[2]);
        word_expect("assembler mmacc.w.b",   enc_matmul(3'b011, 3'd0, 3'd1, 3'd7), iss_insn[3]);

        issue_matrix(enc_cfg_reg(4'b0010), 32'd4, 32'd0); // M = 4
        issue_matrix(enc_cfg_reg(4'b0011), 32'd4, 32'd0); // N = 4
        issue_matrix(enc_cfg_reg(4'b0001), 32'd4, 32'd0); // K = 4

        for (int r = 0; r < 4; r++) begin
            host_write(3'd0, r[2:0], 3'd0, a_rows[r]); // tr0 = A row-major
            host_write(3'd1, r[2:0], 3'd0, b_cols[r]); // tr1 = B transposed columns
        end

        if (verbose_data) begin
            $display("");
            $display("MAC verbose data path:");
            $display("  A rows in tr0, each word packs 4 INT8 values");
            for (int r = 0; r < 4; r++) begin
                $display("    [%0d] %0d %0d %0d %0d  (packed=0x%08x)",
                         r, a_rows[r][7:0], a_rows[r][15:8], a_rows[r][23:16], a_rows[r][31:24], a_rows[r]);
            end
            $display("  B columns in tr1, each word packs one transposed column");
            for (int c = 0; c < 4; c++) begin
                $display("    [%0d] %0d %0d %0d %0d  (packed=0x%08x)",
                         c, b_cols[c][7:0], b_cols[c][15:8], b_cols[c][23:16], b_cols[c][31:24], b_cols[c]);
            end
            $display("  initial C accumulators");
            for (int r = 0; r < 4; r++) begin
                $display("    [%0d] %0d %0d %0d %0d",
                         r,
                         $signed(c_init[r * 4 + 0]),
                         $signed(c_init[r * 4 + 1]),
                         $signed(c_init[r * 4 + 2]),
                         $signed(c_init[r * 4 + 3]));
            end
            $display("  For each MAC op: C[row][col] = C_init[row][col] + sum_k(A[row][k] * B[k][col])");
        end

        for (int acc = 0; acc < 4; acc++) begin
            for (int r = 0; r < 4; r++) begin
                for (int c = 0; c < 4; c++) begin
                    host_write(3'(4 + acc), r[2:0], c[2:0], c_init[r * 4 + c]);
                end
            end
        end

        for (int op = 0; op < 4; op++) begin
            issue_matrix(iss_insn[op], 32'd0, 32'd0);
            check_acc(3'(4 + op), op * 16);
            if (verbose_data) begin
                $display("  BEFORE MAC op%0d: A=tr0, B=tr1, C_init=acc%0d", op, 4 + op);
                print_mac_compare($sformatf("AFTER MAC op%0d: acc%0d result vs ISS", op, 4 + op), 3'(4 + op), op * 16);
            end
        end

        $display("");
        $display("MAC all supported signedness variants checked: uu, us, su, ss");
        for (int op = 0; op < 4; op++) begin
            host_read_word(3'(4 + op), 3'd0, 3'd0, rtl0);
            host_read_word(3'(4 + op), 3'd0, 3'd1, rtl1);
            host_read_word(3'(4 + op), 3'd0, 3'd2, rtl2);
            host_read_word(3'(4 + op), 3'd0, 3'd3, rtl3);
            $display("  op%0d row0 RTL: %0d %0d %0d %0d | ISS: %0d %0d %0d %0d",
                     op, $signed(rtl0), $signed(rtl1), $signed(rtl2), $signed(rtl3),
                     $signed(iss_expected[op * 16 + 0]), $signed(iss_expected[op * 16 + 1]),
                     $signed(iss_expected[op * 16 + 2]), $signed(iss_expected[op * 16 + 3]));
        end

        if (errors == 0) $display("MATRIX_MAC_V2_TEST_PASS");
        else $display("MATRIX_MAC_V2_TEST_FAIL errors=%0d", errors);
        $finish;
    end
endmodule
