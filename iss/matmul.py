import os
import re
import struct
import math # Needed for FP8 conversion checks

# =============================================================================
# CÁC HÀM TIỆN ÍCH CHUYỂN ĐỔI KIỂU DỮ LIỆU (Giữ nguyên)
# =============================================================================
# --- Float <-> Bits ---
def bits_to_float32(bits):
    try: return struct.unpack('f', struct.pack('I', bits & 0xFFFFFFFF))[0]
    except: return 0.0
def float_to_bits32(f):
    try: return struct.unpack('I', struct.pack('f', f))[0]
    except OverflowError: return 0x7f800000 if f > 0 else 0xff800000
    except: return 0
def bits_to_float16(bits):
    bits = bits & 0xFFFF
    try: return struct.unpack('e', struct.pack('H', bits))[0]
    except: return 0.0
def float_to_bits16(f):
    try: return struct.unpack('H', struct.pack('e', f))[0]
    except OverflowError: return 0x7c00 if f > 0 else 0xfc00
    except: return 0

# --- FP8 Simplified Converters ---
def float_to_bits8_e4m3(f):
    if math.isnan(f): return 0b10000000
    if math.isinf(f): return 0b01111000 if f > 0 else 0b11111000
    bits32 = float_to_bits32(f); sign = (bits32 >> 31) & 0x1
    if (bits32 & 0x7FFFFFFF) == 0: return 0b10000000 if sign else 0b00000000
    exponent32 = ((bits32 >> 23) & 0xFF) - 127; mantissa32 = bits32 & 0x7FFFFF
    bias8 = 7; exponent8 = exponent32 + bias8
    if exponent8 >= 15: return 0b11111000 if sign else 0b01111000
    if exponent8 <= 0: return 0b10000000 if sign else 0b00000000
    mantissa8 = (mantissa32 >> 20) & 0x7
    if (mantissa32 >> 19) & 0x1:
        mantissa8 += 1
        if mantissa8 > 0x7: mantissa8 = 0; exponent8 += 1
        if exponent8 >= 15: return 0b11111000 if sign else 0b01111000
    return (sign << 7) | (exponent8 << 3) | mantissa8

def float_to_bits8_e5m2(f):
    if math.isnan(f): return 0b10000000
    if math.isinf(f): return 0b01111100 if f > 0 else 0b11111100
    bits32 = float_to_bits32(f); sign = (bits32 >> 31) & 0x1
    if (bits32 & 0x7FFFFFFF) == 0: return 0b10000000 if sign else 0b00000000
    exponent32 = ((bits32 >> 23) & 0xFF) - 127; mantissa32 = bits32 & 0x7FFFFF
    bias8 = 15; exponent8 = exponent32 + bias8
    if exponent8 >= 31: return 0b11111100 if sign else 0b01111100
    if exponent8 <= 0: return 0b10000000 if sign else 0b00000000
    mantissa8 = (mantissa32 >> 21) & 0x3
    if (mantissa32 >> 20) & 0x1:
        mantissa8 += 1
        if mantissa8 > 0x3: mantissa8 = 0; exponent8 += 1
        if exponent8 >= 31: return 0b11111100 if sign else 0b01111100
    return (sign << 7) | (exponent8 << 2) | mantissa8

# --- Bits -> Signed Int ---
def bits_to_signed_int32(bits):
    bits &= 0xFFFFFFFF; return bits - 0x100000000 if bits & 0x80000000 else bits
def bits_to_signed_int16(bits):
    val = bits & 0xFFFF; return val - 0x10000 if val & 0x8000 else val
def bits_to_signed_int8(bits):
    val = bits & 0xFF; return val - 0x100 if val & 0x80 else val

# --- Int <-> Bits ---
def bits_to_int32(bits): return bits_to_signed_int32(bits)
def int_to_bits32(i): return int(i) & 0xFFFFFFFF

# =============================================================================
# CÁC HÀM TIỆN ÍCH ĐỌC/GHI/HIỂN THỊ TRẠNG THÁI (Giữ nguyên _read*)
# =============================================================================
def _read_csr_value(csr_name):
    script_dir = os.path.dirname(os.path.abspath(__file__))
    for filename in ["config.txt", "status.txt"]:
        try:
            with open(os.path.join(script_dir, filename), "r") as f:
                for line in f:
                    match = re.search(r"(\w+)\s*\(.+\):\s*(0x[0-9a-fA-F]+)", line)
                    if match and match.group(1).strip() == csr_name:
                        return int(match.group(2), 16)
        except FileNotFoundError: continue
    return 0

