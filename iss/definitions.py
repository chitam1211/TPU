# ------------------------------------------------------------------------
# CÁC HẰNG SỐ KÍCH THƯỚC (Từ VARIABLES.py)
# ------------------------------------------------------------------------
XLEN = 32
ELEN = 32
TLEN = 512
TRLEN = 128
ROWNUM = TLEN // TRLEN
ARLEN = (TLEN // TRLEN) * ELEN
ALEN = ARLEN * ROWNUM
ELEMENTS_PER_ROW_TR = TRLEN // ELEN

# ------------------------------------------------------------------------
# BẢNG ÁNH XẠ TÊN THANH GHI
# ------------------------------------------------------------------------

# Bảng tra cứu 3-bit cho thanh ghi Ma trận (Từ assembler.py)
MATRIX_REG_MAP = {
    "tr0":  0b000,
    "tr1":  0b001,
    "tr2":  0b010,
    "tr3":  0b011,
    "acc0": 0b100,
    "acc1": 0b101,
    "acc2": 0b110,
    "acc3": 0b111
}

# Bảng tra cứu 5-bit cho thanh ghi GPR 
GPR_MAP = {
    # Tên x0-x31 
    **{f'x{i}': i for i in range(32)},
    
    # Tên ABI (Application Binary Interface)
    'zero': 0, 'ra': 1, 'sp': 2, 'gp': 3, 'tp': 4,
    't0': 5, 't1': 6, 't2': 7,
    's0': 8, 'fp': 8, 's1': 9,
    'a0': 10, 'a1': 11, 'a2': 12, 'a3': 13, 'a4': 14, 'a5': 15,
    'a6': 16, 'a7': 17,
    's2': 18, 's3': 19, 's4': 20, 's5': 21, 's6': 22, 's7': 23,
    's8': 24, 's9': 25, 's10': 26, 's11': 27,
    't3': 28, 't4': 29, 't5': 30, 't6': 31
}

# ------------------------------------------------------------------------
# CÁC NHÓM LỆNH (Từ assembler.py)
# ------------------------------------------------------------------------

# NHÓM 1: MATRIX CONFIGURATION INSTRUCTIONS (Table 2)
matrix_config_instructions = {
    "mrelease": {"instr_type": "CONFIG", "func": 0b0000, "uop": 0b00, "ctrl": 0b0, "rs2": 0b00000, "rs1": 0b00000, "func3": 0b000, "nop": 0b00000, "major_opcode": 0b0101011, "operand_type": "none"},
    "msettileki": {"instr_type": "CONFIG","func": 0b0001,"uop": 0b00,"ctrl": 0b0,"func3": 0b000,"nop": 0b00000, "major_opcode": 0b0101011, "operand_type": "immediate"},
    "msettilemi": {"instr_type": "CONFIG","func": 0b0010,"uop": 0b00,"ctrl": 0b0,"func3": 0b000,"nop": 0b00000, "major_opcode": 0b0101011, "operand_type": "immediate"},
    "msettileni": {"instr_type": "CONFIG","func": 0b0011,"uop": 0b00,"ctrl": 0b0,"func3": 0b000,"nop": 0b00000, "major_opcode": 0b0101011, "operand_type": "immediate"},
    "msettilek": {"instr_type": "CONFIG", "func": 0b0001, "uop": 0b00, "ctrl": 0b1, "func3": 0b000, "nop": 0b00000, "major_opcode": 0b0101011, "operand_type": "register"},
    "msettilem": {"instr_type": "CONFIG", "func": 0b0010, "uop": 0b00, "ctrl": 0b1, "func3": 0b000, "nop": 0b00000, "major_opcode": 0b0101011, "operand_type": "register"},
    "msettilen": {"instr_type": "CONFIG", "func": 0b0011, "uop": 0b00, "ctrl": 0b1, "func3": 0b000, "nop": 0b00000, "major_opcode": 0b0101011, "operand_type": "register"},
}

# NHÓM 2: MATRIX MISC INSTRUCTIONS (Table 3)
matrix_misc_instructions = {
    # Mzero Instructions
    "mzero": {"func": 0b0000, "uop": 0b11, "ctrl": 0b000, "func3": 0b000, "d_size": 0b00, "opcode": 0b0101011, "variant": "mzero", "instr_type": "MISC" },
    "mzero2r": {"func": 0b0000, "uop": 0b11, "ctrl": 0b001, "func3": 0b000, "d_size": 0b00, "opcode": 0b0101011, "variant": "mzero", "instr_type": "MISC"},
    "mzero4r": {"func": 0b0000, "uop": 0b11, "ctrl": 0b011, "func3": 0b000, "d_size": 0b00, "opcode": 0b0101011, "variant": "mzero", "instr_type": "MISC"},
    "mzero8r": {"func": 0b0000, "uop": 0b11, "ctrl": 0b111, "func3": 0b000, "d_size": 0b00, "opcode": 0b0101011, "variant": "mzero", "instr_type": "MISC"},
    "mmov.mm": {"func": 0b0001, "uop": 0b11, "ctrl": 0b000, "ms2": 0b000, "s_size": 0b00, "func3": 0b000, "d_size": 0b00, "opcode": 0b0101011, "variant": "md_ms1", "instr_type": "MISC"},
    "mmovb.m.x": {"func": 0b0011, "uop": 0b11, "ctrl25": 0b1, "func3": 0b000, "d_size": 0b00, "opcode": 0b0101011, "variant": "md_rs2_rs1", "instr_type": "MISC"},
    "mmovh.m.x": {"func": 0b0011, "uop": 0b11, "ctrl25": 0b1, "func3": 0b000, "d_size": 0b01, "opcode": 0b0101011, "variant": "md_rs2_rs1", "instr_type": "MISC"},
    "mmovw.m.x": {"func": 0b0011, "uop": 0b11, "ctrl25": 0b1, "func3": 0b000, "d_size": 0b10, "opcode": 0b0101011, "variant": "md_rs2_rs1", "instr_type": "MISC"},
    "mmovd.m.x": {"func": 0b0011, "uop": 0b11, "ctrl25": 0b1, "func3": 0b000, "d_size": 0b11, "opcode": 0b0101011, "variant": "md_rs2_rs1", "instr_type": "MISC"},
    "mdupb.m.x": {"func": 0b0011, "uop": 0b11, "ctrl25": 0b0, "func3": 0b000, "d_size": 0b00, "opcode": 0b0101011, "variant": "md_rs2_rs1", "instr_type": "MISC"},
    "mduph.m.x": {"func": 0b0011, "uop": 0b11, "ctrl25": 0b0, "func3": 0b000, "d_size": 0b01, "opcode": 0b0101011, "variant": "md_rs2_rs1", "instr_type": "MISC"},
    "mdupw.m.x": {"func": 0b0011, "uop": 0b11, "ctrl25": 0b0, "func3": 0b000, "d_size": 0b10, "opcode": 0b0101011, "variant": "md_rs2_rs1", "instr_type": "MISC"},
    "mdupd.m.x": {"func": 0b0011, "uop": 0b11, "ctrl25": 0b0, "func3": 0b000, "d_size": 0b11, "opcode": 0b0101011, "variant": "md_rs2_rs1", "instr_type": "MISC"},
    "mmovb.x.m": {"func": 0b0010, "uop": 0b11, "ctrl25": 0b0, "ctrl24_23": 0b11, "func3": 0b000, "opcode": 0b0101011, "variant": "rd_ms2_rs1", "instr_type": "MISC"},
    "mmovh.x.m": {"func": 0b0010, "uop": 0b11, "ctrl25": 0b0, "ctrl24_23": 0b01, "func3": 0b000, "opcode": 0b0101011, "variant": "rd_ms2_rs1", "instr_type": "MISC"},
    "mmovw.x.m": {"func": 0b0010, "uop": 0b11, "ctrl25": 0b0, "ctrl24_23": 0b10, "func3": 0b000, "opcode": 0b0101011, "variant": "rd_ms2_rs1", "instr_type": "MISC"},
    "mmovd.x.m": {"func": 0b0010, "uop": 0b11, "ctrl25": 0b0, "ctrl24_23": 0b11, "func3": 0b000, "opcode": 0b0101011, "variant": "rd_ms2_rs1", "instr_type": "MISC"},
    "mbce8": {"func": 0b0101, "uop": 0b10, "func3": 0b000, "opcode": 0b0101011, "variant": "md_ms1_imm3", "instr_type": "MISC"},
    "mrbc.mv.i": {"func": 0b0110, "uop": 0b10, "func3": 0b001, "opcode": 0b0101011, "variant": "md_ms1_imm3", "instr_type": "MISC"},
    "mcbce8.mv.i": {"func": 0b0111, "uop": 0b10, "func3": 0b010, "opcode": 0b0101011, "variant": "md_ms1_imm3", "instr_type": "MISC"},
    "mrslidedown": {"func": 0b0101, "uop": 0b11, "s_size": 0b00, "func3": 0b000, "d_size": 0b00, "opcode": 0b0101011, "variant": "md_ms1_imm3_direct", "instr_type": "MISC"},
    "mrslideup": {"func": 0b0110, "uop": 0b11, "s_size": 0b00, "func3": 0b000, "d_size": 0b00, "opcode": 0b0101011, "variant": "md_ms1_imm3_direct", "instr_type": "MISC"},
    "mcslidedown.b": {"func": 0b0111, "uop": 0b11, "s_size": 0b00, "func3": 0b000, "d_size": 0b00, "opcode": 0b0101011, "variant": "md_ms1_imm3_direct", "instr_type": "MISC"},
    "mcslidedown.h": {"func": 0b0111, "uop": 0b11, "s_size": 0b01, "func3": 0b000, "d_size": 0b01, "opcode": 0b0101011, "variant": "md_ms1_imm3_direct", "instr_type": "MISC"},
    "mcslidedown.w": {"func": 0b0111, "uop": 0b11, "s_size": 0b10, "func3": 0b000, "d_size": 0b10, "opcode": 0b0101011, "variant": "md_ms1_imm3_direct", "instr_type": "MISC"},
    "mcslidedown.d": {"func": 0b0111, "uop": 0b11, "s_size": 0b11, "func3": 0b000, "d_size": 0b11, "opcode": 0b0101011, "variant": "md_ms1_imm3_direct", "instr_type": "MISC"},
    "mcslideup.b": {"func": 0b1000, "uop": 0b11, "s_size": 0b00, "func3": 0b000, "d_size": 0b00, "opcode": 0b0101011, "variant": "md_ms1_imm3_direct", "instr_type": "MISC"},
    "mcslideup.h": {"func": 0b1000, "uop": 0b11, "s_size": 0b01, "func3": 0b000, "d_size": 0b01, "opcode": 0b0101011, "variant": "md_ms1_imm3_direct", "instr_type": "MISC"},
    "mcslideup.w": {"func": 0b1000, "uop": 0b11, "s_size": 0b10, "func3": 0b000, "d_size": 0b10, "opcode": 0b0101011, "variant": "md_ms1_imm3_direct", "instr_type": "MISC"},
    "mcslideup.d": {"func": 0b1000, "uop": 0b11, "s_size": 0b11, "func3": 0b000, "d_size": 0b11, "opcode": 0b0101011, "variant": "md_ms1_imm3_direct", "instr_type": "MISC"},
    "mrbca.mv.i": {"func": 0b1001, "uop": 0b11, "s_size": 0b00, "func3": 0b000, "d_size": 0b00, "opcode": 0b0101011, "variant": "md_ms1_imm3_direct", "instr_type": "MISC"},
    "mcbcab.mv.i": {"func": 0b1010, "uop": 0b11, "s_size": 0b00, "func3": 0b000, "d_size": 0b00, "opcode": 0b0101011, "variant": "md_ms1_imm3_direct", "instr_type": "MISC"},
    "mcbcah.mv.i": {"func": 0b1010, "uop": 0b11, "s_size": 0b01, "func3": 0b000, "d_size": 0b01, "opcode": 0b0101011, "variant": "md_ms1_imm3_direct", "instr_type": "MISC"},
    "mcbcaw.mv.i": {"func": 0b1010, "uop": 0b11, "s_size": 0b10, "func3": 0b000, "d_size": 0b10, "opcode": 0b0101011, "variant": "md_ms1_imm3_direct", "instr_type": "MISC"},
    "mcbcad.mv.i": {"func": 0b1010, "uop": 0b11, "s_size": 0b11, "func3": 0b000, "d_size": 0b11, "opcode": 0b0101011, "variant": "md_ms1_imm3_direct", "instr_type": "MISC"},
    "mpack": {"func": 0b0100, "uop": 0b11, "ctrl25": 0b0, "ctrl24_23": 0b00, "s_size": 0b00, "func3": 0b000, "d_size": 0b00, "opcode": 0b0101011, "variant": "md_ms2_ms1", "instr_type": "MISC"},
    "mpackhl": {"func": 0b0100, "uop": 0b11, "ctrl25": 0b0, "ctrl24_23": 0b10, "s_size": 0b00, "func3": 0b000, "d_size": 0b00, "opcode": 0b0101011, "variant": "md_ms2_ms1", "instr_type": "MISC"},
    "mpackhh": {"func": 0b0100, "uop": 0b11, "ctrl25": 0b0, "ctrl24_23": 0b11, "s_size": 0b00, "func3": 0b000, "d_size": 0b00, "opcode": 0b0101011, "variant": "md_ms2_ms1", "instr_type": "MISC"},
}

# NHÓM 3: MATRIX MULTIPLICATION INSTRUCTIONS (Table 4)
matrix_multiply_instructions = {
    "mfmacc.h.e5": {"func": 0b0000, "uop": 0b10, "size_sup": 0b000, "s_size": 0b00, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.h.e4": {"func": 0b0000, "uop": 0b10, "size_sup": 0b001, "s_size": 0b00, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.s.e4": {"func": 0b0000, "uop": 0b10, "size_sup": 0b001, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.bf16.e5": {"func": 0b0000, "uop": 0b10, "size_sup": 0b100, "s_size": 0b00, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.bf16.e4": {"func": 0b0000, "uop": 0b10, "size_sup": 0b101, "s_size": 0b00, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.s.e5": {"func": 0b0000, "uop": 0b10, "size_sup": 0b000, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011,"instr_type": "MULTIPLY"},
    "mfmacc.h": {"func": 0b0000, "uop": 0b10, "size_sup": 0b000, "s_size": 0b01, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.s.h": {"func": 0b0000, "uop": 0b10, "size_sup": 0b000, "s_size": 0b01, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.s.bf16": {"func": 0b0000, "uop": 0b10, "size_sup": 0b001, "s_size": 0b01, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.s.tf32": {"func": 0b0000, "uop": 0b10, "size_sup": 0b001, "s_size": 0b10, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.s": {"func": 0b0000,"uop": 0b10, "size_sup": 0b000, "s_size": 0b10, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.d.s": {"func": 0b0000, "uop": 0b10, "size_sup": 0b000, "s_size": 0b10, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.d": {"func": 0b0000, "uop": 0b10, "size_sup": 0b000, "s_size": 0b11, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mmacc.w.b": {"func": 0b0001, "uop": 0b10, "size_sup": 0b011, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mmaccu.w.b": {"func": 0b0001,"uop": 0b10,"size_sup": 0b000, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mmaccus.w.b": {"func": 0b0001, "uop": 0b10, "size_sup": 0b001, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mmaccsu.w.b": {"func": 0b0001, "uop": 0b10, "size_sup": 0b010, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "pmmacc.w.b": {"func": 0b0001, "uop": 0b10, "size_sup": 0b111, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "pmmaccu.w.b": {"func": 0b0001, "uop": 0b10, "size_sup": 0b100, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011,"instr_type": "MULTIPLY"},
    "pmmaaccus.w.b": {"func": 0b0001, "uop": 0b10, "size_sup": 0b101, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "pmmaccsu.w.b": {"func": 0b0001, "uop": 0b10, "size_sup": 0b110, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b1011011, "instr_type": "MULTIPLY"},
    "mmacc.d.h": {"func": 0b0001,"uop": 0b10,"size_sup": 0b011, "s_size": 0b01, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mmaccu.d.h": {"func": 0b0001, "uop": 0b10, "size_sup": 0b000, "s_size": 0b01, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mmaccus.d.h": {"func": 0b0001, "uop": 0b10, "size_sup": 0b001, "s_size": 0b01, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mmaccsu.d.h": {"func": 0b0001, "uop": 0b10, "size_sup": 0b010, "s_size": 0b01, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mmacc.w.bp": {"func": 0b0010, "uop": 0b10, "size_sup": 0b011, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
}

# NHÓM 4: MATRIX LOAD/STORE INSTRUCTIONS (Table 5)
matrix_loadstore_instructions = {
    "mlae8": {"instr_type": "LOADSTORE", "func": 0b0000, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b00, "major_opcode": 0b0101011},
    "mlae16": {"instr_type": "LOADSTORE", "func": 0b0000, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011},
    "mlae32": {"instr_type": "LOADSTORE", "func": 0b0000, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011},
    "mlae64": {"instr_type": "LOADSTORE", "func": 0b0000, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011},
    "mlbe8": {"instr_type": "LOADSTORE", "func": 0b0001, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b00, "major_opcode": 0b0101011},
    "mlbe16": {"instr_type": "LOADSTORE", "func": 0b0001, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011},
    "mlbe32": {"instr_type": "LOADSTORE", "func": 0b0001, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011 },
    "mlbe64": {"instr_type": "LOADSTORE", "func": 0b0001, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011},
    "mlce8": {"instr_type": "LOADSTORE", "func": 0b0010, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b00, "major_opcode": 0b0101011},
    "mlce16": {"instr_type": "LOADSTORE", "func": 0b0010, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b01  , "major_opcode": 0b0101011},
    "mlce32": {"instr_type": "LOADSTORE", "func": 0b0010, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011},
    "mlce64": {"instr_type": "LOADSTORE", "func": 0b0010, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011},
    "msae8": {"instr_type": "LOADSTORE", "func": 0b0000, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b00, "major_opcode": 0b0101011},
    "msae16": {"instr_type": "LOADSTORE", "func": 0b0000, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011},
    "msae32": {"instr_type": "LOADSTORE", "func": 0b0000, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011},
    "msae64": {"instr_type": "LOADSTORE", "func": 0b0000, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011},
    "msbe8": {"instr_type": "LOADSTORE", "func": 0b0001, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b00, "major_opcode": 0b0101011},
    "msbe16": {"instr_type": "LOADSTORE", "func": 0b0001, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011},
    "msbe32": {"instr_type": "LOADSTORE", "func": 0b0001, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011},
    "msbe64": {"instr_type": "LOADSTORE", "func": 0b0001, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011},
    "msce8": {"instr_type": "LOADSTORE", "func": 0b0010, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b00, "major_opcode": 0b0101011},
    "msce16": {"instr_type": "LOADSTORE", "func": 0b0010, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011},
    "msce32": {"instr_type": "LOADSTORE", "func": 0b0010, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011},
    "msce64": {"instr_type": "LOADSTORE", "func": 0b0010, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011},
    "mlme8": {"instr_type": "LOADSTORE", "func": 0b0011, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b00, "major_opcode": 0b0101011},
    "mlme16": {"instr_type": "LOADSTORE", "func": 0b0011, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011},
    "mlme32": {"instr_type": "LOADSTORE", "func": 0b0011, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011},
    "mlme64": {"instr_type": "LOADSTORE", "func": 0b0011, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011},
    "msme8": {"instr_type": "LOADSTORE", "func": 0b0011, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b00, "major_opcode": 0b0101011},
    "msme16": {"instr_type": "LOADSTORE", "func": 0b0011, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011},
    "msme32": {"instr_type": "LOADSTORE", "func": 0b0011, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011},
    "msme64": {"instr_type": "LOADSTORE", "func": 0b0011, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011},
    "mlate8": {"instr_type": "LOADSTORE", "func": 0b0100, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b00, "major_opcode": 0b0101011},
    "mlate16": {"instr_type": "LOADSTORE", "func": 0b0100, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011},
    "mlate32": {"instr_type": "LOADSTORE", "func": 0b0100, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011},
    "mlate64": {"instr_type": "LOADSTORE", "func": 0b0100, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011},
    "mlbte8": {"instr_type": "LOADSTORE", "func": 0b0101, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b00, "major_opcode": 0b0101011},
    "mlbte16": {"instr_type": "LOADSTORE", "func": 0b0101, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011},
    "mlbte32": {"instr_type": "LOADSTORE", "func": 0b0101, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011},
    "mlbte64": {"instr_type": "LOADSTORE", "func": 0b0101, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011},
    "mlcte8": {"instr_type": "LOADSTORE", "func": 0b0110, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b00, "major_opcode": 0b0101011},
    "mlcte16": {"instr_type": "LOADSTORE", "func": 0b0110, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011},
    "mlcte32": {"instr_type": "LOADSTORE", "func": 0b0110, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011},
    "mlcte64": {"instr_type": "LOADSTORE", "func": 0b0110, "uop": 0b01, "ls": 0b0, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011},
    "msate8": {"instr_type": "LOADSTORE", "func": 0b0100, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b00, "major_opcode": 0b0101011},
    "msate16": {"instr_type": "LOADSTORE", "func": 0b0100, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011},
    "msate32": {"instr_type": "LOADSTORE", "func": 0b0100, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011},
    "msate64": {"instr_type": "LOADSTORE", "func": 0b0100, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011},
    "msbte8": {"instr_type": "LOADSTORE", "func": 0b0101, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b00, "major_opcode": 0b0101011},
    "msbte16": {"instr_type": "LOADSTORE", "func": 0b0101, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011},
    "msbte32": {"instr_type": "LOADSTORE", "func": 0b0101, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011},
    "msbte64": {"instr_type": "LOADSTORE", "func": 0b0101, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011},
    "mscte8": {"instr_type": "LOADSTORE", "func": 0b0110, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b00, "major_opcode": 0b0101011},
    "mscte16": {"instr_type": "LOADSTORE", "func": 0b0110, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011},
    "mscte32": {"instr_type": "LOADSTORE", "func": 0b0110, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011},
    "mscte64": {"instr_type": "LOADSTORE", "func": 0b0110, "uop": 0b01, "ls": 0b1, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011},
}

# NHÓM 5: MATRIX ELEMENT-WISE INSTRUCTIONS (Table 6)
matrix_ew_instructions = {
    # madd.w.mm md, ms2, ms1
    "madd.w.mm": {"instr_type": "EW", "func": 0b0000, "uop": 0b01, "ctrl": 0b111, "s_size": 0b01, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
    "mn4clipl.w.mm": {"instr_type": "EW", "func": 0b0010, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
    "mn4cliph.w.mm": {"instr_type": "EW", "func": 0b0011, "uop": 0b00, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
    "mn4cliplu.w.mm": {"instr_type": "EW", "func": 0b0100, "uop": 0b00, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
    "mn4cliphu.w.mm": { "instr_type": "EW", "func": 0b0101, "uop": 0b00, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
    "msub.w.mm": { "instr_type": "EW", "func": 0b0001, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mmul.w.mm": { "instr_type": "EW", "func": 0b0010, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mmulh.w.mm": { "instr_type": "EW", "func": 0b0011, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mmax.w.mm": { "instr_type": "EW", "func": 0b0100, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mumax.w.mm": { "instr_type": "EW", "func": 0b0011, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mmin.w.mm": { "instr_type": "EW", "func": 0b0110, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mumin.w.mm": { "instr_type": "EW", "func": 0b0111, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"msrl.w.mm": { "instr_type": "EW", "func": 0b1000, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"msll.w.mm": { "instr_type": "EW", "func": 0b1001, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"msra.w.mm": { "instr_type": "EW", "func": 0b1010, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfadd.h.mm": { "instr_type": "EW", "func": 0b0000, "uop": 0b10, "ctrl": 0b111, "s_size": 0b01, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfadd.d.mm": { "instr_type": "EW", "func": 0b0000, "uop": 0b10, "ctrl": 0b111, "s_size": 0b11, "func3": 0b001, "d_size": 0b11, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfsub.h.mm": { "instr_type": "EW", "func": 0b0001, "uop": 0b10, "ctrl": 0b111, "s_size": 0b01, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfsub.s.mm": { "instr_type": "EW", "func": 0b0001, "uop": 0b10, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfsub.d.mm": { "instr_type": "EW", "func": 0b0001, "uop": 0b10, "ctrl": 0b111, "s_size": 0b11, "func3": 0b001, "d_size": 0b11, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfmul.h.mm": { "instr_type": "EW", "func": 0b0010, "uop": 0b10, "ctrl": 0b111, "s_size": 0b01, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfmul.s.mm": { "instr_type": "EW", "func": 0b0010, "uop": 0b10, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfmul.d.mm": { "instr_type": "EW", "func": 0b0010, "uop": 0b10, "ctrl": 0b111, "s_size": 0b11, "func3": 0b001, "d_size": 0b11, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfmax.h.mm": { "instr_type": "EW", "func": 0b0011, "uop": 0b10, "ctrl": 0b111, "s_size": 0b01, "func3": 0b001, "d_size": 0b11, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfmax.s.mm": { "instr_type": "EW", "func": 0b0011, "uop": 0b10, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfmax.d.mm": { "instr_type": "EW", "func": 0b0011, "uop": 0b10, "ctrl": 0b111, "s_size": 0b11, "func3": 0b001, "d_size": 0b11, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfmin.s.mm": { "instr_type": "EW", "func": 0b0100, "uop": 0b10, "ctrl": 0b111, "s_size": 0b01, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfmin.h.mm": { "instr_type": "EW", "func": 0b0100, "uop": 0b10, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfmin.d.mm": { "instr_type": "EW", "func": 0b0100, "uop": 0b10, "ctrl": 0b111, "s_size": 0b11, "func3": 0b001, "d_size": 0b11, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
    # madd.w.mv.i md, ms2, ms1[imm3]
	"madd.w.mv.i": { "instr_type": "EW", "func": 0b0000, "uop": 0b01, "s_size": 0b01, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mn4clipl.w.mv.i": { "instr_type": "EW", "func": 0b0010, "uop": 0b00, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mn4cliph.w.mv.i": { "instr_type": "EW", "func": 0b0011, "uop": 0b00, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mn4cliplu.w.mv.i": { "instr_type": "EW", "func": 0b0100, "uop": 0b00, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mn4cliphu.w.mv.i": { "instr_type": "EW", "func": 0b0101, "uop": 0b00, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"msub.w.mv.i": { "instr_type": "EW", "func": 0b0001, "uop": 0b01, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mmul.w.mv.i": { "instr_type": "EW", "func": 0b0010, "uop": 0b01, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mmulh.w.mv.i": { "instr_type": "EW", "func": 0b0011, "uop": 0b01, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mmax.w.mv.i": { "instr_type": "EW", "func": 0b0100, "uop": 0b01, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mumax.w.mv.i": { "instr_type": "EW", "func": 0b0101, "uop": 0b01, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mmin.w.mv.i": { "instr_type": "EW", "func": 0b0110, "uop": 0b01, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mumin.w.mv.i": { "instr_type": "EW", "func": 0b0111, "uop": 0b01, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"msrl.w.mv.i": { "instr_type": "EW", "func": 0b1000, "uop": 0b01, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"msll.w.mv.i": { "instr_type": "EW", "func": 0b1001, "uop": 0b01, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"msra.w.mv.i": { "instr_type": "EW", "func": 0b1010, "uop": 0b01, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mfadd.h.mv.i": { "instr_type": "EW", "func": 0b0000, "uop": 0b10, "s_size": 0b01, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mfadd.s.mv.i": { "instr_type": "EW", "func": 0b0000, "uop": 0b10, "s_size": 0b10, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mfadd.d.mv.i": { "instr_type": "EW", "func": 0b0000, "uop": 0b10, "s_size": 0b11, "func3": 0b001, "d_size": 0b11, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mfsub.h.mv.i": { "instr_type": "EW", "func": 0b0001, "uop": 0b10, "s_size": 0b01, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mfsub.s.mv.i ": { "instr_type": "EW", "func": 0b0001, "uop": 0b10, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mfsub.d.mv.i": { "instr_type": "EW", "func": 0b0001, "uop": 0b10, "s_size": 0b11, "func3": 0b001, "d_size": 0b11, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mfmul.h.mv.i": { "instr_type": "EW", "func": 0b0010, "uop": 0b10, "s_size": 0b01, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mfmul.s.mv.i": { "instr_type": "EW", "func": 0b0010, "uop": 0b10, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mfmul.d.mv.i": { "instr_type": "EW", "func": 0b0010, "uop": 0b10, "s_size": 0b11, "func3": 0b001, "d_size": 0b11, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mfmax.h.mv.i": { "instr_type": "EW", "func": 0b0011, "uop": 0b10, "s_size": 0b01, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mfmax.s.mv.i": { "instr_type": "EW", "func": 0b0011, "uop": 0b10, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mfmax.d.mv.i": { "instr_type": "EW", "func": 0b0011, "uop": 0b10, "s_size": 0b11, "func3": 0b001, "d_size": 0b11, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mfmin.s.mv.i": { "instr_type": "EW", "func": 0b0100, "uop": 0b10, "s_size": 0b01, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mfmin.h.mv.i": { "instr_type": "EW", "func": 0b0100, "uop": 0b10, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	"mfmin.d.mv.i": { "instr_type": "EW", "func": 0b0100, "uop": 0b10, "s_size": 0b11, "func3": 0b001, "d_size": 0b11, "major_opcode": 0b0101011, "variant": "md_ms2_ms1_imm3_direct"},
	
	# Aliases ngắn gọn (default to .mm variant) - for easier test writing
	"madd.w": {"instr_type": "EW", "func": 0b0000, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"msub.w": {"instr_type": "EW", "func": 0b0001, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mmul.w": {"instr_type": "EW", "func": 0b0010, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mmax.w": {"instr_type": "EW", "func": 0b0100, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mmin.w": {"instr_type": "EW", "func": 0b0110, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mumax.w": {"instr_type": "EW", "func": 0b0101, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mumin.w": {"instr_type": "EW", "func": 0b0111, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"msrl.w": {"instr_type": "EW", "func": 0b1000, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"msll.w": {"instr_type": "EW", "func": 0b1001, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"msra.w": {"instr_type": "EW", "func": 0b1010, "uop": 0b01, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfadd.s": {"instr_type": "EW", "func": 0b0000, "uop": 0b10, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfsub.s": {"instr_type": "EW", "func": 0b0001, "uop": 0b10, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfmul.s": {"instr_type": "EW", "func": 0b0010, "uop": 0b10, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfmax.s": {"instr_type": "EW", "func": 0b0011, "uop": 0b10, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfmin.s": {"instr_type": "EW", "func": 0b0100, "uop": 0b10, "ctrl": 0b111, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfadd.h": {"instr_type": "EW", "func": 0b0000, "uop": 0b10, "ctrl": 0b111, "s_size": 0b01, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfsub.h": {"instr_type": "EW", "func": 0b0001, "uop": 0b10, "ctrl": 0b111, "s_size": 0b01, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfmul.h": {"instr_type": "EW", "func": 0b0010, "uop": 0b10, "ctrl": 0b111, "s_size": 0b01, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfmax.h": {"instr_type": "EW", "func": 0b0011, "uop": 0b10, "ctrl": 0b111, "s_size": 0b01, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	"mfmin.h": {"instr_type": "EW", "func": 0b0100, "uop": 0b10, "ctrl": 0b111, "s_size": 0b01, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms2_ms1"},
	
    # mfcvth.e4.h md, ms1
    "mfcvth.e4.h": {"instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b010, "ms2": 0b000, "s_size": 0b01, "func3": 0b001, "d_size": 0b00, "major_opcode": 0b0101011, "variant": "md_ms1"},
    "mfcvtl.h.e4": {"instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b000, "ms2": 0b000, "s_size": 0b00, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms1"},
    "mfcvth.h.e4": {"instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b010, "ms2": 0b000, "s_size": 0b00, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms1"},
    "mfcvtl.h.e5": {"instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b001, "ms2": 0b000, "s_size": 0b00, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms1"},
    "mfcvth.h.e5": {"instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b011, "ms2": 0b000, "s_size": 0b00, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvtl.e4.h": { "instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b000, "ms2": 0b000, "s_size": 0b01, "func3": 0b001, "d_size": 0b00, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvtl.e5.h": { "instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b001, "ms2": 0b000, "s_size": 0b01, "func3": 0b001, "d_size": 0b00, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvth.e5.h": { "instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b011, "ms2": 0b000, "s_size": 0b01, "func3": 0b001, "d_size": 0b00, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvtl.s.h": { "instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b000, "ms2": 0b000, "s_size": 0b01, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvth.s.h": { "instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b000, "ms2": 0b000, "s_size": 0b01, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvtl.s.bf16": { "instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b001, "ms2": 0b000, "s_size": 0b01, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvth.s.bf16": { "instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b011, "ms2": 0b000, "s_size": 0b01, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvtl.e4.s": { "instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b000, "ms2": 0b000, "s_size": 0b10, "func3": 0b001, "d_size": 0b00, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvth.e4.s": { "instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b010, "ms2": 0b000, "s_size": 0b10, "func3": 0b001, "d_size": 0b00, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvtl.e5.s": { "instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b100, "ms2": 0b000, "s_size": 0b10, "func3": 0b001, "d_size": 0b00, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvth.e5.s": { "instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b110, "ms2": 0b000, "s_size": 0b10, "func3": 0b001, "d_size": 0b00, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvtl.h.s": { "instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b000, "ms2": 0b000, "s_size": 0b10, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvth.h.s": { "instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b010, "ms2": 0b000, "s_size": 0b10, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvtl.bf16.s": { "instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b100, "ms2": 0b000, "s_size": 0b10, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvth.bf16.s": { "instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b110, "ms2": 0b000, "s_size": 0b10, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvt.tf32.s": { "instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b110, "ms2": 0b000, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvt.s.tf32": { "instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b001, "ms2": 0b000, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvtl.d.s": { "instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b000, "ms2": 0b000, "s_size": 0b10, "func3": 0b001, "d_size": 0b11, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvth.d.s": { "instr_type": "EW", "func": 0b0000, "uop": 0b00, "ctrl": 0b010, "ms2": 0b000, "s_size": 0b10, "func3": 0b001, "d_size": 0b11, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"msfcvtl.h.b": { "instr_type": "EW", "func": 0b0001, "uop": 0b00, "ctrl": 0b001, "ms2": 0b000, "s_size": 0b00, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"msfcvth.h.b ": { "instr_type": "EW", "func": 0b0001, "uop": 0b00, "ctrl": 0b011, "ms2": 0b000, "s_size": 0b10, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mufcvtl.h.b": { "instr_type": "EW", "func": 0b0001, "uop": 0b00, "ctrl": 0b000, "ms2": 0b000, "s_size": 0b00, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mufcvth.h.b": { "instr_type": "EW", "func": 0b0001, "uop": 0b00, "ctrl": 0b010, "ms2": 0b000, "s_size": 0b00, "func3": 0b001, "d_size": 0b01, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfcvtl.d.s": { "instr_type": "EW", "func": 0b0001, "uop": 0b00, "ctrl": 0b001, "ms2": 0b000, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mufcvt.s.w": { "instr_type": "EW", "func": 0b0001, "uop": 0b00, "ctrl": 0b000, "ms2": 0b000, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfscvt.w.s": { "instr_type": "EW", "func": 0b0001, "uop": 0b00, "ctrl": 0b101, "ms2": 0b000, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfucvt.w.s": { "instr_type": "EW", "func": 0b0001, "uop": 0b00, "ctrl": 0b100, "ms2": 0b000, "s_size": 0b10, "func3": 0b001, "d_size": 0b10, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfucvtl.b.h": { "instr_type": "EW", "func": 0b0001, "uop": 0b00, "ctrl": 0b100, "ms2": 0b000, "s_size": 0b01, "func3": 0b001, "d_size": 0b00, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfucvth.b.h": { "instr_type": "EW", "func": 0b0001, "uop": 0b00, "ctrl": 0b110, "ms2": 0b000, "s_size": 0b01, "func3": 0b001, "d_size": 0b00, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfscvtl.b.h": { "instr_type": "EW", "func": 0b0001, "uop": 0b00, "ctrl": 0b101, "ms2": 0b000, "s_size": 0b01, "func3": 0b001, "d_size": 0b00, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mfscvth.b.h": { "instr_type": "EW", "func": 0b0001, "uop": 0b00, "ctrl": 0b111, "ms2": 0b000, "s_size": 0b01, "func3": 0b001, "d_size": 0b00, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mscvtl.b.p": { "instr_type": "EW", "func": 0b0110, "uop": 0b00, "ctrl": 0b001, "ms2": 0b000, "s_size": 0b00, "func3": 0b001, "d_size": 0b00, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mscvth.b.p": { "instr_type": "EW", "func": 0b0110, "uop": 0b00, "ctrl": 0b011, "ms2": 0b000, "s_size": 0b00, "func3": 0b001, "d_size": 0b00, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mucvtl.b.p": { "instr_type": "EW", "func": 0b0110, "uop": 0b00, "ctrl": 0b000, "ms2": 0b000, "s_size": 0b00, "func3": 0b001, "d_size": 0b00, "major_opcode": 0b0101011, "variant": "md_ms1"},
	"mucvth.b.p": { "instr_type": "EW", "func": 0b0110, "uop": 0b00, "ctrl": 0b010, "ms2": 0b000, "s_size": 0b00, "func3": 0b001, "d_size": 0b00, "major_opcode": 0b0101011, "variant": "md_ms1"},
}

# ------------------------------------------------------------------------
# GỘP TẤT CẢ THÀNH 1 BẢNG
# ------------------------------------------------------------------------
ALL_INSTRUCTIONS = {
    **matrix_config_instructions,
    **matrix_misc_instructions,
    **matrix_multiply_instructions,
    **matrix_loadstore_instructions,
    **matrix_ew_instructions,
}

