`timescale 1ns/1ps

// Lockstep check of the synthesized netlist against the RTL. Two copies of the core run the
// same ACT4 program, each from its own memory, on one clock and one reset; every port is
// compared once per cycle and the first cycle that differs is reported.
//   RTL     : module `core` (rtl/core_if)
//   netlist : Vivado funcsim netlist with every module renamed net_<name> (run_lockstep.py),
//             so both copies can be elaborated together
// Memory model and tohost check are the ones of tb/core_if/tb_act4_unified.v.
// Plusargs: +mem=<hex> +tohost=<hex> [+max_cycles=N] [+max_mismatches=N] [+inject_cycle=N]
//   inject_cycle: from that cycle on, the first instruction word delivered to the netlist copy
//   is replaced by `jal x0, 8`, so the two copies must diverge. This is the self-test of the
//   comparison: a run with it has to end in LOCKSTEP_MISMATCH.
module tb_lockstep;
    localparam [31:0] INJECT_INSN = 32'h0080006f;   // jal x0, 8: skips the next instruction

    reg clk;
    reg rst;
    integer tohost_address;
    integer max_cycles;
    integer max_mismatches;
    integer inject_cycle;
    integer cycle_count;
    integer mismatches;
    reg injected;

    // RTL copy (suffix _r) and netlist copy (suffix _n): core outputs.
    wire        load_signal_r,             load_signal_n;
    wire        instruction_mem_we_re_r,   instruction_mem_we_re_n;
    wire        instruction_mem_request_r, instruction_mem_request_n;
    wire        data_mem_we_re_r,          data_mem_we_re_n;
    wire        data_mem_request_r,        data_mem_request_n;
    wire [3:0]  mask_r,                    mask_n;
    wire [3:0]  instruc_mask_r,            instruc_mask_n;
    wire [31:0] store_data_r,              store_data_n;
    wire [31:0] address_r,                 address_n;
    wire [31:0] pc_r,                      pc_n;

    // Memory responses.
    wire [31:0] instruction_r, instruction_n_mem, load_data_r, load_data_n;
    wire        instruc_valid_r, instruc_valid_n, data_valid_r, data_valid_n;

    // Fault injection on the netlist side only (see inject_cycle above).
    wire inject_now = inject_cycle >= 0 && !injected && cycle_count >= inject_cycle && instruc_valid_n;
    wire [31:0] instruction_n = inject_now ? INJECT_INSN : instruction_n_mem;

    core u_rtl (
        .clk(clk), .rst(rst),
        .data_mem_valid(data_valid_r), .instruc_mem_valid(instruc_valid_r),
        .instruction(instruction_r), .load_data_in(load_data_r),
        .load_signal(load_signal_r), .instruction_mem_we_re(instruction_mem_we_re_r),
        .instruction_mem_request(instruction_mem_request_r), .data_mem_we_re(data_mem_we_re_r),
        .data_mem_request(data_mem_request_r), .mask_singal(mask_r),
        .instruc_mask_singal(instruc_mask_r), .store_data_out(store_data_r),
        .alu_out_address(address_r), .pc_address(pc_r)
    );

    net_core u_net (
        .clk(clk), .rst(rst),
        .data_mem_valid(data_valid_n), .instruc_mem_valid(instruc_valid_n),
        .instruction(instruction_n), .load_data_in(load_data_n),
        .load_signal(load_signal_n), .instruction_mem_we_re(instruction_mem_we_re_n),
        .instruction_mem_request(instruction_mem_request_n), .data_mem_we_re(data_mem_we_re_n),
        .data_mem_request(data_mem_request_n), .mask_singal(mask_n),
        .instruc_mask_singal(instruc_mask_n), .store_data_out(store_data_n),
        .alu_out_address(address_n), .pc_address(pc_n)
    );

    act4_mem u_mem_r (
        .clk(clk), .rst(rst),
        .instruction_mem_request(instruction_mem_request_r), .pc_address(pc_r),
        .data_mem_request(data_mem_request_r), .data_mem_we_re(data_mem_we_re_r),
        .mask(mask_r), .address(address_r), .store_data(store_data_r),
        .instruction(instruction_r), .instruc_mem_valid(instruc_valid_r),
        .load_data_in(load_data_r), .data_mem_valid(data_valid_r)
    );

    act4_mem u_mem_n (
        .clk(clk), .rst(rst),
        .instruction_mem_request(instruction_mem_request_n), .pc_address(pc_n),
        .data_mem_request(data_mem_request_n), .data_mem_we_re(data_mem_we_re_n),
        .mask(mask_n), .address(address_n), .store_data(store_data_n),
        .instruction(instruction_n_mem), .instruc_mem_valid(instruc_valid_n),
        .load_data_in(load_data_n), .data_mem_valid(data_valid_n)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        rst = 1'b0;
        cycle_count = 0;
        mismatches = 0;
        injected = 1'b0;
        max_cycles = 5000000;
        max_mismatches = 1;
        inject_cycle = -1;

        if (!$value$plusargs("tohost=%h", tohost_address))
            $fatal(1, "Missing +tohost=<hex address>");
        if ($value$plusargs("max_cycles=%d", max_cycles)) begin end
        if ($value$plusargs("max_mismatches=%d", max_mismatches)) begin end
        if ($value$plusargs("inject_cycle=%d", inject_cycle))
            $display("LOCKSTEP_INJECT armed at cycle %0d (netlist copy only)", inject_cycle);

        // glbl.GSR holds every netlist flip-flop for the first 100 ns, so release reset after
        // it (as tb_act4_unified does with -d NETLIST); the RTL copy waits the same time.
        repeat (15) @(posedge clk);
        rst <= 1'b1;
    end

    // Cycle counter, timeout, tohost check (on the RTL copy; the comparison below makes the
    // netlist copy write the same word in the same cycle).
    always @(posedge clk) begin
        if (rst) begin
            cycle_count <= cycle_count + 1;
            if (inject_now) begin
                injected <= 1'b1;
                $display("LOCKSTEP_INJECT cycle=%0d pc_net=%08x insn %08x -> %08x",
                         cycle_count, pc_n, instruction_n_mem, INJECT_INSN);
            end
            if (cycle_count >= max_cycles)
                $fatal(1, "LOCKSTEP_TIMEOUT cycles=%0d pc_rtl=%08x pc_net=%08x", cycle_count, pc_r, pc_n);

            if (data_mem_request_r && data_mem_we_re_r && address_r == tohost_address && mask_r[0]) begin
                if (store_data_r == 32'd1) begin
                    if (injected)
                        $display("LOCKSTEP_INJECT_UNDETECTED cycles=%0d", cycle_count);
                    else
                        $display("LOCKSTEP_PASS cycles=%0d", cycle_count);
                    $finish;
                end else if (store_data_r[0]) begin
                    $fatal(1, "ACT4_RTL_FAIL tohost=%08x cycles=%0d", store_data_r, cycle_count);
                end
            end
        end
    end

    // Comparison at the falling edge: the netlist flip-flops (UNISIM) update a little after the
    // rising edge, so both copies are settled here. Address and data only matter while a
    // request is active; outside that the bus value is free to differ. !== also flags X/Z.
    task report;
        input [8*24:1] name;
        input [31:0] rtl_value;
        input [31:0] net_value;
        begin
            mismatches = mismatches + 1;
            $display("LOCKSTEP_MISMATCH cycle=%0d signal=%0s rtl=%08x net=%08x pc_rtl=%08x pc_net=%08x",
                     cycle_count, name, rtl_value, net_value, pc_r, pc_n);
        end
    endtask

    always @(negedge clk) begin
        if (rst) begin
            if (pc_r !== pc_n)
                report("pc_address", pc_r, pc_n);
            if (instruction_mem_request_r !== instruction_mem_request_n)
                report("instruction_mem_request", instruction_mem_request_r, instruction_mem_request_n);
            if (instruction_mem_we_re_r !== instruction_mem_we_re_n)
                report("instruction_mem_we_re", instruction_mem_we_re_r, instruction_mem_we_re_n);
            if (instruc_mask_r !== instruc_mask_n)
                report("instruc_mask_singal", instruc_mask_r, instruc_mask_n);
            if (load_signal_r !== load_signal_n)
                report("load_signal", load_signal_r, load_signal_n);
            if (data_mem_request_r !== data_mem_request_n)
                report("data_mem_request", data_mem_request_r, data_mem_request_n);
            if (data_mem_request_r) begin
                if (data_mem_we_re_r !== data_mem_we_re_n)
                    report("data_mem_we_re", data_mem_we_re_r, data_mem_we_re_n);
                if (address_r !== address_n)
                    report("alu_out_address", address_r, address_n);
                if (data_mem_we_re_r) begin
                    if (mask_r !== mask_n)
                        report("mask_singal", mask_r, mask_n);
                    if (store_data_r !== store_data_n)
                        report("store_data_out", store_data_r, store_data_n);
                end
            end
            if (mismatches >= max_mismatches && mismatches > 0)
                $fatal(1, "LOCKSTEP_FAIL mismatches=%0d cycle=%0d", mismatches, cycle_count);
        end
    end
endmodule

// Byte-wide RAM with the request/valid protocol of tb_act4_unified.v (one copy per core).
module act4_mem #(
    parameter integer MEM_BYTES = 1024 * 1024
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        instruction_mem_request,
    input  wire [31:0] pc_address,
    input  wire        data_mem_request,
    input  wire        data_mem_we_re,
    input  wire [3:0]  mask,
    input  wire [31:0] address,
    input  wire [31:0] store_data,
    output reg  [31:0] instruction,
    output reg         instruc_mem_valid,
    output reg  [31:0] load_data_in,
    output reg         data_mem_valid
);
    reg [7:0] mem [0:MEM_BYTES-1];
    reg [1023:0] mem_file;
    integer i;
    // Word-wide data port, as in tb_act4_unified.v: index memory by the word address.
    wire [31:0] word_address = {address[31:2], 2'b00};

    function [31:0] read_word;
        input [31:0] addr;
        begin
            read_word = {mem[addr + 3], mem[addr + 2], mem[addr + 1], mem[addr]};
        end
    endfunction

    initial begin
        instruction = 32'b0;
        load_data_in = 32'b0;
        instruc_mem_valid = 1'b0;
        data_mem_valid = 1'b0;
        if (!$value$plusargs("mem=%s", mem_file))
            $fatal(1, "Missing +mem=<ACT4 hex file>");
        for (i = 0; i < MEM_BYTES; i = i + 1)
            mem[i] = 8'b0;
        $readmemh(mem_file, mem);
    end

    always @(posedge clk) begin
        instruc_mem_valid <= 1'b0;
        data_mem_valid <= 1'b0;

        if (!rst) begin
            instruction <= 32'b0;
            load_data_in <= 32'b0;
        end else begin
            if (instruction_mem_request) begin
                if (pc_address > MEM_BYTES - 4)
                    $fatal(1, "%m: instruction address outside RAM: %08x", pc_address);
                instruction <= read_word(pc_address);
                instruc_mem_valid <= 1'b1;
            end

            if (data_mem_request) begin
                if (address > MEM_BYTES - 4)
                    $fatal(1, "%m: data address outside RAM: %08x", address);
                if (data_mem_we_re) begin
                    if (mask[0]) mem[word_address]     <= store_data[7:0];
                    if (mask[1]) mem[word_address + 1] <= store_data[15:8];
                    if (mask[2]) mem[word_address + 2] <= store_data[23:16];
                    if (mask[3]) mem[word_address + 3] <= store_data[31:24];
                end else begin
                    load_data_in <= read_word(word_address);
                end
                data_mem_valid <= 1'b1;
            end
        end
    end
endmodule
