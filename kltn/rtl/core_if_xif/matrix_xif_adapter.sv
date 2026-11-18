// CV-X-IF adapter for matrix_core_v2 (docs/xif_design.md, section 6.2).
//
// The CPU side is the CV-X-IF bus of cvxif_pkg (split = 0: the register interface shares the
// issue handshake). The matrix side connects to matrix_core_v2 from rtl/matrix_if_xif, which
// adds matrix_mem_ready / matrix_mem_last to the original ports.
//
// One instruction at a time:
//   IDLE        issue_ready = 1, accept = matrix_supported (decoded from issue_req.instr)
//   WAIT_COMMIT accepted, commit not seen yet (the core sends it in the issue cycle, so this
//               state is only for other CPUs and the testbench)
//   START       matrix_valid = 1 for one cycle; insn / rs come from registers latched at issue
//   BUSY        memory requests are passed through; matrix_done gives the result
//   DRAIN       done, but mem_result of an earlier request is still outstanding
//   RESULT      result held until result_ready
// The adapter waits for commit before starting: a matrix instruction writes memory and the
// matrix registers and cannot be undone. A killed instruction goes back to IDLE with no result.
// mem_resp.exc and mem_result.err are not used: this core never reports memory errors.
module matrix_xif_adapter
    import cvxif_pkg::*;
