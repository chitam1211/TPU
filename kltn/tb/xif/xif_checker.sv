// CV-X-IF protocol checker (docs/xif_design.md, section 8). Connects to the bus between a CPU
// and a coprocessor, only observes. Each violation prints "XIF_CHECK <rule>: ..." and
// increments `errors`; the testbench reads `errors` (and calls final_check) at the end.
//
// Rules (configuration of cvxif_pkg: split = 0, one hart):
//   1 issue_req, mem_req and result hold their value while valid && !ready
//   2 register_valid == issue_valid, register_ready == issue_ready
//   3 one result per accepted, committed (not killed) instruction; none otherwise
//   4 result only after the commit of its id; commit only for an issued id
//   5 result.we == issue_resp.writeback of that instruction
//   6 mem_req only for an accepted, committed instruction with loadstore = 1
//   7 one mem_result per mem_req, never more results than requests
module xif_checker
    import cvxif_pkg::*;
(
    input logic          clk,
    input logic          resetn,
    input logic          issue_valid,
    input logic          issue_ready,
    input x_issue_req_t  issue_req,
    input x_issue_resp_t issue_resp,
    input logic          register_valid,
    input logic          register_ready,
    input logic          commit_valid,
    input x_commit_t     commit,
    input logic          mem_valid,
    input logic          mem_ready,
    input x_mem_req_t    mem_req,
    input logic          mem_result_valid,
    input logic          result_valid,
    input logic          result_ready,
    input x_result_t     result
);

    localparam int NID = 1 << X_ID_WIDTH;

    int errors = 0;
    int n_issue = 0, n_accept = 0, n_kill = 0, n_result = 0, n_mem_req = 0, n_mem_result = 0;

    // Per id: issued (waiting for commit), accepted, committed, writeback, loadstore.
    logic issued    [NID];
    logic accepted  [NID];
    logic committed [NID];
    logic wb        [NID];
    logic ls        [NID];

    logic          prev_issue_stall, prev_mem_stall, prev_result_stall;
    x_issue_req_t  prev_issue_req;
    x_mem_req_t    prev_mem_req;
    x_result_t     prev_result;
    int            mem_outstanding;

    task automatic fail(input string rule, input string msg);
        errors++;
        $display("XIF_CHECK %s: %s (t=%0t)", rule, msg, $time);
    endtask

    always @(posedge clk) begin
        if (!resetn) begin
            for (int i = 0; i < NID; i++) begin
                issued[i] = 0; accepted[i] = 0; committed[i] = 0; wb[i] = 0; ls[i] = 0;
            end
            prev_issue_stall = 0; prev_mem_stall = 0; prev_result_stall = 0;
            mem_outstanding = 0;
        end else begin
            // 1: stability
            if (prev_issue_stall && (!issue_valid || issue_req !== prev_issue_req))
                fail("1", "issue_req changed or issue_valid dropped before issue_ready");
            if (prev_mem_stall && (!mem_valid || mem_req !== prev_mem_req))
                fail("1", "mem_req changed or mem_valid dropped before mem_ready");
            if (prev_result_stall && (!result_valid || result !== prev_result))
                fail("1", "result changed or result_valid dropped before result_ready");

            // 2: split = 0
            if (register_valid !== issue_valid) fail("2", "register_valid != issue_valid");
            if (register_ready !== issue_ready) fail("2", "register_ready != issue_ready");

            // Issue
            if (issue_valid && issue_ready) begin
                n_issue++;
                if (issued[issue_req.id] || accepted[issue_req.id])
                    fail("4", $sformatf("issue of id %0d which is still in flight", issue_req.id));
                issued[issue_req.id]   = 1;
                accepted[issue_req.id] = issue_resp.accept;
                wb[issue_req.id]       = issue_resp.writeback;
                ls[issue_req.id]       = issue_resp.loadstore;
                if (!issue_resp.accept && (issue_resp.writeback || issue_resp.loadstore || issue_resp.register_read != 0))
                    fail("3", "rejected instruction with writeback/loadstore/register_read set");
                n_accept += issue_resp.accept;
            end

            // Commit (may be in the issue cycle)
            if (commit_valid) begin
                if (!issued[commit.id] || committed[commit.id])
                    fail("4", $sformatf("commit of id %0d that is not waiting for commit", commit.id));
                if (!accepted[commit.id] || commit.commit_kill) begin
                    n_kill += accepted[commit.id] && commit.commit_kill;
                    issued[commit.id] = 0; accepted[commit.id] = 0;   // no result expected
                end else begin
                    committed[commit.id] = 1;
                end
            end

            // 6, 7: memory
            if (mem_valid && mem_ready) begin
                n_mem_req++;
                mem_outstanding++;
                if (!(accepted[mem_req.id] && committed[mem_req.id] && ls[mem_req.id]))
                    fail("6", $sformatf("mem_req for id %0d that is not a committed load/store", mem_req.id));
            end
            if (mem_result_valid) begin
                n_mem_result++;
                if (mem_outstanding == 0) fail("7", "mem_result without a mem_req");
                else mem_outstanding--;
            end

            // 3, 4, 5: result
            if (result_valid && result_ready) begin
                n_result++;
                if (!accepted[result.id] || !committed[result.id])
                    fail("4", $sformatf("result for id %0d that is not accepted and committed", result.id));
                else if (result.we !== wb[result.id])
                    fail("5", $sformatf("result.we %0d but writeback %0d (id %0d)", result.we, wb[result.id], result.id));
                if (mem_outstanding != 0)
                    fail("7", "result before every mem_result of the instruction");
                issued[result.id] = 0; accepted[result.id] = 0; committed[result.id] = 0;
            end

            prev_issue_stall  = issue_valid && !issue_ready;
            prev_mem_stall    = mem_valid && !mem_ready;
            prev_result_stall = result_valid && !result_ready;
            prev_issue_req    = issue_req;
            prev_mem_req      = mem_req;
            prev_result       = result;
        end
    end

    // Called by the testbench when the bus is idle: nothing may still be waiting.
    task automatic final_check();
        for (int i = 0; i < NID; i++)
            if (issued[i] || accepted[i])
                fail("3", $sformatf("id %0d issued but never finished (no commit or no result)", i));
        if (mem_outstanding != 0) fail("7", $sformatf("%0d mem_result missing", mem_outstanding));
        $display("XIF_CHECK summary: issue %0d accept %0d kill %0d result %0d mem_req %0d mem_result %0d errors %0d",
                 n_issue, n_accept, n_kill, n_result, n_mem_req, n_mem_result, errors);
    endtask

endmodule
