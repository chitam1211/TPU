`timescale 1ns / 1ps

// Tile load/store unit for the deeply-integrated RV32I matrix core.
//
// This is intentionally not a DMA engine. The RV32I pipeline is stalled while a
// matrix load/store instruction is active, and this FSM uses the normal data
// memory port to move one tile row at a time between data memory and regfile.
module matrix_tile_ls
    import matrix_cfg_pkg::*;
#(
    parameter int MATRIX_DIM = ROWNUM,
    parameter int REG_BEATS_PER_ROW = TR_BEATS,
    parameter int ACC_BEATS_PER_ROW = ACC_BEATS,
    localparam int MAX_BEATS = max2(REG_BEATS_PER_ROW, ACC_BEATS_PER_ROW),
    localparam int RF_ROW_W  = idx_w(MATRIX_DIM),
    localparam int RF_BEAT_W = idx_w(MAX_BEATS)
)(
    input  logic        clk,
    input  logic        resetn,

    input  logic                 start_ls,
    input  logic                 is_store,
    input  logic [REG_ID_W-1:0]  target_matrix_id,
    input  logic [31:0]          base_addr,
    input  logic [31:0]          row_stride,
    input  logic [1:0]           elem_size,
    input  logic [3:0]           matrix_sel,
    input  logic [31:0]          tile_m,
    input  logic [31:0]          tile_n,
    input  logic [31:0]          tile_k,
    output logic                 ls_done,
    output logic                 ls_busy,
    output logic                 ls_illegal,

    output logic                 reg_we,
    output logic [REG_ID_W-1:0]  reg_id,
    output logic [RF_ROW_W-1:0]  reg_row_idx,
    output logic [RF_BEAT_W-1:0] reg_beat_idx,
    output logic [31:0]          reg_wdata,
    output logic [REG_ID_W-1:0]  reg_read_id,
    output logic [RF_ROW_W-1:0]  reg_read_row,
    output logic [RF_BEAT_W-1:0] reg_read_beat,
    input  logic [31:0]          reg_rdata,

    output logic        mem_request,
    output logic        mem_we,
    output logic [31:0] mem_addr,
    output logic [31:0] mem_wdata,
    output logic [3:0]  mem_wstrb,
    input  logic [31:0] mem_rdata,
    input  logic        mem_rvalid
);

    typedef enum logic [2:0] {
        ST_IDLE       = 3'd0,
        ST_CALC_ROW   = 3'd1,
        ST_LOAD_REQ   = 3'd2,
        ST_LOAD_WAIT  = 3'd3,
        ST_LOAD_WRITE = 3'd4,
        ST_STORE_REQ  = 3'd5,
        ST_NEXT_BEAT  = 3'd6,
        ST_NEXT_ROW   = 3'd7
    } state_t;

    state_t state;

    // A legal row holds at most MAX_BEATS words: K <= TRLEN/SEW for A/B and
    // N <= ROWNUM 32-bit elements for C (proposal 5.2).
    localparam int ROWS_W      = cnt_w(MATRIX_DIM);
    localparam int COLS_W      = cnt_w(MAX_BEATS * INT8_PER_WORD);
    localparam int BEATS_W     = cnt_w(MAX_BEATS);
    localparam int ROW_BYTES_W = cnt_w(MAX_BEATS * 4);

    logic                latched_is_store;
    logic [REG_ID_W-1:0] latched_target_id;
    logic [31:0]         latched_base_addr;
    logic [31:0]         latched_row_stride;
    logic [1:0]          latched_elem_size;
    logic [3:0]          latched_matrix_sel;
    logic [31:0]         latched_tile_m;
    logic [31:0]         latched_tile_n;
    logic [31:0]         latched_tile_k;

    logic [RF_ROW_W-1:0]  row_cnt;
    logic [RF_BEAT_W-1:0] beat_cnt;

    // Sizes below are narrowed only after shape_illegal_for() accepted the tile,
    // so every legal value fits.
    logic [ROWS_W-1:0]      active_rows;
    logic [COLS_W-1:0]      transfer_cols;
    logic [ROW_BYTES_W-1:0] row_bytes;
    logic [BEATS_W-1:0]     beats_per_row;
    logic [ROW_BYTES_W-1:0] beat_byte_offset;
    logic [ROW_BYTES_W-1:0] bytes_remaining;
    logic [3:0]             wstrb_for_beat;
    logic [31:0]            current_addr;

    function automatic logic [ROWS_W-1:0] transfer_rows_for(
        input logic [3:0]  sel,
        input logic [31:0] m,
        input logic [31:0] n
    );
        case (sel)
            4'b0000: transfer_rows_for = m[ROWS_W-1:0]; // A: M rows
            4'b0001: transfer_rows_for = n[ROWS_W-1:0]; // B is stored transposed: N rows
            4'b0010: transfer_rows_for = m[ROWS_W-1:0]; // C/ACC: M rows
            default: transfer_rows_for = ROWS_W'(MATRIX_DIM);
        endcase
    endfunction

    function automatic logic [COLS_W-1:0] transfer_cols_for(
        input logic [3:0]  sel,
        input logic [31:0] n,
        input logic [31:0] k
    );
        case (sel)
            4'b0000: transfer_cols_for = k[COLS_W-1:0]; // A row width is K
            4'b0001: transfer_cols_for = k[COLS_W-1:0]; // transposed B row width is K
            4'b0010: transfer_cols_for = n[COLS_W-1:0]; // C row width is N
            default: transfer_cols_for = COLS_W'(MATRIX_DIM);
        endcase
    endfunction

    // Words in one row of the target register bank (tile or accumulator).
    function automatic int bank_beats(input logic [REG_ID_W-1:0] id);
        return id[REG_ID_W-1] ? ACC_BEATS_PER_ROW : REG_BEATS_PER_ROW;
    endfunction

    // Proposal 5.3: an unsupported mtilem/mtilen/mtilek setting is an illegal
    // instruction. Rows are limited to ROWNUM; a row holds bank_beats() words,
    // so the column limit depends on the element size.
    function automatic logic shape_illegal_for(
        input logic [3:0]          sel,
        input logic [1:0]          elem_sz,
        input logic [REG_ID_W-1:0] id,
        input logic [31:0]         m,
        input logic [31:0]         n,
        input logic [31:0]         k
    );
        logic [31:0] rows, cols, max_cols;
        begin
            case (sel)
                4'b0000: begin rows = m; cols = k; end
                4'b0001: begin rows = n; cols = k; end
                4'b0010: begin rows = m; cols = n; end
                default: begin rows = '0; cols = '0; end
            endcase
            case (elem_sz)
                2'b00:   max_cols = bank_beats(id) * 4; // 8-bit
                2'b01:   max_cols = bank_beats(id) * 2; // 16-bit
                default: max_cols = bank_beats(id);     // 32-bit
            endcase
            shape_illegal_for = (rows > MATRIX_DIM) || (cols > max_cols);
        end
    endfunction

    function automatic logic [ROW_BYTES_W-1:0] row_bytes_for(
        input logic [1:0]        elem_sz,
        input logic [COLS_W-1:0] cols
    );
        case (elem_sz)
            2'b00:   row_bytes_for = ROW_BYTES_W'(cols);      // 8-bit
            2'b01:   row_bytes_for = ROW_BYTES_W'(cols) << 1; // 16-bit
            default: row_bytes_for = ROW_BYTES_W'(cols) << 2; // 32-bit
        endcase
    endfunction

    function automatic logic [BEATS_W-1:0] beats_for_row(
        input logic [ROW_BYTES_W-1:0] bytes,
        input logic [REG_ID_W-1:0]    id
    );
        int calc;
        begin
            calc = (int'(bytes) + 3) / 4;
            beats_for_row = (calc > bank_beats(id)) ? BEATS_W'(bank_beats(id)) : BEATS_W'(calc);
        end
    endfunction

    function automatic logic [3:0] wstrb_for_remaining_bytes(input logic [ROW_BYTES_W-1:0] remaining);
        case (remaining)
            0:       wstrb_for_remaining_bytes = 4'b0000;
            1:       wstrb_for_remaining_bytes = 4'b0001;
            2:       wstrb_for_remaining_bytes = 4'b0011;
            3:       wstrb_for_remaining_bytes = 4'b0111;
            default: wstrb_for_remaining_bytes = 4'b1111;
        endcase
    endfunction

    always_comb begin
        active_rows      = transfer_rows_for(latched_matrix_sel, latched_tile_m, latched_tile_n);
        transfer_cols    = transfer_cols_for(latched_matrix_sel, latched_tile_n, latched_tile_k);
        row_bytes        = row_bytes_for(latched_elem_size, transfer_cols);
        beats_per_row    = beats_for_row(row_bytes, latched_target_id);
        beat_byte_offset = ROW_BYTES_W'(beat_cnt) << 2;
        bytes_remaining  = (row_bytes > beat_byte_offset) ? (row_bytes - beat_byte_offset) : '0;
        wstrb_for_beat   = wstrb_for_remaining_bytes(bytes_remaining);
        current_addr     = latched_base_addr + (row_cnt * latched_row_stride) + (32'(beat_cnt) << 2);
    end

    assign ls_busy       = (state != ST_IDLE);
    assign reg_read_id   = latched_target_id;
    assign reg_read_row  = row_cnt;
    assign reg_read_beat = beat_cnt;

    assign mem_request   = (state == ST_LOAD_REQ) || (state == ST_STORE_REQ);
    assign mem_we        = (state == ST_STORE_REQ);
    assign mem_addr      = current_addr;
    assign mem_wdata     = reg_rdata;
    assign mem_wstrb     = (state == ST_STORE_REQ) ? wstrb_for_beat : 4'b1111;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            state               <= ST_IDLE;
            ls_done             <= 1'b0;
            ls_illegal          <= 1'b0;
            latched_is_store    <= 1'b0;
            latched_target_id   <= '0;
            latched_base_addr   <= 32'b0;
            latched_row_stride  <= 32'b0;
            latched_elem_size   <= 2'b0;
            latched_matrix_sel  <= 4'b0;
            latched_tile_m      <= 32'b0;
            latched_tile_n      <= 32'b0;
            latched_tile_k      <= 32'b0;
            row_cnt             <= '0;
            beat_cnt            <= '0;
            reg_we              <= 1'b0;
            reg_id              <= '0;
            reg_row_idx         <= '0;
            reg_beat_idx        <= '0;
            reg_wdata           <= 32'b0;
        end else begin
            ls_done <= 1'b0;
            reg_we  <= 1'b0;

            case (state)
                ST_IDLE: begin
                    row_cnt  <= '0;
                    beat_cnt <= '0;
                    if (start_ls) begin
                        latched_is_store   <= is_store;
                        latched_target_id  <= target_matrix_id;
                        latched_base_addr  <= base_addr;
                        latched_row_stride <= row_stride;
                        latched_elem_size  <= elem_size;
                        latched_matrix_sel <= matrix_sel;
                        latched_tile_m     <= tile_m;
                        latched_tile_n     <= tile_n;
                        latched_tile_k     <= tile_k;
                        ls_illegal         <= shape_illegal_for(matrix_sel, elem_size, target_matrix_id,
                                                                tile_m, tile_n, tile_k);
                        state              <= ST_CALC_ROW;
                    end
                end

                ST_CALC_ROW: begin
                    beat_cnt <= '0;
                    if (ls_illegal || (active_rows == '0) || (beats_per_row == '0)) begin
                        ls_done <= 1'b1;
                        state   <= ST_IDLE;
                    end else begin
                        state <= latched_is_store ? ST_STORE_REQ : ST_LOAD_REQ;
                    end
                end

                ST_LOAD_REQ: begin
                    state <= ST_LOAD_WAIT;
                end

                ST_LOAD_WAIT: begin
                    if (mem_rvalid) begin
                        reg_we       <= 1'b1;
                        reg_id       <= latched_target_id;
                        reg_row_idx  <= row_cnt;
                        reg_beat_idx <= beat_cnt;
                        reg_wdata    <= mem_rdata;
                        state        <= ST_LOAD_WRITE;
                    end
                end

                ST_LOAD_WRITE: begin
                    state <= ST_NEXT_BEAT;
                end

                ST_STORE_REQ: begin
                    state <= ST_NEXT_BEAT;
                end

                ST_NEXT_BEAT: begin
                    if (beat_cnt == beats_per_row - 1'b1) begin
                        state <= ST_NEXT_ROW;
                    end else begin
                        beat_cnt <= beat_cnt + 1'b1;
                        state    <= latched_is_store ? ST_STORE_REQ : ST_LOAD_REQ;
                    end
                end

                ST_NEXT_ROW: begin
                    if (row_cnt == active_rows - 1'b1) begin
                        ls_done <= 1'b1;
                        state   <= ST_IDLE;
                    end else begin
                        row_cnt  <= row_cnt + 1'b1;
                        beat_cnt <= '0;
                        state    <= ST_CALC_ROW;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule