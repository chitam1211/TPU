import sys
import re
from pathlib import Path

# --- SỬA LỖI IMPORT ---
# Thêm thư mục gốc (TPU) vào đường dẫn tìm kiếm của Python
# để "from iss.definitions" hoạt động
sys.path.append(str(Path(__file__).resolve().parent.parent))
# ---------------------

# THAY ĐỔI: Import các định nghĩa từ file chung
from iss.definitions import ALL_INSTRUCTIONS, GPR_MAP, MATRIX_REG_MAP

sys.stdout.reconfigure(encoding='utf-8')

class Assembler:
    def __init__(self):
        """Khởi tạo Assembler với các bảng tra cứu."""
        self.instr_map = ALL_INSTRUCTIONS
        self.gpr_map = GPR_MAP
        self.matrix_reg_map = MATRIX_REG_MAP

    def _encode_matrix_register(self, reg_name):
        """
        Trả về mã 3-bit ứng với tên thanh ghi (tr0..tr3, acc0..acc3).
        """
        reg_name = reg_name.strip().lower()
        if reg_name not in self.matrix_reg_map:
            raise ValueError(f"Unknown matrix register '{reg_name}'")
        return self.matrix_reg_map[reg_name]

    def _encode_gpr(self, reg_name):
        """
        Trả về mã 5-bit ứng với tên thanh ghi RISC-V (x0..x31 hoặc ABI).
        """
        reg_name = reg_name.strip().lower()
        if reg_name not in self.gpr_map:
            raise ValueError(f"Unknown RISC-V GPR '{reg_name}'")
        return self.gpr_map[reg_name]

    def _assemble_config(self, tokens, info):
        """
        Lắp ráp lệnh CONFIG. (Logic này đã đúng)
        """
        func = info["func"]
        uop = info["uop"]
        ctrl = info["ctrl"]
        fun_c3 = info["func3"]
        nop = info["nop"]
        opcode = info["major_opcode"]
        
        rs1 = 0
        rs2 = 0

        if info["operand_type"] == "immediate":
            operand = tokens[1]
            imm = int(operand)
            if not (0 <= imm < 1024):
                raise ValueError(f"Immediate '{imm}' out of range for 10 bits")
            rs2 = (imm >> 5) & 0x1F  # 5 bit cao [24:20]
            rs1 = imm & 0x1F        # 5 bit thấp [19:15]
        elif info["operand_type"] == "register":
            operand = tokens[1]
            rs1 = self._encode_gpr(operand)
        
        instruction = (func << 28) | (uop << 26) | (ctrl << 25) | (rs2 << 20) | (rs1 << 15) | (fun_c3 << 12) | (nop << 7) | opcode
        return instruction

    def _assemble_misc(self, tokens, info):
        """
        HOÀN THIỆN: Lắp ráp lệnh MISC (Logic được di chuyển từ file cũ).
        """
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
            if len(tokens) != 2: raise ValueError(f"Lệnh {mnemonic} yêu cầu 1 toán hạng md.")
            md_val = self._encode_matrix_register(tokens[1]) & 0x7
            ctrl = info.get("ctrl", 0) & 0x7
        
        elif variant == "md_ms1":
            if len(tokens) != 3: raise ValueError(f"Lệnh {mnemonic} yêu cầu 2 toán hạng md và ms1.")
            md_val = self._encode_matrix_register(tokens[1]) & 0x7
            ms1_val = self._encode_matrix_register(tokens[2]) & 0x7
        
        elif variant == "md_rs2_rs1":
            if mnemonic in {"mdupb.m.x", "mduph.m.x", "mdupw.m.x", "mdupd.m.x"}:
                if len(tokens) != 3: raise ValueError(f"Lệnh {mnemonic} yêu cầu 2 toán hạng: md và rs2.")
                md_val = self._encode_matrix_register(tokens[1]) & 0x7
                rs2_val = self._encode_gpr(tokens[2]) & 0x1F
                rs1_val = 0 # rs1 mặc định là x0
            else:
                if len(tokens) != 4: raise ValueError(f"Lệnh {mnemonic} yêu cầu 3 toán hạng md, rs2, rs1.")
                md_val = self._encode_matrix_register(tokens[1]) & 0x7
                rs2_val = self._encode_gpr(tokens[2]) & 0x1F
                rs1_val = self._encode_gpr(tokens[3]) & 0x1F
            
            # Trích xuất các trường từ GPRs
            ms2_val = rs2_val & 0x7
            s_size = (rs1_val >> 3) & 0x3
            ms1_val = rs1_val & 0x7
            ctrl25 = info.get("ctrl25", 0) & 0x1
            ctrl24_23 = (rs2_val >> 3) & 0x3 # Bit 4-3 của rs2 (chỉ dùng cho mdupb/...)
            if mnemonic.startswith("mdup"):
                ctrl = (ctrl25 << 2) # ctrl24_23 = 00
            else: # mmovb...
                ctrl = (ctrl25 << 2) | ctrl24_23 # Cần kiểm tra lại tài liệu

        elif variant == "rd_ms2_rs1":
            if len(tokens) != 4: raise ValueError(f"Lệnh {mnemonic} yêu cầu 3 toán hạng rd, ms2, rs1.")
            rd_val = self._encode_gpr(tokens[1]) & 0x1F
            ms2_val = self._encode_matrix_register(tokens[2]) & 0x7
            rs1_val = self._encode_gpr(tokens[3]) & 0x1F
            
            # Trong rd_ms2_rs1, rd_val (5 bit) được dùng cho d_size (2 bit) và md (3 bit)
            d_size = (rd_val >> 3) & 0x3
            md_val = rd_val & 0x7
            s_size = (rs1_val >> 3) & 0x3
            ms1_val = rs1_val & 0x7
            ctrl = ((info.get("ctrl25", 0) & 0x1) << 2) | (info.get("ctrl24_23", 0) & 0x3)

        elif variant == "md_ms1_imm3":
            if len(tokens) != 3: raise ValueError(f"Lệnh {mnemonic} yêu cầu 2 toán hạng md và ms1[imm3].")
            md_val = self._encode_matrix_register(tokens[1]) & 0x7
            match = re.match(r'(\w+)\[(\d+)\]', tokens[2])
            if not match: raise ValueError(f"Toán hạng không hợp lệ: {tokens[2]}")
            ms1_val = self._encode_matrix_register(match.group(1)) & 0x7
            ctrl = int(match.group(2)) & 0x7 # imm3
        
        elif variant == "md_ms2_ms1":
            if len(tokens) != 4: raise ValueError(f"Lệnh {mnemonic} yêu cầu 3 toán hạng md, ms2, ms1.")
            md_val = self._encode_matrix_register(tokens[1]) & 0x7
            ms2_val = self._encode_matrix_register(tokens[2]) & 0x7
            ms1_val = self._encode_matrix_register(tokens[3]) & 0x7
            ctrl = ((info.get("ctrl25", 0) & 0x1) << 2) | (info.get("ctrl24_23", 0) & 0x3)

        elif variant == "md_ms1_imm3_direct":
            if len(tokens) != 4: raise ValueError(f"Lệnh {mnemonic} yêu cầu 3 toán hạng md, ms1, imm3.")
            md_val = self._encode_matrix_register(tokens[1]) & 0x7
            ms1_val = self._encode_matrix_register(tokens[2]) & 0x7
            ctrl = int(tokens[3]) & 0x7 # uimm3
            d_size = info.get("d_size", 0) & 0x3
            s_size = info.get("s_size", 0) & 0x3
            ms2_val = 0 # Mặc định
        
        else:
            raise ValueError(f"Variant không được hỗ trợ: {variant}")

        # Lấy các trường từ info
        func = info.get("func", 0) & 0xF
        uop = info.get("uop", 0) & 0x3
        f3 = info.get("func3", 0) & 0x7
        opc = info.get("opcode", 0) & 0x7F

        # Ghép các bit vào mã lệnh
        code = (opc << 0) | (md_val << 7) | (d_size << 10) | (f3 << 12) | \
               (ms1_val << 15) | (s_size << 18) | (ms2_val << 20) | \
               (ctrl << 23) | (uop << 26) | (func << 28)
        return code

    def _assemble_multiply(self, tokens, info):
        """
        Lắp ráp lệnh MULTIPLY. (Logic này đã đúng)
        """
        md_val  = self._encode_matrix_register(tokens[1]) & 0x7
        ms1_val = self._encode_matrix_register(tokens[2]) & 0x7
        ms2_val = self._encode_matrix_register(tokens[3]) & 0x7
        
        func         = info.get("func", 0)         & 0xF
        uop          = info.get("uop", 0)          & 0x3
        size_sup     = info.get("size_sup", 0)     & 0x7
        s_size       = info.get("s_size", 0)       & 0x3
        func3        = info.get("func3", 0)        & 0x7
        d_size       = info.get("d_size", 0)       & 0x3
        major_opcode = info.get("major_opcode", 0) & 0x7F
        
        code = (major_opcode << 0) | (md_val << 7) | (d_size << 10) | (func3 << 12) | \
               (ms1_val << 15) | (s_size << 18) | (ms2_val << 20) | \
               (size_sup << 23) | (uop << 26) | (func << 28)
        return code

    def _assemble_loadstore(self, tokens, info):
        """
        HOÀN THIỆN: Lắp ráp lệnh LOAD/STORE (Logic mới).
        Định dạng: mlae8 tr0, (x5), x6   hoặc   msae8 tr0, (x5), x6
                   mlme32 tr0, (x5)
        """
        # --- Lấy các trường bit cố định từ info ---
        func4 = info.get("func", 0) & 0xF
        uop = info.get("uop", 0) & 0x3
        ls = info.get("ls", 0) & 0x1
        func3 = info.get("func3", 0) & 0x7
        d_size = info.get("d_size", 0) & 0x3
        opcode = info.get("major_opcode", 0) & 0x7F
        
        rs1 = 0
        rs2 = 0
        md_ms3 = 0 # Tên thanh ghi ma trận (md cho load, ms3 cho store)

        # --- Phân tích toán hạng ---
        # Lệnh load/store (không phải whole) luôn có 3 hoặc 4 token
        # Ví dụ: mlae8 tr0 (x5) x6  hoặc  mlme32 tr0 (x5)
        if len(tokens) < 3 or len(tokens) > 4:
            raise ValueError(f"Lệnh {tokens[0]} có sai số lượng toán hạng.")
            
        # Toán hạng 1: md (load) hoặc ms3 (store)
        md_ms3 = self._encode_matrix_register(tokens[1])
        
        # Toán hạng 2: (rs1)
        match = re.match(r'\((x\d+|[a-z][a-z0-9]+)\)', tokens[2].lower())
        if not match:
            raise ValueError(f"Toán hạng thứ 2 của Load/Store phải là (rs1), ví dụ: (x5) hoặc (sp). Nhận được: '{tokens[2]}'")
        rs1 = self._encode_gpr(match.group(1))

        # Toán hạng 3: rs2 (stride), nếu có
        if len(tokens) == 4:
            rs2 = self._encode_gpr(tokens[3])
        else:
            # Lệnh mlme/msme (whole matrix) chỉ có 2 toán hạng
            # (rs2 mặc định là 0)
            if not tokens[0].startswith("mlme") and not tokens[0].startswith("msme"):
                 raise ValueError(f"Lệnh {tokens[0]} yêu cầu 3 toán hạng (md/ms3, (rs1), rs2).")
        
        # --- Ghép bit theo định dạng (Mục 4.1.2) ---
        # 31..28 | 27..26 | 25 | 24..20 | 19..15 | 14..12 | 11..10 | 9..7   | 6..0
        # func4  | uop    | ls | rs2    | rs1    | func3  | d_size | md/ms3 | opcode
        
        instruction = (func4 << 28) | (uop << 26) | (ls << 25) | (rs2 << 20) | \
                      (rs1 << 15) | (func3 << 12) | (d_size << 10) | (md_ms3 << 7) | opcode
        
        return instruction


    def _assemble_elementwise(self, tokens, info):
        """
        HOÀN THIỆN: Lắp ráp lệnh ELEMENT-WISE.
        """
        mnemonic = tokens[0]
        variant = info.get("variant", "md_ms2_ms1") # Lấy variant từ info

        # Khởi tạo
        ctrl = info.get("ctrl", 0) & 0x7
        ms2_val = info.get("ms2", 0) & 0x7
        s_size = info.get("s_size", 0) & 0x3
        ms1_val = 0
        md_val = 0
        d_size = info.get("d_size", 0) & 0x3

        # Phân tích toán hạng dựa trên variant
        if variant == "md_ms1":
            if len(tokens) != 3: raise ValueError(f"Lệnh {mnemonic} yêu cầu 2 toán hạng: md, ms1.")
            md_val = self._encode_matrix_register(tokens[1])
            ms1_val = self._encode_matrix_register(tokens[2])
            ms2_val = info.get("ms2", 0) & 0x7 # ms2_val được cố định trong info

        elif variant == "md_ms2_ms1":
            if len(tokens) != 4: raise ValueError(f"Lệnh {mnemonic} yêu cầu 3 toán hạng: md, ms2, ms1.")
            md_val = self._encode_matrix_register(tokens[1])
            ms2_val = self._encode_matrix_register(tokens[2])
            ms1_val = self._encode_matrix_register(tokens[3])

        elif variant == "md_ms2_ms1_imm3_direct":
            if len(tokens) != 4: raise ValueError(f"Lệnh {mnemonic} yêu cầu 3 toán hạng: md, ms2, imm3.")
            md_val = self._encode_matrix_register(tokens[1])
            ms2_val = self._encode_matrix_register(tokens[2])
            ctrl = int(tokens[3]) & 0x7 # imm3
            ms1_val = 0 # ms1 không được dùng trong định dạng này

        else:
            raise ValueError(f"Variant '{variant}' không được hỗ trợ cho lệnh Element-wise.")

        # Lấy các trường bit cố định từ info
        func = info.get("func", 0) & 0xF
        uop = info.get("uop", 0) & 0x3
        func3 = info.get("func3", 0) & 0x7
        opcode = info.get("major_opcode", 0) & 0x7F

        # Ghép bit
        code = (func << 28) | (uop << 26) | (ctrl << 23) | (ms2_val << 20) | \
               (s_size << 18) | (ms1_val << 15) | (func3 << 12) | (d_size << 10) | \
               (md_val << 7) | opcode
        return code

    def _assemble_line(self, line):
        """
        Xác định lệnh thuộc nhóm nào, gọi hàm assemble_xxx tương ứng.
        (Đã di chuyển từ file cũ và thêm 'self')
        """
        line = line.split('#')[0].strip()
        if not line:
            return None

        match = re.match(r'^\s*([a-zA-Z0-9.]+)\s*(.*)', line)
        if not match:
            raise ValueError(f"Không thể phân tích dòng lệnh: '{line}'")

        mnemonic = match.group(1).lower()
        remainder = match.group(2).strip()
        
        # Xử lý toán hạng (xử lý dấu phẩy, ngoặc đơn cho load/store)
        if 'loadstore' in ALL_INSTRUCTIONS.get(mnemonic, {}).get('instr_type', '').lower():
             # Giữ nguyên ngoặc đơn cho (rs1)
             operands = re.split(r'[,\s]+(?![^()]*\))', remainder)
        else:
             # Xóa dấu phẩy
             operands = re.split(r'[,\s]+', remainder)
        
        tokens = [mnemonic] + [op for op in operands if op]

        if mnemonic not in self.instr_map:
            raise ValueError(f"Lệnh '{mnemonic}' không tồn tại trong INSTRUCTION_MAP.")

        info = self.instr_map[mnemonic]
        instr_type = info.get("instr_type", "UNKNOWN")

        # THAY ĐỔI: Gọi các hàm helper của class
        if instr_type == "MULTIPLY":
            return self._assemble_multiply(tokens, info)
        elif instr_type == "LOADSTORE":
            return self._assemble_loadstore(tokens, info)
        elif instr_type == "CONFIG":
            return self._assemble_config(tokens, info)
        elif instr_type == "MISC":
            return self._assemble_misc(tokens, info)
        elif instr_type == "EW":
            return self._assemble_elementwise(tokens, info)
        else:
            raise ValueError(f"Chưa hỗ trợ instr_type = '{instr_type}'.")

    def assemble_file(self, input_path, output_path):
        """
        Hàm public: Dịch file assembly thành file mã máy.
        """
        try:
            with open(input_path, "r", encoding="utf-8") as f:
                lines = f.readlines()
        except FileNotFoundError:
            print(f"Lỗi: Không tìm thấy file input '{input_path}'")
            return False

        machine_codes = []
        print(f"Assembling '{input_path}' -> '{output_path}'")
        for line_num, line in enumerate(lines, 1):
            line_stripped = line.split('#')[0].strip()
            if not line_stripped:
                continue
            try:
                code = self._assemble_line(line)
                if code is not None:
                    machine_codes.append(f"{code:032b}")
                    print(f"  {line_stripped:<30} -> {code:032b}")
            except ValueError as e:
                print(f"Lỗi ở dòng {line_num}: {e}\n  > {line_stripped}")
                return False
        
        try:
            with open(output_path, "w", encoding="utf-8") as f:
                f.write("\n".join(machine_codes))
            print("Assembly successful.")
            return True
        except IOError as e:
            print(f"Lỗi khi ghi file output '{output_path}': {e}")
            return False

# ------------------------------------------------------------------------
# HÀM MAIN: ĐỌC FILE INPUT, DỊCH, GHI FILE OUTPUT
# ------------------------------------------------------------------------
def main():
    base_dir = Path(__file__).resolve().parent
    input_path  = base_dir / "assembly.txt"
    output_path = base_dir / "machine_code.txt" # Sửa tên file output

    # 1. Tạo đối tượng Assembler
    asm = Assembler()
    
    # 2. Gọi phương thức assemble_file
    asm.assemble_file(input_path, output_path)

if __name__ == "__main__":
    main()

