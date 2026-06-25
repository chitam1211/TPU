`timescale 1ns/1ps

module tb_rv32i_matrix_system;
    localparam int ROM_WORDS = 256;

    localparam logic [31:0] NOP            = 32'h00000013;
    localparam logic [31:0] ADDI_X1_A_BASE = 32'h04000093;
    localparam logic [31:0] ADDI_X2_STRIDE = 32'h01000113;
    localparam logic [31:0] ADDI_X3_B_BASE = 32'h08000193;
    localparam logic [31:0] ADDI_X4_C_BASE = 32'h0c000213;
    localparam logic [31:0] INSN_MSETTILEK = 32'h1002002b;
    localparam logic [31:0] INSN_MSETTILEM = 32'h2002002b;
    localparam logic [31:0] INSN_MSETTILEN = 32'h3002002b;
    localparam logic [31:0] INSN_MLAE8_A   = 32'h0420802b;
    localparam logic [31:0] INSN_MLBE8_B   = 32'h142180ab;
    localparam logic [31:0] INSN_MZERO_A0  = 32'h0c00022b;
    localparam logic [31:0] INSN_MMACCU    = 32'h18100a2b;
    localparam logic [31:0] INSN_MSCE32_C  = 32'h26220a2b;

    localparam int A_BASE_WORD = 32'h0000_0040 >> 2;
    localparam int B_BASE_WORD = 32'h0000_0080 >> 2;
    localparam int C_BASE_WORD = 32'h0000_00c0 >> 2;

    logic clk;
    logic rst;
    logic [31:0] instruction;
    logic data_mem_valid;
    logic instruc_mem_valid;
    logic [31:0] load_data_in;
    logic load_signal;
    logic instruction_mem_we_re;
    logic instruction_mem_request;
    logic data_mem_we_re;
    logic data_mem_request;
    logic [3:0] mask_signal;
    logic [3:0] instruc_mask_signal;
    logic [31:0] store_data_out;
    logic [31:0] alu_out_address;
    logic [31:0] pc_address;

    logic        host_reg_we;
    logic [2:0]  host_reg_id;
    logic [2:0]  host_reg_row_idx;
    logic [2:0]  host_reg_beat_idx;
    logic [31:0] host_reg_wdata;
    logic [2:0]  host_read_id;
    logic [2:0]  host_read_row;
    logic [2:0]  host_read_beat;
    logic [31:0] host_reg_rdata;
    logic [31:0] debug_mtilem;
    logic [31:0] debug_mtilen;
    logic [31:0] debug_mtilek;
    logic        matrix_busy;
    logic        matrix_done;

    logic [31:0] rom [0:ROM_WORDS-1];
    logic [31:0] dmem [0:255];
    int errors;

    core_matrix uut (
        .clk(clk),
        .rst(rst),
        .data_mem_valid(data_mem_valid),
        .instruc_mem_valid(instruc_mem_valid),
        .instruction(instruction),
        .load_data_in(load_data_in),
        .load_signal(load_signal),
        .instruction_mem_we_re(instruction_mem_we_re),
        .instruction_mem_request(instruction_mem_request),
        .data_mem_we_re(data_mem_we_re),
        .data_mem_request(data_mem_request),
        .mask_singal(mask_signal),
        .instruc_mask_singal(instruc_mask_signal),
        .store_data_out(store_data_out),
        .alu_out_address(alu_out_address),
        .pc_address(pc_address),
        .matrix_host_reg_we(host_reg_we),
        .matrix_host_reg_id(host_reg_id),
        .matrix_host_reg_row_idx(host_reg_row_idx),
        .matrix_host_reg_beat_idx(host_reg_beat_idx),
        .matrix_host_reg_wdata(host_reg_wdata),
        .matrix_host_read_id(host_read_id),
        .matrix_host_read_row(host_read_row),
        .matrix_host_read_beat(host_read_beat),
        .matrix_host_reg_rdata(host_reg_rdata),
        .matrix_debug_mtilem(debug_mtilem),
        .matrix_debug_mtilen(debug_mtilen),
        .matrix_debug_mtilek(debug_mtilek),
        .matrix_busy(matrix_busy),
        .matrix_done(matrix_done)
    );

    always #5 clk = ~clk;
    always_comb instruction = rom[pc_address[9:2]];

    always_ff @(posedge clk) begin
        if (!rst) begin
            data_mem_valid <= 1'b0;
            load_data_in <= 32'b0;
        end else begin
            data_mem_valid <= load_signal;
            if (data_mem_request && data_mem_we_re) begin
                if (mask_signal[0]) dmem[alu_out_address[9:2]][7:0]   <= store_data_out[7:0];
                if (mask_signal[1]) dmem[alu_out_address[9:2]][15:8]  <= store_data_out[15:8];
                if (mask_signal[2]) dmem[alu_out_address[9:2]][23:16] <= store_data_out[23:16];
                if (mask_signal[3]) dmem[alu_out_address[9:2]][31:24] <= store_data_out[31:24];
            end
            if (data_mem_request && !data_mem_we_re) begin
                load_data_in <= dmem[alu_out_address[9:2]];
            end
        end
    end

    task automatic mem_expect(input int word_addr, input logic [31:0] expected);
        begin
            if (dmem[word_addr] !== expected) begin
                $display("ERROR dmem[%0d]: got %0d expected %0d", word_addr, dmem[word_addr], expected);
                errors++;
            end
        end
    endtask

    initial begin
        for (int i = 0; i < ROM_WORDS; i++) rom[i] = NOP;
        rom[32] = ADDI_X1_A_BASE;
        rom[33] = ADDI_X2_STRIDE;
        rom[34] = ADDI_X3_B_BASE;
        rom[35] = ADDI_X4_C_BASE;
        rom[36] = INSN_MSETTILEM;
        rom[37] = INSN_MSETTILEN;
        rom[38] = INSN_MSETTILEK;
        rom[39] = INSN_MLAE8_A;
        rom[40] = INSN_MLBE8_B;
        rom[41] = INSN_MZERO_A0;
        rom[42] = INSN_MMACCU;
        rom[43] = INSN_MSCE32_C;
    end

    initial begin
        $dumpfile("sim/tb_rv32i_matrix_system.vcd");
        $dumpvars(0, tb_rv32i_matrix_system);

        clk = 1'b0;
        rst = 1'b0;
        instruc_mem_valid = 1'b1;
        host_reg_we = 1'b0;
        host_reg_id = 3'b0;
        host_reg_row_idx = 3'b0;
        host_reg_beat_idx = 3'b0;
        host_reg_wdata = 32'b0;
        host_read_id = 3'b0;
        host_read_row = 3'b0;
        host_read_beat = 3'b0;
        errors = 0;
        for (int i = 0; i < 256; i++) dmem[i] = 32'b0;

        dmem[A_BASE_WORD + 0] = 32'h04030201;
        dmem[A_BASE_WORD + 4] = 32'h08070605;
        dmem[A_BASE_WORD + 8] = 32'h0c0b0a09;
        dmem[A_BASE_WORD + 12] = 32'h100f0e0d;

        dmem[B_BASE_WORD + 0] = 32'h0d090501;
        dmem[B_BASE_WORD + 4] = 32'h0e0a0602;
        dmem[B_BASE_WORD + 8] = 32'h0f0b0703;
        dmem[B_BASE_WORD + 12] = 32'h100c0804;

        repeat (3) @(posedge clk);
        rst = 1'b1;
        repeat (420) @(posedge clk);

        mem_expect(C_BASE_WORD + 0,  32'd90);
        mem_expect(C_BASE_WORD + 1,  32'd100);
        mem_expect(C_BASE_WORD + 2,  32'd110);
        mem_expect(C_BASE_WORD + 3,  32'd120);
        mem_expect(C_BASE_WORD + 4,  32'd202);
        mem_expect(C_BASE_WORD + 5,  32'd228);
        mem_expect(C_BASE_WORD + 6,  32'd254);
        mem_expect(C_BASE_WORD + 7,  32'd280);
        mem_expect(C_BASE_WORD + 8,  32'd314);
        mem_expect(C_BASE_WORD + 9,  32'd356);
        mem_expect(C_BASE_WORD + 10, 32'd398);
        mem_expect(C_BASE_WORD + 11, 32'd440);
        mem_expect(C_BASE_WORD + 12, 32'd426);
        mem_expect(C_BASE_WORD + 13, 32'd484);
        mem_expect(C_BASE_WORD + 14, 32'd542);
        mem_expect(C_BASE_WORD + 15, 32'd600);

        if (errors == 0) $display("RV32I_MATRIX_SYSTEM_TEST_PASS");
        else $display("RV32I_MATRIX_SYSTEM_TEST_FAIL errors=%0d", errors);
        $finish;
    end
endmodule
