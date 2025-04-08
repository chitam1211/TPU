import sys
import re
from pathlib import Path
sys.stdout.reconfigure(encoding='utf-8')

# ------------------------------------------------------------------------
# BẢNG ÁNH XẠ TÊN THANH GHI -> 3-bit (ví dụ: 4 tile + 4 accumulator)
# ------------------------------------------------------------------------
REG_CODE = {
    "tr0":  0b000,
    "tr1":  0b001,
    "tr2":  0b010,
    "tr3":  0b011,
    "acc0": 0b100,
    "acc1": 0b101,
    "acc2": 0b110,
    "acc3": 0b111
}

def encode_register(reg_name):
    """
    Trả về mã 3-bit ứng với tên thanh ghi (tr0..tr3, acc0..acc3).
    """
    reg_name = reg_name.strip().lower()
    if reg_name not in REG_CODE:
        raise ValueError(f"Unknown register '{reg_name}'")
    return REG_CODE[reg_name]

def encode_riscv_register(reg_name, is_immediate=False):
    """
    Trả về mã 5-bit ứng với tên thanh ghi RISC-V (x0..x31) hoặc mã 3-bit cho immediate.
    
    Args:
        reg_name (str): Tên thanh ghi (x0..x31) hoặc giá trị immediate (dạng chuỗi hoặc số).
        is_immediate (bool): Nếu True, mã hóa reg_name thành 3-bit immediate (uimm3).
    
    Returns:
        int: Mã 5-bit của thanh ghi hoặc mã 3-bit của immediate.
    
    Raises:
        ValueError: Nếu tên thanh ghi hoặc giá trị immediate không hợp lệ.
    """
    reg_name = reg_name.strip().lower()

    if is_immediate:
        try:
            imm_value = int(reg_name)  # Chuyển chuỗi thành số nguyên
            if not (0 <= imm_value <= 7):
                raise ValueError(f"Giá trị immediate phải từ 0 đến 7, nhận được '{imm_value}'")
            # Ánh xạ giá trị immediate theo định nghĩa của uimm3
            uimm3_map = {0: 0b000, 1: 0b001, 3: 0b011, 7: 0b111}
            if imm_value not in uimm3_map:
                raise ValueError(f"Giá trị immediate '{imm_value}' không được hỗ trợ cho uimm3")
            return uimm3_map[imm_value]  # Trả về mã 3-bit
        except ValueError:
            raise ValueError(f"Giá trị immediate không hợp lệ: '{reg_name}'")
    else:
        reg_map = {f'x{i}': i for i in range(32)}
        if reg_name not in reg_map:
            raise ValueError(f"Unknown RISC-V register '{reg_name}'")
        return reg_map[reg_name]  # Trả về mã 5-bit 
# ------------------------------------------------------------------------
# NHÓM 1: MATRIX CONFIGURATION INSTRUCTIONS (Table 2)
# ------------------------------------------------------------------------
matrix_config_instructions = {
    "mrelease": {"instr_type": "CONFIG", "func": 0b0000, "uop": 0b00, "ctrl": 0b0, "rs2": 0b00000, "rs1": 0b00000, "fun_c3": 0b000, "nop": 0b00000, "major_opcode": 0b0101011, "operand_type": "none"},
    "msettileki": {"instr_type": "CONFIG","func": 0b0001,"uop": 0b00,"ctrl": 0b0,"fun_c3": 0b000,"nop": 0b00000, "major_opcode": 0b0101011, "operand_type": "immediate"},
    "msettilemi": {"instr_type": "CONFIG","func": 0b0010,"uop": 0b00,"ctrl": 0b0,"fun_c3": 0b000,"nop": 0b00000, "major_opcode": 0b0101011, "operand_type": "immediate"},
    "msettileni": {"instr_type": "CONFIG","func": 0b0011,"uop": 0b00,"ctrl": 0b0,"fun_c3": 0b000,"nop": 0b00000, "major_opcode": 0b0101011, "operand_type": "immediate"},
    "msettilek": {"instr_type": "CONFIG", "func": 0b0001, "uop": 0b00, "ctrl": 0b1, "fun_c3": 0b000, "nop": 0b00000, "major_opcode": 0b0101011, "operand_type": "register"},
    "msettilem": {"instr_type": "CONFIG", "func": 0b0010, "uop": 0b00, "ctrl": 0b1, "fun_c3": 0b000, "nop": 0b00000, "major_opcode": 0b0101011, "operand_type": "register"},
    "msettilen": {"instr_type": "CONFIG", "func": 0b0011, "uop": 0b00, "ctrl": 0b1, "fun_c3": 0b000, "nop": 0b00000, "major_opcode": 0b0101011, "operand_type": "register"},
    }