def _read_matrix_from_file(filename, reg_name, rows, cols, is_float_file):
    matrix = [[0.0 for _ in range(cols)] for _ in range(rows)]
    script_dir = os.path.dirname(os.path.abspath(__file__))
    try:
        with open(os.path.join(script_dir, filename), "r") as f:
            lines = f.readlines()
            in_correct_register = False
            current_row_index = 0
            for line in lines:
                if reg_name in line and ":" in line and not line.startswith("Row"):
                    in_correct_register = True; current_row_index = 0; continue
                if in_correct_register and line.strip().startswith("Row"):
                    if current_row_index < rows:
                        data_part = line.split(':')[1].strip()
                        if is_float_file:
                            values_str = data_part.split('(')[0].strip()
                            values = [float(v) for v in values_str.split()] if values_str else []
                        else: # Integer file
                            values = [float(int(v)) for v in data_part.split()] if data_part else []
                        for c in range(min(cols, len(values))): matrix[current_row_index][c] = values[c]
                        current_row_index += 1
                if in_correct_register and ":" in line and not line.strip().startswith("Row"): break
    except Exception as e: print(f"  [Error] Failed to read {reg_name} from {filename}: {e}")
    return [row[:cols] for row in matrix[:rows]]


def _update_file(filepath, reg_name, result_matrix, is_float_file, data_type_converter_to_bits, signed_display_converter):
    """
    Hàm chung cập nhật file acc.txt hoặc acc_float.txt.
    Chuyển vị ma trận trước khi ghi
    """
    # Chuyển vị ma trận kết quả
    rows = len(result_matrix)
    cols = len(result_matrix[0]) if rows > 0 else 0
    transposed = [[result_matrix[r][c] for r in range(rows)] for c in range(cols)]
    
    try:
        with open(filepath, "r") as f: lines = f.readlines()
    except FileNotFoundError: lines = []

    output_lines = []
    in_target_block = False
    processed_reg = False

    i = 0
    while i < len(lines):
        line = lines[i]
        if not in_target_block and reg_name in line and ":" in line and not line.strip().startswith("Row"):
            in_target_block = True
            processed_reg = True
            output_lines.append(line)
            i += 1

            # Ghi ma trận đã chuyển vị
            for r in range(cols):  # Sử dụng cols thay vì rows vì đã chuyển vị
                row_data = transposed[r]
                while len(row_data) < 4:
                    row_data.append(0.0 if is_float_file else 0)

                if is_float_file:
                    float_str = ' '.join(str(round(val, 4)) for val in row_data)
                    bit_patterns = [data_type_converter_to_bits(val) for val in row_data]
                    signed_str = ', '.join(str(signed_display_converter(b)) for b in bit_patterns)
                    output_lines.append(f"  Row {r}: {float_str} ({signed_str})\n")
                else:
                    int_str = ' '.join(str(int(round(val))) for val in row_data)
                    output_lines.append(f"  Row {r}: {int_str}\n")

            while i < len(lines) and lines[i].strip().startswith("Row"):
                i += 1
            continue

        elif in_target_block and ":" in line and not line.strip().startswith("Row"):
            in_target_block = False

        if not in_target_block:
            output_lines.append(line)
        i += 1

    if not processed_reg:
        if not output_lines:
            header = "--- Accumulator Registers (acc0-acc3) "
            header += "(Floating-Point Only)---\n" if is_float_file else "(Integer Only)---\n"
            output_lines.append(header)
        output_lines.append(f"\n{reg_name}:\n")
        
        for r in range(cols):  # Sử dụng cols thay vì rows vì đã chuyển vị
            row_data = transposed[r]
            while len(row_data) < 4:
                row_data.append(0.0 if is_float_file else 0)

            if is_float_file:
                float_str = ' '.join(str(round(val, 4)) for val in row_data)
                bit_patterns = [data_type_converter_to_bits(val) for val in row_data]
                signed_str = ', '.join(str(signed_display_converter(b)) for b in bit_patterns)
                output_lines.append(f"  Row {r}: {float_str} ({signed_str})\n")
            else:
                int_str = ' '.join(str(int(round(val))) for val in row_data)
                output_lines.append(f"  Row {r}: {int_str}\n")

    try:
        with open(filepath, "w") as f:
            f.writelines(output_lines)
    except IOError as e:
        print(f"  [Error] Could not write to {filepath}: {e}")

