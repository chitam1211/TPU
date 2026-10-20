`timescale 1ns/1ps
// 4x4 DiP FP32 FMA, globally stepped FSM (not an II=1 pipeline).
// start_matmul must be a one-cycle pulse, already decoded as mfmacc.s.
// A storage: row=i, beat=k. B storage: row=j, beat=k (B transposed).
// C storage: row=i, beat=j. All reads combinational, writes on clock edge.
module matrix_fp_mac (
    input logic clk, resetn,
    input logic start_matmul,
    input logic [2:0] ms1_reg_id, ms2_reg_id, md_acc_id,
    input logic [31:0] out_mtilem, out_mtilen, out_mtilek,
    input logic [2:0] out_xmfrm,
    output logic busy, mac_done, mac_illegal,
    output logic [4:0] mac_fflags,
    output logic mac_reg_we,
    output logic [2:0] mac_reg_id, mac_reg_row_idx, mac_reg_beat_idx,
    output logic [31:0] mac_reg_wdata,
    output logic [2:0] read_id_A, read_row_A, read_beat_A,
    input logic [31:0] read_data_A,
    output logic [2:0] read_id_B, read_row_B, read_beat_B,
    input logic [31:0] read_data_B,
    output logic [2:0] read_id_C, read_row_C, read_beat_C,
    input logic [31:0] read_data_C
    );

    import fp32_fma_pkg::*;
    typedef enum logic [3:0] {
        ST_IDLE, ST_INIT_C, ST_READ, ST_FEED, ST_UNPACK, ST_MULTIPLY,
        ST_ALIGN_ADD, ST_ROUND, ST_WRITE, ST_DONE
    } state_t;

    state_t state;
    logic [2:0] active_M, active_N, active_K, rm;
    logic [2:0] id_a, id_b, id_c;
    logic [1:0] row_idx, col_idx;
    logic [2:0] epoch; // 0..6: M+3 DiP steps for M<=4.
    logic [31:0] a_tile[0:3][0:3], pe_acc[0:3][0:3];
    logic [31:0] weight_pe[0:3][0:3];
    logic [31:0] a_pipe[0:3][0:3], psum_pipe[0:3][0:3];
    logic [31:0] operand_a[0:3][0:3], operand_c[0:3][0:3];
    logic [4:0] epoch_flags;
    wire [31:0] result_bits[0:3][0:3];
    wire [4:0] result_flags[0:3][0:3];

    function automatic logic [1:0] mod4_add(input logic [1:0] x, y);
        return x + y;
    endfunction

    assign busy = (state != ST_IDLE);
    assign read_id_A = id_a;
    assign read_id_B = id_b;
    assign read_id_C = id_c;
    assign read_row_A = {1'b0,row_idx};
    assign read_beat_A = {1'b0,col_idx};
    assign read_row_B = {1'b0,col_idx};
    assign read_beat_B = {1'b0,row_idx};
    assign read_row_C = {1'b0,row_idx};
    assign read_beat_C = {1'b0,col_idx};
    // Combinational write controls: the last write commits before ST_DONE.
    assign mac_reg_we = resetn && (state == ST_WRITE);
    assign mac_reg_id = id_c;
    assign mac_reg_row_idx = {1'b0,row_idx};
    assign mac_reg_beat_idx = {1'b0,col_idx};
    assign mac_reg_wdata = pe_acc[row_idx][col_idx];

    generate
        for (genvar pr = 0; pr < 4; pr++) begin: ROW
            for (genvar c = 0; c < 4; c++) begin: COL
                localparam int K_LOCAL = (pr+c)%4;
                unpack_t ua, ub, uc;
                special_t special;
                sum_t sum;
                result_t rounded;
                logic [47:0] product;
                // Disabled lanes bypass C bit-for-bit: do not evaluate padded 0*Inf.
                wire enabled = (epoch >= pr) && (int'(epoch) < int'(active_M)+pr) &&
                            (c < int'(active_N)) && (K_LOCAL < int'(active_K));
                
                assign rounded = round_pack_fast(sum,special,rm);
                
                assign result_bits[pr][c] = enabled ? rounded.bits : operand_c[pr][c];
                assign result_flags[pr][c] = enabled ? rounded.flags : 5'b0;
                always_ff @(posedge clk) begin
                    if (!resetn) begin
                        ua <= '0; ub <= '0; uc <= '0;
                        special <= '0; product <= '0; sum <= '0;
                    end 
                    else if (enabled) begin
                        case (state)
                        ST_UNPACK: begin
                            ua <= unpack(operand_a[pr][c]);
                            ub <= unpack(weight_pe[pr][c]);
                            uc <= unpack(operand_c[pr][c]);
                            special <= specials(unpack(operand_a[pr][c]),unpack(weight_pe[pr][c]),unpack(operand_c[pr][c]));
                        end
                        ST_MULTIPLY: product <= ua.sig * ub.sig;
                        ST_ALIGN_ADD: sum <= align_add(product,ua,ub,uc,rm);
                        default: begin end
                        endcase
                    end
                end
            end
        end
    endgenerate

    always_comb begin
        epoch_flags = 0;
        for (int pr = 0; pr < 4; pr++) begin
            for (int c = 0; c < 4; c++) begin
                epoch_flags = epoch_flags | result_flags[pr][c];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!resetn) begin
            state <= ST_IDLE;
            active_M <= 0; active_N <= 0; active_K <= 0; rm <= 0;
            id_a <= 0; id_b <= 0; id_c <= 0;
            row_idx <= 0; col_idx <= 0; epoch <= 0;
            mac_done <= 0; mac_illegal <= 0; mac_fflags <= 0;
            for (int r = 0; r < 4; r++) begin
                for (int c = 0; c < 4; c++) begin
                    a_tile[r][c] <= 0; pe_acc[r][c] <= 0; weight_pe[r][c] <= 0;
                    a_pipe[r][c] <= 0; psum_pipe[r][c] <= 0;
                    operand_a[r][c] <= 0; operand_c[r][c] <= 0;
                end
            end
        end 
        else begin
            mac_done <= 0;
            case (state)
                ST_IDLE: begin
                    if (start_matmul) begin
                        id_a <= ms1_reg_id; id_b <= ms2_reg_id; id_c <= md_acc_id;
                        active_M <= out_mtilem[2:0]; active_N <= out_mtilen[2:0];
                        active_K <= out_mtilek[2:0]; rm <= out_xmfrm;
                        row_idx <= 0; col_idx <= 0; epoch <= 0;
                        mac_fflags <= 0; mac_illegal <= 0;
                        if ((out_mtilem > 4) || (out_mtilen > 4) || (out_mtilek > 4) ||
                            (out_xmfrm > 4) || ms1_reg_id[2] || ms2_reg_id[2] || !md_acc_id[2]) begin
                            mac_illegal <= 1;
                            state <= ST_DONE;
                        end 
                        else if ((out_mtilem == 0) || (out_mtilen == 0) || (out_mtilek == 0)) begin
                            state <= ST_DONE; // No writes; C and flags unchanged architecturally.
                        end 
                        else begin
                            state <= ST_INIT_C;
                        end
                    end
                end
                
                ST_INIT_C: begin
                    pe_acc[row_idx][col_idx] <= read_data_C;
                    if ({1'b0,col_idx}+3'd1 == active_N) begin
                        col_idx <= 0;
                        if ({1'b0,row_idx}+3'd1 == active_M) begin
                            row_idx <= 0;
                            state <= ST_READ;
                        end 
                        else row_idx <= row_idx + 2'd1;
                    end 
                    else col_idx <= col_idx + 2'd1;
                end
                
                ST_READ: begin
                    // 16 cycles: read A[i][k] and B[k][j] concurrently through two ports.
                    a_tile[row_idx][col_idx] <= read_data_A;
                    weight_pe[(row_idx-col_idx)&2'b11][col_idx] <= read_data_B;
                    col_idx <= col_idx + 2'd1;
                    if (col_idx == 3) begin
                        row_idx <= row_idx + 2'd1;
                        if (row_idx == 3) state <= ST_FEED;
                    end
                end
                
                ST_FEED: begin
                    for (int c = 0; c < 4; c++) begin
                        operand_a[0][c] <= (epoch < active_M) ? a_tile[epoch[1:0]][c] : 32'b0;
                        operand_c[0][c] <= (epoch < active_M) ? pe_acc[epoch[1:0]][c] : 32'b0;
                    end
                    for (int pr = 1; pr < 4; pr++) begin
                        for (int c = 0; c < 4; c++) begin
                            operand_a[pr][c] <= a_pipe[pr-1][mod4_add(c[1:0],2'd1)];
                            operand_c[pr][c] <= psum_pipe[pr-1][c];
                        end
                    end
                    state <= ST_UNPACK;
                end
                
                ST_UNPACK: state <= ST_MULTIPLY;
                
                ST_MULTIPLY: state <= ST_ALIGN_ADD;
                
                ST_ALIGN_ADD: state <= ST_ROUND;
                
                ST_ROUND: begin
                    mac_fflags <= mac_fflags | epoch_flags;
                    for (int pr = 0; pr < 4; pr++) begin
                        for (int c = 0; c < 4; c++) begin
                            a_pipe[pr][c] <= operand_a[pr][c];
                            psum_pipe[pr][c] <= result_bits[pr][c];
                        end
                    end
                    if (epoch >= 3) begin
                        for (int c = 0; c < 4; c++) begin
                            if (c < int'(active_N)) pe_acc[epoch-3][c] <= result_bits[3][c];
                        end
                    end
                    if (epoch == active_M+3'd2) begin
                        row_idx <= 0; col_idx <= 0;
                        state <= ST_WRITE;
                    end 
                    else begin
                        epoch <= epoch + 3'd1;
                        state <= ST_FEED;
                    end
                end
                
                ST_WRITE: begin
                    if ({1'b0,col_idx}+3'd1 == active_N) begin
                        col_idx <= 0;
                        if ({1'b0,row_idx}+3'd1 == active_M) state <= ST_DONE;
                        else row_idx <= row_idx + 2'd1;
                    end 
                    else col_idx <= col_idx + 2'd1;
                end

                ST_DONE: begin
                    mac_done <= 1;
                    state <= ST_IDLE;
                end
                
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