def assemble_config(tokens, info):
    """
    Lắp ráp lệnh CONFIG dựa trên info và tokens.
    """
    func = info["func"]
    uop = info["uop"]
    ctrl = info["ctrl"]
    fun_c3 = info["fun_c3"]
    nop = info["nop"]
    opcode = info["major_opcode"]
    
    if info["operand_type"] == "none":
        rs2 = info.get("rs2", 0)
        rs1 = info.get("rs1", 0)
    elif info["operand_type"] == "immediate":
        operand = tokens[1]
        imm = int(operand)  # Giả sử uimm10
        rs2 = (imm >> 5) & 0x1F  # 5 bit cao
        rs1 = imm & 0x1F        # 5 bit thấp
    elif info["operand_type"] == "register":
        operand = tokens[1]
        rs1 = encode_register(operand)
        rs2 = 0
    else:
        raise ValueError(f"Loại toán hạng không hợp lệ: {info['operand_type']}")
    
    # Lắp ráp lệnh 32-bit
    instruction = (func << 28) | (uop << 26) | (ctrl << 25) | (rs2 << 20) | (rs1 << 15) | (fun_c3 << 12) | (nop << 7) | opcode
    return instruction

# ------------------------------------------------------------------------
# NHÓM 2: MATRIX MISC INSTRUCTIONS (Table 3)
# ------------------------------------------------------------------------
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
    # Data Broadcast Instructions
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

