// OP-FP and R4 (fused multiply-add) decoding for RV32F. Memory and CSR decoding stay separate.
// One module per pipeline stage, each taking only the instruction fields it reads:
//   fp_decode_id: unit class and register-file usage, at ID (Decode.v).
//   fp_decode_ex: operation select of the one-cycle units, at EX (Core.v, from instruction_execute).
// Reserved rm is passed to arithmetic/conversion units for the core's no-write policy.
module fp_decode_id (
    input wire [6:0] opcode,
    input wire [2:0] funct3,
    input wire [4:0] rs2,
    input wire [6:0] funct7,
    output reg addsub, mul, divsqrt, fma, cvt_to_int, cvt_to_float, compare, minmax,
    output reg use_x1, use_f1, use_f2, use_f3,
    output reg write_x, write_f
);
    always @(*) begin
        addsub=0; mul=0; divsqrt=0; fma=0; cvt_to_int=0; cvt_to_float=0; compare=0; minmax=0;
        use_x1=0; use_f1=0; use_f2=0; use_f3=0; write_x=0; write_f=0;
        // FMADD/FMSUB/FNMSUB/FNMADD.S: opcode 0x43/0x47/0x4b/0x4f, fmt=S.
        if (opcode[6:4] == 3'b100 && opcode[1:0] == 2'b11 && funct7[1:0] == 2'b00) begin
            fma=1; use_f1=1; use_f2=1; use_f3=1; write_f=1;
        end
        if (opcode == 7'h53) begin
            case (funct7)
                7'h00, 7'h04: begin addsub=1; use_f1=1; use_f2=1; write_f=1; end
                7'h08: begin mul=1; use_f1=1; use_f2=1; write_f=1; end
                7'h0c: begin divsqrt=1; use_f1=1; use_f2=1; write_f=1; end
                7'h2c: if (rs2 == 0) begin divsqrt=1; use_f1=1; write_f=1; end
                7'h10: if (funct3 <= 2) begin use_f1=1; use_f2=1; write_f=1; end      // FSGNJ[N|X]
                7'h50: if (funct3 <= 2) begin compare=1; use_f1=1; use_f2=1; write_x=1; end
                7'h14: if (funct3 <= 1) begin minmax=1; use_f1=1; use_f2=1; write_f=1; end
                7'h60: if (rs2 <= 1) begin cvt_to_int=1; use_f1=1; write_x=1; end
                7'h68: if (rs2 <= 1) begin cvt_to_float=1; use_x1=1; write_f=1; end
                7'h70: if (rs2 == 0 && funct3 <= 1) begin use_f1=1; write_x=1; end   // FMV.X.W, FCLASS
                7'h78: if (rs2 == 0 && funct3 == 0) begin use_x1=1; write_f=1; end   // FMV.W.X
                default: begin end
            endcase
        end
    end
endmodule

module fp_decode_ex (
    input wire [6:0] opcode,
    input wire [2:0] funct3,
    input wire [4:0] rs2,
    input wire [6:0] funct7,
    output reg compare, minmax, misc,
    output reg [2:0] misc_op
);
    // misc_op: 0=move (either direction), 1=sgnj, 2=sgnjn, 3=sgnjx, 4=class.
    always @(*) begin
        compare=0; minmax=0; misc=0; misc_op=0;
        if (opcode == 7'h53) begin
            case (funct7)
                7'h10: if (funct3 <= 2) begin misc=1; misc_op=funct3+3'd1; end
                7'h50: if (funct3 <= 2) compare=1;
                7'h14: if (funct3 <= 1) minmax=1;
                7'h70: if (rs2 == 0) begin
                    case (funct3)
                        0: begin misc=1; misc_op=0; end
                        1: begin misc=1; misc_op=4; end
                        default: begin end
                    endcase
                end
                7'h78: if (rs2 == 0 && funct3 == 0) begin misc=1; misc_op=0; end
                default: begin end
            endcase
        end
    end
endmodule
