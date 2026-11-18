// rv32if_matrix_xif_microprocessor: core_matrix_xif + 1 KB IMEM + 1 KB DMEM.
// Same ports and memories as rtl/matrix_if/rv32if_matrix_microprocessor.v (the direct
// version), so the two can be synthesised and compared; here the CPU reaches the matrix unit
// over CV-X-IF. IMEM_FILE (optional) preloads the instruction memory with $readmemh.
// Extra outputs: halt_hint (jal x0,0 in EX) and halted (rtl/core_matrix_xif/halt_detect.v).
module rv32if_matrix_xif_microprocessor #(
    parameter IMEM_FILE = ""
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] instruction,

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
    output wire        matrix_done,

    output wire        halted
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
    wire halt_hint;
    wire xif_idle;

    // INSTRUCTION MEMORY
    instruc_mem_top #(
        .INIT_MEM(IMEM_FILE != ""),
        .INIT_FILE(IMEM_FILE)
    ) u_instruction_memory (
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

    // CORE + CV-X-IF + MATRIX
    core_matrix_xif u_core (
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
        .matrix_done(matrix_done),

        .halt_hint(halt_hint),
        .xif_idle(xif_idle)
    );

    // DATA MEMORY
    data_mem_top u_data_memory (
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

    // HALT: program ends in jal x0, 0
    halt_detect #(.DRAIN_CYCLES(3)) u_halt (
        .clk(clk),
        .rst_n(rst),
        .halt_hint(halt_hint),
        .busy(!xif_idle),
        .halted(halted)
    );
endmodule
