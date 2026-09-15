`timescale 1ns/1ps

// Real instruction/data RAMs and real CPU pipeline. Only the optional fixture
// delays response-valid; it never forces CPU registers or pipeline signals.
module tb_fp_mem_e2e;
    reg clk = 0;
    reg rst = 0;
    always #5 clk = ~clk;
`ifdef DELAYED_MEMORY
    core_if_delayed_test_system dut (.clk(clk), .rst(rst), .instruction(32'b0));
`else
    microprocessor dut (.clk(clk), .rst(rst), .instruction(32'b0));
`endif

    reg [31:0] patterns [0:31];
    reg expected_write [0:255];
    reg [31:0] expected_addr [0:255];
    reg [31:0] expected_data [0:255];
    reg [3:0] expected_mask [0:255];
    integer program_size, expected_count, observed_count, fp_writes;
    integer i, j, cycles, jal_link, jalr_link, jump_target;
    reg active = 0;
    reg [31:0] lfsr;

    function [31:0] enc_i;
        input [6:0] op;
        input [4:0] rd, rs1;
        input [2:0] f3;
        input integer imm;
        begin enc_i = {imm[11:0], rs1, f3, rd, op}; end
    endfunction
    function [31:0] enc_s;
        input [6:0] op;
        input [4:0] rs1, rs2;
        input [2:0] f3;
        input integer imm;
        begin enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], op}; end
    endfunction
    function [31:0] enc_b;
        input [2:0] f3;
        input [4:0] rs1, rs2;
        input integer imm;
        begin enc_b = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], 7'b1100011}; end
    endfunction
    function [31:0] enc_j;
        input [4:0] rd;
        input integer imm;
        begin enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'b1101111}; end
    endfunction

    task emit;
        input [31:0] word;
        begin
            if (program_size >= 256) $fatal(1, "Program exceeds instruction RAM");
            dut.u_instruction_memory.u_memory.mem[program_size] = word;
            program_size = program_size + 1;
        end
    endtask
    task expect_mem;
        input wr;
        input [31:0] addr, data;
        input [3:0] mask;
        begin
            expected_write[expected_count] = wr;
            expected_addr[expected_count] = addr;
            expected_data[expected_count] = data;
            expected_mask[expected_count] = mask;
            expected_count = expected_count + 1;
        end
    endtask
    task check32;
        input [31:0] actual, expected;
        input [8*80-1:0] label;
        begin
            if (actual !== expected)
                $fatal(1, "%0s expected=%h actual=%h", label, expected, actual);
        end
    endtask
    task clear_program;
        begin
            active = 0;
            program_size = 0;
            expected_count = 0;
            observed_count = 0;
            fp_writes = 0;
            for (j = 0; j < 256; j = j + 1)
                dut.u_instruction_memory.u_memory.mem[j] = 32'h00000013;
            dut.u_data_memory.u_memory.mem[255] = 0;
        end
    endtask
    task run_to_signature;
        begin
            @(negedge clk);
            active = 1;
            rst = 1;
            cycles = 0;
            while (dut.u_data_memory.u_memory.mem[255] !== 32'h00000123 && cycles < 5000) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (cycles == 5000) $fatal(1, "Timeout pc=%h requests=%0d/%0d", dut.pc_address, observed_count, expected_count);
            repeat (12) @(negedge clk);
            if (observed_count != expected_count)
                $fatal(1, "Memory request count expected=%0d actual=%0d", expected_count, observed_count);
        end
    endtask

    // Independent architectural transaction expectations catch replay, missing
    // loads/stores, incorrect address selection and wrong register-file sources.
    always @(posedge clk) begin
        if (rst && active) begin
            if ($test$plusargs("trace"))
                $display("TRACE t=%0t pc=%h D=%h issue=%b hazard=%b E=%h M=%h wait=%b W=%h fwe=%b wb=%h f1=%h", $time,
                    dut.pc_address, dut.u_core.instruction_decode, dut.u_core.decode_issue, dut.u_core.dependency_wait,
                    dut.u_core.instruction_execute, dut.u_core.instruction_memstage, dut.u_core.memory_wait,
                    dut.u_core.instruction_wb, dut.u_core.fp_reg_write_wb, dut.u_core.rd_wb_data,
                    dut.u_core.u_decodestage.u_fp_regfile0.register[1]);
            if ((^{dut.instruction_mem_request, dut.data_mem_request,
                   dut.u_core.reg_write_wb, dut.u_core.fp_reg_write_wb}) === 1'bx)
                $fatal(1, "Unknown request/write-enable");
            if (dut.u_core.reg_write_wb && dut.u_core.fp_reg_write_wb)
                $fatal(1, "One instruction wrote both GPR and FPR");
            if (dut.u_core.fp_reg_write_wb)
                fp_writes = fp_writes + 1;
            if (dut.data_mem_request) begin
                if (observed_count >= expected_count)
                    $fatal(1, "Unexpected memory request addr=%h", dut.alu_out_address);
                check32(dut.alu_out_address, expected_addr[observed_count], "Effective address");
                if (dut.data_mem_we_re !== expected_write[observed_count])
                    $fatal(1, "Wrong request type at transaction %0d", observed_count);
                if (dut.data_mem_we_re) begin
                    check32(dut.store_data, expected_data[observed_count], "Store bits");
                    if (dut.mask !== expected_mask[observed_count])
                        $fatal(1, "Store mask expected=%b actual=%b", expected_mask[observed_count], dut.mask);
                end
                observed_count = observed_count + 1;
            end
        end
    end

    initial begin
        // Independent known encodings keep helper mistakes from passing silently.
        check32(enc_i(7'h07, 3, 2, 2, 8), 32'h00812187, "FLW encoding");
        check32(enc_s(7'h27, 2, 7, 2, 8), 32'h00712427, "FSW encoding");
        check32(enc_i(7'h13, 1, 0, 0, 64), 32'h04000093, "ADDI encoding");

        patterns[0] = 32'h00000000; // +0
        patterns[1] = 32'h80000000; // -0
        patterns[2] = 32'h3f800000; // +1
        patterns[3] = 32'hbf800000; // -1
        patterns[4] = 32'h7fc12345; // qNaN with payload
        patterns[5] = 32'h7f812345; // sNaN: loads/stores must preserve payload
        patterns[6] = 32'h7f800000; // +infinity
        patterns[7] = 32'hff800000; // -infinity
        patterns[8] = 32'h00000001; // smallest subnormal
        patterns[9] = 32'h007fffff; // largest subnormal
        patterns[10] = 32'h00800000; // smallest normal
        patterns[11] = 32'h7f7fffff; // largest finite
        lfsr = 32'h23521419;
        for (i = 12; i < 32; i = i + 1) begin
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            patterns[i] = lfsr;
        end
        for (i = 0; i < 256; i = i + 1)
            dut.u_data_memory.u_memory.mem[i] = 32'ha5a5a5a5;
        for (i = 0; i < 32; i = i + 1)
            dut.u_data_memory.u_memory.mem[16 + i] = patterns[i];

        clear_program;
        emit(enc_i(7'h13, 1, 0, 0, 64));
        emit(enc_i(7'h13, 2, 0, 0, 256));
        emit(enc_i(7'h13, 5, 0, 0, 'h155));
        emit(enc_i(7'h13, 7, 0, 0, 'h177));
        emit(enc_i(7'h13, 31, 0, 0, 'h1aa));
        emit(enc_i(7'h13, 0, 0, 0, 'h55)); // attempted x0 write

        // Every FPR, including f0 and f31; dependent FLW/FSW with no software NOPs.
        for (i = 0; i < 32; i = i + 1) begin
            emit(enc_i(7'h07, i[4:0], 1, 2, 4*i));
            expect_mem(0, 64 + 4*i, 0, 0);
            emit(enc_s(7'h27, 2, i[4:0], 2, 4*i));
            expect_mem(1, 256 + 4*i, patterns[i], 4'hf);
        end
        emit(enc_i(7'h03, 5, 1, 2, 0)); expect_mem(0, 64, 0, 0);
        emit(enc_s(7'h23, 2, 5, 2, 128)); expect_mem(1, 384, 0, 4'hf);
        emit(enc_i(7'h03, 0, 1, 2, 4)); expect_mem(0, 68, 0, 0);
        emit(enc_i(7'h13, 6, 0, 0, 'h123));
        emit(enc_i(7'h13, 3, 1, 0, 4));
        emit(enc_i(7'h07, 7, 3, 2, -4)); expect_mem(0, 64, 0, 0);
        emit(enc_s(7'h27, 2, 7, 2, 132)); expect_mem(1, 388, 0, 4'hf);
        emit(enc_i(7'h13, 4, 2, 0, 140));
        emit(enc_s(7'h27, 4, 1, 2, -4)); expect_mem(1, 392, patterns[1], 4'hf);
        // Two identical encodings are two distinct dynamic instructions.
        emit(enc_i(7'h07, 12, 1, 2, 48)); expect_mem(0, 112, 0, 0);
        emit(enc_i(7'h07, 12, 1, 2, 48)); expect_mem(0, 112, 0, 0);

        // Integer byte/halfword regressions exercise all upper byte lanes.
        emit(enc_i(7'h13, 8, 0, 0, -128));
        emit(enc_s(7'h23, 2, 8, 0, 147)); expect_mem(1, 403, 32'h80000000, 4'h8);
        emit(enc_i(7'h03, 9, 2, 0, 147)); expect_mem(0, 403, 0, 0);
        emit(enc_i(7'h03, 10, 2, 4, 147)); expect_mem(0, 403, 0, 0);
        emit(enc_s(7'h23, 2, 8, 1, 150)); expect_mem(1, 406, 32'hff800000, 4'hc);
        emit(enc_i(7'h03, 11, 2, 1, 150)); expect_mem(0, 406, 0, 0);
        emit(enc_i(7'h03, 13, 2, 5, 150)); expect_mem(0, 406, 0, 0);
        emit(enc_i(7'h13, 14, 8, 2, -1)); // SLTI
        emit(enc_i(7'h13, 15, 8, 7, -1)); // ANDI
        emit(enc_i(7'h13, 16, 8, 4, -1)); // XORI
        emit(enc_i(7'h13, 17, 0, 6, -1)); // ORI
        emit(enc_i(7'h13, 18, 0, 3, -1)); // SLTIU
        emit({7'b0, 5'd10, 5'd6, 3'b000, 5'd19, 7'h33}); // ADD

        // Taken branch / JAL / JALR must discard younger FP memory operations.
        emit(enc_b(0, 19, 19, 12));
        emit(enc_i(7'h07, 31, 0, 2, 0));
        emit(enc_s(7'h27, 0, 31, 2, 960));
        jal_link = program_size*4 + 4;
        emit(enc_j(20, 12));
        emit(enc_i(7'h07, 31, 0, 2, 0));
        emit(enc_s(7'h27, 0, 31, 2, 964));
        jump_target = (program_size + 4)*4;
        emit(enc_i(7'h13, 21, 0, 0, jump_target + 1));
        jalr_link = program_size*4 + 4;
        emit(enc_i(7'h67, 22, 21, 0, 0));
        emit(enc_i(7'h07, 31, 0, 2, 0));
        emit(enc_s(7'h27, 0, 31, 2, 968));

        emit(enc_i(7'h13, 23, 0, 0, 3));
        emit(enc_s(7'h27, 2, 0, 2, 160));
        for (i = 0; i < 3; i = i + 1) expect_mem(1, 416, 0, 4'hf);
        emit(enc_i(7'h13, 23, 23, 0, -1));
        emit(enc_b(1, 23, 0, -8));
        emit(enc_b(1, 0, 0, 8)); // not taken
        emit(enc_i(7'h07, 5, 1, 1, 0)); // unsupported FP format
        emit(enc_s(7'h27, 0, 5, 1, 972)); // unsupported FP format
        emit(enc_s(7'h23, 0, 6, 2, 1020)); expect_mem(1, 1020, 'h123, 4'hf);
        emit(enc_j(0, 0));

        repeat (3) @(negedge clk);
        run_to_signature;
        for (i = 0; i < 32; i = i + 1) begin
            check32(dut.u_data_memory.u_memory.mem[64+i], patterns[i], "FP raw-bit round trip");
            check32(dut.u_core.u_decodestage.u_fp_regfile0.register[i],
                    i == 7 ? 32'b0 : patterns[i], "FPR contents");
        end
        if (fp_writes != 35) $fatal(1, "Expected 35 FP writebacks, got %0d", fp_writes);
        check32(dut.u_core.u_decodestage.u_regfile0.register[0], 0, "x0");
        check32(dut.u_core.u_decodestage.u_regfile0.register[1], 64, "x1 base preserved");
        check32(dut.u_core.u_decodestage.u_regfile0.register[2], 256, "x2 base preserved");
        check32(dut.u_core.u_decodestage.u_regfile0.register[5], 0, "LW writes x5");
        check32(dut.u_core.u_decodestage.u_regfile0.register[7], 'h177, "FLW leaves x7 unchanged");
        check32(dut.u_core.u_decodestage.u_regfile0.register[31], 'h1aa, "FLW leaves x31 unchanged");
        check32(dut.u_core.u_decodestage.u_regfile0.register[6], 'h123, "x0 not forwarded");
        check32(dut.u_core.u_decodestage.u_regfile0.register[9], 32'hffffff80, "LB sign extension");
        check32(dut.u_core.u_decodestage.u_regfile0.register[10], 128, "LBU zero extension");
        check32(dut.u_core.u_decodestage.u_regfile0.register[11], 32'hffffff80, "LH sign extension");
        check32(dut.u_core.u_decodestage.u_regfile0.register[13], 'hff80, "LHU zero extension");
        check32(dut.u_core.u_decodestage.u_regfile0.register[14], 1, "SLTI negative immediate");
        check32(dut.u_core.u_decodestage.u_regfile0.register[15], 32'hffffff80, "ANDI negative immediate");
        check32(dut.u_core.u_decodestage.u_regfile0.register[16], 'h7f, "XORI negative immediate");
        check32(dut.u_core.u_decodestage.u_regfile0.register[17], 32'hffffffff, "ORI negative immediate");
        check32(dut.u_core.u_decodestage.u_regfile0.register[18], 1, "SLTIU negative immediate");
        check32(dut.u_core.u_decodestage.u_regfile0.register[19], 419, "Dependent ADD");
        check32(dut.u_core.u_decodestage.u_regfile0.register[20], jal_link, "JAL link PC");
        check32(dut.u_core.u_decodestage.u_regfile0.register[22], jalr_link, "JALR link PC");
        check32(dut.u_core.u_decodestage.u_regfile0.register[23], 0, "Backward branch loop");
        check32(dut.u_data_memory.u_memory.mem[100], 32'h80a5a5a5, "SB preserves untouched bytes");
        check32(dut.u_data_memory.u_memory.mem[98], patterns[1], "FSW negative immediate");
        check32(dut.u_data_memory.u_memory.mem[101], 32'hff80a5a5, "SH preserves untouched bytes");
        for (i = 240; i <= 243; i = i + 1)
            check32(dut.u_data_memory.u_memory.mem[i], 32'ha5a5a5a5, "No wrong-path/invalid stores");
        $display("FP_MEM_E2E round-trip/regression PASS: %0d requests, %0d FP writes, %0d cycles", observed_count, fp_writes, cycles);

        // Cancel an accepted FLW before write-back, then restart a new program.
        rst = 0;
        clear_program;
        emit(enc_i(7'h07, 5, 0, 2, 68)); expect_mem(0, 68, 0, 0);
        emit(enc_j(0, 0));
        repeat (2) @(negedge clk);
        active = 1;
        rst = 1;
        wait (dut.data_mem_request === 1'b1);
        @(posedge clk);
        #1;
        rst = 0;
        active = 0;
        #1;
        if (dut.u_core.reg_write_wb !== 0 || dut.u_core.fp_reg_write_wb !== 0)
            $fatal(1, "Reset left write-back enabled");
        for (i = 0; i < 32; i = i + 1) begin
            check32(dut.u_core.u_decodestage.u_regfile0.register[i], 0, "GPR reset");
            check32(dut.u_core.u_decodestage.u_fp_regfile0.register[i], 0, "FPR reset");
        end
        clear_program;
        emit(enc_s(7'h27, 0, 5, 2, 512)); expect_mem(1, 512, 0, 4'hf);
        emit(enc_i(7'h07, 0, 0, 2, 68)); expect_mem(0, 68, 0, 0);
        emit(enc_s(7'h27, 0, 0, 2, 516)); expect_mem(1, 516, patterns[1], 4'hf);
        emit(enc_i(7'h03, 5, 0, 2, 72)); expect_mem(0, 72, 0, 0);
        emit(enc_i(7'h07, 5, 0, 2, 76)); expect_mem(0, 76, 0, 0);
        emit(enc_s(7'h27, 0, 5, 2, 520)); expect_mem(1, 520, patterns[3], 4'hf);
        emit(enc_s(7'h23, 0, 5, 2, 524)); expect_mem(1, 524, patterns[2], 4'hf);
        emit(enc_i(7'h13, 6, 0, 0, 'h123));
        emit(enc_s(7'h23, 0, 6, 2, 1020)); expect_mem(1, 1020, 'h123, 4'hf);
        emit(enc_j(0, 0));
        repeat (2) @(negedge clk);
        run_to_signature;
        check32(dut.u_data_memory.u_memory.mem[128], 0, "No stale FLW write-back after reset");
        check32(dut.u_data_memory.u_memory.mem[129], patterns[1], "Writable f0 after reset");
        check32(dut.u_data_memory.u_memory.mem[130], patterns[3], "FSW uses f5");
        check32(dut.u_data_memory.u_memory.mem[131], patterns[2], "SW uses x5");
        if (fp_writes != 2) $fatal(1, "Reset/restart FP write count=%0d", fp_writes);
`ifdef DELAYED_MEMORY
        $display("FP_MEM_E2E_DELAYED_TEST_PASS");
`else
        $display("FP_MEM_E2E_TEST_PASS");
`endif
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "Global test timeout");
    end
endmodule

// Same core and RAM modules as Microprocessor.v. Responses are delayed by
// address-dependent extra cycles; requests remain accepted on the first edge.
module core_if_delayed_test_system (
    input wire clk, rst,
    input wire [31:0] instruction
);
    wire [31:0] instruction_data, pc_address, load_data_out, alu_out_address, store_data;
    wire [3:0] mask, instruc_mask_singal;
    wire instruction_mem_we_re, instruction_mem_request, data_mem_we_re, data_mem_request, load_signal;
    wire imem_raw_valid, dmem_raw_valid;
    reg instruc_mem_valid = 0, data_mem_valid = 0;
    integer i_remaining, d_remaining;
    instruc_mem_top u_instruction_memory (
        .clk(clk), .rst(rst), .we_re(instruction_mem_we_re), .request(instruction_mem_request),
        .mask(instruc_mask_singal), .address(pc_address[9:2]), .data_in(instruction),
        .valid(imem_raw_valid), .data_out(instruction_data)
    );
    core u_core (
        .clk(clk), .rst(rst), .instruction(instruction_data), .load_data_in(load_data_out),
        .mask_singal(mask), .load_signal(load_signal), .instruc_mask_singal(instruc_mask_singal),
        .instruction_mem_we_re(instruction_mem_we_re), .instruction_mem_request(instruction_mem_request),
        .data_mem_we_re(data_mem_we_re), .data_mem_request(data_mem_request),
        .instruc_mem_valid(instruc_mem_valid), .data_mem_valid(data_mem_valid),
        .store_data_out(store_data), .pc_address(pc_address), .alu_out_address(alu_out_address)
    );
    data_mem_top u_data_memory (
        .clk(clk), .rst(rst), .we_re(data_mem_we_re), .request(data_mem_request),
        .address(alu_out_address[9:2]), .data_in(store_data), .mask(mask), .load(load_signal),
        .valid(dmem_raw_valid), .data_out(load_data_out)
    );
    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            instruc_mem_valid <= 0;
            data_mem_valid <= 0;
            i_remaining <= 0;
            d_remaining <= 0;
        end else begin
            instruc_mem_valid <= 0;
            data_mem_valid <= 0;
            if (imem_raw_valid) i_remaining <= 1 + pc_address[3:2];
            else if (i_remaining > 0) begin
                i_remaining <= i_remaining - 1;
                if (i_remaining == 1) instruc_mem_valid <= 1;
            end
            if (dmem_raw_valid) d_remaining <= 1 + alu_out_address[4:2];
            else if (d_remaining > 0) begin
                d_remaining <= d_remaining - 1;
                if (d_remaining == 1) data_mem_valid <= 1;
            end
        end
    end
endmodule
