// core_matrix_xif: RV32IF core (rtl/core_if_xif/Core.v, XIF = 1) + matrix coprocessor
// (matrix_xif_coproc: matrix_xif_adapter + matrix_core_v2), joined by CV-X-IF v1.0.0
// (docs/xif_design.md). Wiring only, no logic of its own.
//
// Same ports as rtl/matrix_if/core_matrix.v, so tb/matrix/tb_matrix_regress.sv and the tops
// built on core_matrix take this module unchanged. The matrix unit has no memory port of its
// own: its requests go through the XIF memory interface and the core's data port.
//
// Extra outputs (may be left unconnected):
//   halt_hint  jal x0,0 executing in EX, for rtl/core_matrix_xif/halt_detect.v
//   xif_idle   the adapter is idle (no matrix instruction issued and unfinished)
//
// Simulation only: +define+XIF_CHECKER attaches tb/xif/xif_checker.sv to the bus (inside
// matrix_xif_coproc).
module core_matrix_xif (
    input  wire        clk,
    input  wire        rst,
    input  wire        data_mem_valid,
    input  wire        instruc_mem_valid,
    input  wire [31:0] instruction,
    input  wire [31:0] load_data_in,

    output wire        load_signal,
    output wire        instruction_mem_we_re,
    output wire        instruction_mem_request,
    output wire        data_mem_we_re,
    output wire        data_mem_request,
    output wire [3:0]  mask_singal,
    output wire [3:0]  instruc_mask_singal,
    output wire [31:0] store_data_out,
    output wire [31:0] alu_out_address,
    output wire [31:0] pc_address,

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

    output wire        halt_hint,
    output wire        xif_idle
);

    // CV-X-IF bus (names as on both modules)
    wire        xif_issue_valid, xif_issue_ready, xif_issue_accept;
    wire [31:0] xif_issue_instr, xif_register_rs1, xif_register_rs2;
    wire [2:0]  xif_issue_id;
    wire [1:0]  xif_register_rs_valid;
    wire        xif_commit_valid, xif_commit_kill;
    wire        xif_mem_valid, xif_mem_ready, xif_mem_we, xif_mem_result_valid;
    wire [31:0] xif_mem_addr, xif_mem_wdata, xif_mem_result_rdata;
    wire [3:0]  xif_mem_be;
    wire        xif_result_valid, xif_result_ready, xif_result_we;
    wire [31:0] xif_result_data;

    core #(.XIF(1)) u_core (
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
        .pc_address(pc_address),

        .xif_issue_valid(xif_issue_valid),
        .xif_issue_ready(xif_issue_ready),
        .xif_issue_instr(xif_issue_instr),
        .xif_issue_id(xif_issue_id),
        .xif_issue_accept(xif_issue_accept),
        .xif_register_rs1(xif_register_rs1),
        .xif_register_rs2(xif_register_rs2),
        .xif_register_rs_valid(xif_register_rs_valid),
        .xif_commit_valid(xif_commit_valid),
        .xif_commit_kill(xif_commit_kill),
        .xif_mem_valid(xif_mem_valid),
        .xif_mem_ready(xif_mem_ready),
        .xif_mem_addr(xif_mem_addr),
        .xif_mem_we(xif_mem_we),
        .xif_mem_be(xif_mem_be),
        .xif_mem_wdata(xif_mem_wdata),
        .xif_mem_result_valid(xif_mem_result_valid),
        .xif_mem_result_rdata(xif_mem_result_rdata),
        .xif_result_valid(xif_result_valid),
        .xif_result_ready(xif_result_ready),
        .xif_result_data(xif_result_data),
        .xif_result_we(xif_result_we),

        .halt_hint(halt_hint)
    );

    matrix_xif_coproc u_coproc (
        .clk(clk),
        .rst(rst),

        .xif_issue_valid(xif_issue_valid),
        .xif_issue_ready(xif_issue_ready),
        .xif_issue_instr(xif_issue_instr),
        .xif_issue_id(xif_issue_id),
        .xif_issue_accept(xif_issue_accept),
        .xif_register_rs1(xif_register_rs1),
        .xif_register_rs2(xif_register_rs2),
        .xif_register_rs_valid(xif_register_rs_valid),
        .xif_commit_valid(xif_commit_valid),
        .xif_commit_kill(xif_commit_kill),
        .xif_mem_valid(xif_mem_valid),
        .xif_mem_ready(xif_mem_ready),
        .xif_mem_addr(xif_mem_addr),
        .xif_mem_we(xif_mem_we),
        .xif_mem_be(xif_mem_be),
        .xif_mem_wdata(xif_mem_wdata),
        .xif_mem_result_valid(xif_mem_result_valid),
        .xif_mem_result_rdata(xif_mem_result_rdata),
        .xif_result_valid(xif_result_valid),
        .xif_result_ready(xif_result_ready),
        .xif_result_data(xif_result_data),
        .xif_result_we(xif_result_we),

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

        .xif_idle(xif_idle)
    );
endmodule
