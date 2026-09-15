module decode (
    input wire clk,
    input wire rst,
    input wire valid,
    input wire reg_write_en_in,
    input wire fp_reg_write_en_in,
    input wire load_control_signal,
    input wire [31:0] instruction,
    input wire [31:0] pc_address,
    input wire [31:0] rd_wb_data,
    input wire [31:0] instruction_rd,

    output wire load,
    output wire store,
    output wire jalr,
    output wire next_sel,
    output wire branch_result,
    output wire reg_write_en_out,
    output wire fp_reg_write_en_out,
    output wire fp_load,
    output wire fp_store,
    output wire fp_addsub,
    output wire fp_csr_access,
    output wire [3:0]  alu_control,
    output wire [1:0]  mem_to_reg,
    output wire [4:0]  rs1 , rs2,
    output wire [31:0] opb_data,
    output wire [31:0] opa_mux_out,
    output wire [31:0] opb_mux_out,
    output wire matrix_decode
    );

    wire branch;
    wire operand_a;
    wire operand_b;
    wire mem_en_unused;
    wire [2:0]  imm_sel;
    wire [31:0] op_a , op_b;
    wire [31:0] fp_op_a, fp_op_b, int_opa, int_opb;
    wire legacy_reg_write, legacy_fp_reg_write;
    assign fp_addsub = instruction[6:0] == 7'h53 &&
                       (instruction[31:25] == 7'h00 || instruction[31:25] == 7'h04);
    assign fp_csr_access = instruction[6:0] == 7'h73 && instruction[13:12] != 0 &&
                           instruction[31:20] >= 12'h001 && instruction[31:20] <= 12'h003;
    assign reg_write_en_out = legacy_reg_write || fp_csr_access;
    assign fp_reg_write_en_out = legacy_fp_reg_write || fp_addsub;
    assign opa_mux_out = fp_addsub ? fp_op_a : (fp_csr_access ? op_a : int_opa);
    assign opb_mux_out = fp_addsub ? fp_op_b : int_opb;
    wire [31:0] imm_mux_out;
    wire [31:0] i_immo , s_immo , sb_immo , uj_immo , u_immo;

    // CONTROL UNIT
    controlunit u_cu0 
    (
        .opcode(instruction[6:0]),
        .fun3(instruction[14:12]),
        .fun7(instruction[30]),
        .valid(valid),
        .reg_write(legacy_reg_write),
        .fp_reg_write(legacy_fp_reg_write),
        .fp_load(fp_load),
        .fp_store(fp_store),
        .imm_sel(imm_sel),
        .next_sel(next_sel),
        .operand_b(operand_b),
        .operand_a(operand_a),
        .mem_to_reg(mem_to_reg),
        .mem_en(mem_en_unused),
        .Load(load),
        .Store(store),
        .jalr_out(jalr),
        .Branch(branch),
        .load_control(load_control_signal),
        .alu_control(alu_control),
        .matrix_decode(matrix_decode)
    );

    // IMMEDIATE GENERATION
    immediategen u_imm_gen0 (
        .instr(instruction),
        .i_imme(i_immo),
        .sb_imme(sb_immo),
        .s_imme(s_immo),
        .uj_imme(uj_immo),
        .u_imme(u_immo)
    );

    //IMMEDIATE SELECTION MUX
    mux3_8 u_mux0(
        .a(i_immo),
        .b(s_immo),
        .c(sb_immo),
        .d(uj_immo),
        .e(u_immo),
        .f(32'b0),
        .g(32'b0),
        .h(32'b0),
        .sel(imm_sel),
        .out(imm_mux_out)
    );

    // REGISTER FILE
    registerfile u_regfile0 
    (
        .clk(clk),
        .rst(rst),
        .en(reg_write_en_in),
        .rs1(instruction[19:15]),
        .rs2(instruction[24:20]),
        .rd(instruction_rd[11:7]),
        .data(rd_wb_data),
        .op_a(op_a),
        .op_b(op_b)
    );

    // FPR write-back is independent of GPR write-back; f0 is writable.
    fp_register_file u_fp_regfile0 (
        .clk(clk),
        .rst(rst),
        .en(fp_reg_write_en_in),
        .rs1(instruction[19:15]),
        .rs2(instruction[24:20]),
        .rs3(instruction[31:27]),
        .rd(instruction_rd[11:7]),
        .data(rd_wb_data),
        .op_a(fp_op_a),
        .op_b(fp_op_b),
        .op_c()
    );

    assign rs1 = instruction[19:15];
    assign rs2 = instruction[24:20];
    assign opb_data = fp_store ? fp_op_b : op_b;

    //SELECTION OF PROGRAM COUNTER OR OPERAND A
    mux u_mux1 
    (
        .a(op_a),
        .b(pc_address),
        .sel(operand_a),
        .out(int_opa)
    );
    
    //SELECTION OF OPERAND B OR IMMEDIATE     
    mux u_mux2(
        .a(op_b),
        .b(imm_mux_out),
        .sel(operand_b),
        .out(int_opb)
    );

    //BRANCH
    branch u_branch0(
        .en(branch),
        .op_a(op_a),
        .op_b(op_b),
        .fun3(instruction[14:12]),
        .result(branch_result)
    );
endmodule
