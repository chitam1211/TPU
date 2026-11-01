`timescale 1ns/1ps
// Parameterized DiP FP32 FMA, globally stepped FSM (not an II=1 pipeline).
// start_matmul must be a one-cycle pulse, already decoded as mfmacc.s.
// A storage: row=i, beat=k. B storage: row=j, beat=k (B transposed).
// C storage: row=i, beat=j. All reads combinational, writes on clock edge.
// M output rows, N output columns, K pipeline stages are independent.
// RF address widths follow the compute dimensions (rows: max(M,N), beats: max(N,K)).
module matrix_fp_mac
    import matrix_cfg_pkg::*;
#(
    parameter int COMPUTE_ROWS = TMMAX,
    parameter int COMPUTE_COLS = TNMAX,
    parameter int MAX_K_FP32 = TKMAX_FP32,
    localparam int LOAD_ROWS = max2(COMPUTE_ROWS, COMPUTE_COLS),
    localparam int RF_ROW_W  = idx_w(LOAD_ROWS),
    localparam int RF_BEAT_W = idx_w(max2(COMPUTE_COLS, MAX_K_FP32))
)(
    input logic clk, resetn,
    input logic start_matmul,
    input logic [REG_ID_W-1:0] ms1_reg_id, ms2_reg_id, md_acc_id,
    input logic [31:0] out_mtilem, out_mtilen, out_mtilek,
    input logic [2:0] out_xmfrm,
    output logic busy, mac_done, mac_illegal,
    output logic [4:0] mac_fflags,
    output logic mac_reg_we,
    output logic [REG_ID_W-1:0] mac_reg_id,
    output logic [RF_ROW_W-1:0] mac_reg_row_idx,
    output logic [RF_BEAT_W-1:0] mac_reg_beat_idx,
    output logic [31:0] mac_reg_wdata,
    output logic [REG_ID_W-1:0] read_id_A, read_id_B, read_id_C,
    output logic [RF_ROW_W-1:0] read_row_A, read_row_B, read_row_C,
    output logic [RF_BEAT_W-1:0] read_beat_A, read_beat_B, read_beat_C,
    input logic [31:0] read_data_A,
    input logic [31:0] read_data_B,
    input logic [31:0] read_data_C
    );

    import fp32_fma_pkg::*;
    logic is_mfmacc_s;
    logic illegal_inst;

    // The dispatcher currently supplies only mfmacc.s to this module.
    // When more operations are supported, pass their decoded selectors here.
    assign is_mfmacc_s = start_matmul;

    always_comb begin
        illegal_inst = 1'b1;
        case (1'b1)
            is_mfmacc_s: begin
                illegal_inst =
                    (out_mtilem > COMPUTE_ROWS) ||
                    (out_mtilen > COMPUTE_COLS) ||
                    (out_mtilek > MAX_K_FP32) ||
                    (out_xmfrm > 3'd4) ||
                    ms1_reg_id[REG_ID_W-1] || ms2_reg_id[REG_ID_W-1] || !md_acc_id[REG_ID_W-1];
            end
            default: illegal_inst = 1'b1;
        endcase
    end

    typedef enum logic [3:0] {
        ST_IDLE, 
        ST_INIT_C, 
        ST_READ, 
        ST_FEED, 
        ST_UNPACK, 
        ST_MULTIPLY,
        ST_ALIGN_ADD, 
        ST_ROUND, 
        ST_WRITE, 
        ST_DONE
    } state_t;

    localparam int EPOCH_W = (COMPUTE_ROWS + MAX_K_FP32 > 2) ?
                            $clog2(COMPUTE_ROWS + MAX_K_FP32) : 1;
    // active_* hold 0..COMPUTE_ROWS/COLS/MAX_K_FP32.
    localparam int M_W = cnt_w(COMPUTE_ROWS);
    localparam int N_W = cnt_w(COMPUTE_COLS);
    localparam int K_W = cnt_w(MAX_K_FP32);
    initial begin
        if (COMPUTE_ROWS < 1 || COMPUTE_COLS < 1 || MAX_K_FP32 < 1)
            $fatal(1, "FP MAC dimensions must be at least 1");
    end

    state_t state;
    logic [M_W-1:0] active_M;
    logic [N_W-1:0] active_N;
    logic [K_W-1:0] active_K;
    logic [2:0] rm;
    logic [REG_ID_W-1:0] id_a, id_b, id_c;
    logic [RF_ROW_W-1:0] row_idx;  // A/B/C register row
    logic [RF_BEAT_W-1:0] col_idx; // A/B: k beat, C: n beat
    logic [EPOCH_W-1:0] epoch;
    logic [31:0] a_tile[0:COMPUTE_ROWS-1][0:MAX_K_FP32-1];
    logic [31:0] pe_acc[0:COMPUTE_ROWS-1][0:COMPUTE_COLS-1];
    logic [31:0] weight_pe[0:MAX_K_FP32-1][0:COMPUTE_COLS-1];
    // A rotates across K lanes, independently of the N output columns.
    logic [31:0] a_pipe[0:MAX_K_FP32-1][0:MAX_K_FP32-1];
    logic [31:0] psum_pipe[0:MAX_K_FP32-1][0:COMPUTE_COLS-1];
    logic [31:0] operand_a[0:MAX_K_FP32-1][0:COMPUTE_COLS-1];
    logic [31:0] operand_c[0:MAX_K_FP32-1][0:COMPUTE_COLS-1];
    logic [4:0] epoch_flags;
    wire [31:0] result_bits[0:MAX_K_FP32-1][0:COMPUTE_COLS-1];
    wire [4:0] result_flags[0:MAX_K_FP32-1][0:COMPUTE_COLS-1];

    assign busy = (state != ST_IDLE);
    assign read_id_A = id_a;
    assign read_id_B = id_b;
    assign read_id_C = id_c;
    assign read_row_A = row_idx;
    assign read_beat_A = col_idx;
    assign read_row_B = row_idx;
    assign read_beat_B = col_idx;
    assign read_row_C = row_idx;
    assign read_beat_C = col_idx;
    // Combinational write controls: the last write commits before ST_DONE.
    assign mac_reg_we = resetn && (state == ST_WRITE);
    assign mac_reg_id = id_c;
    assign mac_reg_row_idx = row_idx;
    assign mac_reg_beat_idx = col_idx;
    assign mac_reg_wdata = pe_acc[row_idx][col_idx];

    generate
        for (genvar pr = 0; pr < MAX_K_FP32; pr++) begin: ROW
            for (genvar c = 0; c < COMPUTE_COLS; c++) begin: COL
                localparam int K_LOCAL = (pr+c)%MAX_K_FP32;
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
        for (int pr = 0; pr < MAX_K_FP32; pr++) begin
            for (int c = 0; c < COMPUTE_COLS; c++) begin
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
            for (int r = 0; r < COMPUTE_ROWS; r++) begin
                for (int k = 0; k < MAX_K_FP32; k++) a_tile[r][k] <= 0;
                for (int c = 0; c < COMPUTE_COLS; c++) pe_acc[r][c] <= 0;
            end
            for (int pr = 0; pr < MAX_K_FP32; pr++) begin
                for (int k = 0; k < MAX_K_FP32; k++) a_pipe[pr][k] <= 0;
                for (int c = 0; c < COMPUTE_COLS; c++) begin
                    weight_pe[pr][c] <= 0; psum_pipe[pr][c] <= 0;
                    operand_a[pr][c] <= 0; operand_c[pr][c] <= 0;
                end
            end
        end 
        else begin
            mac_done <= 0;
            case (state)
                ST_IDLE: begin
                    if (start_matmul) begin
                        id_a <= ms1_reg_id; id_b <= ms2_reg_id; id_c <= md_acc_id;
                        active_M <= out_mtilem[M_W-1:0]; active_N <= out_mtilen[N_W-1:0];
                        active_K <= out_mtilek[K_W-1:0]; rm <= out_xmfrm;
                        row_idx <= 0; col_idx <= 0; epoch <= 0;
                        mac_fflags <= 0; mac_illegal <= 0;
                        if (illegal_inst) begin
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
                    if (int'(col_idx)+1 == active_N) begin
                        col_idx <= 0;
                        if (int'(row_idx)+1 == active_M) begin
                            row_idx <= 0;
                            state <= ST_READ;
                        end 
                        else row_idx <= row_idx + 1'b1;
                    end 
                    else col_idx <= col_idx + 1'b1;
                end
                
                ST_READ: begin
                    // Scan max(M,N)*K positions; each port loads its own tile.
                    if (row_idx < COMPUTE_ROWS)
                        a_tile[row_idx][col_idx] <= read_data_A;
                    if (row_idx < COMPUTE_COLS)
                        weight_pe[(int'(col_idx)+MAX_K_FP32-(int'(row_idx)%MAX_K_FP32))%MAX_K_FP32][row_idx] <= read_data_B;
                    if (col_idx == MAX_K_FP32-1) begin
                        col_idx <= 0;
                        if (row_idx == LOAD_ROWS-1) begin
                            row_idx <= 0;
                            state <= ST_FEED;
                        end else row_idx <= row_idx + 1'b1;
                    end else col_idx <= col_idx + 1'b1;
                end
                
                ST_FEED: begin
                    for (int c = 0; c < COMPUTE_COLS; c++) begin
                        operand_a[0][c] <= (epoch < active_M) ? a_tile[epoch][c%MAX_K_FP32] : 32'b0;
                        operand_c[0][c] <= (epoch < active_M) ? pe_acc[epoch][c] : 32'b0;
                    end
                    for (int pr = 1; pr < MAX_K_FP32; pr++) begin
                        for (int c = 0; c < COMPUTE_COLS; c++) begin
                            operand_a[pr][c] <= a_pipe[pr-1][(c+1)%MAX_K_FP32];
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
                    for (int pr = 0; pr < MAX_K_FP32; pr++) begin
                        for (int c = 0; c < COMPUTE_COLS; c++) begin
                            psum_pipe[pr][c] <= result_bits[pr][c];
                        end
                    end
                    for (int k = 0; k < MAX_K_FP32; k++) begin
                        a_pipe[0][k] <= (epoch < active_M) ? a_tile[epoch][k] : 32'b0;
                        for (int pr = 1; pr < MAX_K_FP32; pr++)
                            a_pipe[pr][k] <= a_pipe[pr-1][(k+1)%MAX_K_FP32];
                    end
                    if (epoch >= MAX_K_FP32-1) begin
                        for (int c = 0; c < COMPUTE_COLS; c++) begin
                            if (c < int'(active_N)) pe_acc[epoch-(MAX_K_FP32-1)][c] <= result_bits[MAX_K_FP32-1][c];
                        end
                    end
                    if (int'(epoch) == int'(active_M)+MAX_K_FP32-2) begin
                        row_idx <= 0; col_idx <= 0;
                        state <= ST_WRITE;
                    end 
                    else begin
                        epoch <= epoch + 1'b1;
                        state <= ST_FEED;
                    end
                end
                
                ST_WRITE: begin
                    if (int'(col_idx)+1 == active_N) begin
                        col_idx <= 0;
                        if (int'(row_idx)+1 == active_M) state <= ST_DONE;
                        else row_idx <= row_idx + 1'b1;
                    end 
                    else col_idx <= col_idx + 1'b1;
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
