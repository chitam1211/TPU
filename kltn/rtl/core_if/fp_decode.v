// OP-FP and R4 (fused multiply-add) decoding for the F26 checkpoint. Memory and CSR decoding stay separate.
// Reserved rm is passed to arithmetic/conversion units for the core's no-write policy.
module fp_decode (
    input wire [31:0] instruction,
    output reg addsub, mul, divsqrt, fma, cvt_to_int, cvt_to_float, misc, compare, minmax,
    output reg [2:0] misc_op,
    output reg use_x1, use_f1, use_f2, use_f3,
    output reg write_x, write_f
);
    // misc_op: 0=move (either direction), 1=sgnj, 2=sgnjn, 3=sgnjx, 4=class.
    always @(*) begin
        addsub=0; mul=0; divsqrt=0; fma=0; cvt_to_int=0; cvt_to_float=0;
        misc=0; compare=0; minmax=0; misc_op=0;
        use_x1=0; use_f1=0; use_f2=0; use_f3=0; write_x=0; write_f=0;
        // FMADD/FMSUB/FNMSUB/FNMADD.S: opcode 0x43/0x47/0x4b/0x4f, fmt=S.
        if (instruction[6:4] == 3'b100 && instruction[1:0] == 2'b11 &&
            instruction[26:25] == 2'b00) begin
            fma=1; use_f1=1; use_f2=1; use_f3=1; write_f=1;
        end
        if (instruction[6:0] == 7'h53) begin
            case (instruction[31:25])
                7'h00, 7'h04: begin
                    addsub=1; use_f1=1; use_f2=1; write_f=1;
                end
                7'h08: begin
                    mul=1; use_f1=1; use_f2=1; write_f=1;
                end
                7'h0c: begin
                    divsqrt=1; use_f1=1; use_f2=1; write_f=1;
                end
                7'h2c: if (instruction[24:20] == 0) begin
                    divsqrt=1; use_f1=1; write_f=1;
                end
                7'h10: if (instruction[14:12] <= 2) begin
                    misc=1; misc_op=instruction[14:12]+3'd1;
                    use_f1=1; use_f2=1; write_f=1;
                end
                7'h50: if (instruction[14:12] <= 2) begin
                    compare=1; use_f1=1; use_f2=1; write_x=1;
                end
                7'h14: if (instruction[14:12] <= 1) begin
                    minmax=1; use_f1=1; use_f2=1; write_f=1;
                end
                7'h60: if (instruction[24:20] <= 1) begin
                    cvt_to_int=1; use_f1=1; write_x=1;
                end
                7'h68: if (instruction[24:20] <= 1) begin
                    cvt_to_float=1; use_x1=1; write_f=1;
                end
                7'h70: if (instruction[24:20] == 0) begin
                    case (instruction[14:12])
                        0: begin misc=1; misc_op=0; use_f1=1; write_x=1; end
                        1: begin misc=1; misc_op=4; use_f1=1; write_x=1; end
                        default: begin end
                    endcase
                end
                7'h78: if (instruction[24:20] == 0 && instruction[14:12] == 0) begin
                    misc=1; misc_op=0; use_x1=1; write_f=1;
                end
                default: begin end
            endcase
        end
    end
endmodule