(
    input  logic          clk,
    input  logic          resetn,

    // Issue and register
    input  logic          issue_valid,
    output logic          issue_ready,
    input  x_issue_req_t  issue_req,
    output x_issue_resp_t issue_resp,
    input  logic          register_valid,
    output logic          register_ready,
    input  x_register_t   register_req,

    // Commit
    input  logic          commit_valid,
    input  x_commit_t     commit,

    // Memory request / response and memory result
    output logic          mem_valid,
    input  logic          mem_ready,
    output x_mem_req_t    mem_req,
    input  x_mem_resp_t   mem_resp,
    input  logic          mem_result_valid,
    input  x_mem_result_t mem_result,

    // Result
    output logic          result_valid,
    input  logic          result_ready,
    output x_result_t     result,

    // matrix_core_v2
    output logic          matrix_valid,
    output logic [31:0]   matrix_insn,
    output logic [31:0]   matrix_rs1,
    output logic [31:0]   matrix_rs2,
    input  logic          matrix_supported,
    input  logic          matrix_done,
    input  logic          matrix_wb_we,
    input  logic [4:0]    matrix_wb_rd,
    input  logic [31:0]   matrix_wb_data,
    input  logic          matrix_mem_request,
    input  logic          matrix_mem_we,
    input  logic [31:0]   matrix_mem_addr,
    input  logic [31:0]   matrix_mem_wdata,
    input  logic [3:0]    matrix_mem_wstrb,
    input  logic          matrix_mem_last,
    output logic          matrix_mem_ready,
    output logic [31:0]   matrix_mem_rdata,
    output logic          matrix_mem_rvalid
);

    typedef enum logic [2:0] {
        S_IDLE        = 3'd0,
        S_WAIT_COMMIT = 3'd1,
        S_START       = 3'd2,
        S_BUSY        = 3'd3,
        S_DRAIN       = 3'd4,
        S_RESULT      = 3'd5
    } state_t;

    state_t      state;
    logic [31:0] insn_q, rs1_q, rs2_q;
    x_id_t       id_q;
    logic        res_we_q;
    logic [4:0]  res_rd_q;
    logic [31:0] res_data_q;
    logic [2:0]  outstanding;     // memory requests whose mem_result has not arrived

    // Source registers and GPR write, from the encoding (same rules as core_matrix.v):
    // msettile{k,m,n} (rs1), load/store (rs1, rs2), mmov*.x.m (rs1), mmov*.m.x / mdup (rs1, rs2).
    // Only mmovw.x.m writes a GPR: the configuration instructions require rd = 0.
    logic [31:0] ins;
    logic        uses_rs1, uses_rs2, writes_gpr, is_ls;
    assign ins = issue_req.instr;
    always_comb begin
        uses_rs1   = (ins[14:12] == 3'b000) &&
                     ((ins[27:26] == 2'b00 && ins[25]) || ins[27:26] == 2'b01 ||
                      (ins[27:26] == 2'b11 && (ins[31:28] == 4'b0010 || ins[31:28] == 4'b0011)));
        uses_rs2   = (ins[14:12] == 3'b000) &&
                     (ins[27:26] == 2'b01 || (ins[27:26] == 2'b11 && ins[31:28] == 4'b0011));
        writes_gpr = (ins[14:12] == 3'b000) && (ins[27:26] == 2'b11) && (ins[31:28] == 4'b0010) &&
                     (ins[11:7] != 5'd0);
        is_ls      = (ins[14:12] == 3'b000) && (ins[27:26] == 2'b01);
    end

    // Issue. While IDLE the matrix core sees issue_req.instr, so matrix_supported decodes it.
    logic                accept;
    logic [X_NUM_RS-1:0] reads;
    assign accept = matrix_supported;
    assign reads  = accept ? {uses_rs2, uses_rs1} : '0;

    assign issue_ready    = (state == S_IDLE) && ((register_req.rs_valid & reads) == reads);
    assign register_ready = issue_ready;
    assign issue_resp.accept        = accept;
    assign issue_resp.writeback     = accept && writes_gpr;
    assign issue_resp.register_read = reads;
    assign issue_resp.loadstore     = accept && is_ls;

    wire issue_fire  = issue_valid && issue_ready && accept;
    wire commit_this = commit_valid && (commit.id == (state == S_IDLE ? issue_req.id : id_q));

    // Matrix core inputs.
    assign matrix_valid = (state == S_START);
    assign matrix_insn  = (state == S_IDLE) ? issue_req.instr : insn_q;
    assign matrix_rs1   = rs1_q;
    assign matrix_rs2   = rs2_q;

    // Memory: requests pass through while BUSY; every request gets one mem_result, in order.
    // The tile load/store unit only reads mem_result in its load-wait state, so the results of
    // stores reach it harmlessly; the adapter only counts them.
    wire mem_fire = mem_valid && mem_ready;
    assign mem_valid         = (state == S_BUSY) && matrix_mem_request;
    assign matrix_mem_ready  = (state == S_BUSY) && mem_ready;
    assign matrix_mem_rvalid = mem_result_valid;
    assign matrix_mem_rdata  = mem_result.rdata;

    assign mem_req.hartid = '0;
    assign mem_req.id     = id_q;
    assign mem_req.addr   = matrix_mem_addr;
    assign mem_req.mode   = 2'b11;
    assign mem_req.we     = matrix_mem_we;
    assign mem_req.size   = 3'd2;
    assign mem_req.be     = matrix_mem_we ? matrix_mem_wstrb : 4'b1111;
    assign mem_req.attr   = 2'b00;
    assign mem_req.wdata  = matrix_mem_wdata;
    assign mem_req.last   = matrix_mem_last;
    assign mem_req.spec   = 1'b0;

    wire [2:0] outstanding_next = outstanding + {2'b0, mem_fire} - {2'b0, mem_result_valid};

    // Result: straight from matrix_done when every mem_result is in, else from the registers.
    wire done_now = (state == S_BUSY) && matrix_done && (outstanding_next == 3'd0);
    assign result_valid  = done_now || (state == S_RESULT);
    assign result.hartid = '0;
    assign result.id     = id_q;
    assign result.data   = done_now ? matrix_wb_data : res_data_q;
    assign result.rd     = done_now ? matrix_wb_rd   : res_rd_q;
    assign result.we     = done_now ? matrix_wb_we   : res_we_q;
    assign result.exc     = 1'b0;
    assign result.exccode = '0;
    assign result.err     = 1'b0;
    assign result.dbg     = 1'b0;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            state       <= S_IDLE;
            insn_q      <= '0;
            rs1_q       <= '0;
            rs2_q       <= '0;
            id_q        <= '0;
            res_we_q    <= 1'b0;
            res_rd_q    <= '0;
            res_data_q  <= '0;
            outstanding <= '0;
        end else begin
            outstanding <= outstanding_next;

            unique case (state)
                S_IDLE: if (issue_fire) begin
                    insn_q <= issue_req.instr;
                    rs1_q  <= register_req.rs[0];
                    rs2_q  <= register_req.rs[1];
                    id_q   <= issue_req.id;
                    if (commit_this) state <= commit.commit_kill ? S_IDLE : S_START;
                    else             state <= S_WAIT_COMMIT;
                end
                S_WAIT_COMMIT: if (commit_this) state <= commit.commit_kill ? S_IDLE : S_START;
                S_START: state <= S_BUSY;
                S_BUSY: if (matrix_done) begin
                    res_we_q   <= matrix_wb_we;
                    res_rd_q   <= matrix_wb_rd;
                    res_data_q <= matrix_wb_data;
                    if (!done_now)         state <= S_DRAIN;
                    else if (result_ready) state <= S_IDLE;
                    else                   state <= S_RESULT;
                end
                S_DRAIN:  if (outstanding_next == 3'd0) state <= S_RESULT;
                S_RESULT: if (result_ready) state <= S_IDLE;
                default:  state <= S_IDLE;
            endcase
        end
    end

endmodule
