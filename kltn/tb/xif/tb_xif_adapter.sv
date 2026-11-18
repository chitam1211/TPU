`timescale 1ns / 1ps

// Testbench for matrix_xif_adapter + matrix_core_v2 (rtl/matrix_if_xif copy), without a CPU.
// A behavioural CPU drives the CV-X-IF bus; xif_checker watches it.
//
// Each round runs, with fresh random int8 data:
//   msettilem/n/k 4, 4, 16 (rs1)      mlae8 tr0, A      mlbe8 tr1, Bt     mzero acc0
//   mmacc.w.b acc0, tr0, tr1          mzero acc0 (commit_kill = 1, must have no effect)
//   msce32 acc0, C                    mmovw.x.m x10, acc0, idx    mmovw.x.m x0, acc0, idx
//   an unsupported 0x2B instruction (must be rejected, no result)
// and checks C = A * Bt^T in memory and the two mmovw.x.m results.
// Randomised: mem_ready, mem_result latency (1-10 cycles, in order), result_ready, commit delay.
//
// Usage: vvp tb_xif_adapter.out [+rounds=N] [+seed=S]   -> prints XIF_ADAPTER_PASS / FAIL
module tb_xif_adapter;
    import cvxif_pkg::*;

    localparam logic [6:0] OPC_MX = 7'h2B;
    localparam int A_BASE = 32'h1000, B_BASE = 32'h1100, C_BASE = 32'h1200, STRIDE = 16;

    logic clk = 0, resetn = 0;
    always #5 clk = ~clk;

    // Bus
    logic          issue_valid = 0, issue_ready;
    x_issue_req_t  issue_req = '0;
    x_issue_resp_t issue_resp;
    logic          register_valid, register_ready;
    x_register_t   register_req = '0;
    logic          commit_valid = 0;
    x_commit_t     commit = '0;
    logic          mem_valid, mem_ready = 0;
    x_mem_req_t    mem_req;
    x_mem_resp_t   mem_resp = '0;
    logic          mem_result_valid = 0;
    x_mem_result_t mem_result = '0;
    logic          result_valid, result_ready = 0;
    x_result_t     result;
    assign register_valid = issue_valid;

    // Adapter <-> matrix core
    logic        m_valid, m_supported, m_busy, m_done, m_wb_we;
    logic [31:0] m_insn, m_rs1, m_rs2, m_wb_data;
    logic [4:0]  m_wb_rd;
    logic        mm_req, mm_we, mm_last, mm_ready, mm_rvalid;
    logic [31:0] mm_addr, mm_wdata, mm_rdata;
    logic [3:0]  mm_wstrb;
    logic [31:0] dbg_m, dbg_n, dbg_k, host_rdata;

    matrix_xif_adapter u_adapter (
        .clk(clk), .resetn(resetn),
        .issue_valid(issue_valid), .issue_ready(issue_ready), .issue_req(issue_req), .issue_resp(issue_resp),
        .register_valid(register_valid), .register_ready(register_ready), .register_req(register_req),
        .commit_valid(commit_valid), .commit(commit),
        .mem_valid(mem_valid), .mem_ready(mem_ready), .mem_req(mem_req), .mem_resp(mem_resp),
        .mem_result_valid(mem_result_valid), .mem_result(mem_result),
        .result_valid(result_valid), .result_ready(result_ready), .result(result),
        .matrix_valid(m_valid), .matrix_insn(m_insn), .matrix_rs1(m_rs1), .matrix_rs2(m_rs2),
        .matrix_supported(m_supported), .matrix_done(m_done),
        .matrix_wb_we(m_wb_we), .matrix_wb_rd(m_wb_rd), .matrix_wb_data(m_wb_data),
        .matrix_mem_request(mm_req), .matrix_mem_we(mm_we), .matrix_mem_addr(mm_addr),
        .matrix_mem_wdata(mm_wdata), .matrix_mem_wstrb(mm_wstrb), .matrix_mem_last(mm_last),
        .matrix_mem_ready(mm_ready), .matrix_mem_rdata(mm_rdata), .matrix_mem_rvalid(mm_rvalid));

    matrix_core_v2 u_matrix (
        .clk(clk), .resetn(resetn),
        .matrix_valid(m_valid), .matrix_insn(m_insn), .matrix_rs1(m_rs1), .matrix_rs2(m_rs2),
        .matrix_supported(m_supported), .matrix_busy(m_busy), .matrix_done(m_done),
        .matrix_wb_we(m_wb_we), .matrix_wb_rd(m_wb_rd), .matrix_wb_data(m_wb_data),
        .matrix_mem_request(mm_req), .matrix_mem_we(mm_we), .matrix_mem_addr(mm_addr),
        .matrix_mem_wdata(mm_wdata), .matrix_mem_wstrb(mm_wstrb), .matrix_mem_last(mm_last),
        .matrix_mem_ready(mm_ready), .matrix_mem_rdata(mm_rdata), .matrix_mem_rvalid(mm_rvalid),
        .host_reg_we(1'b0), .host_reg_id(3'd0), .host_reg_row_idx(3'd0), .host_reg_beat_idx(3'd0),
        .host_reg_wdata(32'd0), .host_read_id(3'd0), .host_read_row(3'd0), .host_read_beat(3'd0),
        .host_reg_rdata(host_rdata), .debug_mtilem(dbg_m), .debug_mtilen(dbg_n), .debug_mtilek(dbg_k));

    xif_checker u_chk (
        .clk(clk), .resetn(resetn),
        .issue_valid(issue_valid), .issue_ready(issue_ready), .issue_req(issue_req), .issue_resp(issue_resp),
        .register_valid(register_valid), .register_ready(register_ready),
        .commit_valid(commit_valid), .commit(commit),
        .mem_valid(mem_valid), .mem_ready(mem_ready), .mem_req(mem_req),
        .mem_result_valid(mem_result_valid),
        .result_valid(result_valid), .result_ready(result_ready), .result(result));

    // ------------------------------------------------------------------ memory (16 KB)
    logic [31:0] mem [0:4095];
    logic [31:0] rq_data [$];     // mem_result data, in request order
    int          rq_time [$];     // cycle at which each result may be returned
    int          cycle = 0, last_time = 0;
    int          p_mem_ready = 60, p_result_ready = 60;   // percent

    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (resetn && mem_valid && mem_ready) begin
            int t;
            t = cycle + 1 + $urandom_range(0, 9);
            if (t < last_time) t = last_time;     // results stay in order
            last_time = t;
            if (mem_req.we) begin
                logic [31:0] bm;
                bm = {{8{mem_req.be[3]}}, {8{mem_req.be[2]}}, {8{mem_req.be[1]}}, {8{mem_req.be[0]}}};
                mem[mem_req.addr[13:2]] <= (mem[mem_req.addr[13:2]] & ~bm) | (mem_req.wdata & bm);
                rq_data.push_back(32'h0);
            end else begin
                rq_data.push_back(mem[mem_req.addr[13:2]]);
            end
            rq_time.push_back(t);
        end
    end

    // Drive at the negative edge so the DUT sees stable inputs at the positive edge.
    always @(negedge clk) begin
        mem_ready    <= ($urandom_range(0, 99) < p_mem_ready);
        result_ready <= ($urandom_range(0, 99) < p_result_ready);
        if (rq_time.size() != 0 && rq_time[0] <= cycle) begin
            mem_result_valid <= 1'b1;
            mem_result.rdata <= rq_data[0];
            rq_time.pop_front();
            rq_data.pop_front();
        end else begin
            mem_result_valid <= 1'b0;
        end
    end

    // ------------------------------------------------------------------ CPU model
    int    errors = 0;
    x_id_t next_id = '0;

    // Offload one instruction. kill: commit_kill; returns accept and the result (if any).
    task automatic offload(input logic [31:0] instr, input logic [31:0] rs1, input logic [31:0] rs2,
                           input logic kill, output logic accepted, output x_result_t res);
        int delay = $urandom_range(0, 3);
        x_id_t id = next_id;
        next_id++;
        @(negedge clk);
        issue_valid           <= 1'b1;
        issue_req.instr       <= instr;
        issue_req.id          <= id;
        register_req.hartid   <= '0;
        register_req.id       <= id;
        register_req.rs[0]    <= rs1;
        register_req.rs[1]    <= rs2;
        register_req.rs_valid <= 2'b11;
        // Commit in the issue cycle when delay = 0 (as the core does), else later.
        commit_valid          <= (delay == 0);
        commit.id             <= id;
        commit.commit_kill    <= kill;
        @(posedge clk);
        while (!issue_ready) @(posedge clk);
        accepted = issue_resp.accept;
        @(negedge clk);
        issue_valid  <= 1'b0;
        commit_valid <= 1'b0;
        if (delay != 0) begin
            repeat (delay - 1) @(negedge clk);
            commit_valid <= 1'b1;
            @(negedge clk);
            commit_valid <= 1'b0;
        end
        res = '0;
        if (accepted && !kill) begin
            @(posedge clk);
            while (!(result_valid && result_ready)) @(posedge clk);
            res = result;
            if (res.id !== id) begin
                errors++;
                $display("FAIL result id %0d expected %0d", res.id, id);
            end
        end
    endtask

    function automatic logic [31:0] r_type(input logic [6:0] f7, input logic [4:0] rs2,
                                           input logic [4:0] rs1, input logic [4:0] rd);
        return {f7, rs2, rs1, 3'b000, rd, OPC_MX};
    endfunction
    function automatic logic [31:0] cfg_rs(input logic [3:0] func4);
        return {func4, 2'b00, 1'b1, 5'd0, 5'd1, 3'b000, 5'd0, OPC_MX};
    endfunction
    function automatic logic [31:0] mls(input logic [3:0] func4, input logic st, input logic [1:0] dsize,
                                        input logic [2:0] md);
        return {func4, 2'b01, st, 5'd2, 5'd1, 3'b000, dsize, md, OPC_MX};
    endfunction
    function automatic logic [31:0] mmovw_x_m(input logic [4:0] rd, input logic [2:0] ms2);
        return {4'b0010, 2'b11, 1'b0, 2'b10, ms2, 5'd6, 3'b000, rd, OPC_MX};
    endfunction
    localparam logic [31:0] MZERO_ACC0 = {4'b0000, 2'b11, 14'd0, 5'd4, OPC_MX};
    localparam logic [31:0] MMACC_ACC0 = {4'b0001, 2'b10, 3'd3, 3'd1, 2'b00, 3'd0, 3'b000, 2'b10, 3'd4, OPC_MX};
    localparam logic [31:0] UNSUPPORTED = {25'h1ABCDE, OPC_MX} | (32'h7 << 12);   // func3 = 7

    logic        acc;
    x_result_t   res;
    logic [7:0]  a [4][16], bt [4][16];
    logic [31:0] c_exp [4][4];
    int          rounds = 20, seed = 1;

    task automatic expect_accept(input string name, input logic got, input logic want);
        if (got !== want) begin
            errors++;
            $display("FAIL %s: accept %0d expected %0d", name, got, want);
        end
    endtask

    initial begin
        if ($value$plusargs("rounds=%d", rounds)) ;
        if ($value$plusargs("seed=%d", seed)) seed = $urandom(seed);
        for (int i = 0; i < 4096; i++) mem[i] = '0;
        repeat (4) @(posedge clk);
        resetn = 1;

        for (int r = 0; r < rounds; r++) begin
            // Round 0 runs with ready always 1 (the core's case), later rounds randomly.
            p_mem_ready    = (r == 0) ? 100 : 30 + 10 * (r % 7);
            p_result_ready = (r == 0) ? 100 : 30 + 10 * ((r + 3) % 7);
            for (int i = 0; i < 4; i++)
                for (int k = 0; k < 16; k++) begin
                    a[i][k]  = $urandom;
                    bt[i][k] = $urandom;
                    mem[(A_BASE + STRIDE * i + k) >> 2][8 * (k % 4) +: 8] = a[i][k];
                    mem[(B_BASE + STRIDE * i + k) >> 2][8 * (k % 4) +: 8] = bt[i][k];
                end
            for (int i = 0; i < 4; i++)
                for (int j = 0; j < 4; j++) begin
                    int s;
                    s = 0;
                    for (int k = 0; k < 16; k++)
                        s += int'($signed(a[i][k])) * int'($signed(bt[j][k]));
                    c_exp[i][j] = s;
                end

            offload(cfg_rs(4'd2), 4, 0, 0, acc, res);  expect_accept("msettilem", acc, 1);
            offload(cfg_rs(4'd3), 4, 0, 0, acc, res);  expect_accept("msettilen", acc, 1);
            offload(cfg_rs(4'd1), 16, 0, 0, acc, res); expect_accept("msettilek", acc, 1);
            offload(mls(4'd0, 0, 2'b00, 3'd0), A_BASE, STRIDE, 0, acc, res); expect_accept("mlae8", acc, 1);
            offload(mls(4'd1, 0, 2'b00, 3'd1), B_BASE, STRIDE, 0, acc, res); expect_accept("mlbe8", acc, 1);
            offload(MZERO_ACC0, 0, 0, 0, acc, res);    expect_accept("mzero", acc, 1);
            offload(MMACC_ACC0, 0, 0, 0, acc, res);    expect_accept("mmacc", acc, 1);
            offload(MZERO_ACC0, 0, 0, 1, acc, res);    expect_accept("mzero killed", acc, 1);
            offload(mls(4'd2, 1, 2'b10, 3'd4), C_BASE, STRIDE, 0, acc, res); expect_accept("msce32", acc, 1);
            begin
                int idx;
                idx = $urandom_range(0, 15);
                offload(mmovw_x_m(5'd10, 3'd4), idx, 0, 0, acc, res);
                expect_accept("mmovw.x.m x10", acc, 1);
                if (res.we !== 1 || res.rd !== 10 || res.data !== c_exp[idx / 4][idx % 4]) begin
                    errors++;
                    $display("FAIL mmovw.x.m x10, acc0[%0d]: we %0d rd %0d data %08x expected %08x",
                             idx, res.we, res.rd, res.data, c_exp[idx / 4][idx % 4]);
                end
                offload(mmovw_x_m(5'd0, 3'd4), idx, 0, 0, acc, res);
                expect_accept("mmovw.x.m x0", acc, 1);
                if (res.we !== 0) begin
                    errors++;
                    $display("FAIL mmovw.x.m x0: we = 1");
                end
            end
            offload(UNSUPPORTED, 0, 0, 0, acc, res);   expect_accept("unsupported", acc, 0);

            repeat (8) @(posedge clk);   // last mem_result of msce32 has arrived long ago
            for (int i = 0; i < 4; i++)
                for (int j = 0; j < 4; j++)
                    if (mem[(C_BASE + STRIDE * i + 4 * j) >> 2] !== c_exp[i][j]) begin
                        errors++;
                        $display("FAIL round %0d C[%0d][%0d] = %08x expected %08x", r, i, j,
                                 mem[(C_BASE + STRIDE * i + 4 * j) >> 2], c_exp[i][j]);
                    end
            for (int i = 0; i < 4; i++)                 // clear C for the next round
                for (int j = 0; j < 4; j++) mem[(C_BASE + STRIDE * i + 4 * j) >> 2] = 32'hDEADBEEF;
        end

        u_chk.final_check();
        if (errors == 0 && u_chk.errors == 0) $display("XIF_ADAPTER_PASS rounds=%0d cycles=%0d", rounds, cycle);
        else $display("XIF_ADAPTER_FAIL errors=%0d checker=%0d", errors, u_chk.errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("XIF_ADAPTER_FAIL timeout");
        $finish;
    end
endmodule
