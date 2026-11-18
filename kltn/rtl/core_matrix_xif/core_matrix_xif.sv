// core_matrix_xif: RV32IF core (rtl/core_if_xif/Core.v, XIF = 1) + matrix_xif_adapter +
// matrix_core_v2 (rtl/matrix_if_xif copy, with mem_ready / mem_last), joined by CV-X-IF v1.0.0
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
// Simulation only: +define+XIF_CHECKER attaches tb/xif/xif_checker.sv to the bus and prints
// "XIF_CHECK_ERRORS <n>" at the end of the run when it found violations.
module core_matrix_xif
    import cvxif_pkg::*;
(
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

    // ------------------------------------------------------------------ CV-X-IF bus
    logic          issue_valid, issue_ready;
    x_issue_req_t  issue_req;
    x_issue_resp_t issue_resp;
    logic          register_valid, register_ready;
    x_register_t   register_req;
    logic          commit_valid;
    x_commit_t     commit;
    logic          mem_valid, mem_ready;
    x_mem_req_t    mem_req;
    x_mem_resp_t   mem_resp;
    logic          mem_result_valid;
    x_mem_result_t mem_result;
    logic          result_valid, result_ready;
    x_result_t     result;

    // Core side: flat signals, packed into the structs below.
    logic [31:0] core_issue_instr, core_rs1, core_rs2, core_mem_rdata;
    logic [2:0]  core_issue_id;
    logic [1:0]  core_rs_valid;
    logic        core_commit_kill;

    // Split = 0: the register interface shares the issue handshake.
    assign register_valid = issue_valid;

    assign issue_req.instr  = core_issue_instr;
    assign issue_req.hartid = '0;
    assign issue_req.id     = core_issue_id;

    assign register_req.hartid   = '0;
    assign register_req.id       = core_issue_id;
    assign register_req.rs       = {core_rs2, core_rs1};      // rs[0] = rs1, rs[1] = rs2
    assign register_req.rs_valid = core_rs_valid;

    // The core commits in the issue cycle, with the id it just issued.
    assign commit.hartid      = '0;
    assign commit.id          = core_issue_id;
    assign commit.commit_kill = core_commit_kill;

    // This core never reports memory exceptions or bus errors.
    assign mem_resp = '0;
    assign mem_result.hartid = '0;
    assign mem_result.id     = mem_req.id;
    assign mem_result.rdata  = core_mem_rdata;
    assign mem_result.err    = 1'b0;
    assign mem_result.dbg    = 1'b0;

    // The adapter is ready to issue only when idle (rs_valid is always 2'b11).
    assign xif_idle = issue_ready;

    // ------------------------------------------------------------------ core
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

        .xif_issue_valid(issue_valid),
        .xif_issue_ready(issue_ready),
        .xif_issue_instr(core_issue_instr),
        .xif_issue_id(core_issue_id),
        .xif_issue_accept(issue_resp.accept),
        .xif_register_rs1(core_rs1),
        .xif_register_rs2(core_rs2),
        .xif_register_rs_valid(core_rs_valid),
        .xif_commit_valid(commit_valid),
        .xif_commit_kill(core_commit_kill),
        .xif_mem_valid(mem_valid),
        .xif_mem_ready(mem_ready),
        .xif_mem_addr(mem_req.addr),
        .xif_mem_we(mem_req.we),
        .xif_mem_be(mem_req.be),
        .xif_mem_wdata(mem_req.wdata),
        .xif_mem_result_valid(mem_result_valid),
        .xif_mem_result_rdata(core_mem_rdata),
        .xif_result_valid(result_valid),
        .xif_result_ready(result_ready),
        .xif_result_data(result.data),
        .xif_result_we(result.we),

        .halt_hint(halt_hint)
    );

    // ------------------------------------------------------------------ adapter
    logic        m_valid, m_supported, m_wb_we;
    logic [31:0] m_insn, m_rs1, m_rs2, m_wb_data;
    logic [4:0]  m_wb_rd;
    logic        mm_request, mm_we, mm_last, mm_ready, mm_rvalid;
    logic [31:0] mm_addr, mm_wdata, mm_rdata;
    logic [3:0]  mm_wstrb;

    matrix_xif_adapter u_adapter (
        .clk(clk),
        .resetn(rst),
        .issue_valid(issue_valid),
        .issue_ready(issue_ready),
        .issue_req(issue_req),
        .issue_resp(issue_resp),
        .register_valid(register_valid),
        .register_ready(register_ready),
        .register_req(register_req),
        .commit_valid(commit_valid),
        .commit(commit),
        .mem_valid(mem_valid),
        .mem_ready(mem_ready),
        .mem_req(mem_req),
        .mem_resp(mem_resp),
        .mem_result_valid(mem_result_valid),
        .mem_result(mem_result),
        .result_valid(result_valid),
        .result_ready(result_ready),
        .result(result),

        .matrix_valid(m_valid),
        .matrix_insn(m_insn),
        .matrix_rs1(m_rs1),
        .matrix_rs2(m_rs2),
        .matrix_supported(m_supported),
        .matrix_done(matrix_done),
        .matrix_wb_we(m_wb_we),
        .matrix_wb_rd(m_wb_rd),
        .matrix_wb_data(m_wb_data),
        .matrix_mem_request(mm_request),
        .matrix_mem_we(mm_we),
        .matrix_mem_addr(mm_addr),
        .matrix_mem_wdata(mm_wdata),
        .matrix_mem_wstrb(mm_wstrb),
        .matrix_mem_last(mm_last),
        .matrix_mem_ready(mm_ready),
        .matrix_mem_rdata(mm_rdata),
        .matrix_mem_rvalid(mm_rvalid)
    );

    // ------------------------------------------------------------------ matrix unit
    matrix_core_v2 u_matrix (
        .clk(clk),
        .resetn(rst),
        .matrix_valid(m_valid),
        .matrix_insn(m_insn),
        .matrix_rs1(m_rs1),
        .matrix_rs2(m_rs2),
        .matrix_supported(m_supported),
        .matrix_busy(matrix_busy),
        .matrix_done(matrix_done),
        .matrix_wb_we(m_wb_we),
        .matrix_wb_rd(m_wb_rd),
        .matrix_wb_data(m_wb_data),
        .matrix_mem_request(mm_request),
        .matrix_mem_we(mm_we),
        .matrix_mem_addr(mm_addr),
        .matrix_mem_wdata(mm_wdata),
        .matrix_mem_wstrb(mm_wstrb),
        .matrix_mem_last(mm_last),
        .matrix_mem_ready(mm_ready),
        .matrix_mem_rdata(mm_rdata),
        .matrix_mem_rvalid(mm_rvalid),

        .host_reg_we(matrix_host_reg_we),
        .host_reg_id(matrix_host_reg_id),
        .host_reg_row_idx(matrix_host_reg_row_idx),
        .host_reg_beat_idx(matrix_host_reg_beat_idx),
        .host_reg_wdata(matrix_host_reg_wdata),
        .host_read_id(matrix_host_read_id),
        .host_read_row(matrix_host_read_row),
        .host_read_beat(matrix_host_read_beat),
        .host_reg_rdata(matrix_host_reg_rdata),

        .debug_mtilem(matrix_debug_mtilem),
        .debug_mtilen(matrix_debug_mtilen),
        .debug_mtilek(matrix_debug_mtilek)
    );

