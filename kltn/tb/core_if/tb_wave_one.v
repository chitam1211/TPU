`timescale 1ns/1ps
// Isolated single-instruction run for waveform viewing.
// Registers and data RAM are preloaded from the case file (no setup instructions
// in the program), the program is the one target instruction, and dumping stops
// right after it retires. Result, flags and (for stores) memory are checked
// against the architectural model's expectation.
module tb_wave_one;
    reg clk=0, rst=0;
    always #5 clk=~clk;
    microprocessor dut(.clk(clk),.rst(rst),.instruction(32'b0));
    reg [2047:0] case_path, wave_path;
    integer fd, st, i, cycles=0;
    reg [31:0] insn, value, csr_want, mem_index, mem_value, tmp;
    reg wx, wf, mem_check;
    reg [4:0] rd;
    reg [31:0] gpr[0:31], fpr[0:31];
    // Register-file contents are arrays and are not dumped, so expose the
    // destination register of the target instruction as plain wires.
    wire [31:0] dest_fpr = dut.u_core.u_decodestage.u_fp_regfile0.register[rd];
    wire [31:0] dest_gpr = dut.u_core.u_decodestage.u_regfile0.register[rd];
    wire [31:0] mem_word = dut.u_data_memory.u_memory.mem[mem_index[7:0]];   // word checked after fsw
    task check;
        input [31:0] actual, expected;
        input [8*40-1:0] label;
        begin
            if (actual !== expected) $fatal(1,"%0s got=%h expected=%h", label, actual, expected);
        end
    endtask
    initial begin
        if (!$value$plusargs("case=%s", case_path)) $fatal(1,"Missing +case=file");
        if ($value$plusargs("vcd=%s", wave_path)) begin $dumpfile(wave_path); $dumpvars(0,tb_wave_one); end
        fd = $fopen(case_path,"r");
        if (!fd) $fatal(1,"Cannot open case");
        st = $fscanf(fd,"%h %h %h %h %h %h %h %h %h\n",insn,wx,wf,rd,value,csr_want,mem_check,mem_index,mem_value);
        if (st != 9) $fatal(1,"Bad case header");
        for (i=0;i<32;i=i+1) begin st=$fscanf(fd,"%h\n",gpr[i]); if (st!=1) $fatal(1,"Bad gpr"); end
        for (i=0;i<32;i=i+1) begin st=$fscanf(fd,"%h\n",fpr[i]); if (st!=1) $fatal(1,"Bad fpr"); end
        for (i=0;i<256;i=i+1) begin st=$fscanf(fd,"%h\n",tmp); if (st!=1) $fatal(1,"Bad dmem"); dut.u_data_memory.u_memory.mem[i]=tmp; end
        $fclose(fd);
        for (i=0;i<256;i=i+1) dut.u_instruction_memory.u_memory.mem[i] = 32'h00000013;
        dut.u_instruction_memory.u_memory.mem[0] = insn;
        repeat(3) @(negedge clk);
        rst = 1;
        // Registers are written after reset release, before the first fetch completes.
        for (i=0;i<32;i=i+1) begin
            dut.u_core.u_decodestage.u_regfile0.register[i] = gpr[i];
            dut.u_core.u_decodestage.u_fp_regfile0.register[i] = fpr[i];
        end
        while (!(dut.u_core.wb_valid && dut.u_core.instruction_wb === insn) && cycles < 2000) begin
            @(negedge clk); cycles = cycles + 1;
        end
        if (cycles >= 2000) $fatal(1,"Instruction never retired");
        check(dut.u_core.reg_write_wb, wx, "GPR write enable");
        check(dut.u_core.fp_reg_write_wb, wf, "FPR write enable");
        if (wx || wf) begin
            check(dut.u_core.instruction_wb[11:7], rd, "Destination register");
            check(dut.u_core.rd_wb_data, value, "Writeback bits");
        end
        @(negedge clk);   // fflags are committed at the end of the WB cycle
        check({24'b0,dut.u_core.frm,dut.u_core.fflags}, csr_want, "FCSR after retirement");
        if (mem_check) check(dut.u_data_memory.u_memory.mem[mem_index], mem_value, "Stored memory word");
        $dumpoff;
        $display("WAVE_ONE_TEST_PASS cycles=%0d", cycles);
        $finish;
    end
    initial begin #200000; $fatal(1,"Global timeout"); end
endmodule
