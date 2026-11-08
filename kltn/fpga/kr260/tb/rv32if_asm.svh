// =============================================================================
// rv32if_asm.svh : ham ma hoa lenh RV32I / RV32F / ma tran cho testbench he thong.
// `include ben trong module testbench (sau 'import tb_matrix_pkg::*;').
// Dung boi Verify/top_test/tb_top.sv va Source_code/fpga/kr260/tb/tb_kr260_programs.sv.
// =============================================================================
    // ---------------------------------------------------------------------
    // Ma hoa lenh RV32I / RV32F
    // ---------------------------------------------------------------------
    function automatic logic [31:0] r_t(input logic [6:0] f7, input int rs2, input int rs1,
                                        input logic [2:0] f3, input int rd, input logic [6:0] op);
        return {f7, 5'(rs2), 5'(rs1), f3, 5'(rd), op};
    endfunction
    function automatic logic [31:0] i_t(input int imm, input int rs1, input logic [2:0] f3,
                                        input int rd, input logic [6:0] op);
        return {12'(imm), 5'(rs1), f3, 5'(rd), op};
    endfunction
    function automatic logic [31:0] s_t(input int imm, input int rs2, input int rs1,
                                        input logic [2:0] f3, input logic [6:0] op);
        logic [11:0] i; i = 12'(imm);
        return {i[11:5], 5'(rs2), 5'(rs1), f3, i[4:0], op};
    endfunction
    function automatic logic [31:0] b_t(input int off, input int rs2, input int rs1, input logic [2:0] f3);
        logic [12:0] i; i = 13'(off);
        return {i[12], i[10:5], 5'(rs2), 5'(rs1), f3, i[4:1], i[11], 7'b1100011};
    endfunction
    function automatic logic [31:0] j_t(input int off, input int rd);
        logic [20:0] i; i = 21'(off);
        return {i[20], i[10:1], i[11], i[19:12], 5'(rd), 7'b1101111};
    endfunction

    // R-type ALU
    function automatic logic [31:0] e_add (int rd, int a, int b); return r_t(7'h00, b, a, 3'b000, rd, 7'h33); endfunction
    function automatic logic [31:0] e_sub (int rd, int a, int b); return r_t(7'h20, b, a, 3'b000, rd, 7'h33); endfunction
    function automatic logic [31:0] e_sll (int rd, int a, int b); return r_t(7'h00, b, a, 3'b001, rd, 7'h33); endfunction
    function automatic logic [31:0] e_slt (int rd, int a, int b); return r_t(7'h00, b, a, 3'b010, rd, 7'h33); endfunction
    function automatic logic [31:0] e_sltu(int rd, int a, int b); return r_t(7'h00, b, a, 3'b011, rd, 7'h33); endfunction
    function automatic logic [31:0] e_xor (int rd, int a, int b); return r_t(7'h00, b, a, 3'b100, rd, 7'h33); endfunction
    function automatic logic [31:0] e_srl (int rd, int a, int b); return r_t(7'h00, b, a, 3'b101, rd, 7'h33); endfunction
    function automatic logic [31:0] e_sra (int rd, int a, int b); return r_t(7'h20, b, a, 3'b101, rd, 7'h33); endfunction
    function automatic logic [31:0] e_or  (int rd, int a, int b); return r_t(7'h00, b, a, 3'b110, rd, 7'h33); endfunction
    function automatic logic [31:0] e_and (int rd, int a, int b); return r_t(7'h00, b, a, 3'b111, rd, 7'h33); endfunction
    // I-type ALU
    function automatic logic [31:0] e_addi (int rd, int a, int imm); return i_t(imm, a, 3'b000, rd, 7'h13); endfunction
    function automatic logic [31:0] e_slti (int rd, int a, int imm); return i_t(imm, a, 3'b010, rd, 7'h13); endfunction
    function automatic logic [31:0] e_sltiu(int rd, int a, int imm); return i_t(imm, a, 3'b011, rd, 7'h13); endfunction
    function automatic logic [31:0] e_xori (int rd, int a, int imm); return i_t(imm, a, 3'b100, rd, 7'h13); endfunction
    function automatic logic [31:0] e_ori  (int rd, int a, int imm); return i_t(imm, a, 3'b110, rd, 7'h13); endfunction
    function automatic logic [31:0] e_andi (int rd, int a, int imm); return i_t(imm, a, 3'b111, rd, 7'h13); endfunction
    function automatic logic [31:0] e_slli (int rd, int a, int sh);  return i_t(sh, a, 3'b001, rd, 7'h13); endfunction
    function automatic logic [31:0] e_srli (int rd, int a, int sh);  return i_t(sh, a, 3'b101, rd, 7'h13); endfunction
    function automatic logic [31:0] e_srai (int rd, int a, int sh);  return i_t(sh | 32'h400, a, 3'b101, rd, 7'h13); endfunction
    function automatic logic [31:0] e_lui  (int rd, logic [19:0] imm); return {imm, 5'(rd), 7'h37}; endfunction
    function automatic logic [31:0] e_auipc(int rd, logic [19:0] imm); return {imm, 5'(rd), 7'h17}; endfunction
    // Load / store
    function automatic logic [31:0] e_lb (int rd, int a, int imm); return i_t(imm, a, 3'b000, rd, 7'h03); endfunction
    function automatic logic [31:0] e_lh (int rd, int a, int imm); return i_t(imm, a, 3'b001, rd, 7'h03); endfunction
    function automatic logic [31:0] e_lw (int rd, int a, int imm); return i_t(imm, a, 3'b010, rd, 7'h03); endfunction
    function automatic logic [31:0] e_lbu(int rd, int a, int imm); return i_t(imm, a, 3'b100, rd, 7'h03); endfunction
    function automatic logic [31:0] e_lhu(int rd, int a, int imm); return i_t(imm, a, 3'b101, rd, 7'h03); endfunction
    function automatic logic [31:0] e_sb (int src, int a, int imm); return s_t(imm, src, a, 3'b000, 7'h23); endfunction
    function automatic logic [31:0] e_sh (int src, int a, int imm); return s_t(imm, src, a, 3'b001, 7'h23); endfunction
    function automatic logic [31:0] e_sw (int src, int a, int imm); return s_t(imm, src, a, 3'b010, 7'h23); endfunction
    // Jump
    function automatic logic [31:0] e_jalr(int rd, int a, int imm); return i_t(imm, a, 3'b000, rd, 7'h67); endfunction
    // RV32F
    function automatic logic [31:0] e_flw(int fd, int a, int imm); return i_t(imm, a, 3'b010, fd, 7'h07); endfunction
    function automatic logic [31:0] e_fsw(int fs, int a, int imm); return s_t(imm, fs, a, 3'b010, 7'h27); endfunction
    function automatic logic [31:0] e_fop(logic [6:0] f7, int rd, int a, int b, logic [2:0] rm);
        return r_t(f7, b, a, rm, rd, 7'h53);
    endfunction
    function automatic logic [31:0] e_r4(logic [6:0] op, int rd, int a, int b, int c);
        return {5'(c), 2'b00, 5'(b), 5'(a), 3'b000, 5'(rd), op};
    endfunction
    function automatic logic [31:0] e_csr(logic [2:0] f3, int rd, logic [11:0] csr, int rs1);
        return {csr, 5'(rs1), f3, 5'(rd), 7'h73};
    endfunction

    // Lenh ma tran
    function automatic logic [31:0] m_setm(int v); return enc_cfg(4'b0010, 1'b0, 10'(v), 5'd0); endfunction
    function automatic logic [31:0] m_setn(int v); return enc_cfg(4'b0011, 1'b0, 10'(v), 5'd0); endfunction
    function automatic logic [31:0] m_setk(int v); return enc_cfg(4'b0001, 1'b0, 10'(v), 5'd0); endfunction
    function automatic logic [31:0] m_ld(logic [3:0] f4, logic [1:0] ds, logic [2:0] md, int base, int stride);
        return enc_ls(f4, 1'b0, 5'(stride), 5'(base), ds, md);
    endfunction
    function automatic logic [31:0] m_st(logic [3:0] f4, logic [1:0] ds, logic [2:0] md, int base, int stride);
        return enc_ls(f4, 1'b1, 5'(stride), 5'(base), ds, md);
    endfunction
    function automatic logic [31:0] m_mmacc(logic [2:0] md, logic [2:0] ms2, logic [2:0] ms1);
        return enc_mma(4'b0001, 3'b011, ms2, 2'b00, ms1, 2'b10, md);       // mmacc.w.b (s8 x s8)
    endfunction
    function automatic logic [31:0] m_mfmacc(logic [2:0] md, logic [2:0] ms2, logic [2:0] ms1);
        return enc_mma(4'b0000, 3'b000, ms2, 2'b10, ms1, 2'b10, md);       // mfmacc.s
    endfunction
    function automatic logic [31:0] m_zero(logic [2:0] md);
        return enc_raw(4'b0000, 2'b11, 3'd0, 3'd0, 2'b00, 3'd0, 3'b000, 2'b00, md);
    endfunction

