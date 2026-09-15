module core (
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
    output wire [31:0] pc_address
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
    wire fp_load_decode, fp_store_decode, matrix_decode;
    wire fp_addsub_decode, fp_csr_decode;
    // Full funct7 is required: other OP-FP operations must not alias ADD/SUB.
    function is_fp_addsub;
        input [31:0] insn;
        begin is_fp_addsub = insn[6:0] == 7'h53 &&
            (insn[31:25] == 7'h00 || insn[31:25] == 7'h04); end
    endfunction
    function is_fp_csr;
        input [31:0] insn;
        begin is_fp_csr = insn[6:0] == 7'h73 && insn[13:12] != 0 &&
            insn[31:20] >= 12'h001 && insn[31:20] <= 12'h003; end
    endfunction
    wire fp_arith_execute = execute_valid && is_fp_addsub(instruction_execute);
    wire csr_execute = execute_valid && is_fp_csr(instruction_execute);
    wire csr_memstage = memstage_valid && is_fp_csr(instruction_memstage);
    wire csr_wb = wb_valid && is_fp_csr(instruction_wb);
    wire older_fp = (execute_valid && is_fp_addsub(instruction_execute)) ||
                    (memstage_valid && is_fp_addsub(instruction_memstage)) ||
                    (wb_valid && is_fp_addsub(instruction_wb));
    wire older_csr = csr_execute || csr_memstage || csr_wb;
    wire csr_wait = (fp_csr_decode && (older_fp || older_csr)) ||
                    (fp_addsub_decode && older_csr);
    wire [2:0] frm, effective_rm;
    wire [4:0] fflags, fp_flags;
    wire [31:0] csr_read_data, fp_result;
    wire fp_done, fp_busy, fp_illegal_rm;
    reg fp_issued, fp_complete;
    reg [4:0] fp_flags_memstage, fp_flags_wb;
    reg [31:0] csr_operand_wb;
    wire [31:0] csr_operand_execute = instruction_execute[14] ?
        {27'b0, instruction_execute[19:15]} : opa_mux_out_execute;
    wire fp_start = fp_arith_execute && !fp_issued && !memory_wait;
    wire fp_wait = fp_arith_execute && !(fp_done || fp_complete);
    wire execute_wait = memory_wait || fp_wait;
    wire [31:0] execute_result = fp_arith_execute ? fp_result :
                                (csr_execute ? csr_read_data : alu_res_out_execute);
    assign effective_rm = instruction_execute[14:12] == 3'b111 ?
                          frm : instruction_execute[14:12];
    fp32_addsub u_fp_addsub(
        .clk(clk), .rst(rst), .start(fp_start), .sub(instruction_execute[27]),
        .a(opa_mux_out_execute), .b(opb_mux_out_execute), .rm(effective_rm),
        .busy(fp_busy), .done(fp_done), .result(fp_result), .flags(fp_flags),
        .illegal_rm(fp_illegal_rm)
    );
    fp_csr u_fp_csr(
        .clk(clk), .rst(rst), .read_addr(instruction_execute[31:20]),
        .read_data(csr_read_data),
        .write_en(csr_wb && (instruction_wb[13:12] == 1 || instruction_wb[19:15] != 0)),
        .write_addr(instruction_wb[31:20]), .write_op(instruction_wb[13:12]),
        .write_data(csr_operand_wb),
        .flags_en(wb_valid && fp_reg_write_wb && is_fp_addsub(instruction_wb)),
        .flags_in(fp_flags_wb), .frm(frm), .fflags(fflags)
    );
    // Sideband state follows the same EX/MEM and MEM/WB boundaries as results.
    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            fp_issued <= 0; fp_complete <= 0;
            fp_flags_memstage <= 0; fp_flags_wb <= 0; csr_operand_wb <= 0;
        end else begin
            if (fp_start) fp_issued <= 1;
            if (fp_done) fp_complete <= 1;
            if (!execute_wait) begin fp_issued <= 0; fp_complete <= 0; end
            if (!memory_wait)
                fp_flags_memstage <= (fp_arith_execute && !fp_wait && !fp_illegal_rm) ? fp_flags : 5'b0;
            fp_flags_wb <= fp_flags_memstage;
            csr_operand_wb <= op_b_memstage;
        end
    end

    // Five pipeline stages, with conservative dependency stalls and one
    // outstanding request per memory port. A request is accepted on a rising
    // edge; valid is its completion response (including store completion).
    reg fetch_pending, discard_fetch;
    reg decode_valid, execute_valid, memstage_valid, wb_valid;
    reg mem_request_sent;
    reg uses_x_rs1, uses_x_rs2, uses_f_rs1, uses_f_rs2;
    wire memory_op = memstage_valid && (load_memstage || store_memstage);
    wire memory_wait = memory_op && !data_mem_valid;
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
                uses_f_rs1 = fp_addsub_decode;
                uses_f_rs2 = fp_addsub_decode;
            end
            7'h73: uses_x_rs1 = fp_csr_decode && !instruction_decode[14];
            default: begin end
        endcase
    end

    wire x_rs1_wait = (rs1_decode != 0) && (
        (execute_valid && reg_write_execute && rs1_decode == instruction_execute[11:7]) ||
        (memstage_valid && reg_write_memstage && rs1_decode == instruction_memstage[11:7]) ||
        (wb_valid && reg_write_wb && rs1_decode == instruction_wb[11:7]));
    wire x_rs2_wait = (rs2_decode != 0) && (
        (execute_valid && reg_write_execute && rs2_decode == instruction_execute[11:7]) ||
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
    wire dependency_wait = (uses_x_rs1 && x_rs1_wait) ||
                           (uses_x_rs2 && x_rs2_wait) ||
                           (uses_f_rs1 && f_rs1_wait) ||
                           (uses_f_rs2 && f_rs2_wait) || csr_wait;
    wire decode_issue = decode_valid && !dependency_wait && !execute_wait && !redirect;

    assign instruction_mem_request = rst && !fetch_pending && !decode_valid &&
                                     !execute_wait && !redirect;
    assign data_mem_request = rst && memory_op && !mem_request_sent;

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
            if (!memory_wait)
                memstage_valid <= execute_valid && !fp_wait;
            wb_valid <= memstage_valid && !memory_wait;

            if (data_mem_request)
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
        .fp_csr_access(fp_csr_decode),
        .matrix_decode(matrix_decode),
        .mem_to_reg(mem_to_reg_decode),
        .branch_result(branch_result_decode),
        .opb_data(op_b_decode),
        .instruction_rd(instruction_wb),
        .alu_control(alu_control_decode),
        .opa_mux_out(opa_mux_out_decode),
        .opb_mux_out(opb_mux_out_decode)
    );

    //DECODE STAGE PIPELINE
    decode_pipe u_decodepipeline(
        .clk(clk),
        .rst(rst),
        .stall(execute_wait),
        .bubble(!decode_issue),
        .matrix_decode_in(matrix_decode),
        .matrix_decode_out(),
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
        .bubble(!execute_valid || fp_wait),
        .load_in(load_execute),
        .store_in(store_execute),
        .opb_datain(csr_execute ? csr_operand_execute : op_b_execute),
        .alu_res(execute_result),
        .mem_reg_in(mem_to_reg_execute),
        .next_sel_addr(next_sel_address_execute),
        .pre_address_in(pre_pc_addr_execute),
        .instruction_in(instruction_execute),
        .reg_write_in(reg_write_execute),
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
        .we_re(data_mem_we_re),
        .request(),
        .store_data_out(store_data_out),
        .wrap_load_out(wrap_load_memstage)
    );

    assign rd_memstage = instruction_memstage[11:7];
    assign alu_out_address = alu_res_out_memstage;
    assign mask_singal = mask ;
    assign load_signal = memstage_valid && load_memstage;

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
endmodule
