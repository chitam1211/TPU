`timescale 1ns / 1ps

// RV32I matrix core v2.
//
// This version removes the PicoRV32 PCPI path. Matrix custom instructions enter
// through a native RV32I pipeline dispatch interface:
//   CPU EX -> matrix_dispatch -> matrix_core_v2 -> matrix_regfile/FUs
// Tile load/store instructions use the CPU data-memory port while the pipeline
// is stalled. The host regfile port remains only for debug/test inspection.
module matrix_core_v2
    import matrix_cfg_pkg::*;
#(
    // Defaults come from matrix_cfg_pkg (ELEN/TLEN/TRLEN of the proposal).
    parameter int REG_ROWS = ROWNUM,
    parameter int REG_BEATS_PER_ROW = TR_BEATS,
    parameter int ACC_BEATS_PER_ROW = ACC_BEATS,
    parameter int COMPUTE_ROWS = TMMAX,
    parameter int COMPUTE_COLS = TNMAX,
    parameter int MAX_K_INT8 = TKMAX_INT8,
    parameter int MAX_K_FP32 = TKMAX_FP32,
    localparam int RF_ROW_W  = idx_w(REG_ROWS),
    localparam int RF_BEAT_W = idx_w(max2(REG_BEATS_PER_ROW, ACC_BEATS_PER_ROW)),
    // Debug host port keeps at least the 3-bit CPU-top pins: an index past the
    // register is ignored on write and reads as 0.
    localparam int HOST_IDX_W = max2(3, max2(RF_ROW_W, RF_BEAT_W))
)(
    input  logic        clk,
    input  logic        resetn,

    // Native matrix dispatch interface from the RV32I pipeline.
    input  logic        matrix_valid,
    input  logic [31:0] matrix_insn,
    input  logic [31:0] matrix_rs1,
    input  logic [31:0] matrix_rs2,
    output logic        matrix_supported,
    output logic        matrix_busy,
    output logic        matrix_done,
    output logic        matrix_wb_we,
    output logic [4:0]  matrix_wb_rd,
    output logic [31:0] matrix_wb_data,

    // Data-memory port borrowed from the RV32I MEM stage while the matrix
    // instruction stalls the pipeline.
    output logic        matrix_mem_request,
    output logic        matrix_mem_we,
    output logic [31:0] matrix_mem_addr,
    output logic [31:0] matrix_mem_wdata,
    output logic [3:0]  matrix_mem_wstrb,
    input  logic [31:0] matrix_mem_rdata,
    input  logic        matrix_mem_rvalid,

    // Simple host/test port for preloading and inspecting the matrix regfile.
    input  logic                  host_reg_we,
    input  logic [REG_ID_W-1:0]   host_reg_id,
    input  logic [HOST_IDX_W-1:0] host_reg_row_idx,
    input  logic [HOST_IDX_W-1:0] host_reg_beat_idx,
    input  logic [31:0]           host_reg_wdata,

    input  logic [REG_ID_W-1:0]   host_read_id,
    input  logic [HOST_IDX_W-1:0] host_read_row,
    input  logic [HOST_IDX_W-1:0] host_read_beat,
    output logic [31:0]           host_reg_rdata,

    output logic [31:0] debug_mtilem,
    output logic [31:0] debug_mtilen,
    output logic [31:0] debug_mtilek
);

    // Proposal ch. 2 constraints on the configuration in matrix_cfg_pkg.
    initial begin
        if ((TLEN & (TLEN - 1)) != 0 || (TRLEN & (TRLEN - 1)) != 0 ||
            TRLEN > TLEN || TRLEN < WORD_W)
            $fatal(1, "TLEN/TRLEN must be powers of 2 with 32 <= TRLEN <= TLEN");
        // C elements are stored and accumulated as single 32-bit beats.
        if (ELEN != 32)
            $fatal(1, "Only ELEN = 32 is implemented");
    end

    // Compute capacities must fit the register storage. B is transposed, so N
    // needs RF rows as well as C beats; K is limited by the tile row width.
    initial begin
        if (COMPUTE_ROWS > REG_ROWS || COMPUTE_COLS > REG_ROWS ||
            COMPUTE_COLS > ACC_BEATS_PER_ROW || MAX_K_FP32 > REG_BEATS_PER_ROW ||
            MAX_K_INT8 > REG_BEATS_PER_ROW * INT8_PER_WORD)
            $fatal(1, "MAC tile capacities exceed matrix register storage");
    end

    logic start_mld, start_matmul, start_mst, start_cfg, start_misc, start_ew;
    logic start_fp_matmul, start_fp_ew;
    logic fp_ew_active, fp_ew_done, fp_ew_illegal, fp_ew_reg_we;
    logic [4:0] fp_ew_fflags;
    logic [REG_ID_W-1:0]  fp_ew_reg_id;
    logic [RF_ROW_W-1:0]  fp_ew_reg_row_idx;
    logic [RF_BEAT_W-1:0] fp_ew_reg_beat_idx;
    logic [31:0] fp_ew_reg_wdata;
    logic [REG_ID_W-1:0]  fp_ew_read_id_A, fp_ew_read_id_B;
    logic [RF_ROW_W-1:0]  fp_ew_read_row_A, fp_ew_read_row_B;
    logic [RF_BEAT_W-1:0] fp_ew_read_beat_A, fp_ew_read_beat_B;
    logic [REG_ID_W-1:0]  ms1_reg_id, ms2_reg_id, md_tr_id, md_acc_id;

    logic        mac_reg_we;
    // Retained locally like fp_mac_illegal; CPU trap routing is not implemented.
    logic        int_mac_illegal;
    logic        ew_illegal;   // int element-wise tile above the legal shape
    logic        ls_illegal;   // tile load/store with an unsupported mtile* setting
    logic [REG_ID_W-1:0]  mac_reg_id;
    logic [RF_ROW_W-1:0]  mac_reg_row_idx;
    logic [RF_BEAT_W-1:0] mac_reg_beat_idx;
    logic [31:0]          mac_reg_wdata;

    logic        fp_mac_reg_we;
    logic [REG_ID_W-1:0]  fp_mac_reg_id;
    logic [RF_ROW_W-1:0]  fp_mac_reg_row_idx;
    logic [RF_BEAT_W-1:0] fp_mac_reg_beat_idx;
    logic [31:0] fp_mac_reg_wdata;
    logic [REG_ID_W-1:0]  fp_mac_read_id_A, fp_mac_read_id_B, fp_mac_read_id_C;
    logic [RF_ROW_W-1:0]  fp_mac_read_row_A, fp_mac_read_row_B, fp_mac_read_row_C;
    logic [RF_BEAT_W-1:0] fp_mac_read_beat_A, fp_mac_read_beat_B, fp_mac_read_beat_C;
    logic        fp_mac_done, fp_mac_active;
    // Retain the FP unit status for inspection. The existing CPU interface
    // has no illegal-instruction trap or hardware xmfflags update path.
    logic        fp_mac_illegal;
    logic [4:0]  fp_mac_fflags;

    logic        misc_reg_we;
    logic [REG_ID_W-1:0]  misc_reg_id;
    logic [RF_ROW_W-1:0]  misc_reg_row_idx;
    logic [RF_BEAT_W-1:0] misc_reg_beat_idx;
    logic [31:0] misc_reg_wdata;

    logic        ew_reg_we;
    logic [REG_ID_W-1:0]  ew_reg_id;
    logic [RF_ROW_W-1:0]  ew_reg_row_idx;
    logic [RF_BEAT_W-1:0] ew_reg_beat_idx;
    logic [31:0] ew_reg_wdata;

    logic        ls_reg_we;
    logic [REG_ID_W-1:0]  ls_reg_id;
    logic [RF_ROW_W-1:0]  ls_reg_row_idx;
    logic [RF_BEAT_W-1:0] ls_reg_beat_idx;
    logic [31:0] ls_reg_wdata;
    logic [REG_ID_W-1:0]  ls_read_id;
    logic [RF_ROW_W-1:0]  ls_read_row;
    logic [RF_BEAT_W-1:0] ls_read_beat;

    logic [REG_ID_W-1:0]  mac_read_id_A, mac_read_id_B, mac_read_id_C;
    logic [RF_ROW_W-1:0]  mac_read_row_A, mac_read_row_B, mac_read_row_C;
    logic [RF_BEAT_W-1:0] mac_read_beat_A, mac_read_beat_B, mac_read_beat_C;
    logic [31:0] reg_mac_rdata_A, reg_mac_rdata_B, reg_mac_rdata_C;

    // The integer MAC reads every row at one beat; the regfile vector port
    // takes a beat per row, so the beat is replicated across REG_ROWS lanes.
    logic [REG_ID_W-1:0]            mac_vec_read_id_A, mac_vec_read_id_B;
    logic [RF_BEAT_W-1:0]           mac_vec_read_beat_A, mac_vec_read_beat_B;
    logic [REG_ROWS*32-1:0]         reg_mac_vec_rdata_A, reg_mac_vec_rdata_B;

    logic [REG_ID_W-1:0]  misc_read_id_A;
    logic [RF_ROW_W-1:0]  misc_read_row_A;
    logic [RF_BEAT_W-1:0] misc_read_beat_A;
    logic [REG_ID_W-1:0]  ew_read_id_A, ew_read_id_B;
    logic [RF_ROW_W-1:0]  ew_read_row_A, ew_read_row_B;
    logic [RF_BEAT_W-1:0] ew_read_beat_A, ew_read_beat_B;

    logic [REG_ID_W-1:0]  core_read_id_A, core_read_id_B, core_read_id_C;
    logic [RF_ROW_W-1:0]  core_read_row_A, core_read_row_B, core_read_row_C;
    logic [RF_BEAT_W-1:0] core_read_beat_A, core_read_beat_B, core_read_beat_C;

    logic [31:0] csr_rdata;
    logic [31:0] out_mtilem, out_mtilek, out_mtilen;
    logic [2:0]  out_xmfrm;
    logic        out_xmsat, out_xmsaten;

    logic mac_done, misc_done, ew_done, ls_done, core_done;
    logic misc_gpr_we;
    logic [31:0] misc_gpr_wdata;

    logic        cfg_we;
    logic [11:0] cfg_addr;
    logic [31:0] cfg_wdata;

    logic mac_active, misc_active, ew_active, ls_active;

    assign debug_mtilem = out_mtilem;
    assign debug_mtilen = out_mtilen;
    assign debug_mtilek = out_mtilek;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            core_done <= 1'b0;
        end else begin
            core_done <= mac_done | fp_mac_done | fp_ew_done | misc_done | ew_done | ls_done | start_cfg;
        end
    end

    always_ff @(posedge clk) begin
        if (!resetn) begin
            mac_active  <= 1'b0;
            fp_mac_active <= 1'b0;
            fp_ew_active <= 1'b0;
            misc_active <= 1'b0;
            ew_active   <= 1'b0;
            ls_active   <= 1'b0;
        end else begin
            if (start_matmul) begin
                mac_active <= 1'b1;
            end else if (mac_done) begin
                mac_active <= 1'b0;
            end

            if (start_fp_matmul) begin
                fp_mac_active <= 1'b1;
            end else if (fp_mac_done) begin
                fp_mac_active <= 1'b0;
            end

            if (start_fp_ew) fp_ew_active <= 1'b1;
            else if (fp_ew_done) fp_ew_active <= 1'b0;

            if (start_misc) begin
                misc_active <= 1'b1;
            end else if (misc_done) begin
                misc_active <= 1'b0;
            end

            if (start_ew) begin
                ew_active <= 1'b1;
            end else if (ew_done) begin
                ew_active <= 1'b0;
            end

            if (start_mld || start_mst) begin
                ls_active <= 1'b1;
            end else if (ls_done) begin
                ls_active <= 1'b0;
            end
        end
    end

    always_comb begin
        cfg_we    = 1'b0;
        cfg_addr  = 12'h000;
        cfg_wdata = 32'b0;

        if (start_cfg) begin
            unique case (matrix_insn[31:28])
                4'b0000: begin
                    cfg_we = 1'b0; // mrelease
                end
                4'b0001: begin
                    cfg_we    = 1'b1;
                    cfg_addr  = 12'h805; // mtilek
                    cfg_wdata = matrix_insn[25] ? matrix_rs1 : {22'b0, matrix_insn[24:15]};
                end
                4'b0010: begin
                    cfg_we    = 1'b1;
                    cfg_addr  = 12'h803; // mtilem
                    cfg_wdata = matrix_insn[25] ? matrix_rs1 : {22'b0, matrix_insn[24:15]};
                end
                4'b0011: begin
                    cfg_we    = 1'b1;
                    cfg_addr  = 12'h804; // mtilen
                    cfg_wdata = matrix_insn[25] ? matrix_rs1 : {22'b0, matrix_insn[24:15]};
                end
                default: begin
                    cfg_we = 1'b0;
                end
            endcase
        end
    end

    logic                 core_reg_we;
    logic [REG_ID_W-1:0]  core_reg_id;
    logic [RF_ROW_W-1:0]  core_reg_row_idx;
    logic [RF_BEAT_W-1:0] core_reg_beat_idx;
    logic [31:0]          core_reg_wdata;

    // Host accesses outside the addressed register (row/beat past its size).
    function automatic logic host_in_range(
        input logic [REG_ID_W-1:0]   id,
        input logic [HOST_IDX_W-1:0] row,
        input logic [HOST_IDX_W-1:0] beat
    );
        return (row < REG_ROWS) &&
               (beat < (id[REG_ID_W-1] ? ACC_BEATS_PER_ROW : REG_BEATS_PER_ROW));
    endfunction

    logic        host_wr_ok, host_rd_ok;
    logic [31:0] host_rf_rdata;

    assign host_wr_ok     = host_reg_we && host_in_range(host_reg_id, host_reg_row_idx, host_reg_beat_idx);
    assign host_rd_ok     = host_in_range(host_read_id, host_read_row, host_read_beat);
    assign host_reg_rdata = host_rd_ok ? host_rf_rdata : 32'b0;

    assign core_reg_we       = mac_reg_we | fp_mac_reg_we | fp_ew_reg_we | ew_reg_we | misc_reg_we | ls_reg_we | host_wr_ok;
    assign core_reg_id       = mac_reg_we  ? mac_reg_id  :
                               fp_mac_reg_we ? fp_mac_reg_id :
                               fp_ew_reg_we ? fp_ew_reg_id :
                               ew_reg_we   ? ew_reg_id   :
                               misc_reg_we ? misc_reg_id :
                               ls_reg_we   ? ls_reg_id   : host_reg_id;
    assign core_reg_row_idx  = mac_reg_we  ? mac_reg_row_idx  :
                               fp_mac_reg_we ? fp_mac_reg_row_idx :
                               fp_ew_reg_we ? fp_ew_reg_row_idx :
                               ew_reg_we   ? ew_reg_row_idx   :
                               misc_reg_we ? misc_reg_row_idx :
                               ls_reg_we   ? ls_reg_row_idx   : RF_ROW_W'(host_reg_row_idx);
    assign core_reg_beat_idx = mac_reg_we  ? mac_reg_beat_idx  :
                               fp_mac_reg_we ? fp_mac_reg_beat_idx :
                               fp_ew_reg_we ? fp_ew_reg_beat_idx :
                               ew_reg_we   ? ew_reg_beat_idx   :
                               misc_reg_we ? misc_reg_beat_idx :
                               ls_reg_we   ? ls_reg_beat_idx   : RF_BEAT_W'(host_reg_beat_idx);
    assign core_reg_wdata    = mac_reg_we  ? mac_reg_wdata :
                               fp_mac_reg_we ? fp_mac_reg_wdata :
                               fp_ew_reg_we ? fp_ew_reg_wdata :
                               ew_reg_we   ? ew_reg_wdata :
                               misc_reg_we ? misc_reg_wdata :
                               ls_reg_we   ? ls_reg_wdata   : host_reg_wdata;

    always_comb begin
        core_read_id_A   = mac_read_id_A;
        core_read_row_A  = mac_read_row_A;
        core_read_beat_A = mac_read_beat_A;

        core_read_id_B   = mac_read_id_B;
        core_read_row_B  = mac_read_row_B;
        core_read_beat_B = mac_read_beat_B;

        core_read_id_C   = mac_read_id_C;
        core_read_row_C  = mac_read_row_C;
        core_read_beat_C = mac_read_beat_C;

        if (!mac_active && fp_mac_active) begin
            core_read_id_A   = fp_mac_read_id_A;
            core_read_row_A  = fp_mac_read_row_A;
            core_read_beat_A = fp_mac_read_beat_A;

            core_read_id_B   = fp_mac_read_id_B;
            core_read_row_B  = fp_mac_read_row_B;
            core_read_beat_B = fp_mac_read_beat_B;

            core_read_id_C   = fp_mac_read_id_C;
            core_read_row_C  = fp_mac_read_row_C;
            core_read_beat_C = fp_mac_read_beat_C;
        end else if (!mac_active && fp_ew_active) begin
            core_read_id_A   = fp_ew_read_id_A;
            core_read_row_A  = fp_ew_read_row_A;
            core_read_beat_A = fp_ew_read_beat_A;
            core_read_id_B   = fp_ew_read_id_B;
            core_read_row_B  = fp_ew_read_row_B;
            core_read_beat_B = fp_ew_read_beat_B;
            core_read_id_C   = '0;
            core_read_row_C  = '0;
            core_read_beat_C = '0;
        end else if (!mac_active && ew_active) begin
            core_read_id_A   = ew_read_id_A;
            core_read_row_A  = ew_read_row_A;
            core_read_beat_A = ew_read_beat_A;

            core_read_id_B   = ew_read_id_B;
            core_read_row_B  = ew_read_row_B;
            core_read_beat_B = ew_read_beat_B;

            core_read_id_C   = '0;
            core_read_row_C  = '0;
            core_read_beat_C = '0;
        end else if (!mac_active && !ew_active && misc_active) begin
            core_read_id_A   = misc_read_id_A;
            core_read_row_A  = misc_read_row_A;
            core_read_beat_A = misc_read_beat_A;

            core_read_id_B   = '0;
            core_read_row_B  = '0;
            core_read_beat_B = '0;

            core_read_id_C   = '0;
            core_read_row_C  = '0;
            core_read_beat_C = '0;
        end else if (!mac_active && !ew_active && !misc_active && ls_active) begin
            core_read_id_A   = ls_read_id;
            core_read_row_A  = ls_read_row;
            core_read_beat_A = ls_read_beat;

            core_read_id_B   = '0;
            core_read_row_B  = '0;
            core_read_beat_B = '0;

            core_read_id_C   = '0;
            core_read_row_C  = '0;
            core_read_beat_C = '0;
        end
    end

    matrix_dispatch #(
        .MATRIX_DIM(REG_ROWS),
        .ENABLE_LS(1'b1)
    ) u_dispatch (
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

        .start_mld(start_mld),
        .start_matmul(start_matmul),
        .start_fp_matmul(start_fp_matmul),
        .start_mst(start_mst),
        .start_cfg(start_cfg),
        .start_misc(start_misc),
        .start_ew(start_ew),
        .start_fp_ew(start_fp_ew),

        .ms1_reg_id(ms1_reg_id),
        .ms2_reg_id(ms2_reg_id),
        .md_tr_id(md_tr_id),
        .md_acc_id(md_acc_id),

        .core_done(core_done),
        .csr_rdata(csr_rdata),
        .misc_gpr_we(misc_gpr_we),
        .misc_gpr_wdata(misc_gpr_wdata)
    );

    matrix_tile_ls #(
        .MATRIX_DIM(REG_ROWS),
        .REG_BEATS_PER_ROW(REG_BEATS_PER_ROW),
        .ACC_BEATS_PER_ROW(ACC_BEATS_PER_ROW)
    ) u_tile_ls (
        .clk(clk),
        .resetn(resetn),
        .start_ls(start_mld | start_mst),
        .is_store(start_mst),
        .target_matrix_id((matrix_insn[31:28] == 4'b0010) ? md_acc_id : md_tr_id),
        .base_addr(matrix_rs1),
        .row_stride(matrix_rs2),
        .elem_size(matrix_insn[11:10]),
        .matrix_sel(matrix_insn[31:28]),
        .tile_m(out_mtilem),
        .tile_n(out_mtilen),
        .tile_k(out_mtilek),
        .ls_done(ls_done),
        .ls_busy(),
        .ls_illegal(ls_illegal),

        .reg_we(ls_reg_we),
        .reg_id(ls_reg_id),
        .reg_row_idx(ls_reg_row_idx),
        .reg_beat_idx(ls_reg_beat_idx),
        .reg_wdata(ls_reg_wdata),
        .reg_read_id(ls_read_id),
        .reg_read_row(ls_read_row),
        .reg_read_beat(ls_read_beat),
        .reg_rdata(reg_mac_rdata_A),

        .mem_request(matrix_mem_request),
        .mem_we(matrix_mem_we),
        .mem_addr(matrix_mem_addr),
        .mem_wdata(matrix_mem_wdata),
        .mem_wstrb(matrix_mem_wstrb),
        .mem_rdata(matrix_mem_rdata),
        .mem_rvalid(matrix_mem_rvalid)
    );

    matrix_mac_int #(
        .COMPUTE_ROWS(COMPUTE_ROWS),
        .COMPUTE_COLS(COMPUTE_COLS),
        .MAX_K_INT8(MAX_K_INT8)
    ) u_mac (
        .clk(clk),
        .resetn(resetn),
        .start_matmul(start_matmul),
        .matrix_insn(matrix_insn),
        .ms1_reg_id(ms1_reg_id),
        .ms2_reg_id(ms2_reg_id),
        .md_acc_id(md_acc_id),
        .mac_done(mac_done),
        .mac_illegal(int_mac_illegal),
        .out_mtilem(out_mtilem),
        .out_mtilen(out_mtilen),
        .out_mtilek(out_mtilek),
        .out_xmsaten(out_xmsaten),

        .mac_reg_we(mac_reg_we),
        .mac_reg_id(mac_reg_id),
        .mac_reg_row_idx(mac_reg_row_idx),
        .mac_reg_beat_idx(mac_reg_beat_idx),
        .mac_reg_wdata(mac_reg_wdata),

        .read_id_A(mac_read_id_A),
        .read_row_A(mac_read_row_A),
        .read_beat_A(mac_read_beat_A),
        .read_data_A(reg_mac_rdata_A),

        .read_id_B(mac_read_id_B),
        .read_row_B(mac_read_row_B),
        .read_beat_B(mac_read_beat_B),
        .read_data_B(reg_mac_rdata_B),

        .read_id_C(mac_read_id_C),
        .read_row_C(mac_read_row_C),
        .read_beat_C(mac_read_beat_C),
        .read_data_C(reg_mac_rdata_C),

        .vec_read_id_A(mac_vec_read_id_A),
        .vec_read_beat_A(mac_vec_read_beat_A),
        .vec_read_data_A(reg_mac_vec_rdata_A),

        .vec_read_id_B(mac_vec_read_id_B),
        .vec_read_beat_B(mac_vec_read_beat_B),
        .vec_read_data_B(reg_mac_vec_rdata_B)
    );

    // FP32 uses the same combinational RF ports and completion handshake as
    // the integer engine. Each FP32 C element occupies one 32-bit beat.
    matrix_fp_mac #(
        .COMPUTE_ROWS(COMPUTE_ROWS),
        .COMPUTE_COLS(COMPUTE_COLS),
        .MAX_K_FP32(MAX_K_FP32)
    ) u_fp_mac (
        .clk(clk),
        .resetn(resetn),
        .start_matmul(start_fp_matmul),
        .ms1_reg_id(ms1_reg_id),
        .ms2_reg_id(ms2_reg_id),
        .md_acc_id(md_acc_id),
        .out_mtilem(out_mtilem),
        .out_mtilen(out_mtilen),
        .out_mtilek(out_mtilek),
        .out_xmfrm(out_xmfrm),
        .busy(),
        .mac_done(fp_mac_done),
        .mac_illegal(fp_mac_illegal),
        .mac_fflags(fp_mac_fflags),
        .mac_reg_we(fp_mac_reg_we),
        .mac_reg_id(fp_mac_reg_id),
        .mac_reg_row_idx(fp_mac_reg_row_idx),
        .mac_reg_beat_idx(fp_mac_reg_beat_idx),
        .mac_reg_wdata(fp_mac_reg_wdata),
        .read_id_A(fp_mac_read_id_A),
        .read_row_A(fp_mac_read_row_A),
        .read_beat_A(fp_mac_read_beat_A),
        .read_data_A(reg_mac_rdata_A),
        .read_id_B(fp_mac_read_id_B),
        .read_row_B(fp_mac_read_row_B),
        .read_beat_B(fp_mac_read_beat_B),
        .read_data_B(reg_mac_rdata_B),
        .read_id_C(fp_mac_read_id_C),
        .read_row_C(fp_mac_read_row_C),
        .read_beat_C(fp_mac_read_beat_C),
        .read_data_C(reg_mac_rdata_C)
    );

    matrix_misc #(
        .MATRIX_DIM(REG_ROWS),
        .BEATS_PER_ROW(REG_BEATS_PER_ROW)
    ) u_misc (
        .clk(clk),
        .resetn(resetn),
        .start_misc(start_misc),
        .matrix_insn(matrix_insn),
        .matrix_rs1(matrix_rs1),
        .matrix_rs2(matrix_rs2),
        
        .misc_done(misc_done),
        .misc_reg_we(misc_reg_we),
        .misc_reg_id(misc_reg_id),
        .misc_reg_row_idx(misc_reg_row_idx),
        .misc_reg_beat_idx(misc_reg_beat_idx),
        .misc_reg_wdata(misc_reg_wdata),
        
        .read_id_A(misc_read_id_A),
        .read_row_A(misc_read_row_A),
        .read_beat_A(misc_read_beat_A),
        .read_data_A(reg_mac_rdata_A),
        .misc_gpr_we(misc_gpr_we),
        .misc_gpr_wdata(misc_gpr_wdata)
    );

    matrix_ew #(
        .MATRIX_DIM(REG_ROWS),
        .BEATS_PER_ROW(REG_BEATS_PER_ROW)
    ) u_ew (
        .clk(clk),
        .resetn(resetn),
        .start_ew(start_ew),
        .matrix_insn(matrix_insn),
        
        .out_xmsaten(out_xmsaten),
        .out_mtilem(out_mtilem),
        .out_mtilen(out_mtilen),
        
        .ew_done(ew_done),
        .ew_illegal(ew_illegal),
        .ew_reg_we(ew_reg_we),
        .ew_reg_id(ew_reg_id),
        .ew_reg_row_idx(ew_reg_row_idx),
        .ew_reg_beat_idx(ew_reg_beat_idx),
        .ew_reg_wdata(ew_reg_wdata),
        
        .read_id_A(ew_read_id_A),
        .read_row_A(ew_read_row_A),
        .read_beat_A(ew_read_beat_A),
        .read_data_A(reg_mac_rdata_A),
        
        .read_id_B(ew_read_id_B),
        .read_row_B(ew_read_row_B),
        .read_beat_B(ew_read_beat_B),
        .read_data_B(reg_mac_rdata_B)
    );

    // Status is retained locally, as for FP MAC (no CPU trap/fflags path).
    matrix_ew_fp #(
        .MATRIX_DIM(REG_ROWS), .BEATS_PER_ROW(REG_BEATS_PER_ROW)
    ) u_fp_ew (
        .clk(clk), 
        .resetn(resetn), 
        .start_fp_ew(start_fp_ew),
        .matrix_insn(matrix_insn), 
        
        .out_xmfrm(out_xmfrm),
        .out_mtilem(out_mtilem), 
        .out_mtilen(out_mtilen),
        
        .fp_ew_done(fp_ew_done), 
        .fp_ew_illegal(fp_ew_illegal),
        .fp_ew_fflags(fp_ew_fflags),
        .fp_ew_reg_we(fp_ew_reg_we),
        .fp_ew_reg_id(fp_ew_reg_id),
        .fp_ew_reg_row_idx(fp_ew_reg_row_idx),
        .fp_ew_reg_beat_idx(fp_ew_reg_beat_idx),
        .fp_ew_reg_wdata(fp_ew_reg_wdata),
        
        .read_id_A(fp_ew_read_id_A),
        .read_row_A(fp_ew_read_row_A),
        .read_beat_A(fp_ew_read_beat_A),
        .read_data_A(reg_mac_rdata_A),
        
        .read_id_B(fp_ew_read_id_B),
        .read_row_B(fp_ew_read_row_B),
        .read_beat_B(fp_ew_read_beat_B),
        .read_data_B(reg_mac_rdata_B)
    );

    matrix_regfile #(
        .MATRIX_DIM(REG_ROWS),
        .BEATS_PER_ROW(REG_BEATS_PER_ROW),
        .ACC_BEATS_PER_ROW(ACC_BEATS_PER_ROW)
    ) u_regfile (
        .clk(clk),
        .resetn(resetn),
        .reg_we(core_reg_we),
        .reg_id(core_reg_id),
        .reg_row_idx(core_reg_row_idx),
        .reg_beat_idx(core_reg_beat_idx),
        .reg_wdata(core_reg_wdata),

        .host_read_id(host_read_id),
        .host_read_row(RF_ROW_W'(host_read_row)),
        .host_read_beat(RF_BEAT_W'(host_read_beat)),
        .reg_rdata(host_rf_rdata),

        .mac_read_id_A(core_read_id_A),
        .mac_read_row_A(core_read_row_A),
        .mac_read_beat_A(core_read_beat_A),
        .reg_mac_rdata_A(reg_mac_rdata_A),

        .mac_read_id_B(core_read_id_B),
        .mac_read_row_B(core_read_row_B),
        .mac_read_beat_B(core_read_beat_B),
        .reg_mac_rdata_B(reg_mac_rdata_B),

        .mac_read_id_C(core_read_id_C),
        .mac_read_row_C(core_read_row_C),
        .mac_read_beat_C(core_read_beat_C),
        .reg_mac_rdata_C(reg_mac_rdata_C),

        .mac_vec_read_id_A(mac_vec_read_id_A),
        .mac_vec_read_beats_A({REG_ROWS{mac_vec_read_beat_A}}),
        .reg_mac_vec_rdata_A(reg_mac_vec_rdata_A),

        .mac_vec_read_id_B(mac_vec_read_id_B),
        .mac_vec_read_beats_B({REG_ROWS{mac_vec_read_beat_B}}),
        .reg_mac_vec_rdata_B(reg_mac_vec_rdata_B),

        .csr_we(cfg_we),
        .csr_addr(cfg_addr),
        .csr_wdata(cfg_wdata),
        .csr_rdata(csr_rdata),

        .out_mtilem(out_mtilem),
        .out_mtilen(out_mtilen),
        .out_mtilek(out_mtilek),
        .out_xmsat(out_xmsat),
        .out_xmfrm(out_xmfrm),
        .out_xmsaten(out_xmsaten)
    );

endmodule
