`timescale 1ns/1ps

// Matrix regression bench: RV32IF core + matrix unit, one program per case.
// The DUT is chosen at compile time (-DDUT=<module>, default core_matrix; -DCORE=<path> if the
// pipeline is not the DUT itself) so the same bench runs the current design and the CV-X-IF
// version; both must keep the core_matrix port list.
// Memory: 64 KiB byte array, one request per cycle answered the next cycle on both ports (as
// tb_act4_unified.v and data_mem_top). The program ends with a store of 1 to TOHOST.
// Output (stdout):
//   RETIRE <cycle> <pc> <insn>      one line per instruction leaving WB
//   STATE  ...                      final state: GPR, FPR, matrix registers, tile CSRs, data RAM
//   MATRIX_REGRESS_DONE cycles=<n> matrix_insns=<n> matrix_busy=<n>
`ifndef DUT
`define DUT core_matrix
`endif
// Hierarchy of the pipeline inside the DUT (retire trace, register dump).
`ifndef CORE
`define CORE uut
`endif

module tb_matrix_regress;
    localparam int MEM_BYTES = 65536;
    localparam int TOHOST    = 32'h3FF0;
    localparam int DUMP_LO   = 32'h1000;
    localparam int DUMP_HI   = 32'h3FF0;        // exclusive

    logic clk = 1'b0;
    logic rst = 1'b0;
    logic instruc_mem_valid = 1'b0, data_mem_valid = 1'b0;
    logic [31:0] instruction = 32'b0, load_data_in = 32'b0;
    logic load_signal, instruction_mem_we_re, instruction_mem_request;
    logic data_mem_we_re, data_mem_request;
    logic [3:0] mask_signal, instruc_mask_signal;
    logic [31:0] store_data_out, alu_out_address, pc_address;
    logic matrix_busy, matrix_done;
    logic [2:0] host_read_id = 3'd0, host_read_row = 3'd0, host_read_beat = 3'd0;
    logic [31:0] host_reg_rdata, mtilem, mtilen, mtilek;

    logic [7:0] mem [0:MEM_BYTES-1];
    integer cycle = 0, max_cycles = 200000, matrix_insns = 0, busy_cycles = 0;

    `DUT uut (
        .clk(clk), .rst(rst),
        .data_mem_valid(data_mem_valid), .instruc_mem_valid(instruc_mem_valid),
        .instruction(instruction), .load_data_in(load_data_in),
        .load_signal(load_signal), .instruction_mem_we_re(instruction_mem_we_re),
        .instruction_mem_request(instruction_mem_request), .data_mem_we_re(data_mem_we_re),
        .data_mem_request(data_mem_request), .mask_singal(mask_signal),
        .instruc_mask_singal(instruc_mask_signal), .store_data_out(store_data_out),
        .alu_out_address(alu_out_address), .pc_address(pc_address),
        .matrix_host_reg_we(1'b0), .matrix_host_reg_id(3'd0), .matrix_host_reg_row_idx(3'd0),
        .matrix_host_reg_beat_idx(3'd0), .matrix_host_reg_wdata(32'd0),
        .matrix_host_read_id(host_read_id), .matrix_host_read_row(host_read_row),
        .matrix_host_read_beat(host_read_beat), .matrix_host_reg_rdata(host_reg_rdata),
        .matrix_debug_mtilem(mtilem), .matrix_debug_mtilen(mtilen), .matrix_debug_mtilek(mtilek),
        .matrix_busy(matrix_busy), .matrix_done(matrix_done)
    );

    always #5 clk = ~clk;

    function automatic logic [31:0] read_word(input logic [31:0] a);
        read_word = {mem[a + 3], mem[a + 2], mem[a + 1], mem[a]};
    endfunction

    wire [31:0] data_word_address = {alu_out_address[31:2], 2'b00};

    initial begin
        string prog;
        if (!$value$plusargs("mem=%s", prog)) $fatal(1, "Missing +mem=<program+data hex>");
        if ($value$plusargs("max_cycles=%d", max_cycles)) begin end
        for (int i = 0; i < MEM_BYTES; i++) mem[i] = 8'h00;
        $readmemh(prog, mem);
        repeat (5) @(posedge clk);
        rst <= 1'b1;
    end

    always @(posedge clk) begin
        instruc_mem_valid <= 1'b0;
        data_mem_valid <= 1'b0;
        if (rst) begin
            cycle <= cycle + 1;
            if (cycle >= max_cycles) $fatal(1, "MATRIX_REGRESS_TIMEOUT cycles=%0d pc=%08x", cycle, pc_address);
            if (matrix_done) matrix_insns <= matrix_insns + 1;
            if (matrix_busy) busy_cycles <= busy_cycles + 1;
            if (instruction_mem_request) begin
                if (pc_address > MEM_BYTES - 4) $fatal(1, "Instruction address outside RAM: %08x", pc_address);
                instruction <= read_word(pc_address);
                instruc_mem_valid <= 1'b1;
            end
            if (data_mem_request) begin
                if (alu_out_address > MEM_BYTES - 4) $fatal(1, "Data address outside RAM: %08x", alu_out_address);
                if (data_mem_we_re) begin
                    if (mask_signal[0]) mem[data_word_address]     <= store_data_out[7:0];
                    if (mask_signal[1]) mem[data_word_address + 1] <= store_data_out[15:8];
                    if (mask_signal[2]) mem[data_word_address + 2] <= store_data_out[23:16];
                    if (mask_signal[3]) mem[data_word_address + 3] <= store_data_out[31:24];
                    if (alu_out_address == TOHOST && store_data_out == 32'd1) begin
                        @(negedge clk);
                        dump_state();
                        $finish;
                    end
                end else begin
                    load_data_in <= read_word(data_word_address);
                end
                data_mem_valid <= 1'b1;
            end
            // Retire trace: same pipeline names in core_matrix and the XIF version.
            if (`CORE.wb_valid)
                $display("RETIRE %0d %08x %08x", cycle, `CORE.pre_pc_addr_wb, `CORE.instruction_wb);
        end
    end

    task automatic dump_state();
        for (int r = 1; r < 32; r++)
            $display("STATE x%0d %08x", r, `CORE.u_decodestage.u_regfile0.register[r]);
        for (int r = 0; r < 32; r++)
            $display("STATE f%0d %08x", r, `CORE.u_decodestage.u_fp_regfile0.register[r]);
        // Matrix registers through the host read port (combinational): ids 0-3 tr0-tr3,
        // 4-7 acc0-acc3; 4 rows x 8 beat indices (out-of-range beats read as 0).
        for (int id = 0; id < 8; id++)
            for (int row = 0; row < 4; row++)
                for (int beat = 0; beat < 8; beat++) begin
                    host_read_id = id; host_read_row = row; host_read_beat = beat;
                    #0.1;
                    $display("STATE m%0d.%0d.%0d %08x", id, row, beat, host_reg_rdata);
                end
        $display("STATE mtilem %08x", mtilem);
        $display("STATE mtilen %08x", mtilen);
        $display("STATE mtilek %08x", mtilek);
        for (int a = DUMP_LO; a < DUMP_HI; a += 4)
            $display("STATE mem%04x %08x", a, read_word(a));
        $display("MATRIX_REGRESS_DONE cycles=%0d matrix_insns=%0d matrix_busy=%0d",
                 cycle, matrix_insns, busy_cycles);
    endtask
endmodule
