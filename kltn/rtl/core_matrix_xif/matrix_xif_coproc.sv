// matrix_xif_coproc: the matrix coprocessor as seen over CV-X-IF v1.0.0 (docs/xif_design.md):
// matrix_xif_adapter + matrix_core_v2 (rtl/matrix_if_xif copy, with mem_ready / mem_last).
// Wiring only, no logic of its own.
//
// The CV-X-IF ports are flat and carry the names of the core's ports (rtl/core_if_xif/Core.v,
// xif_*), with the directions reversed, so core_matrix_xif connects the two name for name and
// the out-of-context timing budgets (fpga/kv260/ooc_budget.tcl) use one name per signal. The
// structs of cvxif_pkg are packed here; fields the core does not drive are constants.
//
// Simulation only: +define+XIF_CHECKER attaches tb/xif/xif_checker.sv to the bus and prints
// "XIF_CHECK summary ..." at the end of the run, and "XIF_CHECK_ERRORS ..." on violations.
module matrix_xif_coproc
    import cvxif_pkg::*;
(
    input  wire        clk,
    input  wire        rst,                     // active low, as the core

    // CV-X-IF: issue + register (split = 0: one handshake), commit
    input  wire        xif_issue_valid,
    output wire        xif_issue_ready,
    input  wire [31:0] xif_issue_instr,
    input  wire [2:0]  xif_issue_id,            // also register.id and commit.id
    output wire        xif_issue_accept,
    input  wire [31:0] xif_register_rs1,
    input  wire [31:0] xif_register_rs2,
    input  wire [1:0]  xif_register_rs_valid,
    input  wire        xif_commit_valid,
    input  wire        xif_commit_kill,
    // CV-X-IF: memory request / result
    output wire        xif_mem_valid,
    input  wire        xif_mem_ready,
    output wire [31:0] xif_mem_addr,
    output wire        xif_mem_we,
    output wire [3:0]  xif_mem_be,
    output wire [31:0] xif_mem_wdata,
    input  wire        xif_mem_result_valid,
    input  wire [31:0] xif_mem_result_rdata,
    // CV-X-IF: result
    output wire        xif_result_valid,
    input  wire        xif_result_ready,
    output wire [31:0] xif_result_data,
    output wire        xif_result_we,

    // Matrix register file host port and debug outputs (as core_matrix.v)
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

    output wire        xif_idle                 // adapter idle: no matrix instruction in flight
);

    // ------------------------------------------------------------------ CV-X-IF structs
    logic          issue_ready;
    x_issue_req_t  issue_req;
    x_issue_resp_t issue_resp;
    logic          register_ready;
    x_register_t   register_req;
    x_commit_t     commit;
    logic          mem_valid;
    x_mem_req_t    mem_req;
    x_mem_resp_t   mem_resp;
    x_mem_result_t mem_result;
    logic          result_valid;
    x_result_t     result;

    assign issue_req.instr  = xif_issue_instr;
    assign issue_req.hartid = '0;
    assign issue_req.id     = xif_issue_id;

    assign register_req.hartid   = '0;
    assign register_req.id       = xif_issue_id;
    assign register_req.rs       = {xif_register_rs2, xif_register_rs1};   // rs[0] = rs1
    assign register_req.rs_valid = xif_register_rs_valid;

    // The core commits in the issue cycle, with the id it just issued.
    assign commit.hartid      = '0;
    assign commit.id          = xif_issue_id;
    assign commit.commit_kill = xif_commit_kill;

    // The core never reports memory exceptions or bus errors.
    assign mem_resp          = '0;
    assign mem_result.hartid = '0;
    assign mem_result.id     = mem_req.id;
    assign mem_result.rdata  = xif_mem_result_rdata;
    assign mem_result.err    = 1'b0;
    assign mem_result.dbg    = 1'b0;

    assign xif_issue_ready  = issue_ready;
    assign xif_issue_accept = issue_resp.accept;
    assign xif_mem_valid    = mem_valid;
    assign xif_mem_addr     = mem_req.addr;
    assign xif_mem_we       = mem_req.we;
    assign xif_mem_be       = mem_req.be;
    assign xif_mem_wdata    = mem_req.wdata;
    assign xif_result_valid = result_valid;
    assign xif_result_data  = result.data;
    assign xif_result_we    = result.we;

    // The adapter is ready to issue only when idle (rs_valid is always 2'b11 from this core).
    assign xif_idle = issue_ready;

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
        .issue_valid(xif_issue_valid),
        .issue_ready(issue_ready),
        .issue_req(issue_req),
        .issue_resp(issue_resp),
        .register_valid(xif_issue_valid),        // split = 0
        .register_ready(register_ready),
        .register_req(register_req),
        .commit_valid(xif_commit_valid),
        .commit(commit),
        .mem_valid(mem_valid),
        .mem_ready(xif_mem_ready),
        .mem_req(mem_req),
        .mem_resp(mem_resp),
        .mem_result_valid(xif_mem_result_valid),
        .mem_result(mem_result),
        .result_valid(result_valid),
        .result_ready(xif_result_ready),
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
        .issue_valid(xif_issue_valid), .issue_ready(issue_ready), .issue_req(issue_req), .issue_resp(issue_resp),
        .register_valid(xif_issue_valid), .register_ready(register_ready),
        .commit_valid(xif_commit_valid), .commit(commit),
        .mem_valid(mem_valid), .mem_ready(xif_mem_ready), .mem_req(mem_req),
        .mem_result_valid(xif_mem_result_valid),
        .result_valid(result_valid), .result_ready(xif_result_ready), .result(result));

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
