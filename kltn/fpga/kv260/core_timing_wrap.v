// Timing-characterization wrapper for `core`; not part of the simulated design.
// Every data port of core is registered, so port-to-register paths become
// register-to-register paths that Vivado times (out-of-context leaves bare
// ports unconstrained). Adds one cycle on the memory handshake, which is fine
// for measuring but means this wrapper must not replace `core` in simulation.
module core_timing_wrap (
    input wire clk,
    input wire rst,
    input wire data_mem_valid,
    input wire instruc_mem_valid,
    input wire [31:0] instruction,
    input wire [31:0] load_data_in,

    output reg load_signal,
    output reg instruction_mem_we_re,
    output reg instruction_mem_request,
    output reg data_mem_we_re,
    output reg data_mem_request,
    output reg [3:0] mask_singal,
    output reg [3:0] instruc_mask_singal,
    output reg [31:0] store_data_out,
    output reg [31:0] alu_out_address,
    output reg [31:0] pc_address
);
    reg data_mem_valid_q, instruc_mem_valid_q;
    reg [31:0] instruction_q, load_data_in_q;

    wire load_signal_d, instruction_mem_we_re_d, instruction_mem_request_d;
    wire data_mem_we_re_d, data_mem_request_d;
    wire [3:0] mask_singal_d, instruc_mask_singal_d;
    wire [31:0] store_data_out_d, alu_out_address_d, pc_address_d;

    always @(posedge clk) begin
        data_mem_valid_q <= data_mem_valid;
        instruc_mem_valid_q <= instruc_mem_valid;
        instruction_q <= instruction;
        load_data_in_q <= load_data_in;

        load_signal <= load_signal_d;
        instruction_mem_we_re <= instruction_mem_we_re_d;
        instruction_mem_request <= instruction_mem_request_d;
        data_mem_we_re <= data_mem_we_re_d;
        data_mem_request <= data_mem_request_d;
        mask_singal <= mask_singal_d;
        instruc_mask_singal <= instruc_mask_singal_d;
        store_data_out <= store_data_out_d;
        alu_out_address <= alu_out_address_d;
        pc_address <= pc_address_d;
    end

    core u_core (
        .clk(clk),
        .rst(rst),
        .data_mem_valid(data_mem_valid_q),
        .instruc_mem_valid(instruc_mem_valid_q),
        .instruction(instruction_q),
        .load_data_in(load_data_in_q),
        .load_signal(load_signal_d),
        .instruction_mem_we_re(instruction_mem_we_re_d),
        .instruction_mem_request(instruction_mem_request_d),
        .data_mem_we_re(data_mem_we_re_d),
        .data_mem_request(data_mem_request_d),
        .mask_singal(mask_singal_d),
        .instruc_mask_singal(instruc_mask_singal_d),
        .store_data_out(store_data_out_d),
        .alu_out_address(alu_out_address_d),
        .pc_address(pc_address_d)
    );
endmodule
