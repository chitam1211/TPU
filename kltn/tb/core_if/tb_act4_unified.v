`timescale 1ns/1ps

module tb_act4_unified;
    localparam integer MEM_BYTES = 1024 * 1024;

    reg clk;
    reg rst;
    reg instruc_mem_valid;
    reg data_mem_valid;
    reg [31:0] instruction;
    reg [31:0] load_data_in;

    wire load_signal;
    wire instruction_mem_we_re;
    wire instruction_mem_request;
    wire data_mem_we_re;
    wire data_mem_request;
    wire [3:0] mask_singal;
    wire [3:0] instruc_mask_singal;
    wire [31:0] store_data_out;
    wire [31:0] alu_out_address;
    wire [31:0] pc_address;

    reg [7:0] mem [0:MEM_BYTES-1];
    reg [1023:0] mem_file;
    reg trace_enabled;
    reg explain_enabled;
    integer tohost_address;
    integer max_cycles;
    integer cycle_count;
    integer i;

    core dut (
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
        .mask_singal(mask_singal),
        .instruc_mask_singal(instruc_mask_singal),
        .store_data_out(store_data_out),
        .alu_out_address(alu_out_address),
        .pc_address(pc_address)
    );

    function [31:0] read_word;
        input [31:0] address;
        begin
            read_word = {
                mem[address + 3], mem[address + 2],
                mem[address + 1], mem[address]
            };
        end
    endfunction

    // The data port is word-wide, like data_mem_top (address[9:2]): the core sends the byte
    // address, a lane mask and lane-aligned store data, and extracts sub-word loads itself
    // from the whole word. So memory is indexed by the word address.
    wire [31:0] data_word_address = {alu_out_address[31:2], 2'b00};

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        rst = 1'b0;
        instruc_mem_valid = 1'b0;
        data_mem_valid = 1'b0;
        instruction = 32'b0;
        load_data_in = 32'b0;
        cycle_count = 0;
        trace_enabled = 1'b0;
        explain_enabled = 1'b0;
        max_cycles = 5000000;

        if (!$value$plusargs("mem=%s", mem_file))
            $fatal(1, "Missing +mem=<ACT4 hex file>");
        if (!$value$plusargs("tohost=%h", tohost_address))
            $fatal(1, "Missing +tohost=<hex address>");
        if ($value$plusargs("max_cycles=%d", max_cycles)) begin end
        if ($test$plusargs("trace")) trace_enabled = 1'b1;
        if ($test$plusargs("explain")) explain_enabled = 1'b1;

        for (i = 0; i < MEM_BYTES; i = i + 1)
            mem[i] = 8'b0;
        $readmemh(mem_file, mem);

`ifdef NETLIST
        // Post-synthesis netlist: glbl.GSR holds every flip-flop for the first 100 ns,
        // so release reset after it; the cycle count then starts as in RTL simulation.
        repeat (15) @(posedge clk);
