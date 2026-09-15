module matrix_regfile_bram #(
    parameter int MATRIX_DIM = 4,
    parameter int BEATS_PER_ROW = 4,
    parameter int ACC_BEATS_PER_ROW = 8,
    parameter logic [31:0] ISA_FEATURE = 32'h0000_0002
)(
    input  logic clk,
    input  logic resetn,

    input  logic        reg_we,
    input  logic [2:0]  reg_id,
    input  logic [2:0]  reg_row_idx,
    input  logic [2:0]  reg_beat_idx,
    input  logic [31:0] reg_wdata,

    input  logic [2:0]  host_read_id,
    input  logic [2:0]  host_read_row,
    input  logic [2:0]  host_read_beat,
    output logic [31:0] reg_rdata,

    input  logic [2:0]  mac_read_id_A,
    input  logic [2:0]  mac_read_row_A,
    input  logic [2:0]  mac_read_beat_A,
    output logic [31:0] reg_mac_rdata_A,

    input  logic [2:0]  mac_read_id_B,
    input  logic [2:0]  mac_read_row_B,
    input  logic [2:0]  mac_read_beat_B,
    output logic [31:0] reg_mac_rdata_B,

    input  logic [2:0]  mac_read_id_C,
    input  logic [2:0]  mac_read_row_C,
    input  logic [2:0]  mac_read_beat_C,
    output logic [63:0] reg_mac_rdata_C,

    input  logic [2:0]   mac_vec_read_id_A,
    input  logic [11:0]  mac_vec_read_beats_A,
    output logic [127:0] reg_mac_vec_rdata_A,

    input  logic [2:0]   mac_vec_read_id_B,
    input  logic [11:0]  mac_vec_read_beats_B,
    output logic [127:0] reg_mac_vec_rdata_B,

    input  logic        csr_we,
    input  logic [11:0] csr_addr,
    input  logic [31:0] csr_wdata,
    output logic [31:0] csr_rdata,

    output logic [31:0] out_mtilem,
    output logic [31:0] out_mtilen,
    output logic [31:0] out_mtilek,
    output logic [1:0]  out_xmxrm,
    output logic        out_xmsat,
    output logic [2:0]  out_xmfrm,
    output logic        out_xmsaten
);

    // Experimental BRAM-backed register file.
    //
    // This module keeps the same top-level port list as matrix_regfile, but the
    // data-read behavior is intentionally different: reads are synchronous and
    // the data appears one clock after the read address is presented.
    //
    // It is therefore not a drop-in replacement for the current matrix core
    // without adding read-wait states to MAC/EW/MISC/load-store FSMs.
    //
    // Multiple read ports are implemented by memory replication. This spends
    // more BRAMs, but avoids the large multi-read LUT/FF register file.

    localparam int NUM_ARCH_REGS  = 4;
    localparam int TR_DEPTH       = NUM_ARCH_REGS * MATRIX_DIM * BEATS_PER_ROW;
    localparam int ACC_DEPTH      = NUM_ARCH_REGS * MATRIX_DIM * ACC_BEATS_PER_ROW;
    localparam int NUM_READ_PORTS = 13;

    localparam int RP_HOST   = 0;
    localparam int RP_A      = 1;
    localparam int RP_B      = 2;
    localparam int RP_C_LO   = 3;
    localparam int RP_C_HI   = 4;
    localparam int RP_VEC_A0 = 5;
    localparam int RP_VEC_A1 = 6;
    localparam int RP_VEC_A2 = 7;
    localparam int RP_VEC_A3 = 8;
    localparam int RP_VEC_B0 = 9;
    localparam int RP_VEC_B1 = 10;
    localparam int RP_VEC_B2 = 11;
    localparam int RP_VEC_B3 = 12;

    (* ram_style = "block" *)
    logic [31:0] tr_mem [0:NUM_READ_PORTS-1][0:TR_DEPTH-1];

    (* ram_style = "block" *)
    logic [31:0] acc_mem [0:NUM_READ_PORTS-1][0:ACC_DEPTH-1];

    logic [2:0]  rd_id   [0:NUM_READ_PORTS-1];
    logic [2:0]  rd_row  [0:NUM_READ_PORTS-1];
    logic [3:0]  rd_beat [0:NUM_READ_PORTS-1];
    logic [31:0] rd_data_q [0:NUM_READ_PORTS-1];

    logic       wr_is_acc;
    logic [1:0] wr_idx;
    logic       wr_tr_valid;
    logic       wr_acc_valid;
    int unsigned tr_wr_addr;
    int unsigned acc_wr_addr;

    assign wr_is_acc = reg_id[2];
    assign wr_idx    = reg_id[1:0];

    assign wr_tr_valid = reg_we && !wr_is_acc &&
                         (reg_row_idx < MATRIX_DIM) &&
                         (reg_beat_idx < BEATS_PER_ROW);

    assign wr_acc_valid = reg_we && wr_is_acc &&
                          (reg_row_idx < MATRIX_DIM) &&
                          (reg_beat_idx < ACC_BEATS_PER_ROW);

    function automatic int unsigned tr_addr(
        input logic [1:0] idx,
        input logic [2:0] row,
        input logic [3:0] beat
    );
        begin
            tr_addr = ((idx * MATRIX_DIM) + row) * BEATS_PER_ROW + beat;
        end
    endfunction

    function automatic int unsigned acc_addr(
        input logic [1:0] idx,
        input logic [2:0] row,
        input logic [3:0] beat
    );
        begin
            acc_addr = ((idx * MATRIX_DIM) + row) * ACC_BEATS_PER_ROW + beat;
        end
    endfunction

    function automatic logic valid_tr_read(
        input logic [2:0] id,
        input logic [2:0] row,
        input logic [3:0] beat
    );
        begin
            valid_tr_read = !id[2] && (row < MATRIX_DIM) && (beat < BEATS_PER_ROW);
        end
    endfunction

    function automatic logic valid_acc_read(
        input logic [2:0] id,
        input logic [2:0] row,
        input logic [3:0] beat
    );
        begin
            valid_acc_read = id[2] && (row < MATRIX_DIM) && (beat < ACC_BEATS_PER_ROW);
        end
    endfunction

    always_comb begin
        rd_id[RP_HOST] = host_read_id;
        rd_row[RP_HOST] = host_read_row;
        rd_beat[RP_HOST] = {1'b0, host_read_beat};

        rd_id[RP_A] = mac_read_id_A;
        rd_row[RP_A] = mac_read_row_A;
        rd_beat[RP_A] = {1'b0, mac_read_beat_A};

        rd_id[RP_B] = mac_read_id_B;
        rd_row[RP_B] = mac_read_row_B;
        rd_beat[RP_B] = {1'b0, mac_read_beat_B};

        rd_id[RP_C_LO] = mac_read_id_C;
        rd_row[RP_C_LO] = mac_read_row_C;
        rd_beat[RP_C_LO] = {1'b0, mac_read_beat_C};

        rd_id[RP_C_HI] = mac_read_id_C;
        rd_row[RP_C_HI] = mac_read_row_C;
        rd_beat[RP_C_HI] = {1'b0, mac_read_beat_C} + 4'd1;

        rd_id[RP_VEC_A0] = mac_vec_read_id_A;
        rd_row[RP_VEC_A0] = 3'd0;
        rd_beat[RP_VEC_A0] = {1'b0, mac_vec_read_beats_A[2:0]};

        rd_id[RP_VEC_A1] = mac_vec_read_id_A;
        rd_row[RP_VEC_A1] = 3'd1;
        rd_beat[RP_VEC_A1] = {1'b0, mac_vec_read_beats_A[5:3]};

        rd_id[RP_VEC_A2] = mac_vec_read_id_A;
        rd_row[RP_VEC_A2] = 3'd2;
        rd_beat[RP_VEC_A2] = {1'b0, mac_vec_read_beats_A[8:6]};

        rd_id[RP_VEC_A3] = mac_vec_read_id_A;
        rd_row[RP_VEC_A3] = 3'd3;
        rd_beat[RP_VEC_A3] = {1'b0, mac_vec_read_beats_A[11:9]};

        rd_id[RP_VEC_B0] = mac_vec_read_id_B;
        rd_row[RP_VEC_B0] = 3'd0;
        rd_beat[RP_VEC_B0] = {1'b0, mac_vec_read_beats_B[2:0]};

        rd_id[RP_VEC_B1] = mac_vec_read_id_B;
        rd_row[RP_VEC_B1] = 3'd1;
        rd_beat[RP_VEC_B1] = {1'b0, mac_vec_read_beats_B[5:3]};

        rd_id[RP_VEC_B2] = mac_vec_read_id_B;
        rd_row[RP_VEC_B2] = 3'd2;
        rd_beat[RP_VEC_B2] = {1'b0, mac_vec_read_beats_B[8:6]};

        rd_id[RP_VEC_B3] = mac_vec_read_id_B;
        rd_row[RP_VEC_B3] = 3'd3;
        rd_beat[RP_VEC_B3] = {1'b0, mac_vec_read_beats_B[11:9]};
    end

    assign tr_wr_addr  = tr_addr(wr_idx, reg_row_idx, {1'b0, reg_beat_idx});
    assign acc_wr_addr = acc_addr(wr_idx, reg_row_idx, {1'b0, reg_beat_idx});

    always_ff @(posedge clk) begin
        if (!resetn) begin
            for (int p = 0; p < NUM_READ_PORTS; p++) begin
                rd_data_q[p] <= 32'b0;
            end
        end else begin
            for (int p = 0; p < NUM_READ_PORTS; p++) begin
                if (wr_tr_valid) begin
                    tr_mem[p][tr_wr_addr] <= reg_wdata;
                end
                if (wr_acc_valid) begin
                    acc_mem[p][acc_wr_addr] <= reg_wdata;
                end

                if (wr_tr_valid &&
                    valid_tr_read(rd_id[p], rd_row[p], rd_beat[p]) &&
                    (rd_id[p][1:0] == wr_idx) &&
                    (rd_row[p] == reg_row_idx) &&
                    (rd_beat[p] == {1'b0, reg_beat_idx})) begin
                    rd_data_q[p] <= reg_wdata;
                end else if (wr_acc_valid &&
                             valid_acc_read(rd_id[p], rd_row[p], rd_beat[p]) &&
                             (rd_id[p][1:0] == wr_idx) &&
                             (rd_row[p] == reg_row_idx) &&
                             (rd_beat[p] == {1'b0, reg_beat_idx})) begin
                    rd_data_q[p] <= reg_wdata;
                end else if (valid_tr_read(rd_id[p], rd_row[p], rd_beat[p])) begin
                    rd_data_q[p] <= tr_mem[p][tr_addr(rd_id[p][1:0], rd_row[p], rd_beat[p])];
                end else if (valid_acc_read(rd_id[p], rd_row[p], rd_beat[p])) begin
                    rd_data_q[p] <= acc_mem[p][acc_addr(rd_id[p][1:0], rd_row[p], rd_beat[p])];
                end else begin
                    rd_data_q[p] <= 32'b0;
                end
            end
        end
    end

    assign reg_rdata = rd_data_q[RP_HOST];

    assign reg_mac_rdata_A = rd_data_q[RP_A];
    assign reg_mac_rdata_B = rd_data_q[RP_B];
    assign reg_mac_rdata_C = {rd_data_q[RP_C_HI], rd_data_q[RP_C_LO]};

    assign reg_mac_vec_rdata_A = {
        rd_data_q[RP_VEC_A3],
        rd_data_q[RP_VEC_A2],
        rd_data_q[RP_VEC_A1],
        rd_data_q[RP_VEC_A0]
    };

    assign reg_mac_vec_rdata_B = {
        rd_data_q[RP_VEC_B3],
        rd_data_q[RP_VEC_B2],
        rd_data_q[RP_VEC_B1],
        rd_data_q[RP_VEC_B0]
    };

    // CSR storage remains implemented as ordinary registers. These registers
    // are small, control-oriented, and should not be put in BRAM.
    localparam logic [31:0] MAX_M_TILE = MATRIX_DIM;
    localparam logic [31:0] MAX_N_TILE = MATRIX_DIM;
    localparam logic [31:0] MAX_K_TILE = 32'd16;

    logic [31:0] csr_mtilem;
    logic [31:0] csr_mtilen;
    logic [31:0] csr_mtilek;

    logic [4:0]  csr_xmfflags;
    logic [2:0]  csr_xmfrm;
    logic [1:0]  csr_xmxrm;
    logic        csr_xmsat;
    logic        csr_xmsaten;

    assign out_mtilem  = csr_mtilem;
    assign out_mtilen  = csr_mtilen;
    assign out_mtilek  = csr_mtilek;
    assign out_xmxrm   = csr_xmxrm;
    assign out_xmsat   = csr_xmsat;
    assign out_xmfrm   = csr_xmfrm;
    assign out_xmsaten = csr_xmsaten;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            csr_mtilem   <= 32'b0;
            csr_mtilen   <= 32'b0;
            csr_mtilek   <= 32'b0;
            csr_xmfflags <= 5'b0;
            csr_xmfrm    <= 3'b0;
            csr_xmxrm    <= 2'b0;
            csr_xmsat    <= 1'b0;
            csr_xmsaten  <= 1'b0;
        end else if (csr_we) begin
            case (csr_addr)
                12'h802: begin
                    csr_xmsaten  <= csr_wdata[11];
                    csr_xmfrm    <= csr_wdata[10:8];
                    csr_xmfflags <= csr_wdata[7:3];
                    csr_xmsat    <= csr_wdata[2];
                    csr_xmxrm    <= csr_wdata[1:0];
                end
                12'h803: csr_mtilem   <= (csr_wdata > MAX_M_TILE) ? MAX_M_TILE : csr_wdata;
                12'h804: csr_mtilen   <= (csr_wdata > MAX_N_TILE) ? MAX_N_TILE : csr_wdata;
                12'h805: csr_mtilek   <= (csr_wdata > MAX_K_TILE) ? MAX_K_TILE : csr_wdata;
                12'h806: csr_xmxrm    <= csr_wdata[1:0];
                12'h807: csr_xmsat    <= csr_wdata[0];
                12'h808: csr_xmfflags <= csr_wdata[4:0];
                12'h809: csr_xmfrm    <= csr_wdata[2:0];
                12'h80A: csr_xmsaten  <= csr_wdata[0];
                default: ;
            endcase
        end
    end

    always_comb begin
        case (csr_addr)
            12'h802: csr_rdata = {20'b0, csr_xmsaten, csr_xmfrm, csr_xmfflags, csr_xmsat, csr_xmxrm};
            12'h803: csr_rdata = csr_mtilem;
            12'h804: csr_rdata = csr_mtilen;
            12'h805: csr_rdata = csr_mtilek;
            12'h806: csr_rdata = {30'b0, csr_xmxrm};
            12'h807: csr_rdata = {31'b0, csr_xmsat};
            12'h808: csr_rdata = {27'b0, csr_xmfflags};
            12'h809: csr_rdata = {29'b0, csr_xmfrm};
            12'h80A: csr_rdata = {31'b0, csr_xmsaten};
            12'hCC0: csr_rdata = ISA_FEATURE;
            12'hCC1: csr_rdata = MATRIX_DIM * BEATS_PER_ROW * 4;
            12'hCC2: csr_rdata = BEATS_PER_ROW * 4;
            12'hCC3: csr_rdata = MATRIX_DIM * ACC_BEATS_PER_ROW * 4;
            default: csr_rdata = 32'b0;
        endcase
    end

endmodule
