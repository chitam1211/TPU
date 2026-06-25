`timescale 1ns / 1ps

// RV32I matrix core v2.
//
// This version removes the PicoRV32 PCPI path. Matrix custom instructions enter
// through a native RV32I pipeline dispatch interface:
//   CPU EX -> matrix_dispatch -> matrix_core_v2 -> matrix_regfile/FUs
// Tile load/store instructions use the CPU data-memory port while the pipeline
// is stalled. The host regfile port remains only for debug/test inspection.
module matrix_core_v2 #(
    parameter int REG_ROWS = 4,
    parameter int REG_BEATS_PER_ROW = 4,
    parameter int COMPUTE_ROWS = 4,
    parameter int COMPUTE_COLS = 4,
    parameter int MAX_K_INT8 = 16
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
    input  logic        host_reg_we,
    input  logic [2:0]  host_reg_id,
    input  logic [2:0]  host_reg_row_idx,
    input  logic [2:0]  host_reg_beat_idx,
    input  logic [31:0] host_reg_wdata,

    input  logic [2:0]  host_read_id,
    input  logic [2:0]  host_read_row,
    input  logic [2:0]  host_read_beat,
    output logic [31:0] host_reg_rdata,

    output logic [31:0] debug_mtilem,
    output logic [31:0] debug_mtilen,
    output logic [31:0] debug_mtilek
);

    logic start_mld, start_matmul, start_mst, start_cfg, start_misc, start_ew;
    logic [2:0] ms1_reg_id, ms2_reg_id, md_tr_id, md_acc_id;

    logic        mac_reg_we;
    logic [2:0]  mac_reg_id;
    logic [2:0]  mac_reg_row_idx;
    logic [2:0]  mac_reg_beat_idx;
    logic [63:0] mac_reg_wdata;

    logic        misc_reg_we;
    logic [2:0]  misc_reg_id;
    logic [2:0]  misc_reg_row_idx;
    logic [2:0]  misc_reg_beat_idx;
    logic [31:0] misc_reg_wdata;

    logic        ew_reg_we;
    logic [2:0]  ew_reg_id;
    logic [2:0]  ew_reg_row_idx;
    logic [2:0]  ew_reg_beat_idx;
    logic [31:0] ew_reg_wdata;

    logic        ls_reg_we;
    logic [2:0]  ls_reg_id;
    logic [2:0]  ls_reg_row_idx;
    logic [2:0]  ls_reg_beat_idx;
    logic [31:0] ls_reg_wdata;
    logic [2:0]  ls_read_id, ls_read_row, ls_read_beat;

    logic [2:0]  mac_read_id_A, mac_read_id_B, mac_read_id_C;
    logic [2:0]  mac_read_row_A, mac_read_row_B, mac_read_row_C;
    logic [2:0]  mac_read_beat_A, mac_read_beat_B, mac_read_beat_C;
    logic [31:0] reg_mac_rdata_A, reg_mac_rdata_B;
    logic [63:0] reg_mac_rdata_C;

    logic [2:0]   mac_vec_read_id_A, mac_vec_read_id_B;
    logic [11:0]  mac_vec_read_beats_A, mac_vec_read_beats_B;
    logic [127:0] reg_mac_vec_rdata_A, reg_mac_vec_rdata_B;

    logic [2:0] misc_read_id_A, misc_read_row_A, misc_read_beat_A;
    logic [2:0] ew_read_id_A, ew_read_row_A, ew_read_beat_A;
    logic [2:0] ew_read_id_B, ew_read_row_B, ew_read_beat_B;

    logic [2:0] core_read_id_A, core_read_row_A, core_read_beat_A;
    logic [2:0] core_read_id_B, core_read_row_B, core_read_beat_B;
    logic [2:0] core_read_id_C, core_read_row_C, core_read_beat_C;

    logic [31:0] csr_rdata;
    logic [31:0] out_mtilem, out_mtilek, out_mtilen;
    logic [1:0]  out_xmxrm;
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
            core_done <= mac_done | misc_done | ew_done | ls_done | start_cfg;
        end
    end

    always_ff @(posedge clk) begin
        if (!resetn) begin
            mac_active  <= 1'b0;
            misc_active <= 1'b0;
            ew_active   <= 1'b0;
            ls_active   <= 1'b0;
        end else begin
            if (start_matmul) begin
                mac_active <= 1'b1;
            end else if (mac_done) begin
                mac_active <= 1'b0;
            end

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

    logic        core_reg_we;
    logic [2:0]  core_reg_id;
    logic [2:0]  core_reg_row_idx;
    logic [2:0]  core_reg_beat_idx;
    logic [31:0] core_reg_wdata;

    assign core_reg_we       = mac_reg_we | ew_reg_we | misc_reg_we | ls_reg_we | host_reg_we;
    assign core_reg_id       = mac_reg_we  ? mac_reg_id  :
                               ew_reg_we   ? ew_reg_id   :
                               misc_reg_we ? misc_reg_id :
                               ls_reg_we   ? ls_reg_id   : host_reg_id;
    assign core_reg_row_idx  = mac_reg_we  ? mac_reg_row_idx  :
                               ew_reg_we   ? ew_reg_row_idx   :
                               misc_reg_we ? misc_reg_row_idx :
                               ls_reg_we   ? ls_reg_row_idx   : host_reg_row_idx;
    assign core_reg_beat_idx = mac_reg_we  ? mac_reg_beat_idx  :
                               ew_reg_we   ? ew_reg_beat_idx   :
                               misc_reg_we ? misc_reg_beat_idx :
                               ls_reg_we   ? ls_reg_beat_idx   : host_reg_beat_idx;
    assign core_reg_wdata    = mac_reg_we  ? mac_reg_wdata[31:0] :
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

        if (!mac_active && ew_active) begin
            core_read_id_A   = ew_read_id_A;
            core_read_row_A  = ew_read_row_A;
            core_read_beat_A = ew_read_beat_A;

            core_read_id_B   = ew_read_id_B;
            core_read_row_B  = ew_read_row_B;
            core_read_beat_B = ew_read_beat_B;

            core_read_id_C   = 3'b0;
            core_read_row_C  = 3'b0;
            core_read_beat_C = 3'b0;
        end else if (!mac_active && !ew_active && misc_active) begin
            core_read_id_A   = misc_read_id_A;
            core_read_row_A  = misc_read_row_A;
            core_read_beat_A = misc_read_beat_A;

            core_read_id_B   = 3'b0;
            core_read_row_B  = 3'b0;
            core_read_beat_B = 3'b0;

            core_read_id_C   = 3'b0;
            core_read_row_C  = 3'b0;
            core_read_beat_C = 3'b0;
        end else if (!mac_active && !ew_active && !misc_active && ls_active) begin
            core_read_id_A   = ls_read_id;
            core_read_row_A  = ls_read_row;
            core_read_beat_A = ls_read_beat;

            core_read_id_B   = 3'b0;
            core_read_row_B  = 3'b0;
            core_read_beat_B = 3'b0;

            core_read_id_C   = 3'b0;
            core_read_row_C  = 3'b0;
            core_read_beat_C = 3'b0;
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
        .start_mst(start_mst),
        .start_cfg(start_cfg),
        .start_misc(start_misc),
        .start_ew(start_ew),

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
        .REG_BEATS_PER_ROW(REG_BEATS_PER_ROW)
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

    matrix_mac_v2 #(
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
        .vec_read_beats_A(mac_vec_read_beats_A),
        .vec_read_data_A(reg_mac_vec_rdata_A),

        .vec_read_id_B(mac_vec_read_id_B),
        .vec_read_beats_B(mac_vec_read_beats_B),
        .vec_read_data_B(reg_mac_vec_rdata_B)
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

    matrix_regfile #(
        .MATRIX_DIM(REG_ROWS),
        .BEATS_PER_ROW(REG_BEATS_PER_ROW)
    ) u_regfile (
        .clk(clk),
        .resetn(resetn),
        .reg_we(core_reg_we),
        .reg_id(core_reg_id),
        .reg_row_idx(core_reg_row_idx),
        .reg_beat_idx(core_reg_beat_idx),
        .reg_wdata(core_reg_wdata),

        .host_read_id(host_read_id),
        .host_read_row(host_read_row),
        .host_read_beat(host_read_beat),
        .reg_rdata(host_reg_rdata),

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
        .mac_vec_read_beats_A(mac_vec_read_beats_A),
        .reg_mac_vec_rdata_A(reg_mac_vec_rdata_A),

        .mac_vec_read_id_B(mac_vec_read_id_B),
        .mac_vec_read_beats_B(mac_vec_read_beats_B),
        .reg_mac_vec_rdata_B(reg_mac_vec_rdata_B),

        .csr_we(cfg_we),
        .csr_addr(cfg_addr),
        .csr_wdata(cfg_wdata),
        .csr_rdata(csr_rdata),

        .out_mtilem(out_mtilem),
        .out_mtilen(out_mtilen),
        .out_mtilek(out_mtilek),
        .out_xmxrm(out_xmxrm),
        .out_xmsat(out_xmsat),
        .out_xmfrm(out_xmfrm),
        .out_xmsaten(out_xmsaten)
    );

endmodule