def _print_matrix_contents(filename, reg_name, rows, cols, is_float_file, bits_converter, signed_converter):
    type_name = "unknown"
    if signed_converter: type_name = signed_converter.__name__.split('_')[-1]
    print(f"     -- Contents of {reg_name} (from {filename}, interpreted as {type_name}):")
    matrix = _read_matrix_from_file(filename, reg_name, rows, cols, is_float_file)
    
    for r in range(min(rows, len(matrix))):
        row_float_vals = matrix[r][:cols]
        while len(row_float_vals) < cols:
            row_float_vals.append(0.0)
        if is_float_file:
            bit_patterns = [bits_converter(f) for f in row_float_vals]
            signed_ints = [signed_converter(b) for b in bit_patterns]
            float_str = ' '.join([str(f) for f in row_float_vals])
            signed_str = ', '.join([str(i) for i in signed_ints])
            print(f"       Row {r}: {float_str} ({signed_str})")
        else:
            int_vals = [int(round(f)) for f in row_float_vals]
            print(f"       Row {r}: {' '.join(map(str, int_vals))}")

# =============================================================================
# HÀM XỬ LÝ CHÍNH (Giữ nguyên logic chính)
# =============================================================================
def handle_matmul_instruction(instruction):
    # 1. Giải mã Lệnh
    func4    = instruction[0:4]
    size_sup = instruction[6:9]
    s_size   = instruction[12:14]
    d_size   = instruction[20:22]
    ms2      = instruction[9:12]
    ms1      = instruction[14:17]
    md_ms3   = instruction[22:25]

    tr_source1_name, tr_source2_name = f"tr{int(ms1, 2)}", f"tr{int(ms2, 2)}"
    acc_dest_name = f"acc{int(md_ms3, 2) - 4}"

    # 2. Xác định các thuộc tính & converters dựa trên lệnh
    source_file, acc_file = "matrix_float.txt", "acc_float.txt"
    source_bits_conv, source_signed_conv = float_to_bits32, bits_to_signed_int32
    dest_bits_conv, dest_signed_conv = float_to_bits32, bits_to_signed_int32
    source_bits, dest_bits = 32, 32
    instr_name, is_float_op = "Unknown", True

    # --- Non-Widen ---
    if func4 == "0000" and s_size == "01" and d_size == "01": # mfmacc.h (fp16->fp16)
        instr_name = "mfmacc.h"
        source_bits_conv, source_signed_conv = float_to_bits16, bits_to_signed_int16
        dest_bits_conv, dest_signed_conv = float_to_bits16, bits_to_signed_int16
        source_bits, dest_bits = 16, 16
    elif func4 == "0000" and s_size == "10" and d_size == "10": # mfmacc.s (fp32->fp32)
        instr_name = "mfmacc.s"
        source_bits_conv, source_signed_conv = float_to_bits32, bits_to_signed_int32
        dest_bits_conv, dest_signed_conv = float_to_bits32, bits_to_signed_int32
        source_bits, dest_bits = 32, 32
    # --- Double-Widen ---
    elif func4 == "0000" and s_size == "00" and d_size == "01": # mfmacc.h.eX (fp8->fp16)
        instr_name = "mfmacc.h.e5" if size_sup == "000" else "mfmacc.h.e4"
        source_bits_conv = float_to_bits8_e5m2 if size_sup == "000" else float_to_bits8_e4m3
        source_signed_conv = bits_to_signed_int8
        dest_bits_conv, dest_signed_conv = float_to_bits16, bits_to_signed_int16
        source_bits, dest_bits = 8, 16
    elif func4 == "0000" and s_size == "01" and d_size == "10": # mfmacc.s.h (fp16->fp32)
        instr_name = "mfmacc.s.h"
        source_bits_conv, source_signed_conv = float_to_bits16, bits_to_signed_int16
        dest_bits_conv, dest_signed_conv = float_to_bits32, bits_to_signed_int32
        source_bits, dest_bits = 16, 32
    # --- Quad-Widen ---
    # --- Float ---
    elif func4 == "0000" and s_size == "00" and d_size == "10": # mfmacc.s.eX (fp8->fp32)
        instr_name = "mfmacc.s.e5" if size_sup == "000" else "mfmacc.s.e4"
        source_bits_conv = float_to_bits8_e5m2 if size_sup == "000" else float_to_bits8_e4m3
        source_signed_conv = bits_to_signed_int8
        dest_bits_conv, dest_signed_conv = float_to_bits32, bits_to_signed_int32 # Đích là FP32
        source_bits, dest_bits = 8, 32
        is_float_op = True

    # --- Integer ---
    elif func4 == "0001" and s_size == "00" and d_size == "10": # mmacc.w.b (int8->int32)
        instr_name = "mmacc.w.b"
        source_file, acc_file = "matrix.txt", "acc.txt"
        source_bits_conv = lambda x: int(x) & 0xFF
        source_signed_conv = bits_to_signed_int8
        dest_bits_conv, dest_signed_conv = int_to_bits32, bits_to_signed_int32
        source_bits, dest_bits = 8, 32
        is_float_op = False
    else:
        print(f"  -> WARNING: Instruction format not fully recognized. Assuming FP32 non-widen.")
        instr_name = "mfmacc.s (assumed)"

    widen_factor = dest_bits // source_bits if source_bits > 0 else 1
    print(f"  -> Executing: {instr_name} on {tr_source1_name}, {tr_source2_name} -> {acc_dest_name}")
    print(f"     - Widen Factor: {widen_factor}x ({source_bits}-bit source -> {dest_bits}-bit dest)")
    print(f"     - Reading sources from: {source_file}")
    print(f"     - Writing result to: {acc_file}")

    # 3. Đọc Trạng thái và In ra Nội dung Trước Tính toán
    M, N, K = _read_csr_value('mtilem'), _read_csr_value('mtilen'), _read_csr_value('mtilek')
    if M*N*K == 0: print("  [Warning] Tile dimensions are zero. Skipping."); return

    print("     -- Before computation --")
    _print_matrix_contents(source_file, tr_source1_name, M, K, is_float_op, source_bits_conv, source_signed_conv)
    _print_matrix_contents(source_file, tr_source2_name, N, K, is_float_op, source_bits_conv, source_signed_conv)
    _print_matrix_contents(acc_file, acc_dest_name, M, N, is_float_op, dest_bits_conv, dest_signed_conv)

    mat_A = _read_matrix_from_file(source_file, tr_source1_name, M, K, is_float_op)
    mat_B = _read_matrix_from_file(source_file, tr_source2_name, N, K, is_float_op)
    mat_C_old = _read_matrix_from_file(acc_file, acc_dest_name, M, N, is_float_op)

    # 4. Thực hiện Tính toán
    mat_C_new = [[mat_C_old[r][c] for c in range(N)] for r in range(M)]
    print("     - Starting computation loop...")
    for m in range(M):
        for n in range(N):
            dot_product = 0.0
            k_limit = K
            for k in range(k_limit):
                 if m < len(mat_A) and k < len(mat_A[m]) and n < len(mat_B) and k < len(mat_B[n]):
                     a_val, b_val = mat_A[m][k], mat_B[n][k]
                     dot_product += a_val * b_val
                 else: continue
            if not is_float_op:
                mat_C_new[m][n] = float(int(mat_C_new[m][n]) + int(round(dot_product)))
            else: mat_C_new[m][n] += dot_product
    print(f"     - Computation complete.")

    # 5. Ghi Trạng thái Mới
    script_dir = os.path.dirname(os.path.abspath(__file__))
    _update_file(os.path.join(script_dir, acc_file), acc_dest_name, mat_C_new, is_float_op, dest_bits_conv, dest_signed_conv)
    print(f"     - Update of {acc_file} successful.")

    # In ra trạng thái sau khi cập nhật
    print("     -- After computation --")
    _print_matrix_contents(acc_file, acc_dest_name, M, N, is_float_op, dest_bits_conv, dest_signed_conv)