def assemble_misc(tokens, info):
    mnemonic = tokens[0]
    variant = info.get("variant", "rs2_rs1")
    # Khởi tạo các giá trị mặc định
    ctrl = 0
    ms2_val = info.get("ms2", 0) & 0x7
    s_size = info.get("s_size", 0) & 0x3
    ms1_val = 0
    md_val = 0
    d_size = info.get("d_size", 0) & 0x3
    # Xử lý theo variant
    if variant == "mzero":
        if len(tokens) != 2:
            raise ValueError(f"Lệnh {mnemonic} yêu cầu 1 toán hạng md.")
        md_reg = tokens[1]
        md_val = encode_register(md_reg) & 0x7
        ctrl = info.get("ctrl", 0) & 0x7
    elif variant == "md_ms1":
        if len(tokens) != 3:
            raise ValueError(f"Lệnh {mnemonic} yêu cầu 2 toán hạng md và ms1.")
        md_reg = tokens[1]
        ms1_reg = tokens[2]
        md_val = encode_register(md_reg) & 0x7
        ms1_val = encode_register(ms1_reg) & 0x7
    elif variant == "md_rs2_rs1":
        if mnemonic in {"mdupb.m.x", "mduph.m.x", "mdupw.m.x", "mdupd.m.x"}:
            # Dành cho lệnh đặc biệt: chỉ có 2 toán hạng: md và rs2.
            if len(tokens) != 3:
                raise ValueError(f"Lệnh {mnemonic} yêu cầu 2 toán hạng: md và rs2 (rs1 mặc định là x0).")
            md_reg = tokens[1]
            rs2_reg = tokens[2]
            md_val = encode_register(md_reg) & 0x7
            rs2_val = encode_riscv_register(rs2_reg) & 0x1F
            # Các trường được trích xuất như trước
            ctrl24_23 = (rs2_val >> 3) & 0x3
            ms2_val = rs2_val & 0x7
            # Vì đặc biệt nên rs1 luôn bằng 0
            rs1_val = 0
            s_size = (rs1_val >> 3) & 0x3
            ms1_val = rs1_val & 0x7
            ctrl25 = info.get("ctrl25", 0) & 0x1
            ctrl = ctrl25 << 2
        else:
            if len(tokens) != 4:
                raise ValueError(f"Lệnh {mnemonic} yêu cầu 3 toán hạng md, rs2, rs1.")
            md_reg = tokens[1]
            rs2_reg = tokens[2]
            rs1_reg = tokens[3]
            md_val = encode_register(md_reg) & 0x7
            rs2_val = encode_riscv_register(rs2_reg) & 0x1F  # Lấy giá trị rs2 (5 bit)
            rs1_val = encode_riscv_register(rs1_reg) & 0x1F  # Lấy giá trị rs1 (5 bit)        
            # Trích xuất từ rs2_val
            #ctrl24_23 = (rs2_val >> 3) & 0x3  # Bit 4-3 của rs2 → ctrl24_23
            ms2_val = rs2_val & 0x7           # Bit 2-0 của rs2 → ms2
            # Trích xuất từ rs1_val
            s_size = (rs1_val >> 3) & 0x3     # Bit 4-3 của rs1 → s_size
            ms1_val = rs1_val & 0x7           # Bit 2-0 của rs1 → ms1
            # Lấy ctrl25 từ info và gán vào ctrl
            ctrl25 = info.get("ctrl25", 0) & 0x1
            ctrl = ctrl25 << 2  # Chỉ sử dụng ctrl25, dịch trái 2 bit để đặt vào bit 25

    elif variant == "rd_ms2_rs1":
        if len(tokens) != 4:
            raise ValueError(f"Lệnh {mnemonic} yêu cầu 3 toán hạng rd, ms2, rs1.")
        rd_reg = tokens[1]
        ms2_reg = tokens[2]
        rs1_reg = tokens[3]
        rd_val = encode_riscv_register(rd_reg) & 0x1F
        ms2_val = encode_register(ms2_reg) & 0x7
        rs1_val = encode_riscv_register(rs1_reg) & 0x1F
        d_size = (rd_val >> 3) & 0x3
        md_val = rd_val & 0x7
        s_size = (rs1_val >> 3) & 0x3
        ms1_val = rs1_val & 0x7
        ctrl = info.get("ctrl", 0) & 0x7
    elif variant == "md_ms1_imm3":
        if len(tokens) != 3:
            raise ValueError(f"Lệnh {mnemonic} yêu cầu 2 toán hạng md và ms1[imm3].")
        md_reg = tokens[1]
        ms1_imm = tokens[2]
        match = re.match(r'(\w+)\[(\d+)\]', ms1_imm)
        if not match:
            raise ValueError(f"Toán hạng không hợp lệ: {ms1_imm}")
        ms1_reg = match.group(1)
        imm3 = int(match.group(2)) & 0x7
        md_val = encode_register(md_reg) & 0x7
        ms1_val = encode_register(ms1_reg) & 0x7
        ctrl = imm3
    elif variant == "md_ms2_ms1":
        if len(tokens) != 4:
            raise ValueError(f"Lệnh {mnemonic} yêu cầu 3 toán hạng md, ms2, ms1.")
        md_reg = tokens[1]
        ms2_reg = tokens[2]
        ms1_reg = tokens[3]
        md_val = encode_register(md_reg) & 0x7
        ms2_val = encode_register(ms2_reg) & 0x7
        ms1_val = encode_register(ms1_reg) & 0x7
        # Kết hợp ctrl25 (1 bit) và ctrl24_23 (2 bit) thành một trường 3-bit cho trường ctrl
        ctrl = ((info.get("ctrl25", 0) & 0x1) << 2) | (info.get("ctrl24_23", 0) & 0x3)
    elif variant == "md_ms1_imm3_direct":
        if len(tokens) != 4:
            raise ValueError(f"Lệnh {mnemonic} yêu cầu 3 toán hạng md, ms1, imm3.")
        md_reg = tokens[1]
        ms1_reg = tokens[2]
        # Lấy immediate và đảm bảo nó là 3-bit (uimm3)
        uimm3 = int(tokens[3]) & 0x7  
        md_val = encode_register(md_reg) & 0x7
        ms1_val = encode_register(ms1_reg) & 0x7
        # Đọc trường d_size và s_size từ info, s_size đã được quy định sẵn
        d_size = info.get("d_size", 0) & 0x3
        s_size = info.get("s_size", 0) & 0x3
        # Với variant này, ms2 luôn mặc định là 0
        ms2_val = 0
        # Sử dụng uimm3 làm giá trị cho trường immediate (vị trí bit [25..23])
        ctrl = uimm3
    else:
        raise ValueError(f"Variant không được hỗ trợ: {variant}")

    # Lấy các trường từ info
    func = info.get("func", 0) & 0xF
    uop = info.get("uop", 0) & 0x3
    f3 = info.get("func3", 0) & 0x7
    opc = info.get("opcode", 0) & 0x7F

    # Ghép các bit vào mã lệnh
    code = 0
    code |= (opc << 0)      # [6..0]
    code |= (md_val << 7)   # [9..7]
    code |= (d_size << 10)  # [11..10]
    code |= (f3 << 12)      # [14..12]
    code |= (ms1_val << 15) # [17..15]
    code |= (s_size << 18)  # [19..18]
    code |= (ms2_val << 20) # [22..20]
    code |= (ctrl << 23)    # [25..23], chỉ có bit 25 được dùng từ ctrl25
    code |= (uop << 26)     # [27..26]
    code |= (func << 28)    # [31..28]

    return code
