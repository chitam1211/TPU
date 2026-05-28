module matrix_dma #(
    parameter int AXI_ADDR_WIDTH = 32,
    parameter int AXI_DATA_WIDTH = 32,
    parameter int MATRIX_DIM = 4,
    parameter int REG_BEATS_PER_ROW = 4
)(
    input logic clk,
    input logic resetn,

    //1. Control interface
    input logic         start_ls,
    input logic         is_store,
    input logic [2:0]   target_matrix_id,
    input logic [31:0]  base_addr,
    input logic [31:0]  row_stride,
    input logic [1:0]   elem_size,
    input logic [3:0]   matrix_sel,
    input logic [31:0]  tile_m,
    input logic [31:0]  tile_n,
    input logic [31:0]  tile_k,
    output logic        dma_done,

    //2. Matrix register file interface
    output logic        reg_we,
    output logic [2:0]  reg_id,
    output logic [2:0]  reg_row_idx,
    output logic [2:0]  reg_beat_idx,
    output logic [31:0] reg_wdata,
    input  logic [31:0] reg_rdata,

    //3. AXI4 Full Master interface
    //Write address channel (AW)
    output logic [AXI_ADDR_WIDTH - 1 : 0]   m_axi_awaddr, 
    output logic [7:0]                      m_axi_awlen,  //burst length
    output logic [2:0]                      m_axi_awsize, //burst size
    output logic [1:0]                      m_axi_awburst, //burst type
    output logic                            m_axi_awvalid,
    input logic                             m_axi_awready,

    //Write data channel (W)
    output logic [AXI_DATA_WIDTH - 1 : 0]   m_axi_wdata,
    output logic [3:0]                      m_axi_wstrb,
    output logic                            m_axi_wlast,
    output logic                            m_axi_wvalid,
    input  logic                            m_axi_wready,

    //Write respone channel(B)
    input logic [1:0]                       m_axi_bresp,
    input logic                             m_axi_bvalid,
    output logic                            m_axi_bready,

    //Read address channel channel (AR)
    output logic [AXI_ADDR_WIDTH - 1 : 0]   m_axi_araddr,
    output logic [7:0]                      m_axi_arlen,    // Burst length
    output logic [2:0]                      m_axi_arsize,   // Burst size
    output logic [1:0]                      m_axi_arburst,    // Burst type
    output logic                            m_axi_arvalid,
    input  logic                            m_axi_arready,

    //Read data channel (R)
    input logic [AXI_DATA_WIDTH - 1 : 0]    m_axi_rdata,
    input logic [1:0]                       m_axi_rresp,
    input logic                             m_axi_rlast, // last beat
    input logic                             m_axi_rvalid,
    output logic                            m_axi_rready
);

    // Latch control inputs at start of a DMA op so they don't change mid-flight
    logic        ls_active;
    logic        latched_is_store;
    logic [2:0]  latched_target_id;
    logic [31:0] latched_base_addr;
    logic [31:0] latched_row_stride;
    logic [1:0]  latched_elem_size;
    logic [3:0]  latched_matrix_sel;
    logic [31:0] latched_tile_m;
    logic [31:0] latched_tile_n;
    logic [31:0] latched_tile_k;

    assign reg_id = latched_target_id;

    assign m_axi_awsize     = 3'b010; // 4 bytes
    assign m_axi_awburst    = 2'b01;  // incr
    assign m_axi_arsize     = 3'b010;
    assign m_axi_arburst    = 2'b01;

    //FSM states
    typedef enum logic [2:0] {
        ST_IDLE     =   3'd0,
        ST_CALC_ROW =   3'd1,
        ST_AW_REQ   =   3'd2,
        ST_W_BURST  =   3'd3,
        ST_B_WAIT   =   3'd4,
        ST_AR_REQ   =   3'd5,
        ST_R_BURST  =   3'd6,
        ST_NEXT_ROW =   3'd7
    }   fsm_state_t;

    fsm_state_t state;

    //Counter
    logic [2:0] row_cnt;
    logic [2:0] beat_cnt;

    // Map current DMA indices to regfile read address
    assign reg_row_idx  = row_cnt;
    assign reg_beat_idx = beat_cnt;

    // Use combinational regfile read for store data
    assign m_axi_wdata = reg_rdata;

    // Use combinational write for load data to avoid beat misalignment
    assign reg_we    = (state == ST_R_BURST) && m_axi_rvalid && m_axi_rready;
    assign reg_wdata = m_axi_rdata;

    // Packed-lite row transfer. A uses MxK, B is stored transposed as NxK,
    // and C/ACC uses MxN. The transfer shape follows the configured tile.
    localparam int BEATS_PER_ROW = REG_BEATS_PER_ROW;
    localparam logic [4:0] MATRIX_DIM_L = MATRIX_DIM;
    localparam logic [3:0] BEATS_PER_ROW_L = REG_BEATS_PER_ROW;

    logic [4:0] transfer_rows;
    logic [4:0] transfer_cols;
    logic [4:0] active_rows;
    logic [4:0] active_cols;
    logic [6:0] row_bytes;
    logic [3:0] beats_calc;
    logic [2:0] beats_per_row;
    logic [6:0] beat_byte_offset;
    logic [6:0] bytes_remaining;
    logic [3:0] wstrb_for_beat;

    function automatic logic [4:0] transfer_rows_for(
        input logic [3:0]  sel,
        input logic [31:0] m,
        input logic [31:0] n
    );
        unique case (sel)
            4'b0000: transfer_rows_for = m[4:0]; // A: M rows
            4'b0001: transfer_rows_for = n[4:0]; // B is stored transposed: N rows
            4'b0010: transfer_rows_for = m[4:0]; // C/ACC: M rows
            default: transfer_rows_for = MATRIX_DIM_L;
        endcase
    endfunction

    function automatic logic [4:0] transfer_cols_for(
        input logic [3:0]  sel,
        input logic [31:0] m,
        input logic [31:0] n,
        input logic [31:0] k
    );
        unique case (sel)
            4'b0000: transfer_cols_for = k[4:0]; // A: K columns
            4'b0001: transfer_cols_for = k[4:0]; // B transpose rows hold K elements
            4'b0010: transfer_cols_for = n[4:0]; // C/ACC: N columns
            default: transfer_cols_for = MATRIX_DIM_L;
        endcase
    endfunction

    function automatic logic [6:0] row_bytes_for(
        input logic [1:0] elem_sz,
        input logic [4:0] cols
    );
        unique case (elem_sz)
            2'b00: row_bytes_for = {2'b0, cols};       // 8-bit elements
            2'b01: row_bytes_for = {1'b0, cols, 1'b0}; // 16-bit elements
            2'b10: row_bytes_for = {cols, 2'b00};      // 32-bit elements
            default: row_bytes_for = {cols, 2'b00};
        endcase
    endfunction

    function automatic logic [2:0] beats_for_row(
        input logic [6:0] bytes
    );
        logic [3:0] calc;
        begin
            calc = (bytes == 7'd0) ? 4'd0 : ((bytes + 7'd3) >> 2);
            beats_for_row = (calc > BEATS_PER_ROW_L) ? BEATS_PER_ROW_L[2:0] : calc[2:0];
        end
    endfunction

    function automatic logic [3:0] wstrb_for_remaining_bytes(
        input logic [6:0] remaining
    );
        unique case (remaining)
            7'd0:    wstrb_for_remaining_bytes = 4'b0000;
            7'd1:    wstrb_for_remaining_bytes = 4'b0001;
            7'd2:    wstrb_for_remaining_bytes = 4'b0011;
            7'd3:    wstrb_for_remaining_bytes = 4'b0111;
            default: wstrb_for_remaining_bytes = 4'b1111;
        endcase
    endfunction

    always_comb begin
        transfer_rows = transfer_rows_for(latched_matrix_sel, latched_tile_m, latched_tile_n);
        transfer_cols = transfer_cols_for(latched_matrix_sel, latched_tile_m, latched_tile_n, latched_tile_k);
        active_rows = (transfer_rows > MATRIX_DIM_L) ? MATRIX_DIM_L : transfer_rows;
        active_cols = transfer_cols;
        row_bytes = row_bytes_for(latched_elem_size, active_cols);
        beats_calc = (row_bytes == 7'd0) ? 4'd0 : ((row_bytes + 7'd3) >> 2);
        beats_per_row = beats_for_row(row_bytes);
        beat_byte_offset = {2'b0, beat_cnt, 2'b00};
        bytes_remaining = (row_bytes > beat_byte_offset) ? (row_bytes - beat_byte_offset) : 7'd0;
        wstrb_for_beat = wstrb_for_remaining_bytes(bytes_remaining);
    end

    logic [7:0] burst_len;
    logic       w_last;
    assign burst_len    = (beats_per_row == 3'd0) ? 8'd0 : ({5'b0, beats_per_row} - 8'd1);
    assign m_axi_awlen  = burst_len;
    assign m_axi_arlen  = burst_len;
    assign w_last       = (beat_cnt == burst_len[2:0]);
    assign m_axi_wlast  = m_axi_wvalid && (state == ST_W_BURST) && w_last;
    assign m_axi_wstrb  = (state == ST_W_BURST) ? wstrb_for_beat : 4'b0000;

    logic [31:0]    current_row_addr;
    assign current_row_addr = latched_base_addr + (row_cnt * latched_row_stride);

    //Main FSM
    always_ff @(posedge clk) begin
        if(!resetn) begin
            state           <= ST_IDLE;
            dma_done        <= 1'b0;
            row_cnt         <= '0;
            beat_cnt        <= '0;
            m_axi_awvalid   <= 1'b0;
            m_axi_wvalid    <= 1'b0;
            m_axi_bready    <= 1'b0;
            m_axi_arvalid   <= 1'b0;
            m_axi_rready    <= 1'b0;
            ls_active        <= 1'b0;
            latched_is_store <= 1'b0;
            latched_target_id<= '0;
            latched_base_addr<= '0;
            latched_row_stride<= '0;
            latched_elem_size<= '0;
            latched_matrix_sel<= '0;
            latched_tile_m    <= '0;
            latched_tile_n    <= '0;
            latched_tile_k    <= '0;
        end else begin
            //mac dinh
            dma_done <= 1'b0;

            case(state)
                ST_IDLE: begin
                    row_cnt     <= '0;
                    beat_cnt    <= '0;
                    if(start_ls) begin
                        ls_active         <= 1'b1;
                        latched_is_store  <= is_store;
                        latched_target_id <= target_matrix_id;
                        latched_base_addr <= base_addr;
                        latched_row_stride<= row_stride;
                        latched_elem_size <= elem_size;
                        latched_matrix_sel<= matrix_sel;
                        latched_tile_m     <= tile_m;
                        latched_tile_n     <= tile_n;
                        latched_tile_k     <= tile_k;
                        state   <= ST_CALC_ROW;
                    end
                end

                ST_CALC_ROW: begin
                    beat_cnt    <= '0;
                    if ((active_rows == 5'd0) || (beats_per_row == 3'd0)) begin
                        dma_done  <= 1'b1;
                        ls_active <= 1'b0;
                        state     <= ST_IDLE;
                    end else if(latched_is_store) begin
                        m_axi_awaddr <= current_row_addr;
                        state        <= ST_AW_REQ;
                    end else begin
                        m_axi_araddr <= current_row_addr;
                        state        <= ST_AR_REQ;
                    end
                end

                //Store burst

                ST_AW_REQ: begin
                    m_axi_awvalid   <= 1'b1;
                    if(m_axi_awready && m_axi_awvalid) begin
                        m_axi_awvalid <= 1'b0;
                        state         <= ST_W_BURST;
                    end
                end

                ST_W_BURST: begin
                    m_axi_wvalid <= 1'b1;

                    if (m_axi_wready && m_axi_wvalid) begin
                        if(w_last) begin
                            m_axi_wvalid <= 1'b0;
                            m_axi_bready <= 1'b1;
                            state        <= ST_B_WAIT;
                        end else begin
                            beat_cnt <= beat_cnt + 3'd1;
                        end
                    end
                end

                ST_B_WAIT: begin
                    if(m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready <= 1'b0;
                        state        <= ST_NEXT_ROW;
                    end
                end

                //Load burst
                ST_AR_REQ: begin
                    m_axi_arvalid <= 1'b1;
                    if(m_axi_arready && m_axi_arvalid) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready  <= 1'b1;
                        state         <= ST_R_BURST;
                    end
                end

                ST_R_BURST: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        if(m_axi_rlast || beat_cnt == burst_len[2:0]) begin
                            m_axi_rready <= 1'b0;
                            state        <= ST_NEXT_ROW;
                        end else begin
                            beat_cnt <= beat_cnt + 3'd1;
                        end
                    end
                end

                //Next row
                ST_NEXT_ROW: begin
                    if(row_cnt == active_rows[2:0] - 3'd1) begin
                        dma_done <= 1'b1;
                        ls_active <= 1'b0;
                        state    <= ST_IDLE;
                    end else begin
                        row_cnt <= row_cnt + 3'd1;
                        state   <= ST_CALC_ROW;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule






