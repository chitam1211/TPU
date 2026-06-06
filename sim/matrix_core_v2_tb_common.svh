localparam logic [6:0] OPCODE_MATRIX = 7'b0101011;

logic clk = 1'b0;
logic resetn;

logic        matrix_valid;
logic [31:0] matrix_insn;
logic [31:0] matrix_rs1;
logic [31:0] matrix_rs2;
logic        matrix_supported;
logic        matrix_busy;
logic        matrix_done;
logic        matrix_wb_we;
logic [4:0]  matrix_wb_rd;
logic [31:0] matrix_wb_data;

logic        matrix_mem_request;
logic        matrix_mem_we;
logic [31:0] matrix_mem_addr;
logic [31:0] matrix_mem_wdata;
logic [3:0]  matrix_mem_wstrb;
logic [31:0] matrix_mem_rdata;
logic        matrix_mem_rvalid;

logic        host_reg_we;
logic [2:0]  host_reg_id;
logic [2:0]  host_reg_row_idx;
logic [2:0]  host_reg_beat_idx;
logic [31:0] host_reg_wdata;
logic [2:0]  host_read_id;
logic [2:0]  host_read_row;
logic [2:0]  host_read_beat;
logic [31:0] host_reg_rdata;

logic [31:0] debug_mtilem;
logic [31:0] debug_mtilen;
logic [31:0] debug_mtilek;

logic [31:0] dmem [0:255];
int errors;

always #5 clk = ~clk;

matrix_core_v2 uut (
    .clk(clk),
    .resetn(resetn),
    .matrix_valid(matrix_valid),
    .matrix_insn(matrix_insn),
    .matrix_rs1(matrix_rs1),
    .matrix_rs2(matrix_rs2),
    .matrix_supported(matrix_supported),
    .matrix_busy(matrix_busy),
    .matrix_done(matrix_done),
    .matrix_wb_we(matrix_wb_we),
    .matrix_wb_rd(matrix_wb_rd),
    .matrix_wb_data(matrix_wb_data),
    .matrix_mem_request(matrix_mem_request),
    .matrix_mem_we(matrix_mem_we),
    .matrix_mem_addr(matrix_mem_addr),
    .matrix_mem_wdata(matrix_mem_wdata),
    .matrix_mem_wstrb(matrix_mem_wstrb),
    .matrix_mem_rdata(matrix_mem_rdata),
    .matrix_mem_rvalid(matrix_mem_rvalid),
    .host_reg_we(host_reg_we),
    .host_reg_id(host_reg_id),
    .host_reg_row_idx(host_reg_row_idx),
    .host_reg_beat_idx(host_reg_beat_idx),
    .host_reg_wdata(host_reg_wdata),
    .host_read_id(host_read_id),
    .host_read_row(host_read_row),
    .host_read_beat(host_read_beat),
    .host_reg_rdata(host_reg_rdata),
    .debug_mtilem(debug_mtilem),
    .debug_mtilen(debug_mtilen),
    .debug_mtilek(debug_mtilek)
);

always_ff @(posedge clk) begin
    if (!resetn) begin
        matrix_mem_rvalid <= 1'b0;
        matrix_mem_rdata  <= 32'b0;
    end else begin
        matrix_mem_rvalid <= 1'b0;

        if (matrix_mem_request && matrix_mem_we) begin
            if (matrix_mem_wstrb[0]) dmem[matrix_mem_addr[9:2]][7:0]   <= matrix_mem_wdata[7:0];
            if (matrix_mem_wstrb[1]) dmem[matrix_mem_addr[9:2]][15:8]  <= matrix_mem_wdata[15:8];
            if (matrix_mem_wstrb[2]) dmem[matrix_mem_addr[9:2]][23:16] <= matrix_mem_wdata[23:16];
            if (matrix_mem_wstrb[3]) dmem[matrix_mem_addr[9:2]][31:24] <= matrix_mem_wdata[31:24];
        end

        if (matrix_mem_request && !matrix_mem_we) begin
            matrix_mem_rdata  <= dmem[matrix_mem_addr[9:2]];
            matrix_mem_rvalid <= 1'b1;
        end
    end
end

function automatic logic [31:0] enc_matrix(
    input logic [3:0] func4,
    input logic [1:0] uop,
    input logic [2:0] ctrl,
    input logic [2:0] ms2,
    input logic [1:0] s_size,
    input logic [2:0] ms1,
    input logic [2:0] func3,
    input logic [1:0] d_size,
    input logic [2:0] md
);
    enc_matrix = {func4, uop, ctrl, ms2, s_size, ms1, func3, d_size, md, OPCODE_MATRIX};
endfunction

