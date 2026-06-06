`timescale 1ns/1ps

module tb_matrix_mac_v2;
    `include "matrix_core_v2_tb_common.svh"

    logic trace_mac_active;
    int trace_mac_cycle;

    task automatic print_mac_state_name(input logic [2:0] state);
        begin
            case (state)
                3'd0: $write("IDLE");
                3'd1: $write("INIT_C");
                3'd2: $write("LOAD_W");
                3'd3: $write("CLEAR_PIPE");
                3'd4: $write("DIP_RUN");
                3'd5: $write("WRITE");
                default: $write("UNKNOWN");
            endcase
        end
    endtask

    task automatic print_mac_matrix4(input string label, input int sel);
        begin
            $display("    %s", label);
            for (int r = 0; r < 4; r++) begin
                $write("      r%0d:", r);
                for (int c = 0; c < 4; c++) begin
                    case (sel)
                        0: $write(" %0d", uut.u_mac.weight_pe[r][c]);
                        1: $write(" %0d", uut.u_mac.a_pipe[r][c]);
                        2: $write(" %0d", uut.u_mac.psum_pipe[r][c]);
                        default: $write(" %0d", uut.u_mac.pe_acc[r][c]);
                    endcase
                end
                $display("");
            end
        end
    endtask

    task automatic trace_mac_cycle_print;
        begin
            $write("MAC clk %0d T=%0t state=", trace_mac_cycle, $time);
            print_mac_state_name(uut.u_mac.state);
            $display(" chunk=%0d/%0d dip_cycle=%0d last=%0d valid={%0b,%0b,%0b,%0b} row={%0d,%0d,%0d,%0d}",
                     uut.u_mac.chunk_idx,
                     uut.u_mac.num_chunks,
                     uut.u_mac.dip_cycle,
                     uut.u_mac.dip_last_cycle,
                     uut.u_mac.pipe_valid[0],
                     uut.u_mac.pipe_valid[1],
                     uut.u_mac.pipe_valid[2],
                     uut.u_mac.pipe_valid[3],
                     uut.u_mac.pipe_row[0],
                     uut.u_mac.pipe_row[1],
                     uut.u_mac.pipe_row[2],
                     uut.u_mac.pipe_row[3]);

            if (uut.u_mac.state == 3'd3) begin
                print_mac_matrix4("B weight_pe after permutation", 0);
            end

            if (uut.u_mac.state == 3'd4) begin
                $display("    inject_valid=%0b inject_a={%0d,%0d,%0d,%0d}",
                         uut.u_mac.inject_valid,
                         uut.u_mac.inject_a[0],
                         uut.u_mac.inject_a[1],
                         uut.u_mac.inject_a[2],
                         uut.u_mac.inject_a[3]);
                print_mac_matrix4("A pipe: diagonal/rotating flow", 1);
                print_mac_matrix4("Partial sums: vertical flow", 2);
                print_mac_matrix4("C accumulators", 3);
            end

            if (uut.u_mac.mac_reg_we) begin
                $display("    WRITEBACK acc%0d row=%0d col=%0d data=%0d",
                         uut.u_mac.mac_reg_id - 3'd4,
                         uut.u_mac.mac_reg_row_idx,
                         uut.u_mac.mac_reg_beat_idx,
                         uut.u_mac.mac_reg_wdata[31:0]);
            end
        end
    endtask

    always @(posedge clk) begin
        if (trace_mac_active) begin
            #1;
            trace_mac_cycle_print();
            trace_mac_cycle++;
        end
    end

    initial begin
        $dumpfile("sim/tb_matrix_mac_v2.vcd");
        $dumpvars(0, tb_matrix_mac_v2);
        trace_mac_active = 1'b0;
        trace_mac_cycle = 0;

        reset_dut();

        issue_matrix(enc_cfg_reg(4'b0010), 32'd4, 32'd0);
        issue_matrix(enc_cfg_reg(4'b0011), 32'd4, 32'd0);
        issue_matrix(enc_cfg_reg(4'b0001), 32'd4, 32'd0);

        // A is row-major 4x4 in tr0, one packed INT8 word per row.
        host_write(3'd0, 3'd0, 3'd0, 32'h04030201);
        host_write(3'd0, 3'd1, 3'd0, 32'h08070605);
        host_write(3'd0, 3'd2, 3'd0, 32'h0c0b0a09);
        host_write(3'd0, 3'd3, 3'd0, 32'h100f0e0d);

        // B is stored transposed in tr1: each row is one original B column.
        host_write(3'd1, 3'd0, 3'd0, 32'h0d090501);
        host_write(3'd1, 3'd1, 3'd0, 32'h0e0a0602);
        host_write(3'd1, 3'd2, 3'd0, 32'h0f0b0703);
        host_write(3'd1, 3'd3, 3'd0, 32'h100c0804);

        issue_matrix(enc_misc(4'b0000, 3'b000, 3'd0, 3'd0, 2'b00, 2'b00, 3'd4),
                     32'd0, 32'd0); // mzero acc0

        if ($test$plusargs("TRACE_MAC")) begin
            $display("");
            $display("TRACE_MAC enabled: DiP MAC cycle-by-cycle trace");
            $display("  A moves through PE rows with lane rotation, which is the diagonal-input part.");
            $display("  B is loaded as permuted stationary weights. Partial sums move top-to-bottom.");
            trace_mac_cycle = 0;
            trace_mac_active = 1'b1;
        end

        issue_matrix(enc_matmul(3'b000, 3'd0, 3'd1, 3'd4), 32'd0, 32'd0); // mmaccu.w.b acc0,tr0,tr1

        if (trace_mac_active) begin
            repeat (2) @(posedge clk);
            trace_mac_active = 1'b0;
            $display("TRACE_MAC done");
            $display("");
        end

        host_expect(3'd4, 3'd0, 3'd0, 32'd90);
        host_expect(3'd4, 3'd0, 3'd1, 32'd100);
        host_expect(3'd4, 3'd0, 3'd2, 32'd110);
        host_expect(3'd4, 3'd0, 3'd3, 32'd120);
        host_expect(3'd4, 3'd1, 3'd0, 32'd202);
        host_expect(3'd4, 3'd1, 3'd1, 32'd228);
        host_expect(3'd4, 3'd1, 3'd2, 32'd254);
        host_expect(3'd4, 3'd1, 3'd3, 32'd280);
        host_expect(3'd4, 3'd2, 3'd0, 32'd314);
        host_expect(3'd4, 3'd2, 3'd1, 32'd356);
        host_expect(3'd4, 3'd2, 3'd2, 32'd398);
        host_expect(3'd4, 3'd2, 3'd3, 32'd440);
        host_expect(3'd4, 3'd3, 3'd0, 32'd426);
        host_expect(3'd4, 3'd3, 3'd1, 32'd484);
        host_expect(3'd4, 3'd3, 3'd2, 32'd542);
        host_expect(3'd4, 3'd3, 3'd3, 32'd600);

        if (errors == 0) $display("MATRIX_MAC_V2_TEST_PASS");
        else $display("MATRIX_MAC_V2_TEST_FAIL errors=%0d", errors);
        $finish;
    end
endmodule
