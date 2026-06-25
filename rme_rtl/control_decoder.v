module control_decoder (
    input wire [2:0] fun3,
    input wire fun7,
    input wire i_type,
    input wire r_type,
    input wire load,
    input wire store,
    input wire branch,
    input wire jal,
    input wire jalr,
    input wire lui,
    input wire auipc,
    input wire matrix,
    input wire load_control,

    output reg Load,
    output reg Store,
    output reg Matrix,
    output reg jalr_out,
    output reg [1:0] mem_to_reg,
    output reg reg_write,
    output reg mem_en,
    output reg operand_b,
    output reg operand_a,
    output reg [2:0]imm_sel,
    output reg Branch,
    output reg next_sel,
    output reg [3:0]alu_control
);

    always @(*) begin
        reg_write   = r_type | i_type | load | jal | jalr | lui | auipc | load_control;
        operand_a   = branch | jal | auipc;
        operand_b   = i_type | load | store | branch | jal | jalr | lui | auipc;
        Load        = load;
        Store       = store;
        Branch      = branch;
        next_sel    = jal;
        jalr_out    = jalr;
        mem_en      = store;
        mem_to_reg  = 2'b00;
        imm_sel     = 3'b000;
        alu_control = 4'b0000;

        if(r_type) begin //rtype
            mem_to_reg = 2'b00;
            case({fun7, fun3})
                4'b0_000: alu_control = 4'b0000; // ADD
                4'b1_000: alu_control = 4'b0001; // SUB
                4'b0_001: alu_control = 4'b0010; // SLL
                4'b0_010: alu_control = 4'b0011; // SLT
                4'b0_011: alu_control = 4'b0100; // SLTU
                4'b0_100: alu_control = 4'b0101; // XOR
                4'b0_101: alu_control = 4'b0110; // SRL
                4'b1_101: alu_control = 4'b0111; // SRA
                4'b0_110: alu_control = 4'b1000; // OR
                4'b0_111: alu_control = 4'b1001; // AND
                default:  alu_control = 4'b0000;
            endcase
        end
        else if (i_type) begin //itype
            imm_sel = 3'b000; //i_type selection
            mem_to_reg = 2'b00;
            case({fun7, fun3})
                4'b0_000: alu_control = 4'b0000; // ADDI
                4'b0_001: alu_control = 4'b0010; // SLLI
                4'b0_010: alu_control = 4'b0011; // SLTI
                4'b0_011: alu_control = 4'b0100; // SLTIU
                4'b0_100: alu_control = 4'b0101; // XORI
                4'b0_101: alu_control = 4'b0110; // SRLI
                4'b1_101: alu_control = 4'b0111; // SRAI
                4'b0_110: alu_control = 4'b1000; // ORI
                4'b0_111: alu_control = 4'b1001; // ANDI
                default:  alu_control = 4'b0000;
            endcase
        end
        else if (store) begin //store
            imm_sel = 3'b001; //store selection
            mem_to_reg = 2'b00;
            // All store operations use ADD for address calculation
            alu_control = 4'b0000;
        end
        else if (load) begin
            imm_sel = 3'b000; //i_type selection
            mem_to_reg = 2'b01;
            // All load operations use ADD for address calculation
            alu_control = 4'b0000;
        end
        else if (branch) begin
            alu_control = 4'b0000;
            mem_to_reg = 2'b00;
            imm_sel = 3'b010; //branch selection
        end
        else if (jal) begin
            alu_control = 4'b0000;
            mem_to_reg = 2'b10;
            imm_sel = 3'b011; //jal selection
        end
        else if (jalr) begin
            mem_to_reg = 2'b00;
            alu_control = 4'b0000;
            imm_sel = 3'b000; //i_type selection
        end
        else if (lui) begin
            mem_to_reg = 2'b00;
            imm_sel = 3'b100; //u_type selection
            alu_control = 4'b1111;
        end
        else if (auipc) begin
            mem_to_reg = 2'b00;
            alu_control = 4'b0000;
            imm_sel = 3'b100; //u_type selection
        end
    end

endmodule
