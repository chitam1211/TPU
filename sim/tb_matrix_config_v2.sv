`timescale 1ns/1ps

module tb_matrix_config_v2;
    `include "matrix_core_v2_tb_common.svh"

    logic [31:0] iss_insn [0:6];
    logic wb_we;
    logic [4:0] wb_rd;
    logic [31:0] wb_data;

    initial begin
        $dumpfile("sim/tb_matrix_config_v2.vcd");
        $dumpvars(0, tb_matrix_config_v2);
        $readmemh("sim/golden/config_insn.mem", iss_insn);

        reset_dut();

        word_expect("assembler mrelease",   enc_cfg_none(4'b0000), iss_insn[0]);
        word_expect("assembler msettilemi", enc_cfg_imm(4'b0010, 10'd2), iss_insn[1]);
        word_expect("assembler msettileni", enc_cfg_imm(4'b0011, 10'd3), iss_insn[2]);
        word_expect("assembler msettileki", enc_cfg_imm(4'b0001, 10'd5), iss_insn[3]);
        word_expect("assembler msettilem",  enc_cfg_reg(4'b0010), iss_insn[4]);
        word_expect("assembler msettilen",  enc_cfg_reg(4'b0011), iss_insn[5]);
        word_expect("assembler msettilek",  enc_cfg_reg(4'b0001), iss_insn[6]);

        if (verbose_data) begin
            $display("");
            $display("CONFIG verbose data path:");
            $display("  initial CSR: M=%0d N=%0d K=%0d", debug_mtilem, debug_mtilen, debug_mtilek);
            $display("  immediate instructions set CSR directly from imm10");
            $display("  register instructions set CSR from matrix_rs1 with clamp to supported range");
        end

        issue_matrix(iss_insn[1], 32'd0, 32'd0); // msettilemi 2
        if (verbose_data) $display("  msettilemi 2      -> M=%0d N=%0d K=%0d", debug_mtilem, debug_mtilen, debug_mtilek);
        if (debug_mtilem !== 32'd2) begin
            $display("ERROR msettilemi mtilem got %0d expected 2", debug_mtilem);
            errors++;
        end

        issue_matrix(iss_insn[2], 32'd0, 32'd0); // msettileni 3
        if (verbose_data) $display("  msettileni 3      -> M=%0d N=%0d K=%0d", debug_mtilem, debug_mtilen, debug_mtilek);
        if (debug_mtilen !== 32'd3) begin
            $display("ERROR msettileni mtilen got %0d expected 3", debug_mtilen);
            errors++;
        end

        issue_matrix(iss_insn[3], 32'd0, 32'd0); // msettileki 5
        if (verbose_data) $display("  msettileki 5      -> M=%0d N=%0d K=%0d", debug_mtilem, debug_mtilen, debug_mtilek);
        if (debug_mtilek !== 32'd5) begin
            $display("ERROR msettileki mtilek got %0d expected 5", debug_mtilek);
            errors++;
        end

        issue_matrix(iss_insn[4], 32'd7, 32'd0); // msettilem, clamps to 4
        if (verbose_data) $display("  msettilem rs1=7   -> M=%0d N=%0d K=%0d (M clamps to 4)", debug_mtilem, debug_mtilen, debug_mtilek);
        if (debug_mtilem !== 32'd4) begin
            $display("ERROR msettilem mtilem got %0d expected 4", debug_mtilem);
            errors++;
        end

        issue_matrix(iss_insn[5], 32'd1, 32'd0); // msettilen
        if (verbose_data) $display("  msettilen rs1=1   -> M=%0d N=%0d K=%0d", debug_mtilem, debug_mtilen, debug_mtilek);
        if (debug_mtilen !== 32'd1) begin
            $display("ERROR msettilen mtilen got %0d expected 1", debug_mtilen);
            errors++;
        end

        issue_matrix(iss_insn[6], 32'd20, 32'd0); // msettilek, clamps to 16
        if (verbose_data) $display("  msettilek rs1=20  -> M=%0d N=%0d K=%0d (K clamps to 16)", debug_mtilem, debug_mtilen, debug_mtilek);
        if (debug_mtilek !== 32'd16) begin
            $display("ERROR msettilek mtilek got %0d expected 16", debug_mtilek);
            errors++;
        end

        issue_matrix_capture_wb(iss_insn[0], 32'd0, 32'd0, wb_we, wb_rd, wb_data); // mrelease
        if (wb_we !== 1'b0) begin
            $display("ERROR mrelease unexpectedly wrote GPR rd=%0d data=0x%08x", wb_rd, wb_data);
            errors++;
        end
        if (debug_mtilem !== 32'd4 || debug_mtilen !== 32'd1 || debug_mtilek !== 32'd16) begin
            $display("ERROR mrelease changed tile CSR M=%0d N=%0d K=%0d",
                     debug_mtilem, debug_mtilen, debug_mtilek);
            errors++;
        end

        $display("");
        $display("CONFIG all supported instructions checked: mrelease, msettile{i/reg} M/N/K");
        $display("  final CSR RTL: M=%0d N=%0d K=%0d", debug_mtilem, debug_mtilen, debug_mtilek);

        if (errors == 0) $display("MATRIX_CONFIG_V2_TEST_PASS");
        else $display("MATRIX_CONFIG_V2_TEST_FAIL errors=%0d", errors);
        $finish;
    end
endmodule
