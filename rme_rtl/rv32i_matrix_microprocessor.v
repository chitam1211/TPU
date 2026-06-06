module rv32i_matrix_microprocessor (
    input wire clk,
    input wire rst,
    input wire [31:0]instruction,

    input  wire        matrix_host_reg_we,
    input  wire [2:0]  matrix_host_reg_id,
    input  wire [2:0]  matrix_host_reg_row_idx,
    input  wire [2:0]  matrix_host_reg_beat_idx,
    input  wire [31:0] matrix_host_reg_wdata,
    input  wire [2:0]  matrix_host_read_id,
    input  wire [2:0]  matrix_host_read_row,
    input  wire [2:0]  matrix_host_read_beat,
    output wire [31:0] matrix_host_reg_rdata,
    output wire [31:0] matrix_debug_mtilem,
    output wire [31:0] matrix_debug_mtilen,
    output wire [31:0] matrix_debug_mtilek,
    output wire        matrix_busy,
    output wire        matrix_done
    );

    wire [31:0] instruction_data;
    wire [31:0] pc_address;
    wire [31:0] load_data_out;
    wire [31:0] alu_out_address;
    wire [31:0] store_data;
    wire [3:0]  mask;
    wire [3:0]  instruc_mask_singal;
    wire instruction_mem_we_re;
    wire instruction_mem_request;
    wire instruc_mem_valid;
    wire data_mem_valid;
    wire data_mem_we_re;
    wire data_mem_request;
    wire load_signal;
    wire store;

    // INSTRUCTION MEMORY
    instruc_mem_top #(
        .INIT_MEM(1)
    )u_instruction_memory(
        .clk(clk),
        .rst(rst),
        .we_re(instruction_mem_we_re),
        .request(instruction_mem_request),
        .mask(instruc_mask_singal),
        .address(pc_address[9:2]),
        .data_in(instruction),
        .valid(instruc_mem_valid),
        .data_out(instruction_data)
    );

    //CORE
    core_matrix u_core(
        .clk(clk),
        .rst(rst),
        .instruction(instruction_data),
        .load_data_in(load_data_out),
        .mask_singal(mask),
        .load_signal(load_signal),
        .instruc_mask_singal(instruc_mask_singal),
        .instruction_mem_we_re(instruction_mem_we_re),
        .instruction_mem_request(instruction_mem_request),
        .data_mem_we_re(data_mem_we_re),
        .data_mem_request(data_mem_request),
        .instruc_mem_valid(instruc_mem_valid),
        .data_mem_valid(data_mem_valid),
        .store_data_out(store_data),
        .pc_address(pc_address),
        .alu_out_address(alu_out_address),

        .matrix_host_reg_we(matrix_host_reg_we),
        .matrix_host_reg_id(matrix_host_reg_id),
        .matrix_host_reg_row_idx(matrix_host_reg_row_idx),
        .matrix_host_reg_beat_idx(matrix_host_reg_beat_idx),
        .matrix_host_reg_wdata(matrix_host_reg_wdata),
        .matrix_host_read_id(matrix_host_read_id),
        .matrix_host_read_row(matrix_host_read_row),
        .matrix_host_read_beat(matrix_host_read_beat),
        .matrix_host_reg_rdata(matrix_host_reg_rdata),
        .matrix_debug_mtilem(matrix_debug_mtilem),
        .matrix_debug_mtilen(matrix_debug_mtilen),
        .matrix_debug_mtilek(matrix_debug_mtilek),
        .matrix_busy(matrix_busy),
        .matrix_done(matrix_done)
    );


    // DATA MEMORY
    data_mem_top u_data_memory(
        .clk(clk),
        .rst(rst),
        .we_re(data_mem_we_re),
        .request(data_mem_request),
        .address(alu_out_address[9:2]),
        .data_in(store_data),
        .mask(mask),
        .load(load_signal),
        .valid(data_mem_valid),
        .data_out(load_data_out)
    );
endmodule
