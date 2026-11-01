`timescale 1ns/1ps

// Differential bench for `core`: the same program runs on two builds of the core (two
// compilations of this bench, e.g. the reference RTL and the changed one), and the logs
// must be identical apart from the CYCLES line.
// Memory: 64 KiB byte array. Each port has one request outstanding; the response comes
// 1 + d cycles later, d random in [0, +ilat] / [0, +dlat] from +seed (0: next cycle, as
// tb_act4_unified.v). Stores write at the request; loads read at the request.
// Output (stdout):
//   R <pc> <insn> [x|f <rd> <value>]   one line per instruction leaving WB
//   W <addr> <data> <mask>             one line per store
//   END fflags=<v> frm=<v>
//   CYCLES <n>
// The program ends with a word store of 1 to TOHOST.
module tb_core_diff;
    localparam integer MEM_BYTES = 65536;
    localparam [31:0] TOHOST = 32'h0000fff0;
    localparam [31:0] CODE_END = 32'h00008000;      // gen_core_diff.py: code below, data above

    reg clk = 1'b0;
    reg rst = 1'b0;
    reg instruc_mem_valid = 1'b0, data_mem_valid = 1'b0;
    reg [31:0] instruction = 32'b0, load_data_in = 32'b0;
    wire load_signal, instruction_mem_we_re, instruction_mem_request;
    wire data_mem_we_re, data_mem_request;
    wire [3:0] mask_singal, instruc_mask_singal;
    wire [31:0] store_data_out, alu_out_address, pc_address;

    reg [7:0] mem [0:MEM_BYTES-1];
    reg [1023:0] mem_file;
    integer seed = 1, ilat = 0, dlat = 0, max_cycles = 200000;
    integer cycle_count = 0, i;
    reg ipend = 1'b0, dpend = 1'b0;
    integer icnt = 0, dcnt = 0, d;
    reg [31:0] iaddr, dword, done_pc = 32'b0;
    reg done_pending = 1'b0;

    core dut (
        .clk(clk), .rst(rst),
        .data_mem_valid(data_mem_valid), .instruc_mem_valid(instruc_mem_valid),
        .instruction(instruction), .load_data_in(load_data_in),
        .load_signal(load_signal), .instruction_mem_we_re(instruction_mem_we_re),
        .instruction_mem_request(instruction_mem_request), .data_mem_we_re(data_mem_we_re),
        .data_mem_request(data_mem_request), .mask_singal(mask_singal),
        .instruc_mask_singal(instruc_mask_singal), .store_data_out(store_data_out),
        .alu_out_address(alu_out_address), .pc_address(pc_address)
    );

    function [31:0] read_word;
        input [31:0] address;
        begin
            read_word = {mem[address + 3], mem[address + 2], mem[address + 1], mem[address]};
        end
    endfunction

    wire [31:0] data_word_address = {alu_out_address[31:2], 2'b00};

    always #5 clk = ~clk;

    initial begin
        if (!$value$plusargs("mem=%s", mem_file)) $fatal(1, "Missing +mem=<program hex>");
        if ($value$plusargs("seed=%d", seed)) begin end
        if ($value$plusargs("ilat=%d", ilat)) begin end
        if ($value$plusargs("dlat=%d", dlat)) begin end
        if ($value$plusargs("max_cycles=%d", max_cycles)) begin end
        for (i = 0; i < MEM_BYTES; i = i + 1) mem[i] = 8'b0;
        $readmemh(mem_file, mem);
        repeat (5) @(posedge clk);
        rst <= 1'b1;
    end

    always @(posedge clk) begin
        instruc_mem_valid <= 1'b0;
        data_mem_valid <= 1'b0;
        if (rst) begin
            cycle_count <= cycle_count + 1;
            if (cycle_count >= max_cycles)
                $fatal(1, "CORE_DIFF_TIMEOUT cycles=%0d pc=%08x", cycle_count, pc_address);

            // Instruction port.
            if (ipend) begin
                if (icnt == 0) begin
                    instruction <= read_word(iaddr);
                    instruc_mem_valid <= 1'b1;
                    ipend <= 1'b0;
                end else
                    icnt <= icnt - 1;
            end
            if (instruction_mem_request) begin
                if (pc_address > MEM_BYTES - 4) $fatal(1, "Instruction address outside RAM: %08x", pc_address);
                d = ilat ? $unsigned($random(seed)) % (ilat + 1) : 0;
                if (d == 0) begin
                    instruction <= read_word(pc_address);
                    instruc_mem_valid <= 1'b1;
                end else begin
                    ipend <= 1'b1; icnt <= d - 1; iaddr <= pc_address;
                end
            end

            // Data port.
            if (dpend) begin
                if (dcnt == 0) begin
                    load_data_in <= dword;
                    data_mem_valid <= 1'b1;
                    dpend <= 1'b0;
                end else
                    dcnt <= dcnt - 1;
            end
            if (data_mem_request) begin
                if (alu_out_address > MEM_BYTES - 4) $fatal(1, "Data address outside RAM: %08x", alu_out_address);
                if (data_mem_we_re) begin
                    // Self-modifying code (no fence.i) may legally differ between cores.
                    if (alu_out_address < CODE_END)
                        $fatal(1, "CORE_DIFF_BAD_PROGRAM store into code at %08x", alu_out_address);
                    $display("W %08x %08x %x", alu_out_address, store_data_out, mask_singal);
                    if (mask_singal[0]) mem[data_word_address]     <= store_data_out[7:0];
                    if (mask_singal[1]) mem[data_word_address + 1] <= store_data_out[15:8];
                    if (mask_singal[2]) mem[data_word_address + 2] <= store_data_out[23:16];
                    if (mask_singal[3]) mem[data_word_address + 3] <= store_data_out[31:24];
                    // Stop when this store retires, so older instructions are all logged.
                    if (alu_out_address == TOHOST && store_data_out == 32'd1) begin
                        done_pending <= 1'b1;
                        done_pc <= dut.pre_pc_addr_memstage;
                    end
                end
                d = dlat ? $unsigned($random(seed)) % (dlat + 1) : 0;
                if (d == 0) begin
                    if (!data_mem_we_re) load_data_in <= read_word(data_word_address);
                    data_mem_valid <= 1'b1;
                end else begin
                    dpend <= 1'b1; dcnt <= d - 1; dword <= read_word(data_word_address);
                end
            end

            if (dut.wb_valid) begin
                if (dut.reg_write_wb || dut.fp_reg_write_wb)
                    $display("R %08x %08x %s %0d %08x", dut.pre_pc_addr_wb, dut.instruction_wb,
                             dut.reg_write_wb ? "x" : "f", dut.instruction_wb[11:7],
                             (dut.reg_write_wb && dut.instruction_wb[11:7] == 0) ? 32'd0 : dut.rd_wb_data);
                else
                    $display("R %08x %08x", dut.pre_pc_addr_wb, dut.instruction_wb);
                if (done_pending && dut.pre_pc_addr_wb == done_pc) begin
                    $display("END fflags=%02x frm=%0d", dut.fflags, dut.frm);
                    $display("CYCLES %0d", cycle_count);
                    $finish;
                end
            end
        end
    end
endmodule