function automatic logic [31:0] enc_cfg_reg(input logic [3:0] func4);
    enc_cfg_reg = enc_matrix(func4, 2'b00, 3'b100, 3'd0, 2'b00, 3'd0, 3'b000, 2'b00, 3'd0);
endfunction

function automatic logic [31:0] enc_ls(
    input logic [3:0] matrix_sel,
    input logic       is_store,
    input logic [1:0] elem_size,
    input logic [2:0] md
);
    enc_ls = enc_matrix(matrix_sel, 2'b01, {is_store, 2'b00}, 3'd0, 2'b00, 3'd0, 3'b000, elem_size, md);
endfunction

function automatic logic [31:0] enc_matmul(
    input logic [2:0] size_sup,
    input logic [2:0] ms1,
    input logic [2:0] ms2,
    input logic [2:0] md
);
    enc_matmul = enc_matrix(4'b0001, 2'b10, size_sup, ms2, 2'b00, ms1, 3'b000, 2'b10, md);
endfunction

function automatic logic [31:0] enc_misc(
    input logic [3:0] func4,
    input logic [2:0] ctrl,
    input logic [2:0] ms1,
    input logic [2:0] ms2,
    input logic [1:0] s_size,
    input logic [1:0] d_size,
    input logic [2:0] md
);
    enc_misc = enc_matrix(func4, 2'b11, ctrl, ms2, s_size, ms1, 3'b000, d_size, md);
endfunction

function automatic logic [31:0] enc_ew(
    input logic [3:0] func4,
    input logic [2:0] ctrl,
    input logic [2:0] ms1,
    input logic [2:0] ms2,
    input logic [2:0] md
);
    enc_ew = enc_matrix(func4, 2'b01, ctrl, ms2, 2'b10, ms1, 3'b001, 2'b10, md);
endfunction

task automatic reset_dut;
    begin
        resetn = 1'b0;
        matrix_valid = 1'b0;
        matrix_insn = 32'b0;
        matrix_rs1 = 32'b0;
        matrix_rs2 = 32'b0;
        host_reg_we = 1'b0;
        host_reg_id = 3'b0;
        host_reg_row_idx = 3'b0;
        host_reg_beat_idx = 3'b0;
        host_reg_wdata = 32'b0;
        host_read_id = 3'b0;
        host_read_row = 3'b0;
        host_read_beat = 3'b0;
        errors = 0;
        for (int i = 0; i < 256; i++) begin
            dmem[i] = 32'b0;
        end
        repeat (5) @(posedge clk);
        resetn = 1'b1;
        repeat (2) @(posedge clk);
    end
endtask

task automatic issue_matrix(
    input logic [31:0] insn,
    input logic [31:0] rs1,
    input logic [31:0] rs2
);
    int guard;
    begin
        @(negedge clk);
        matrix_insn  = insn;
        matrix_rs1   = rs1;
        matrix_rs2   = rs2;
        matrix_valid = 1'b1;

        guard = 0;
        while (!matrix_done && guard < 2000) begin
            @(posedge clk);
            guard++;
        end

        if (guard >= 2000) begin
            $display("ERROR timeout waiting for matrix_done insn=0x%08x", insn);
            errors++;
        end

        @(negedge clk);
        matrix_valid = 1'b0;
        matrix_insn  = 32'b0;
        matrix_rs1   = 32'b0;
        matrix_rs2   = 32'b0;
        @(posedge clk);
    end
endtask

task automatic host_write(
    input logic [2:0] reg_id,
    input logic [2:0] row,
    input logic [2:0] beat,
    input logic [31:0] data
);
    begin
        @(negedge clk);
        host_reg_id       = reg_id;
        host_reg_row_idx  = row;
        host_reg_beat_idx = beat;
        host_reg_wdata    = data;
        host_reg_we       = 1'b1;
        @(negedge clk);
        host_reg_we       = 1'b0;
        host_reg_wdata    = 32'b0;
    end
endtask

task automatic host_expect(
    input logic [2:0] reg_id,
    input logic [2:0] row,
    input logic [2:0] beat,
    input logic [31:0] expected
);
    begin
        @(negedge clk);
        host_read_id   = reg_id;
        host_read_row  = row;
        host_read_beat = beat;
        #1;
        if (host_reg_rdata !== expected) begin
            $display("ERROR reg%0d[%0d][%0d]: got 0x%08x expected 0x%08x",
                     reg_id, row, beat, host_reg_rdata, expected);
            errors++;
        end
    end
endtask

task automatic mem_expect(
    input int word_addr,
    input logic [31:0] expected
);
    begin
        if (dmem[word_addr] !== expected) begin
            $display("ERROR dmem[%0d]: got 0x%08x expected 0x%08x",
                     word_addr, dmem[word_addr], expected);
            errors++;
        end
    end
endtask