# ------------------------------------------------------------------------
# NHÓM 3: MATRIX MULTIPLICATION INSTRUCTIONS (Table 4) 
# ------------------------------------------------------------------------
matrix_multiply_instructions = {
    "mfmacc.h.e5": {"func": 0b0000, "uop": 0b01, "size_sup": 0b000, "s_size": 0b00, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.h.e4": {"func": 0b0000, "uop": 0b01, "size_sup": 0b001, "s_size": 0b00, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.s.e4": {"func": 0b0000, "uop": 0b01, "size_sup": 0b001, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.bf16.e5": {"func": 0b0000, "uop": 0b01, "size_sup": 0b100, "s_size": 0b00, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.bf16.e4": {"func": 0b0000, "uop": 0b01, "size_sup": 0b101, "s_size": 0b00, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.s.e5": {"func": 0b0000, "uop": 0b01, "size_sup": 0b000, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011,"instr_type": "MULTIPLY"},
    "mfmacc.h": {"func": 0b0000, "uop": 0b01, "size_sup": 0b000, "s_size": 0b01, "func3": 0b000, "d_size": 0b01, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.s.h": {"func": 0b0000, "uop": 0b01, "size_sup": 0b000, "s_size": 0b01, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.s.bf16": {"func": 0b0000, "uop": 0b01, "size_sup": 0b001, "s_size": 0b01, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.s.tf32": {"func": 0b0000, "uop": 0b01, "size_sup": 0b001, "s_size": 0b10, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.s": {"func": 0b0000,"uop": 0b01, "size_sup": 0b000, "s_size": 0b10, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.d.s": {"func": 0b0000, "uop": 0b01, "size_sup": 0b000, "s_size": 0b10, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mfmacc.d": {"func": 0b0000, "uop": 0b01, "size_sup": 0b000, "s_size": 0b11, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mmacc.w.b": {"func": 0b0001, "uop": 0b01, "size_sup": 0b011, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mmaccu.w.b": {"func": 0b0001,"uop": 0b01,"size_sup": 0b000, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mmaccus.w.b": {"func": 0b0001, "uop": 0b01, "size_sup": 0b001, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mmaccsu.w.b": {"func": 0b0001, "uop": 0b01, "size_sup": 0b010, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "pmmacc.w.b": {"func": 0b0001, "uop": 0b01, "size_sup": 0b111, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "pmmaccu.w.b": {"func": 0b0001, "uop": 0b01, "size_sup": 0b100, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011,"instr_type": "MULTIPLY"},
    "pmmaaccus.w.b": {"func": 0b0001, "uop": 0b01, "size_sup": 0b101, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "pmmaccsu.w.b": {"func": 0b0001, "uop": 0b01, "size_sup": 0b110, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mmacc.d.h": {"func": 0b0001,"uop": 0b01,"size_sup": 0b011, "s_size": 0b01, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mmaccu.d.h": {"func": 0b0001, "uop": 0b01, "size_sup": 0b000, "s_size": 0b01, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mmaccus.d.h": {"func": 0b0001, "uop": 0b01, "size_sup": 0b001, "s_size": 0b01, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mmaccsu.d.h": {"func": 0b0001, "uop": 0b01, "size_sup": 0b010, "s_size": 0b01, "func3": 0b000, "d_size": 0b11, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
    "mmacc.w.bp": {"func": 0b0010, "uop": 0b01, "size_sup": 0b011, "s_size": 0b00, "func3": 0b000, "d_size": 0b10, "major_opcode": 0b0101011, "instr_type": "MULTIPLY"},
}

def assemble_multiply(tokens, info):
    if len(tokens) < 4:
        raise ValueError(f"Lệnh multiply thiếu toán hạng: '{tokens}'")
    
    md_reg  = tokens[1]
    ms2_reg = tokens[2]
    ms1_reg = tokens[3]
    
    # Mã hóa thanh ghi (3 bit mỗi thanh ghi)
    md_val  = encode_register(md_reg)  & 0x7   # 3 bits [9..7]
    ms1_val = encode_register(ms1_reg) & 0x7   # 3 bits [17..15]
    ms2_val = encode_register(ms2_reg) & 0x7   # 3 bits [22..20]
    
    # Lấy giá trị từ info, đảm bảo đúng số bit
    func         = info.get("func", 0)         & 0xF   # 4 bits [31..28]
    uop          = info.get("uop", 0)          & 0x3   # 2 bits [27..26]
    size_sup     = info.get("size_sup", 0)     & 0x7   # 3 bits [25..23]
    s_size       = info.get("s_size", 0)       & 0x3   # 2 bits [19..18]
    func3        = info.get("func3", 0)        & 0x7   # 3 bits [14..12]
    d_size       = info.get("d_size", 0)       & 0x3   # 2 bits [11..10]
    major_opcode = info.get("major_opcode", 0) & 0x7F  # 7 bits [6..0]
    
    # Ghép bit theo định dạng từ bit 0 đến bit 31
    code = 0
    code |= (major_opcode << 0)  # [6..0]
    code |= (md_val << 7)        # [9..7]
    code |= (d_size << 10)       # [11..10]
    code |= (func3 << 12)        # [14..12]
    code |= (ms1_val << 15)      # [17..15]
    code |= (s_size << 18)       # [19..18]
    code |= (ms2_val << 20)      # [22..20]
    code |= (size_sup << 23)     # [25..23]
    code |= (uop << 26)          # [27..26]
    code |= (func << 28)         # [31..28]
    
    return code

# ------------------------------------------------------------------------
# NHÓM 4: MATRIX LOAD/STORE INSTRUCTIONS (Table 5)
# ------------------------------------------------------------------------
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

def assemble_loadstore(tokens, info):
    mnemonic = tokens[0]
    
    # Kiểm tra số lượng token để xác định loại lệnh
    if len(tokens) == 4:
        # Lệnh có rs2: ví dụ mlme8 md, (rs1), rs2
        if mnemonic.startswith("ml"):  # Load
            md_reg = tokens[1]
            rs1_reg = tokens[2].strip("()")
            rs2_reg = tokens[3]
        elif mnemonic.startswith("ms"):  # Store
            ms3_reg = tokens[1]
            rs1_reg = tokens[2].strip("()")
            rs2_reg = tokens[3]
            md_reg = ms3_reg  # md/ms3 dùng chung
        else:
            raise ValueError(f"Không nhận dạng được lệnh: '{mnemonic}'")
        rs2_val = encode_riscv_register(rs2_reg) & 0x1F  # 5-bit
    elif len(tokens) == 3:
        # Lệnh không có rs2: ví dụ mlme8 md, (rs1)
        if mnemonic.startswith("ml"):  # Load
            md_reg = tokens[1]
            rs1_reg = tokens[2].strip("()")
        elif mnemonic.startswith("ms"):  # Store
            ms3_reg = tokens[1]
            rs1_reg = tokens[2].strip("()")
            md_reg = ms3_reg  # md/ms3 dùng chung
        else:
            raise ValueError(f"Không nhận dạng được lệnh: '{mnemonic}'")
        rs2_val = 0  # Đặt rs2 = 00000
    else:
        raise ValueError(f"Lệnh load/store không hợp lệ: '{tokens}'")

    # Mã hóa thanh ghi
    md_val = encode_register(md_reg) & 0x7          # 3-bit
    rs1_val = encode_riscv_register(rs1_reg) & 0x1F  # 5-bit

    # Tạo mã lệnh (giả định các trường khác từ info)
    opc = info.get("major_opcode", 0) & 0x7F
    code = (opc << 0) | (md_val << 7) | (rs1_val << 15) | (rs2_val << 20)
    return code

# ------------------------------------------------------------------------
# NHÓM 5: MATRIX ELEMENT-WISE INSTRUCTIONS (Table 6)
# ------------------------------------------------------------------------
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
# 3 ví dụ tiêu biểu, các lệnh khác đều dựa trên 3 format này

def assemble_elementwise(tokens, info):
    """
    Hàm sinh mã lệnh cho các lệnh Element-Wise (EW).
    Hỗ trợ 3 'variant' chính:
      - "md_ms2_ms1":           <mnemonic> md, ms2, ms1
      - "md_ms2_ms1_imm3_direct": <mnemonic> md, ms2, ms1[imm3]
      - "md_ms1":               <mnemonic> md, ms1
    """

    # Lấy variant từ info (trong dictionary matrix_ew_instructions)
    variant = info.get("variant", "")
    mnemonic = tokens[0]

    # Lấy các trường mặc định (nếu có) từ info
    func   = info.get("func", 0)   & 0xF
    uop    = info.get("uop", 0)    & 0x3
    ctrl   = info.get("ctrl", 0)   & 0x7   # Trường ctrl [25..23], mặc định
    ms2_val= info.get("ms2", 0)    & 0x7   # Nếu lệnh nào đó cần ms2=0 cứng
    s_size = info.get("s_size", 0) & 0x3
    func3  = info.get("func3", 0)  & 0x7
    d_size = info.get("d_size", 0) & 0x3
    opc    = info.get("major_opcode", 0) & 0x7F

    # Khởi tạo giá trị mặc định cho md, ms1
    md_val  = 0
    ms1_val = 0

    # Tùy theo variant để parse số toán hạng và gán giá trị
    if variant == "md_ms2_ms1":
        # Ví dụ: madd.w.mm md, ms2, ms1
        # => tokens[1] = md, tokens[2] = ms2, tokens[3] = ms1
        if len(tokens) != 4:
            raise ValueError(f"Lệnh {mnemonic} yêu cầu 3 toán hạng: md, ms2, ms1.")
        md_reg  = tokens[1]
        ms2_reg = tokens[2]
        ms1_reg = tokens[3]

        md_val  = encode_register(md_reg)  & 0x7
        ms2_val = encode_register(ms2_reg) & 0x7
        ms1_val = encode_register(ms1_reg) & 0x7

    elif variant == "md_ms2_ms1_imm3_direct":
        # Ví dụ: madd.w.mv.i md, ms2, ms1[imm3]
        # => tokens[1] = md, tokens[2] = ms2, tokens[3] = "ms1[imm3]"
        if len(tokens) != 4:
            raise ValueError(f"Lệnh {mnemonic} yêu cầu 3 toán hạng: md, ms2, ms1[imm3].")
        md_reg  = tokens[1]
        ms2_reg = tokens[2]
        ms1_str = tokens[3]  # dạng "tr0[5]" hoặc "acc1[3]" v.v.

        md_val  = encode_register(md_reg)  & 0x7
        ms2_val = encode_register(ms2_reg) & 0x7

        # Parse ms1[imm3]
        match = re.match(r'(tr[0-3]|acc[0-3])\[(\d+)\]', ms1_str)
        if not match:
            raise ValueError(f"Toán hạng ms1[imm3] không hợp lệ: {ms1_str}")
        ms1_name = match.group(1)
        imm_val  = int(match.group(2))
        if not (0 <= imm_val <= 7):
            raise ValueError(f"imm3 phải trong khoảng 0..7, nhận được {imm_val}")

        ms1_val = encode_register(ms1_name) & 0x7
        # ctrl sẽ gán bằng imm3
        ctrl    = imm_val & 0x7

    elif variant == "md_ms1":
        # Ví dụ: mfcvth.e4.h md, ms1
        # => tokens[1] = md, tokens[2] = ms1
        if len(tokens) != 3:
            raise ValueError(f"Lệnh {mnemonic} yêu cầu 2 toán hạng: md, ms1.")
        md_reg  = tokens[1]
        ms1_reg = tokens[2]

        md_val  = encode_register(md_reg)  & 0x7
        ms1_val = encode_register(ms1_reg) & 0x7
        # ms2_val và ctrl lấy mặc định từ info (hoặc 0) nếu cần

    else:
        raise ValueError(f"Variant '{variant}' không được hỗ trợ trong assemble_elementwise.")

    # Bây giờ ghép bit thành mã lệnh theo layout:
    #
    #   [31..28]: func
    #   [27..26]: uop
    #   [25..23]: ctrl
    #   [22..20]: ms2
    #   [19..18]: s_size
    #   [17..15]: ms1
    #   [14..12]: func3
    #   [11..10]: d_size
    #   [9..7]  : md
    #   [6..0]  : opcode (major_opcode)

    code = 0
    code |= (opc    <<  0)  # [6..0]
    code |= (md_val <<  7)  # [9..7]
    code |= (d_size << 10)  # [11..10]
    code |= (func3  << 12)  # [14..12]
    code |= (ms1_val <<15)  # [17..15]
    code |= (s_size << 18)  # [19..18]
    code |= (ms2_val<< 20)  # [22..20]
    code |= (ctrl   << 23)  # [25..23]
    code |= (uop    << 26)  # [27..26]
    code |= (func   << 28)  # [31..28]

    return code

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

# ------------------------------------------------------------------------
# HÀM TỔNG: assemble_line
# ------------------------------------------------------------------------
def assemble_line(line):
    """
    Xác định lệnh thuộc nhóm nào, gọi hàm assemble_xxx tương ứng.
    Cải tiến để nhận diện đúng mnemonic như 'mfmacc.h.e5' và tách toán hạng.
    """
    # Loại bỏ comment và khoảng trắng thừa
    line = line.split('#')[0].strip()
    if not line:
        return None  # Bỏ qua dòng trống hoặc comment

    # Sử dụng regex để tách mnemonic và phần còn lại
    match = re.match(r'^\s*([a-zA-Z0-9.]+)\s*(.*)', line)
    if not match:
        raise ValueError(f"Không thể phân tích dòng lệnh: '{line}'")

    mnemonic = match.group(1).lower()
    remainder = match.group(2).strip()
    # Tách các toán hạng theo cả dấu phẩy và khoảng trắng
    operands = re.split(r'[,\s]+', remainder) if remainder else []
    tokens = [mnemonic] + operands

    if len(tokens) < 1:
        return None

    if mnemonic not in ALL_INSTRUCTIONS:
        raise ValueError(f"Lệnh '{mnemonic}' không tồn tại trong ALL_INSTRUCTIONS.")

    info = ALL_INSTRUCTIONS[mnemonic]
    instr_type = info.get("instr_type", "UNKNOWN")

    # Gọi hàm assemble tương ứng với loại lệnh
    if instr_type == "MULTIPLY":
        if len(tokens) != 4:
            raise ValueError(f"Lệnh multiply yêu cầu 3 toán hạng: '{mnemonic}'")
        return assemble_multiply(tokens, info)
    elif instr_type == "LOADSTORE":
        if len(tokens) != 4:
            raise ValueError(f"Lệnh load/store yêu cầu 3 toán hạng: '{mnemonic}'")
        return assemble_loadstore(tokens, info)
    elif instr_type == "CONFIG":
        operand_type = info.get("operand_type", "register")
        if operand_type == "none":
            if len(tokens) != 1:
                raise ValueError(f"Lệnh {mnemonic} không yêu cầu toán hạng")
        elif operand_type in ["immediate", "register"]:
            if len(tokens) != 2:
                raise ValueError(f"Lệnh {mnemonic} yêu cầu 1 toán hạng")
        else:
            raise ValueError(f"Loại toán hạng không hợp lệ cho lệnh {mnemonic}")
        return assemble_config(tokens, info)
    elif instr_type == "MISC":
        return assemble_misc(tokens, info)
    elif instr_type == "EW":
        return assemble_elementwise(tokens, info)
    else:
        raise ValueError(f"Chưa hỗ trợ instr_type = '{instr_type}'.")


# ------------------------------------------------------------------------
# HÀM XỬ LÝ NHIỀU DÒNG
# ------------------------------------------------------------------------
def assemble_lines(lines):
    machine_codes = []
    for line in lines:
        # Bỏ qua dòng bắt đầu bằng '#' ngay tại đây
        # (hoặc bạn có thể chỉ cần dựa vào line.split('#')[0].strip() bên trên)
        if not line or line.strip().startswith('#'):
            continue
        code = assemble_line(line)
        if code is not None:
            machine_codes.append(code)
    return machine_codes


# ------------------------------------------------------------------------
# HÀM MAIN: ĐỌC FILE INPUT, DỊCH, GHI FILE OUTPUT
# ------------------------------------------------------------------------
def main():
    base_dir = Path(__file__).resolve().parent
    input_path  = base_dir / "assembly.txt"
    output_path = base_dir / "machine_code.txt"

    # Đọc các dòng lệnh từ file input
    with open(input_path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    # Dịch assembly -> machine code
    codes = assemble_lines(lines)

    # Ghi mã máy ra file output (mỗi dòng 1 giá trị nhị phân 32 bit)
    with open(output_path, "w", encoding="utf-8") as f:
        for c in codes:
            f.write(f"{c:032b}\n")

if __name__ == "__main__":
    main()