`else
        repeat (5) @(posedge clk);
`endif
        rst <= 1'b1;
    end

    always @(posedge clk) begin
        instruc_mem_valid <= 1'b0;
        data_mem_valid <= 1'b0;

        if (!rst) begin
            instruction <= 32'b0;
            load_data_in <= 32'b0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (cycle_count >= max_cycles)
                $fatal(1, "ACT4_RTL_TIMEOUT cycles=%0d pc=%08x", cycle_count, pc_address);

            if (instruction_mem_request) begin
                if (pc_address > MEM_BYTES - 4)
                    $fatal(1, "Instruction address outside RAM: %08x", pc_address);
                instruction <= read_word(pc_address);
                instruc_mem_valid <= 1'b1;
            end

            if (data_mem_request) begin
                if (alu_out_address > MEM_BYTES - 4)
                    $fatal(1, "Data address outside RAM: %08x", alu_out_address);

                if (data_mem_we_re) begin
                    if (explain_enabled)
                        $display("MEM_WRITE cycle=%0d address=%08x data=%08x mask=%x",
                                 cycle_count, alu_out_address, store_data_out, mask_singal);
                    if (mask_singal[0]) mem[data_word_address]     <= store_data_out[7:0];
                    if (mask_singal[1]) mem[data_word_address + 1] <= store_data_out[15:8];
                    if (mask_singal[2]) mem[data_word_address + 2] <= store_data_out[23:16];
                    if (mask_singal[3]) mem[data_word_address + 3] <= store_data_out[31:24];

                    if (alu_out_address == tohost_address && mask_singal[0]) begin
                        if (store_data_out == 32'd1) begin
                            $display("ACT4_RTL_PASS cycles=%0d", cycle_count);
                            $finish;
                        end else if (store_data_out[0]) begin
                            $fatal(1, "ACT4_RTL_FAIL tohost=%08x cycles=%0d", store_data_out, cycle_count);
                        end
                    end
                end else begin
                    if (explain_enabled)
                        $display("MEM_READ cycle=%0d address=%08x data=%08x",
                                 cycle_count, alu_out_address, read_word(data_word_address));
                    load_data_in <= read_word(data_word_address);
                end
                data_mem_valid <= 1'b1;
            end

`ifndef NETLIST
            // Internal signals for +trace/+explain exist only in the RTL; a synthesized
            // netlist (compiled with -d NETLIST) keeps just the ports of `core`.
            if (trace_enabled && dut.wb_valid)
                $display("TRACE cycle=%0d pc=%08x insn=%08x", cycle_count,
                         dut.pre_pc_addr_wb, dut.instruction_wb);
            if (explain_enabled) begin
                if (dut.execute_valid && !dut.execute_wait &&
                    (dut.fp_arith_execute || dut.fp_compare_execute ||
                     dut.fp_minmax_execute || dut.fp_misc_execute))
                    $display("FP_EXEC cycle=%0d pc=%08x insn=%08x a=%08x b=%08x c=%08x result=%08x flags=%02x",
                             cycle_count, dut.pre_pc_addr_execute, dut.instruction_execute,
                             dut.opa_mux_out_execute, dut.opb_mux_out_execute, dut.opc_mux_out_execute,
                             dut.execute_result,
                             dut.fp_minmax_execute ? dut.fp_minmax_flags :
                             (dut.fp_compare_execute ? dut.fp_compare_flags : dut.fp_flags));
                if (dut.execute_valid && !dut.execute_wait &&
                    dut.instruction_execute[6:0] == 7'h63)
                    $display("BRANCH cycle=%0d pc=%08x insn=%08x rs1=x%0d value=%08x rs2=x%0d value=%08x taken=%0d",
                             cycle_count, dut.pre_pc_addr_execute, dut.instruction_execute,
                             dut.instruction_execute[19:15],
                             dut.u_decodestage.u_regfile0.register[dut.instruction_execute[19:15]],
                             dut.instruction_execute[24:20],
                             dut.u_decodestage.u_regfile0.register[dut.instruction_execute[24:20]],
                             dut.branch_result_execute);
                if (dut.wb_valid && (dut.reg_write_wb || dut.fp_reg_write_wb))
                    $display("RETIRE cycle=%0d pc=%08x insn=%08x rd=%0d bank=%s value=%08x fflags_before=%02x",
                             cycle_count, dut.pre_pc_addr_wb, dut.instruction_wb,
                             dut.instruction_wb[11:7],
                             dut.reg_write_wb ? "x" : (dut.fp_reg_write_wb ? "f" : "-"),
                             dut.rd_wb_data, dut.fflags);
                else if (dut.wb_valid)
                    $display("RETIRE cycle=%0d pc=%08x insn=%08x bank=- fflags_before=%02x",
                             cycle_count, dut.pre_pc_addr_wb, dut.instruction_wb, dut.fflags);
            end
`endif
        end
    end
endmodule