`ifdef XIF_CHECKER
    xif_checker u_chk (
        .clk(clk), .resetn(rst),
        .issue_valid(issue_valid), .issue_ready(issue_ready), .issue_req(issue_req), .issue_resp(issue_resp),
        .register_valid(register_valid), .register_ready(register_ready),
        .commit_valid(commit_valid), .commit(commit),
        .mem_valid(mem_valid), .mem_ready(mem_ready), .mem_req(mem_req),
        .mem_result_valid(mem_result_valid),
        .result_valid(result_valid), .result_ready(result_ready), .result(result));

    // Same checks as u_chk.final_check(). iverilog: a final block may not call a task, and
    // one with a named block and local variables does not run, so the variables are here.
    integer chk_open_ids, chk_i;
    final begin
        chk_open_ids = 0;
        for (chk_i = 0; chk_i < (1 << X_ID_WIDTH); chk_i = chk_i + 1)
            if (u_chk.issued[chk_i] || u_chk.accepted[chk_i]) chk_open_ids = chk_open_ids + 1;
        $display("XIF_CHECK summary: issue %0d accept %0d result %0d mem_req %0d mem_result %0d errors %0d",
                 u_chk.n_issue, u_chk.n_accept, u_chk.n_result, u_chk.n_mem_req, u_chk.n_mem_result, u_chk.errors);
        if (u_chk.errors != 0 || chk_open_ids != 0 || u_chk.mem_outstanding != 0)
            $display("XIF_CHECK_ERRORS errors=%0d unfinished_ids=%0d mem_outstanding=%0d",
                     u_chk.errors, chk_open_ids, u_chk.mem_outstanding);
    end
`endif
endmodule
