`timescale 1ns/1ps
module tb_fp_decode;
    reg [31:0] instruction;
    wire addsub,mul,divsqrt,fma,cvt_to_int,cvt_to_float,misc,compare,minmax;
    wire use_x1,use_f1,use_f2,use_f3,write_x,write_f;
    wire [2:0] misc_op;
    wire compare_ex, minmax_ex;
    // ID decoder supplies unit class and register usage; EX decoder supplies misc_op/compare/minmax.
    fp_decode_id dut_id(
        .opcode(instruction[6:0]), .funct3(instruction[14:12]),
        .rs2(instruction[24:20]), .funct7(instruction[31:25]),
        .addsub(addsub), .mul(mul), .divsqrt(divsqrt), .fma(fma),
        .cvt_to_int(cvt_to_int), .cvt_to_float(cvt_to_float), .compare(compare), .minmax(minmax),
        .use_x1(use_x1), .use_f1(use_f1), .use_f2(use_f2), .use_f3(use_f3),
        .write_x(write_x), .write_f(write_f));
    fp_decode_ex dut_ex(
        .opcode(instruction[6:0]), .funct3(instruction[14:12]),
        .rs2(instruction[24:20]), .funct7(instruction[31:25]),
        .compare(compare_ex), .minmax(minmax_ex), .misc(misc), .misc_op(misc_op));
    integer f7,f3,s2,opcode,fmt,n=0;
    reg is_fma;
    reg [9:0] expected;
    task check;
        begin
            #1;
            if (minmax !== (instruction[6:0] == 7'h53 && instruction[31:25] == 7'h14 && instruction[14:12] <= 1))
                $fatal(1,"Minmax decode insn=%h",instruction);
            if (compare !== (instruction[6:0] == 7'h53 && instruction[31:25] == 7'h50 && instruction[14:12] <= 2))
                $fatal(1,"Compare decode insn=%h",instruction);
            if (compare_ex !== compare || minmax_ex !== minmax)
                $fatal(1,"ID/EX decoders disagree insn=%h",instruction);
            if (mul !== (instruction[6:0] == 7'h53 && instruction[31:25] == 7'h08))
                $fatal(1,"Mul decode insn=%h",instruction);
            if (divsqrt !== (instruction[6:0] == 7'h53 && (instruction[31:25] == 7'h0c ||
                             (instruction[31:25] == 7'h2c && instruction[24:20] == 0))))
                $fatal(1,"Div/sqrt decode insn=%h",instruction);
            if (cvt_to_int !== (instruction[6:0] == 7'h53 && instruction[31:25] == 7'h60 && instruction[24:20] <= 1))
                $fatal(1,"FCVT.W[U].S decode insn=%h",instruction);
            if (cvt_to_float !== (instruction[6:0] == 7'h53 && instruction[31:25] == 7'h68 && instruction[24:20] <= 1))
                $fatal(1,"FCVT.S.W[U] decode insn=%h",instruction);
            is_fma = (instruction[6:0] == 7'h43 || instruction[6:0] == 7'h47 ||
                      instruction[6:0] == 7'h4b || instruction[6:0] == 7'h4f) &&
                     instruction[26:25] == 0;
            if (fma !== is_fma || use_f3 !== is_fma)
                $fatal(1,"FMA decode insn=%h",instruction);
            if ({addsub,misc,misc_op,use_x1,use_f1,use_f2,write_x,write_f} !== expected)
                $fatal(1,"Decode insn=%h got=%b expected=%b",instruction,
                    {addsub,misc,misc_op,use_x1,use_f1,use_f2,write_x,write_f},expected);
            n=n+1;
        end
    endtask
    initial begin
        for(f7=0;f7<128;f7=f7+1)
          for(f3=0;f3<8;f3=f3+1)
            for(s2=0;s2<32;s2=s2+1) begin
                instruction={f7[6:0],s2[4:0],5'd7,f3[2:0],5'd9,7'h53};
                expected=0;
                if(f7==0 || f7==4) expected={1'b1,1'b0,3'd0,5'b01101};
                if(f7==8 || f7==12) expected={1'b0,1'b0,3'd0,5'b01101};
                if(f7==44 && s2==0) expected={1'b0,1'b0,3'd0,5'b01001};
                if(f7==96 && s2<2) expected={1'b0,1'b0,3'd0,5'b01010};
                if(f7==104 && s2<2) expected={1'b0,1'b0,3'd0,5'b10001};
                if(f7==16 && f3<3) expected={1'b0,1'b1,3'd1+f3[2:0],5'b01101};
                if(f7==80 && f3<3) expected={1'b0,1'b0,3'd0,5'b01110};
                if(f7==20 && f3<2) expected={1'b0,1'b0,3'd0,5'b01101};
                if(f7==112 && s2==0 && f3==0) expected={1'b0,1'b1,3'd0,5'b01010};
                if(f7==112 && s2==0 && f3==1) expected={1'b0,1'b1,3'd4,5'b01010};
                if(f7==120 && s2==0 && f3==0) expected={1'b0,1'b1,3'd0,5'b10001};
                check;
            end
        for(opcode=0;opcode<128;opcode=opcode+1) begin
            instruction={7'h10,5'd2,5'd1,3'd0,5'd3,opcode[6:0]};
            expected=opcode==83 ? {1'b0,1'b1,3'd1,5'b01101} :
                     (opcode==67 || opcode==71 || opcode==75 || opcode==79) ? {1'b0,1'b0,3'd0,5'b01101} : 10'b0;
            check;
        end
        // R4 encodings: only fmt=S (00) is RV32F; rs3/rm fields must not matter.
        for(opcode=0;opcode<4;opcode=opcode+1)
          for(fmt=0;fmt<4;fmt=fmt+1)
            for(f3=0;f3<8;f3=f3+1) begin
                instruction={5'd17,fmt[1:0],5'd2,5'd1,f3[2:0],5'd3,3'b100,opcode[1:0],2'b11};
                expected=fmt==0 ? {1'b0,1'b0,3'd0,5'b01101} : 10'b0;
                check;
            end
        $display("FP_DECODE_TEST_PASS cases=%0d",n); $finish;
    end
endmodule
