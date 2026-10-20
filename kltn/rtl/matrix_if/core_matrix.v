// =============================================================================
// core_matrix: CPU RV32IF (rme_rtl/core_if/Core.v) + core ma tran (matrix_core_v2).
//
// Pipeline 5 tang cua core_if (valid tung tang, stall theo phu thuoc, khong forward).
// Lenh ma tran (opcode custom-1 0101011) duoc thuc thi o tang EX:
//   - phat cho matrix_core_v2 DUNG 1 LAN khi lenh nam o EX (execute_valid) va tang MEM
//     khong con truy cap bo nho dang do (cong bo nho du lieu dung chung);
//   - lenh dung o EX (execute_wait) toi khi matrix_done; tang MEM duoc de trong trong luc do;
//   - gia tri ghi GPR (mmovw.x.m) di theo pipeline nhu ket qua ALU va ghi o tang WB;
//   - matrix_complete chan phat lai lenh vua xong (thay cho viec so sanh ma lenh), nen
//     2 lenh ma tran giong het nhau lien tiep van chay dung.
// =============================================================================
module core_matrix (
    input wire clk,
    input wire rst,
    input wire data_mem_valid,
    input wire instruc_mem_valid,
    input wire [31:0] instruction,
    input wire [31:0] load_data_in,

    output wire load_signal,
    output wire instruction_mem_we_re,
    output wire instruction_mem_request,
    output wire data_mem_we_re,
    output wire data_mem_request,
    output wire [3:0]  mask_singal,
    output wire [3:0]  instruc_mask_singal,
    output wire [31:0] store_data_out,
    output wire [31:0] alu_out_address,
    output wire [31:0] pc_address,

    input  wire        matrix_host_reg_we,
    input  wire [2:0]  matrix_host_reg_id,
    input  wire [2:0]  matrix_host_reg_row_idx,
    input  wire [2:0]  matrix_host_reg_beat_idx,
    input  wire [31:0] matrix_host_reg_wdata,
    input  wire [2:0]  matrix_host_read_id,
    input  wire [2:0]  matrix_host_read_row,
    input  wire [2:0]  matrix_host_read_beat,
    output wire [31:0] matrix_host_reg_rdata,
    output wire [31:0] matrix_debug_mtilem,
    output wire [31:0] matrix_debug_mtilen,
    output wire [31:0] matrix_debug_mtilek,
    output wire        matrix_busy,
    output wire        matrix_done
    );

    wire [31:0] instruc_data_out;
    wire [31:0] pre_address_pc;
    wire [31:0] instruction_fetch , instruction_decode , instruction_execute;
    wire [31:0] instruction_memstage , instruction_wb;
    wire [31:0] pre_pc_addr_fetch , pre_pc_addr_decode , pre_pc_addr_execute;
    wire [31:0] pre_pc_addr_memstage , pre_pc_addr_wb;
    wire load_decode , load_execute , load_memstage;
    wire store_decode , store_execute , store_memstage;
    wire jalr_decode;
    wire next_sel_decode , next_sel_execute;
    wire reg_write_decode , reg_write_execute , reg_write_memstage;
    wire branch_result_decode , branch_result_execute;
    wire [3:0]  mask;
    wire [3:0]  alu_control_decode , alu_control_execute;
    wire [1:0]  mem_to_reg_decode , mem_to_reg_execute;
    wire [1:0]  mem_to_reg_memstage , mem_to_reg_wb;
    wire [4:0]  rs1_decode , rs1_execute;
    wire [4:0]  rs2_decode , rs2_execute;
    wire [4:0]  rd_memstage;
    wire [31:0] op_b_decode , op_b_execute , op_b_memstage;
    wire [31:0] opa_mux_out_decode , opa_mux_out_execute;
    wire [31:0] opb_mux_out_decode , opb_mux_out_execute;
    wire [31:0] opc_mux_out_decode , opc_mux_out_execute;
    wire [31:0] alu_res_out_execute , alu_res_out_memstage;
    wire [31:0] alu_res_out_wb;
    wire [31:0] next_sel_address_execute , next_sel_address_memstage;
    wire [31:0] next_sel_address_wb;
    wire [31:0] wrap_load_memstage , wrap_load_wb;
    wire [31:0] rd_wb_data;
    wire [31:0] alu_in_a , alu_in_b;
    wire reg_write_wb, jalr_execute;
    wire fp_reg_write_decode, fp_reg_write_execute;
    wire fp_reg_write_memstage, fp_reg_write_wb;
    wire fp_load_decode, fp_store_decode, matrix_decode, matrix_execute;
    wire fp_addsub_decode, fp_mul_decode, fp_divsqrt_decode, fp_fma_decode;
    wire fp_cvt_to_int_decode, fp_cvt_to_float_decode;
    wire fp_compare_decode, fp_minmax_decode, fp_csr_decode;
    wire fp_use_x1_decode, fp_use_f1_decode, fp_use_f2_decode, fp_use_f3_decode;
    reg fetch_pending, discard_fetch;
    reg decode_valid, execute_valid, memstage_valid, wb_valid;
    reg mem_request_sent;
    wire memory_op = memstage_valid && (load_memstage || store_memstage);
    wire memory_wait = memory_op && !data_mem_valid;
    wire fp_misc_execute;
    wire fp_compare_execute;
    wire fp_minmax_execute;
    wire [31:0] fp_min_result, fp_max_result;
    wire [4:0] fp_minmax_flags;
    wire [31:0] fp_minmax_result = instruction_execute[12] ? fp_max_result : fp_min_result;
    wire [31:0] fp_compare_result;
    wire [4:0] fp_compare_flags;
    wire [2:0] fp_misc_op;
    wire [31:0] fp_misc_result;

    // Cong bo nho du lieu cua CPU (truoc khi chia se voi core ma tran)
    wire        cpu_data_mem_we_re;
    wire        cpu_data_mem_request;
    wire [31:0] cpu_store_data_out;

    // -------------------------------------------------------------------------
    // Core ma tran
    // -------------------------------------------------------------------------
    localparam [6:0] OPCODE_MATRIX = 7'b0101011;
    wire        matrix_supported;
    wire        matrix_wb_we;
    wire [4:0]  matrix_wb_rd;
    wire [31:0] matrix_wb_data;
    wire        matrix_mem_request;
    wire        matrix_mem_we;
    wire [31:0] matrix_mem_addr;
    wire [31:0] matrix_mem_wdata;
    wire [3:0]  matrix_mem_wstrb;
    reg         matrix_complete;          // lenh ma tran o EX da xong, cho EX chuyen tiep
    reg         matrix_wb_hold;           // giu gia tri ghi GPR neu EX chua chuyen tiep
    reg  [31:0] matrix_wb_hold_data;

    // Lenh ma tran doc GPR: msettile{k,m,n} (rs1), load/store (rs1, rs2),
    // mmov*.x.m (rs1), mmov*.m.x / mdup (rs1, rs2)
    function mx_uses_rs1;
        input [31:0] insn;
        begin mx_uses_rs1 = insn[14:12] == 3'b000 &&
            ((insn[27:26] == 2'b00 && insn[25]) || insn[27:26] == 2'b01 ||
             (insn[27:26] == 2'b11 && (insn[31:28] == 4'b0010 || insn[31:28] == 4'b0011))); end
    endfunction
    function mx_uses_rs2;
        input [31:0] insn;
        begin mx_uses_rs2 = insn[14:12] == 3'b000 &&
            (insn[27:26] == 2'b01 || (insn[27:26] == 2'b11 && insn[31:28] == 4'b0011)); end
    endfunction
    // Lenh ma tran ghi GPR rd = insn[11:7]: mmov*.x.m, cau hinh (rd != 0)
    function mx_writes_gpr;
        input [31:0] insn;
        begin mx_writes_gpr = insn[6:0] == OPCODE_MATRIX && insn[14:12] == 3'b000 &&
            ((insn[27:26] == 2'b11 && insn[31:28] == 4'b0010) || insn[27:26] == 2'b00); end
    endfunction

    wire matrix_in_execute = execute_valid && matrix_execute;
    // Phat dung 1 lan: khong phat lai trong chu ky matrix_done va sau khi da xong
    wire matrix_go   = matrix_in_execute && !memory_wait && !matrix_complete && !matrix_done;
    wire matrix_wait = matrix_in_execute && matrix_supported && !matrix_done && !matrix_complete;
    wire matrix_stall = matrix_wait;          // ten cu (testbench sim/ quan sat)
    wire        matrix_wb_now   = matrix_wb_we || matrix_wb_hold;
    wire [31:0] matrix_wb_value = matrix_wb_we ? matrix_wb_data : matrix_wb_hold_data;

    matrix_core_v2 u_matrix (
        .clk(clk),
        .resetn(rst),
        .matrix_valid(matrix_go),
        .matrix_insn(instruction_execute),
        .matrix_rs1(alu_in_a),
        .matrix_rs2(alu_in_b),
        .matrix_supported(matrix_supported),
        .matrix_busy(matrix_busy),
        .matrix_done(matrix_done),
        .matrix_wb_we(matrix_wb_we),
        .matrix_wb_rd(matrix_wb_rd),
        .matrix_wb_data(matrix_wb_data),
        .matrix_mem_request(matrix_mem_request),
        .matrix_mem_we(matrix_mem_we),
        .matrix_mem_addr(matrix_mem_addr),
        .matrix_mem_wdata(matrix_mem_wdata),
        .matrix_mem_wstrb(matrix_mem_wstrb),
        .matrix_mem_rdata(load_data_in),
        .matrix_mem_rvalid(data_mem_valid),

        .host_reg_we(matrix_host_reg_we),
        .host_reg_id(matrix_host_reg_id),
        .host_reg_row_idx(matrix_host_reg_row_idx),
        .host_reg_beat_idx(matrix_host_reg_beat_idx),
        .host_reg_wdata(matrix_host_reg_wdata),

        .host_read_id(matrix_host_read_id),
        .host_read_row(matrix_host_read_row),
        .host_read_beat(matrix_host_read_beat),
        .host_reg_rdata(matrix_host_reg_rdata),

        .debug_mtilem(matrix_debug_mtilem),
        .debug_mtilen(matrix_debug_mtilen),
        .debug_mtilek(matrix_debug_mtilek)
    );

    // -------------------------------------------------------------------------
    // FP (giu nguyen tu core_if/Core.v)
    // -------------------------------------------------------------------------
    fp_decode u_fp_decode_execute(
        .instruction(instruction_execute), .addsub(), .mul(), .divsqrt(), .fma(),
        .cvt_to_int(), .cvt_to_float(),
        .compare(fp_compare_execute),
        .minmax(fp_minmax_execute),
        .misc(fp_misc_execute), .misc_op(fp_misc_op),
        .use_x1(), .use_f1(), .use_f2(), .use_f3(), .write_x(), .write_f()
    );
    fp_misc u_fp_misc(
        .a(opa_mux_out_execute), .b(opb_mux_out_execute),
        .operation(fp_misc_op), .result(fp_misc_result)
    );
    fp32_compare u_fp_compare(
        .a(opa_mux_out_execute), .b(opb_mux_out_execute),
        .operation(instruction_execute[14:12]),
        .result(fp_compare_result), .flags(fp_compare_flags),
        .min_result(fp_min_result), .max_result(fp_max_result), .minmax_flags(fp_minmax_flags)
    );
    // Full funct7 is required: other OP-FP operations must not alias ADD/SUB.
    function is_fp_addsub;
        input [31:0] insn;
        begin is_fp_addsub = insn[6:0] == 7'h53 &&
            (insn[31:25] == 7'h00 || insn[31:25] == 7'h04); end
    endfunction
    function is_fp_mul;
        input [31:0] insn;
        begin is_fp_mul = insn[6:0] == 7'h53 && insn[31:25] == 7'h08; end
    endfunction
    function is_fp_divsqrt;
        input [31:0] insn;
        begin is_fp_divsqrt = insn[6:0] == 7'h53 && (insn[31:25] == 7'h0c ||
            (insn[31:25] == 7'h2c && insn[24:20] == 0)); end
    endfunction
    // R4 fused multiply-add, single precision only (fmt=00).
    function is_fp_fma;
        input [31:0] insn;
        begin is_fp_fma = insn[6:4] == 3'b100 && insn[1:0] == 2'b11 && insn[26:25] == 2'b00; end
    endfunction
    function is_fp_convert;
        input [31:0] insn;
        begin is_fp_convert = insn[6:0] == 7'h53 &&
            (insn[31:25] == 7'h60 || insn[31:25] == 7'h68) &&
            insn[24:21] == 0; end
    endfunction
    function is_fp_compare;
        input [31:0] insn;
        begin is_fp_compare = insn[6:0] == 7'h53 &&
            insn[31:25] == 7'h50 && insn[14:12] <= 3'd2; end
    endfunction
    function updates_fp_flags;
        input [31:0] insn;
        begin updates_fp_flags = is_fp_addsub(insn) || is_fp_mul(insn) ||
            is_fp_divsqrt(insn) || is_fp_fma(insn) || is_fp_convert(insn) ||
            is_fp_compare(insn) || is_fp_minmax(insn); end
    endfunction
    function is_fp_minmax;
        input [31:0] insn;
        begin is_fp_minmax = insn[6:0] == 7'h53 &&
            insn[31:25] == 7'h14 && insn[14:12] <= 3'd1; end
    endfunction
    function is_fp_csr;
        input [31:0] insn;
        begin is_fp_csr = insn[6:0] == 7'h73 && insn[13:12] != 0 &&
            insn[31:20] >= 12'h001 && insn[31:20] <= 12'h003; end
    endfunction
    wire fp_addsub_execute = execute_valid && is_fp_addsub(instruction_execute);
    wire fp_mul_execute = execute_valid && is_fp_mul(instruction_execute);
    wire fp_divsqrt_execute = execute_valid && is_fp_divsqrt(instruction_execute);
    wire fp_fma_execute = execute_valid && is_fp_fma(instruction_execute);
    wire fp_convert_execute = execute_valid && is_fp_convert(instruction_execute);
    wire fp_arith_execute = fp_addsub_execute || fp_mul_execute ||
                            fp_divsqrt_execute || fp_fma_execute || fp_convert_execute;
    wire csr_execute = execute_valid && is_fp_csr(instruction_execute);
    wire csr_memstage = memstage_valid && is_fp_csr(instruction_memstage);
    wire csr_wb = wb_valid && is_fp_csr(instruction_wb);
    wire older_fp = (execute_valid && updates_fp_flags(instruction_execute)) ||
                    (memstage_valid && updates_fp_flags(instruction_memstage)) ||
                    (wb_valid && updates_fp_flags(instruction_wb));
    wire older_csr = csr_execute || csr_memstage || csr_wb;
    wire csr_wait = (fp_csr_decode && (older_fp || older_csr)) ||
                    ((fp_addsub_decode || fp_mul_decode || fp_divsqrt_decode || fp_fma_decode || fp_cvt_to_int_decode ||
                      fp_cvt_to_float_decode || fp_compare_decode || fp_minmax_decode) && older_csr);
    wire [2:0] frm, effective_rm;
    wire [4:0] fflags, fp_flags, fp_addsub_flags, fp_mul_flags, fp_divsqrt_flags, fp_fma_flags, fp_convert_flags;
    wire [31:0] csr_read_data, fp_result, fp_addsub_result, fp_mul_result;
    wire [31:0] fp_divsqrt_result, fp_fma_result, fp_convert_result;
    wire fp_done, fp_busy, fp_illegal_rm;
    wire fp_addsub_done, fp_addsub_busy, fp_addsub_illegal_rm;
    wire fp_mul_done, fp_mul_busy, fp_mul_illegal_rm;
    wire fp_divsqrt_done, fp_divsqrt_busy, fp_divsqrt_illegal_rm;
    wire fp_fma_done, fp_fma_busy, fp_fma_illegal_rm;
    wire fp_convert_done, fp_convert_busy, fp_convert_illegal_rm;
    reg fp_issued, fp_complete;
    reg [4:0] fp_flags_memstage, fp_flags_wb;
    reg [31:0] csr_operand_wb;
    wire [31:0] csr_operand_execute = instruction_execute[14] ?
        {27'b0, instruction_execute[19:15]} : opa_mux_out_execute;
    wire fp_start = fp_arith_execute && !fp_issued && !memory_wait;
    assign fp_done = fp_addsub_done || fp_mul_done || fp_divsqrt_done || fp_fma_done || fp_convert_done;
    assign fp_busy = fp_addsub_busy || fp_mul_busy || fp_divsqrt_busy || fp_fma_busy || fp_convert_busy;
    assign fp_result = fp_convert_execute ? fp_convert_result :
                       fp_divsqrt_execute ? fp_divsqrt_result :
                       fp_fma_execute ? fp_fma_result :
                       (fp_mul_execute ? fp_mul_result : fp_addsub_result);
    assign fp_flags = fp_convert_execute ? fp_convert_flags :
                      fp_divsqrt_execute ? fp_divsqrt_flags :
                      fp_fma_execute ? fp_fma_flags :
                      (fp_mul_execute ? fp_mul_flags : fp_addsub_flags);
    assign fp_illegal_rm = fp_convert_execute ? fp_convert_illegal_rm :
                           fp_divsqrt_execute ? fp_divsqrt_illegal_rm :
                           fp_fma_execute ? fp_fma_illegal_rm :
                           (fp_mul_execute ? fp_mul_illegal_rm : fp_addsub_illegal_rm);
    wire fp_wait = fp_arith_execute && !(fp_done || fp_complete);
    // EX dung lai khi: tang MEM cho bo nho, FP dang tinh, hoac lenh ma tran chua xong
    wire execute_wait = memory_wait || fp_wait || matrix_wait;
    wire [31:0] execute_result = fp_arith_execute ? fp_result :
                                (fp_minmax_execute ? fp_minmax_result :
                                (fp_compare_execute ? fp_compare_result :
                                (fp_misc_execute ? fp_misc_result :
                                (csr_execute ? csr_read_data : alu_res_out_execute))));
    assign effective_rm = instruction_execute[14:12] == 3'b111 ?
                          frm : instruction_execute[14:12];
    fp32_addsub u_fp_addsub(
        .clk(clk), .rst(rst), .start(fp_start && fp_addsub_execute), .sub(instruction_execute[27]),
        .a(opa_mux_out_execute), .b(opb_mux_out_execute), .rm(effective_rm),
        .busy(fp_addsub_busy), .done(fp_addsub_done), .result(fp_addsub_result), .flags(fp_addsub_flags),
        .illegal_rm(fp_addsub_illegal_rm)
    );
    fp32_mul u_fp_mul(
        .clk(clk), .rst(rst), .start(fp_start && fp_mul_execute),
        .a(opa_mux_out_execute), .b(opb_mux_out_execute), .rm(effective_rm),
        .busy(fp_mul_busy), .done(fp_mul_done), .result(fp_mul_result),
        .flags(fp_mul_flags), .illegal_rm(fp_mul_illegal_rm)
    );
    fp32_divsqrt u_fp_divsqrt(
        .clk(clk), .rst(rst), .start(fp_start && fp_divsqrt_execute),
        .is_sqrt(instruction_execute[30]),
        .a(opa_mux_out_execute), .b(opb_mux_out_execute), .rm(effective_rm),
        .busy(fp_divsqrt_busy), .done(fp_divsqrt_done), .result(fp_divsqrt_result),
        .flags(fp_divsqrt_flags), .illegal_rm(fp_divsqrt_illegal_rm)
    );
    // Opcode bit 2 negates the addend (FMSUB/FNMADD), bit 3 the product (FNMSUB/FNMADD).
    fp32_fma u_fp_fma(
        .clk(clk), .rst(rst), .start(fp_start && fp_fma_execute),
        .negate_product(instruction_execute[3]), .negate_addend(instruction_execute[2]),
        .a(opa_mux_out_execute), .b(opb_mux_out_execute), .c(opc_mux_out_execute),
        .rm(effective_rm),
        .busy(fp_fma_busy), .done(fp_fma_done), .result(fp_fma_result),
        .flags(fp_fma_flags), .illegal_rm(fp_fma_illegal_rm)
    );
    fp32_convert u_fp_convert(
        .clk(clk), .rst(rst), .start(fp_start && fp_convert_execute),
        .to_float(instruction_execute[28]), .unsigned_mode(instruction_execute[20]),
        .a(opa_mux_out_execute), .rm(effective_rm),
        .busy(fp_convert_busy), .done(fp_convert_done),
        .result(fp_convert_result), .flags(fp_convert_flags),
        .illegal_rm(fp_convert_illegal_rm)
    );
    fp_csr u_fp_csr(
        .clk(clk), .rst(rst), .read_addr(instruction_execute[31:20]),
        .read_data(csr_read_data),
        .write_en(csr_wb && (instruction_wb[13:12] == 1 || instruction_wb[19:15] != 0)),
        .write_addr(instruction_wb[31:20]), .write_op(instruction_wb[13:12]),
        .write_data(csr_operand_wb),
        .flags_en(wb_valid && ((fp_reg_write_wb && (is_fp_addsub(instruction_wb) || is_fp_mul(instruction_wb) ||
                                                    is_fp_divsqrt(instruction_wb) || is_fp_fma(instruction_wb))) ||
                              is_fp_convert(instruction_wb) ||
                              is_fp_compare(instruction_wb) || is_fp_minmax(instruction_wb))),
        .flags_in(fp_flags_wb), .frm(frm), .fflags(fflags)
    );
    // Sideband state follows the same EX/MEM and MEM/WB boundaries as results.
    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            fp_issued <= 0; fp_complete <= 0;
            fp_flags_memstage <= 0; fp_flags_wb <= 0; csr_operand_wb <= 0;
            matrix_complete <= 0; matrix_wb_hold <= 0; matrix_wb_hold_data <= 0;
        end else begin
            if (fp_start) fp_issued <= 1;
            if (fp_done) fp_complete <= 1;
            if (!execute_wait) begin fp_issued <= 0; fp_complete <= 0; end
            // Lenh ma tran: xong roi nhung EX chua chuyen tiep -> khong phat lai
            if (!execute_wait) begin
                matrix_complete <= 0;
                matrix_wb_hold  <= 0;
            end else begin
                if (matrix_done) matrix_complete <= 1;
                if (matrix_wb_we) begin
                    matrix_wb_hold      <= 1;
                    matrix_wb_hold_data <= matrix_wb_data;
                end
            end
            if (!memory_wait)
                fp_flags_memstage <= (execute_valid && fp_minmax_execute) ? fp_minmax_flags :
                    (execute_valid && fp_compare_execute) ? fp_compare_flags :
                    ((fp_arith_execute && !fp_wait && !fp_illegal_rm) ? fp_flags : 5'b0);
            fp_flags_wb <= fp_flags_memstage;
            csr_operand_wb <= op_b_memstage;
        end
    end

    // Five pipeline stages, with conservative dependency stalls and one
    // outstanding request per memory port. A request is accepted on a rising
    // edge; valid is its completion response (including store completion).
    reg uses_x_rs1, uses_x_rs2, uses_f_rs1, uses_f_rs2, uses_f_rs3;
    wire redirect = execute_valid && !execute_wait &&
                    (next_sel_execute || jalr_execute || branch_result_execute);
    wire [31:0] redirect_address = jalr_execute ?
                    {alu_res_out_execute[31:1], 1'b0} : alu_res_out_execute;
    wire fetch_accept = fetch_pending && instruc_mem_valid &&
                        !discard_fetch && !redirect;

    // Source-use is determined by the instruction, not by accidental equality
    // between an immediate field and a pending destination register number.
    always @(*) begin
        uses_x_rs1 = 1'b0;
        uses_x_rs2 = 1'b0;
        uses_f_rs1 = 1'b0;
        uses_f_rs2 = 1'b0;
        uses_f_rs3 = 1'b0;
        case (instruction_decode[6:0])
            7'b0110011, 7'b0100011, 7'b1100011: begin
                uses_x_rs1 = 1'b1;
                uses_x_rs2 = 1'b1;
            end
            7'b0010011, 7'b0000011, 7'b1100111:
                uses_x_rs1 = 1'b1;
            7'b0000111: uses_x_rs1 = fp_load_decode;
            7'b0100111: begin
                uses_x_rs1 = fp_store_decode;
                uses_f_rs2 = fp_store_decode;
            end
            7'h53: begin
                uses_x_rs1 = fp_use_x1_decode;
                uses_f_rs1 = fp_use_f1_decode;
                uses_f_rs2 = fp_use_f2_decode;
            end
            7'h43, 7'h47, 7'h4b, 7'h4f: begin
                uses_f_rs1 = fp_use_f1_decode;
                uses_f_rs2 = fp_use_f2_decode;
                uses_f_rs3 = fp_use_f3_decode;
            end
            7'h73: uses_x_rs1 = fp_csr_decode && !instruction_decode[14];
            OPCODE_MATRIX: begin
                uses_x_rs1 = mx_uses_rs1(instruction_decode);
                uses_x_rs2 = mx_uses_rs2(instruction_decode);
            end
            default: begin end
        endcase
    end

    // Lenh ma tran o EX ghi GPR qua pipeline nhung reg_write_execute = 0 (bo giai ma
    // scalar khong biet) -> them vao dieu kien phu thuoc cua tang EX.
    wire writes_x_execute = reg_write_execute || mx_writes_gpr(instruction_execute);
    wire x_rs1_wait = (rs1_decode != 0) && (
        (execute_valid && writes_x_execute && rs1_decode == instruction_execute[11:7]) ||
        (memstage_valid && reg_write_memstage && rs1_decode == instruction_memstage[11:7]) ||
        (wb_valid && reg_write_wb && rs1_decode == instruction_wb[11:7]));
    wire x_rs2_wait = (rs2_decode != 0) && (
        (execute_valid && writes_x_execute && rs2_decode == instruction_execute[11:7]) ||
        (memstage_valid && reg_write_memstage && rs2_decode == instruction_memstage[11:7]) ||
        (wb_valid && reg_write_wb && rs2_decode == instruction_wb[11:7]));
    // No rd!=0 filter here: f0 is writable and can have a pending producer.
    wire f_rs1_wait =
        (execute_valid && fp_reg_write_execute && rs1_decode == instruction_execute[11:7]) ||
        (memstage_valid && fp_reg_write_memstage && rs1_decode == instruction_memstage[11:7]) ||
        (wb_valid && fp_reg_write_wb && rs1_decode == instruction_wb[11:7]);
    wire f_rs2_wait =
        (execute_valid && fp_reg_write_execute && rs2_decode == instruction_execute[11:7]) ||
        (memstage_valid && fp_reg_write_memstage && rs2_decode == instruction_memstage[11:7]) ||
        (wb_valid && fp_reg_write_wb && rs2_decode == instruction_wb[11:7]);
    wire [4:0] rs3_decode = instruction_decode[31:27];
    wire f_rs3_wait =
        (execute_valid && fp_reg_write_execute && rs3_decode == instruction_execute[11:7]) ||
        (memstage_valid && fp_reg_write_memstage && rs3_decode == instruction_memstage[11:7]) ||
        (wb_valid && fp_reg_write_wb && rs3_decode == instruction_wb[11:7]);
    wire dependency_wait = (uses_x_rs1 && x_rs1_wait) ||
                           (uses_x_rs2 && x_rs2_wait) ||
                           (uses_f_rs1 && f_rs1_wait) ||
                           (uses_f_rs2 && f_rs2_wait) ||
                           (uses_f_rs3 && f_rs3_wait) || csr_wait;
    wire decode_issue = decode_valid && !dependency_wait && !execute_wait && !redirect;

    assign instruction_mem_request = rst && !fetch_pending && !decode_valid &&
                                     !execute_wait && !redirect;
    assign cpu_data_mem_request = rst && memory_op && !mem_request_sent;

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            fetch_pending <= 0;
            discard_fetch <= 0;
            decode_valid <= 0;
            execute_valid <= 0;
            memstage_valid <= 0;
            wb_valid <= 0;
            mem_request_sent <= 0;
        end else begin
            if (instruction_mem_request)
                fetch_pending <= 1;
            if (fetch_pending && instruc_mem_valid) begin
                fetch_pending <= 0;
                discard_fetch <= 0;
            end
            if (redirect && fetch_pending && !instruc_mem_valid)
                discard_fetch <= 1;

            if (redirect)
                decode_valid <= 0;
            else if (fetch_accept)
                decode_valid <= 1;
            else if (decode_issue)
                decode_valid <= 0;

            if (!execute_wait)
                execute_valid <= decode_issue;
            // Lenh ma tran chua xong khong duoc vao MEM: tang MEM trong -> cong bo nho ranh
            if (!memory_wait)
                memstage_valid <= execute_valid && !fp_wait && !matrix_wait;
            wb_valid <= memstage_valid && !memory_wait;

            if (cpu_data_mem_request)
                mem_request_sent <= 1;
            if (!memory_wait)
                mem_request_sent <= 0;
        end
    end

    //FETCH STAGE
    fetch u_fetchstage(
        .clk(clk),
        .rst(rst),
        .stall(!fetch_accept && !redirect),
        .load(1'b0),
        .jalr(1'b0),
        .next_sel(redirect),
        .branch_reselt(1'b0),
        .next_address(redirect_address),
        .instruction_fetch(instruction),
        .instruction(instruction_fetch),
        .address_in(0),
        .valid(1'b0),
        .mask(instruc_mask_singal),
        .we_re(instruction_mem_we_re),
        .request(),
        .pre_address_pc(pre_pc_addr_fetch),
        .address_out(pc_address)
    );

    //FETCH STAGE PIPELINE
    fetch_pipe u_fetchpipeline(
        .clk(clk),
        .rst(rst),
        .stall(!fetch_accept),
        .pre_address_pc(pc_address),
        .instruction_fetch(instruction_fetch),
        .pre_address_out(pre_pc_addr_decode),
        .instruction(instruction_decode),
        .next_select(redirect),
        .branch_result(1'b0),
        .jalr(1'b0),
        .load(1'b0)
    );

    //DECODE STAGE
    decode u_decodestage(
        .clk(clk),
        .rst(rst),
        // Explicit stage validity replaces the legacy load replay mechanism.
        .valid(1'b0),
        .load_control_signal(1'b0),
        .reg_write_en_in(reg_write_wb),
        .fp_reg_write_en_in(fp_reg_write_wb),
        .instruction(instruction_decode),
        .pc_address(pre_pc_addr_decode),
        .rd_wb_data(rd_wb_data),
        .rs1(rs1_decode),
        .rs2(rs2_decode),
        .load(load_decode),
        .store(store_decode),
        .jalr(jalr_decode),
        .next_sel(next_sel_decode),
        .reg_write_en_out(reg_write_decode),
        .fp_reg_write_en_out(fp_reg_write_decode),
        .fp_load(fp_load_decode),
        .fp_store(fp_store_decode),
        .fp_addsub(fp_addsub_decode),
        .fp_mul(fp_mul_decode),
        .fp_divsqrt(fp_divsqrt_decode),
        .fp_fma(fp_fma_decode),
        .fp_cvt_to_int(fp_cvt_to_int_decode),
        .fp_cvt_to_float(fp_cvt_to_float_decode),
        .fp_compare(fp_compare_decode),
        .fp_minmax(fp_minmax_decode),
        .fp_csr_access(fp_csr_decode),
        .fp_use_x1(fp_use_x1_decode),
        .fp_use_f1(fp_use_f1_decode),
        .fp_use_f2(fp_use_f2_decode),
        .fp_use_f3(fp_use_f3_decode),
        .matrix_decode(matrix_decode),
        .mem_to_reg(mem_to_reg_decode),
        .branch_result(branch_result_decode),
        .opb_data(op_b_decode),
        .instruction_rd(instruction_wb),
        .alu_control(alu_control_decode),
        .opa_mux_out(opa_mux_out_decode),
        .opb_mux_out(opb_mux_out_decode),
        .opc_mux_out(opc_mux_out_decode)
    );

    //DECODE STAGE PIPELINE
    decode_pipe u_decodepipeline(
        .clk(clk),
        .rst(rst),
        .stall(execute_wait),
        .bubble(!decode_issue),
        .matrix_decode_in(matrix_decode),
        .matrix_decode_out(matrix_execute),
        .load_in(load_decode),
        .store_in(store_decode),
        .jalr_in(jalr_decode),
        .next_sel_in(next_sel_decode),
        .mem_to_reg_in(mem_to_reg_decode),
        .branch_result_in(branch_result_decode),
        .opb_data_in(op_b_decode),
        .alu_control_in(alu_control_decode),
        .opa_mux_in(opa_mux_out_decode),
        .opb_mux_in(opb_mux_out_decode),
        .opc_mux_in(opc_mux_out_decode),
        .pre_address_in(pre_pc_addr_decode),
        .instruction_in(instruction_decode),
        .reg_write_in(reg_write_decode),
        .fp_reg_write_in(fp_reg_write_decode),
        .rs1_in(rs1_decode),
        .rs2_in(rs2_decode),
        .reg_write_out(reg_write_execute),
        .fp_reg_write_out(fp_reg_write_execute),
        .jalr_out(jalr_execute),
        .load(load_execute),
        .store(store_execute),
        .next_sel(next_sel_execute),
        .mem_to_reg(mem_to_reg_execute),
        .branch_result(branch_result_execute),
        .opb_data_out(op_b_execute),
        .alu_control(alu_control_execute),
        .opa_mux_out(opa_mux_out_execute),
        .opb_mux_out(opb_mux_out_execute),
        .opc_mux_out(opc_mux_out_execute),
        .pre_address_out(pre_pc_addr_execute),
        .instruction_out(instruction_execute),
        .rs1_out(rs1_execute),
        .rs2_out(rs2_execute)
    );

    // Decode waits for producers to retire. Never forward an ALU result over
    // a load/store immediate, and never confuse xN with fN.
    assign alu_in_a = opa_mux_out_execute;
    assign alu_in_b = opb_mux_out_execute;

    //EXECUTE STAGE
    execute u_executestage(
        .a_i(alu_in_a),
        .b_i(alu_in_b),
        .pc_address(pre_pc_addr_execute),
        .alu_control(alu_control_execute),
        .alu_res_out(alu_res_out_execute),
        .next_sel_address(next_sel_address_execute)
    );

    //EXECUTE STAGE PIPELINE
    execute_pipe u_executepipeline(
        .clk(clk),
        .rst(rst),
        .stall(memory_wait),
        .bubble(!execute_valid || fp_wait || matrix_wait),
        .load_in(load_execute),
        .store_in(store_execute),
        .opb_datain(csr_execute ? csr_operand_execute : op_b_execute),
        // Lenh ma tran ghi GPR: ket qua tu core ma tran thay cho ket qua ALU
        .alu_res(matrix_execute ? matrix_wb_value : execute_result),
        .mem_reg_in(mem_to_reg_execute),
        .next_sel_addr(next_sel_address_execute),
        .pre_address_in(pre_pc_addr_execute),
        .instruction_in(instruction_execute),
        .reg_write_in((reg_write_execute && (!fp_convert_execute || !fp_illegal_rm)) ||
                      (matrix_execute && matrix_wb_now)),
        .fp_reg_write_in(fp_reg_write_execute && (!fp_arith_execute || !fp_illegal_rm)),
        .reg_write_out(reg_write_memstage),
        .fp_reg_write_out(fp_reg_write_memstage),
        .load_out(load_memstage),
        .store_out(store_memstage),
        .opb_dataout(op_b_memstage),
        .alu_res_out(alu_res_out_memstage),
        .mem_reg_out(mem_to_reg_memstage),
        .next_sel_address(next_sel_address_memstage),
        .pre_address_out(pre_pc_addr_memstage),
        .instruction_out(instruction_memstage)
    );

    //MEMORY STAGE
    memory_stage u_memorystage(
        .rst(rst),
        .load(load_memstage),
        .store(store_memstage),
        .op_b(op_b_memstage),
        .instruction(instruction_memstage),
        .alu_out_address(alu_res_out_memstage),
        .wrap_load_in(load_data_in),
        .mask(mask),
        .data_valid(data_mem_valid),
        .valid(data_mem_valid),
        .we_re(cpu_data_mem_we_re),
        .request(),
        .store_data_out(cpu_store_data_out),
        .wrap_load_out(wrap_load_memstage)
    );

    assign rd_memstage = instruction_memstage[11:7];

    // Cong bo nho du lieu dung chung: core ma tran chi truy cap khi tang MEM trong
    assign alu_out_address  = matrix_mem_request ? matrix_mem_addr  : alu_res_out_memstage;
    assign mask_singal      = matrix_mem_request ? matrix_mem_wstrb : mask;
    assign load_signal      = matrix_mem_request ? ~matrix_mem_we   : (memstage_valid && load_memstage);
    assign data_mem_we_re   = matrix_mem_request ? matrix_mem_we    : cpu_data_mem_we_re;
    assign data_mem_request = matrix_mem_request ? 1'b1             : cpu_data_mem_request;
    assign store_data_out   = matrix_mem_request ? matrix_mem_wdata : cpu_store_data_out;

    //MEMORY STAGE PIPELINE
    memory_pipe u_memstagepipeline(
        .clk(clk),
        .rst(rst),
        .mem_reg_in(mem_to_reg_memstage),
        .wrap_load_in(wrap_load_memstage),
        .alu_res(alu_res_out_memstage),
        .next_sel_addr(next_sel_address_memstage),
        .pre_address_in(pre_pc_addr_memstage),
        .instruction_in(instruction_memstage),
        .reg_write_in(memstage_valid && !memory_wait && reg_write_memstage),
        .fp_reg_write_in(memstage_valid && !memory_wait && fp_reg_write_memstage),
        .reg_write_out(reg_write_wb),
        .fp_reg_write_out(fp_reg_write_wb),
        .alu_res_out(alu_res_out_wb),
        .mem_reg_out(mem_to_reg_wb),
        .next_sel_address(next_sel_address_wb),
        .instruction_out(instruction_wb),
        .pre_address_out(pre_pc_addr_wb),
        .wrap_load_out(wrap_load_wb)
    );

    //WRITE BACK STAGE
    write_back u_wbstage(
        .mem_to_reg(mem_to_reg_wb),
        .alu_out(alu_res_out_wb),
        .data_mem_out(wrap_load_wb),
        .next_sel_address(next_sel_address_wb),
        .rd_sel_mux_out(rd_wb_data)
    );

    // Ten tin hieu ghi GPR o tang WB (testbench he thong quan sat)
    wire        reg_write_rf_wb   = reg_write_wb;
    wire [31:0] instruction_rf_wb = instruction_wb;
endmodule
