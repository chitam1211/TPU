`timescale 1ns / 1ps

module tb_matrix_ew;
    reg clk = 1'b0;
    reg resetn = 1'b0;

    logic        start_ew;
    logic [31:0] pcpi_insn;
    logic        ew_done;
    logic        ew_reg_we;
    logic [2:0]  ew_reg_id;
    logic [2:0]  ew_reg_row_idx;
    logic [2:0]  ew_reg_beat_idx;
    logic [31:0] ew_reg_wdata;
    logic [2:0]  read_id_A;
    logic [2:0]  read_row_A;
    logic [2:0]  read_beat_A;
    logic [31:0] read_data_A;
    logic [2:0]  read_id_B;
    logic [2:0]  read_row_B;
    logic [2:0]  read_beat_B;
    logic [31:0] read_data_B;

    logic [31:0] regs [0:7][0:3][0:3];
    integer errors;
    reg done_seen;

    always #5 clk = ~clk;

    matrix_ew #(
        .MATRIX_DIM(4),
        .BEATS_PER_ROW(4)
    ) dut (
        .clk(clk),
        .resetn(resetn),
        .start_ew(start_ew),
        .pcpi_insn(pcpi_insn),
        .out_xmsaten(1'b0),
        .out_mtilem(32'd4),
        .out_mtilen(32'd4),
        .ew_done(ew_done),
        .ew_reg_we(ew_reg_we),
        .ew_reg_id(ew_reg_id),
        .ew_reg_row_idx(ew_reg_row_idx),
        .ew_reg_beat_idx(ew_reg_beat_idx),
        .ew_reg_wdata(ew_reg_wdata),
        .read_id_A(read_id_A),
        .read_row_A(read_row_A),
        .read_beat_A(read_beat_A),
        .read_data_A(read_data_A),
        .read_id_B(read_id_B),
        .read_row_B(read_row_B),
        .read_beat_B(read_beat_B),
        .read_data_B(read_data_B)
    );

    assign read_data_A = regs[read_id_A][read_row_A][read_beat_A];
    assign read_data_B = regs[read_id_B][read_row_B][read_beat_B];

    task automatic check_reg(
        input int row,
        input int beat,
        input logic [31:0] expected
    );
        begin
            if (regs[4][row][beat] !== expected) begin
                $display("ERROR regs[4][%0d][%0d]: got 0x%08x expected 0x%08x",
                         row, beat, regs[4][row][beat], expected);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        done_seen = 1'b0;
        start_ew = 1'b0;
        pcpi_insn = 32'b0;

        for (int id = 0; id < 8; id++) begin
            for (int r = 0; r < 4; r++) begin
                for (int b = 0; b < 4; b++) begin
                    regs[id][r][b] = 32'b0;
                end
            end
        end

        // md == ms1 == acc0. Row 0 is the vector source. Without snapshotting,
        // later rows would consume the already overwritten row 0.
        regs[4][0][0] = 32'd10;
        regs[4][0][1] = 32'd20;
        regs[4][0][2] = 32'd30;
        regs[4][0][3] = 32'd40;

        regs[5][0][0] = 32'd1;
        regs[5][0][1] = 32'd2;
        regs[5][0][2] = 32'd3;
        regs[5][0][3] = 32'd4;
        regs[5][1][0] = 32'd100;
        regs[5][1][1] = 32'd200;
        regs[5][1][2] = 32'd300;
        regs[5][1][3] = 32'd400;
        regs[5][2][0] = 32'd1000;
        regs[5][2][1] = 32'd2000;
        regs[5][2][2] = 32'd3000;
        regs[5][2][3] = 32'd4000;
        regs[5][3][0] = 32'd5;
        regs[5][3][1] = 32'd6;
        regs[5][3][2] = 32'd7;
        regs[5][3][3] = 32'd8;

        repeat (4) @(posedge clk);
        resetn <= 1'b1;
        repeat (2) @(posedge clk);

        // madd.w.mv acc0, acc1, acc0[row 0]
        pcpi_insn <= 32'h045A_1A2B;
        start_ew <= 1'b1;
        @(posedge clk);
        start_ew <= 1'b0;

        repeat (80) @(posedge clk);

        if (!done_seen) begin
            $display("ERROR EW did not finish");
            errors = errors + 1;
        end

        check_reg(0, 0, 32'd11);
        check_reg(0, 1, 32'd22);
        check_reg(0, 2, 32'd33);
        check_reg(0, 3, 32'd44);
        check_reg(1, 0, 32'd110);
        check_reg(1, 1, 32'd220);
        check_reg(1, 2, 32'd330);
        check_reg(1, 3, 32'd440);
        check_reg(2, 0, 32'd1010);
        check_reg(2, 1, 32'd2020);
        check_reg(2, 2, 32'd3030);
        check_reg(2, 3, 32'd4040);
        check_reg(3, 0, 32'd15);
        check_reg(3, 1, 32'd26);
        check_reg(3, 2, 32'd37);
        check_reg(3, 3, 32'd48);

        if (errors == 0) begin
            $display("EW_ALIAS_TEST_PASS");
        end else begin
            $display("EW_ALIAS_TEST_FAIL errors=%0d", errors);
        end

        $finish;
    end

    always_ff @(posedge clk) begin
        if (resetn && ew_done) begin
            done_seen <= 1'b1;
        end

        if (resetn && ew_reg_we) begin
            regs[ew_reg_id][ew_reg_row_idx][ew_reg_beat_idx] <= ew_reg_wdata;
        end
    end
endmodule
