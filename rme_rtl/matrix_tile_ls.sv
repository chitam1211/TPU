`timescale 1ns / 1ps

// Tile load/store unit for the deeply-integrated RV32I matrix core.
//
// This is intentionally not a DMA engine. The RV32I pipeline is stalled while a
// matrix load/store instruction is active, and this FSM uses the normal data
// memory port to move one tile row at a time between data memory and regfile.
module matrix_tile_ls #(
    parameter int MATRIX_DIM = 4,
    parameter int REG_BEATS_PER_ROW = 4
)(
    input  logic        clk,
    input  logic        resetn,

    input  logic        start_ls,
    input  logic        is_store,
    input  logic [2:0]  target_matrix_id,
    input  logic [31:0] base_addr,
    input  logic [31:0] row_stride,
    input  logic [1:0]  elem_size,
    input  logic [3:0]  matrix_sel,
    input  logic [31:0] tile_m,
    input  logic [31:0] tile_n,
    input  logic [31:0] tile_k,
    output logic        ls_done,
    output logic        ls_busy,

    output logic        reg_we,
    output logic [2:0]  reg_id,
    output logic [2:0]  reg_row_idx,
    output logic [2:0]  reg_beat_idx,
    output logic [31:0] reg_wdata,
    output logic [2:0]  reg_read_id,
    output logic [2:0]  reg_read_row,
    output logic [2:0]  reg_read_beat,
    input  logic [31:0] reg_rdata,

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

    logic        latched_is_store;
    logic [2:0]  latched_target_id;
    logic [31:0] latched_base_addr;
    logic [31:0] latched_row_stride;
    logic [1:0]  latched_elem_size;
    logic [3:0]  latched_matrix_sel;
    logic [31:0] latched_tile_m;
    logic [31:0] latched_tile_n;
    logic [31:0] latched_tile_k;

    logic [2:0] row_cnt;
    logic [2:0] beat_cnt;

    localparam logic [4:0] MATRIX_DIM_L = MATRIX_DIM[4:0];
    localparam logic [3:0] BEATS_PER_ROW_L = REG_BEATS_PER_ROW[3:0];

    logic [4:0] transfer_rows;
    logic [4:0] transfer_cols;
    logic [4:0] active_rows;
    logic [6:0] row_bytes;
    logic [2:0] beats_per_row;
    logic [6:0] beat_byte_offset;
    logic [6:0] bytes_remaining;
    logic [3:0] wstrb_for_beat;
    logic [31:0] current_addr;

    function automatic logic [4:0] transfer_rows_for(
        input logic [3:0]  sel,
        input logic [31:0] m,
        input logic [31:0] n
    );
        case (sel)
            4'b0000: transfer_rows_for = m[4:0]; // A: M rows
            4'b0001: transfer_rows_for = n[4:0]; // B is stored transposed: N rows
            4'b0010: transfer_rows_for = m[4:0]; // C/ACC: M rows
            default: transfer_rows_for = MATRIX_DIM_L;
        endcase
    endfunction

    function automatic logic [4:0] transfer_cols_for(
        input logic [3:0]  sel,
        input logic [31:0] n,
        input logic [31:0] k
    );
        case (sel)
            4'b0000: transfer_cols_for = k[4:0]; // A row width is K
            4'b0001: transfer_cols_for = k[4:0]; // transposed B row width is K
            4'b0010: transfer_cols_for = n[4:0]; // C row width is N
            default: transfer_cols_for = MATRIX_DIM_L;
        endcase
    endfunction

    function automatic logic [6:0] row_bytes_for(
        input logic [1:0] elem_sz,
        input logic [4:0] cols
    );
        case (elem_sz)
            2'b00:   row_bytes_for = {2'b0, cols};       // 8-bit
            2'b01:   row_bytes_for = {1'b0, cols, 1'b0}; // 16-bit
            2'b10:   row_bytes_for = {cols, 2'b00};      // 32-bit
            default: row_bytes_for = {cols, 2'b00};
        endcase
    endfunction

    function automatic logic [2:0] beats_for_row(input logic [6:0] bytes);
        logic [3:0] calc;
        begin
            calc = (bytes == 7'd0) ? 4'd0 : ((bytes + 7'd3) >> 2);
            beats_for_row = (calc > BEATS_PER_ROW_L) ? BEATS_PER_ROW_L[2:0] : calc[2:0];
        end
    endfunction

    function automatic logic [3:0] wstrb_for_remaining_bytes(input logic [6:0] remaining);
        case (remaining)
            7'd0:    wstrb_for_remaining_bytes = 4'b0000;
            7'd1:    wstrb_for_remaining_bytes = 4'b0001;
            7'd2:    wstrb_for_remaining_bytes = 4'b0011;
            7'd3:    wstrb_for_remaining_bytes = 4'b0111;
            default: wstrb_for_remaining_bytes = 4'b1111;
        endcase
    endfunction

    always_comb begin
        transfer_rows    = transfer_rows_for(latched_matrix_sel, latched_tile_m, latched_tile_n);
        transfer_cols    = transfer_cols_for(latched_matrix_sel, latched_tile_n, latched_tile_k);
        active_rows      = (transfer_rows > MATRIX_DIM_L) ? MATRIX_DIM_L : transfer_rows;
        row_bytes        = row_bytes_for(latched_elem_size, transfer_cols);
        beats_per_row    = beats_for_row(row_bytes);
        beat_byte_offset = {2'b0, beat_cnt, 2'b00};
        bytes_remaining  = (row_bytes > beat_byte_offset) ? (row_bytes - beat_byte_offset) : 7'd0;
        wstrb_for_beat   = wstrb_for_remaining_bytes(bytes_remaining);
        current_addr     = latched_base_addr + (row_cnt * latched_row_stride) + {27'b0, beat_cnt, 2'b00};
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
            latched_is_store    <= 1'b0;
            latched_target_id   <= 3'b0;
            latched_base_addr   <= 32'b0;
            latched_row_stride  <= 32'b0;
            latched_elem_size   <= 2'b0;
            latched_matrix_sel  <= 4'b0;
            latched_tile_m      <= 32'b0;
            latched_tile_n      <= 32'b0;
            latched_tile_k      <= 32'b0;
            row_cnt             <= 3'b0;
            beat_cnt            <= 3'b0;
            reg_we              <= 1'b0;
            reg_id              <= 3'b0;
            reg_row_idx         <= 3'b0;
            reg_beat_idx        <= 3'b0;
            reg_wdata           <= 32'b0;
        end else begin
            ls_done <= 1'b0;
            reg_we  <= 1'b0;

            case (state)
                ST_IDLE: begin
                    row_cnt  <= 3'b0;
                    beat_cnt <= 3'b0;
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
                        state              <= ST_CALC_ROW;
                    end
                end

                ST_CALC_ROW: begin
                    beat_cnt <= 3'b0;
                    if ((active_rows == 5'd0) || (beats_per_row == 3'd0)) begin
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
                    if (beat_cnt == beats_per_row - 3'd1) begin
                        state <= ST_NEXT_ROW;
                    end else begin
                        beat_cnt <= beat_cnt + 3'd1;
                        state    <= latched_is_store ? ST_STORE_REQ : ST_LOAD_REQ;
                    end
                end

                ST_NEXT_ROW: begin
                    if (row_cnt == active_rows[2:0] - 3'd1) begin
                        ls_done <= 1'b1;
                        state   <= ST_IDLE;
                    end else begin
                        row_cnt  <= row_cnt + 3'd1;
                        beat_cnt <= 3'b0;
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
