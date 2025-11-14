import os
import struct

# =============================================================================
# CÁC HÀM TIỆN ÍCH CHUYỂN ĐỔI (Cần thiết để ghi file float)
# =============================================================================

def float_to_bits32(f):
    """Chuyển đổi giá trị float thành chuỗi bit 32-bit (dưới dạng int)."""
    try:
        return struct.unpack('I', struct.pack('f', f))[0]
    except (struct.error, OverflowError, TypeError):
        return 0

# =============================================================================
# CÁC HẰNG SỐ VÀ CẤU TRÚC DỮ LIỆU (Giữ nguyên)
# =============================================================================
XLEN = 32
ELEN = 32
TLEN = 512
TRLEN = 128
ROWNUM = TLEN // TRLEN
ARLEN = (TLEN // TRLEN) * ELEN
ALEN = ARLEN * ROWNUM
ELEMENTS_PER_ROW_TR = TRLEN // ELEN
DEFAULT_CSR_VALUE = f"{0:0{XLEN}b}"

REGISTERS = {
    f"{i:05b}": {"name": name, "value": f"{0:0{XLEN}b}"}
    for i, name in enumerate([
        "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0/fp", "s1",
        "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7", "s2", "s3",
        "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"
    ])
}
MATRIX_CONTROL_REGISTERS = {
    "xmcsr":   {"address": 0x802, "privilege": "URW", "value": DEFAULT_CSR_VALUE},
    "mtilem":  {"address": 0x803, "privilege": "URW", "value": DEFAULT_CSR_VALUE},
    "mtilen":  {"address": 0x804, "privilege": "URW", "value": DEFAULT_CSR_VALUE},
    "mtilek":  {"address": 0x805, "privilege": "URW", "value": DEFAULT_CSR_VALUE},
    "xmxrm":   {"address": 0x806, "privilege": "URW", "value": DEFAULT_CSR_VALUE},
    "xmsat":   {"address": 0x807, "privilege": "URW", "value": DEFAULT_CSR_VALUE},
    "xmfflags":{"address": 0x808, "privilege": "URW", "value": DEFAULT_CSR_VALUE},
    "xmfrm":   {"address": 0x809, "privilege": "URW", "value": DEFAULT_CSR_VALUE},
    "xmsaten": {"address": 0x80a, "privilege": "URW", "value": DEFAULT_CSR_VALUE},
    "xmisa":   {"address": 0xcc0, "privilege": "URO", "value": DEFAULT_CSR_VALUE},
    "xtlenb":  {"address": 0xcc1, "privilege": "URO", "value": f"{TLEN//8:0{XLEN}b}"},
    "xtrlenb": {"address": 0xcc2, "privilege": "URO", "value": f"{TRLEN//8:0{XLEN}b}"},
    "xalenb":  {"address": 0xcc3, "privilege": "URO", "value": f"{ALEN//8:0{XLEN}b}"},
}
XMISA_FIELDS = {
    "miew": (31, 1), "mfew": (30, 1), "mfic": (29, 1), "mmf8f32": (9, 1),
    "mmf32f64": (8, 1), "mmbf16f32": (7, 1), "mmf16f32": (6, 1), "mmf8bf16": (5, 1),
    "mmf64f64": (4, 1), "mmf32f32": (3, 1), "mmf16f16": (2, 1), "mmi8i32": (1, 1), "mmi4i32": (0, 1)
}
def build_xmisa_value(fields, xlen):
    val = 0
    processed_bits = set()
    for field, (bit, enabled) in fields.items():
        if bit not in processed_bits and enabled:
            val |= (1 << bit)
            processed_bits.add(bit)
    return f"{val:0{xlen}b}"
MATRIX_CONTROL_REGISTERS["xmisa"]["value"] = build_xmisa_value(XMISA_FIELDS, XLEN)

# =============================================================================
# HÀM CHÍNH ĐỂ GHI CÁC FILE TRẠNG THÁI MẶC ĐỊNH
# =============================================================================
def reset_all_files_to_default():
    print("\n--- Resetting state files to default values (separated Int/Float) ---")
    script_dir = os.path.dirname(os.path.abspath(__file__))

    # --- Ghi file gpr.txt, config.txt, status.txt (Dạng HEX) ---
    try:
        with open(os.path.join(script_dir, "gpr.txt"), "w") as f:
            f.write("--- General Purpose Registers (GPRs) ---\n")
            for reg_num_bin, reg_info in sorted(REGISTERS.items()):
                reg_num_dec = int(reg_num_bin, 2)
                f.write(f"x{reg_num_dec:<2} ({reg_info['name']:<7}): 0x{int(reg_info['value'], 2):08x}\n")
        print("Successfully reset gpr.txt")
    except IOError as e: print(f"Error writing to gpr.txt: {e}")

    config_csrs = ["mtilem", "mtilen", "mtilek", "xmxrm", "xmfrm", "xmsaten"]
    status_csrs = ["xmcsr", "xmsat", "xmfflags", "xmisa", "xtlenb", "xtrlenb", "xalenb"]
    try:
        with open(os.path.join(script_dir, "config.txt"), "w") as f:
            f.write("--- Configuration CSRs ---\n")
            for name in config_csrs:
                info = MATRIX_CONTROL_REGISTERS[name]
                f.write(f"{name:<8} (0x{info['address']:03x}): 0x{int(info['value'], 2):08x}\n")
        print("Successfully reset config.txt")
    except IOError as e: print(f"Error writing to config.txt: {e}")

    try:
        with open(os.path.join(script_dir, "status.txt"), "w") as f:
            f.write("--- Status CSRs ---\n")
            for name in status_csrs:
                info = MATRIX_CONTROL_REGISTERS[name]
                f.write(f"{name:<8} (0x{info['address']:03x}): 0x{int(info['value'], 2):08x}\n")
        print("Successfully reset status.txt")
    except IOError as e: print(f"Error writing to status.txt: {e}")

    # --- Ghi file matrix.txt và acc.txt (Chỉ chứa Số Nguyên - Dạng Decimal) ---
    def write_integer_matrix_reset_file(filepath, header, reg_prefix):
        try:
            with open(filepath, "w") as f:
                f.write(f"{header} (Integer Only)\n")
                for i in range(4):
                    f.write(f"\n{reg_prefix}{i}:\n")
                    for r in range(4):
                        int_str = ' '.join(['0'] * 4)
                        f.write(f"  Row {r}: {int_str}\n")
            print(f"Successfully reset {os.path.basename(filepath)} (Integer)")
        except IOError as e: print(f"Error writing to {os.path.basename(filepath)}: {e}")

    write_integer_matrix_reset_file(os.path.join(script_dir, "matrix.txt"), "--- Tile Registers (tr0-tr3) ---", "tr")
    write_integer_matrix_reset_file(os.path.join(script_dir, "acc.txt"), "--- Accumulator Registers (acc0-acc3) ---", "acc")

    # --- Ghi file matrix_float.txt và acc_float.txt (Số Thực - Dạng float (bit_pattern_int32)) ---
    def write_float_matrix_reset_file(filepath, header, reg_prefix):
        try:
            with open(filepath, "w") as f:
                f.write(f"{header} (Floating-Point Only)\n")
                for i in range(4):
                    f.write(f"\n{reg_prefix}{i}:\n")
                    for r in range(4):
                        # Giá trị mặc định là 0.0, có bit pattern 32-bit là 0
                        float_str = ' '.join([str(0.0)] * 4)
                        bit_pattern_str = ', '.join([str(0)] * 4) # Bit pattern của 0.0 là 0
                        f.write(f"  Row {r}: {float_str} ({bit_pattern_str})\n")
            print(f"Successfully created/reset {os.path.basename(filepath)} (Float)")
        except IOError as e: print(f"Error writing to {os.path.basename(filepath)}: {e}")

    write_float_matrix_reset_file(os.path.join(script_dir, "matrix_float.txt"), "--- Tile Registers (tr0-tr3) ---", "tr")
    write_float_matrix_reset_file(os.path.join(script_dir, "acc_float.txt"), "--- Accumulator Registers (acc0-acc3) ---", "acc")

    try:
        with open(os.path.join(script_dir, "memory.txt"), "w", encoding="utf-8") as f:
            f.write("# Định dạng: <Địa chỉ Hex>: <Các byte Hex cách nhau bằng dấu cách>\n")
            f.write("# Ví dụ: 0x3E8: 0A 14 1E\n")
            
            # --- BẮT ĐẦU CẢI TIẾN ---
            f.write("# RAM 1KB (từ 0x000 đến 0x3FF)\n")
            
            bytes_per_line = 16
            total_bytes = 1024 # Tạo sẵn 1KB RAM rỗng
            
            # Tạo một chuỗi "00 00 00 ..." dài 16 byte
            zero_byte_str = " ".join(["00"] * bytes_per_line) 
            
            # Ghi 64 dòng (64 * 16 = 1024 bytes)
            for i in range(0, total_bytes, bytes_per_line):
                address = i
                f.write(f"0x{address:03X}: {zero_byte_str}\n")
            # --- KẾT THÚC CẢI TIẾN ---

        print(f"Successfully created/reset memory.txt (with 1KB of zeroed RAM)")
    except IOError as e: print(f"Error writing to memory.txt: {e}")
    # --- KẾT THÚC SỬA LẠI ---

    print("\n--- State reset complete ---\n")

# if __name__ == "__main__":
#     main()

