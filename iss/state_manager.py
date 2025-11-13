import re
import os
import struct
import math

# ADD: Import lookup tables from definitions.py
from .definitions import GPR_MAP, MATRIX_REG_MAP, ROWNUM, ELEMENTS_PER_ROW_TR

# =============================================================================
# DATA TYPE CONVERSION UTILITY FUNCTIONS
# (Copied from old matmul.py file)
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

# =============================================================================
# LOAD FUNCTIONS (READ FROM FILES INTO SIMULATOR RAM)
# =============================================================================

def _load_matrix_file(filepath, reg_array, is_float_file):
    """Helper function to read matrix.txt/acc.txt files into RAM array."""
    try:
        with open(filepath, "r") as f:
            lines = f.readlines()
            current_reg_index = -1
            current_row_index = 0
            
            for line in lines:
                # Find register name line, e.g. "tr0:" or "acc1:"
                match = re.search(r"^(tr|acc)(\d):", line.strip())
                if match:
                    current_reg_index = int(match.group(2))
                    current_row_index = 0
                    continue # Move to next line
                
                # If within a register block and encounter "Row" line
                if current_reg_index != -1 and line.strip().startswith("Row"):
                    if current_row_index < ROWNUM:
                        data_part = line.split(':')[1].strip()
                        # Always split at '(' to get only the numeric values part
                        # Format: "Row 0: 1 2 3 4 (1, 2, 3, 4)" or "Row 0: 1.0 2.0 3.0 4.0 (1.0, 2.0, 3.0, 4.0)"
                        values_str = data_part.split('(')[0].strip()
                        
                        # Convert read values
                        if values_str:
                            try:
                                if is_float_file:
                                    values = [float(v) for v in values_str.split()]
                                else:
                                    values = [int(v) for v in values_str.split()]
                                
                                # Write to RAM array (Simulator object)
                                for c in range(min(ELEMENTS_PER_ROW_TR, len(values))):
                                    reg_array[current_reg_index][current_row_index][c] = values[c]
                            except ValueError as e:
                                print(f"  [Warning] Skipping invalid line in {filepath}: {line.strip()}. Error: {e}")
                        
                        current_row_index += 1
                        if current_row_index >= ROWNUM:
                            current_reg_index = -1 # End this register block
                    
    except FileNotFoundError:
        print(f"  [Warning] File {filepath} not found. Using default value 0.")
    except Exception as e:
        print(f"  [Error] Cannot read {filepath}. {e}")


def load_state_from_files(sim):
    """Load state from 7 .txt files into Simulator object (RAM)."""
    print("--- Loading state from files into RAM ---")
    script_dir = os.path.dirname(os.path.abspath(__file__))
    
    # 1. Load GPR
    try:
        with open(os.path.join(script_dir, "gpr.txt"), "r") as f:
            for line in f:
                match = re.search(r"x(\d+)\s*\(.+\):\s*(0x[0-9a-fA-F]+)", line)
                if match:
                    reg_num = int(match.group(1))
                    reg_val = int(match.group(2), 16)
                    sim.gpr.write(reg_num, reg_val) # Write to GPR RAM
        print("  GPRs loaded.")
    except Exception as e: print(f"  [Warning] Could not load gpr.txt. {e}")

    # 2. Load CSRs
    try:
        for filename in ["config.txt", "status.txt"]:
             with open(os.path.join(script_dir, filename), "r") as f:
                for line in f:
                    match = re.search(r"(\w+)\s*\(.+\):\s*(0x[0-9a-fA-F]+)", line)
                    if match:
                        name, val = match.group(1).strip(), int(match.group(2), 16)
                        sim.csr.write(name, val) # Write to CSR RAM
        print("  CSRs loaded.")
    except Exception as e: print(f"  [Warning] Could not load CSRs. {e}")
    
    # 3. Load 4 matrix files
    _load_matrix_file(os.path.join(script_dir, "matrix.txt"), sim.matrix_accelerator.tr_int, is_float_file=False)
    _load_matrix_file(os.path.join(script_dir, "acc.txt"), sim.matrix_accelerator.acc_int, is_float_file=False)
    _load_matrix_file(os.path.join(script_dir, "matrix_float.txt"), sim.matrix_accelerator.tr_float, is_float_file=True)
    _load_matrix_file(os.path.join(script_dir, "acc_float.txt"), sim.matrix_accelerator.acc_float, is_float_file=True)
    print("  Matrix registers loaded.")
    
    # 4. Load Memory from memory.txt
    try:
        loaded_count = 0
        print("  [Debug] Starting memory load...")
        with open(os.path.join(script_dir, "memory.txt"), "r", encoding='utf-8') as f:
            for line_num, line in enumerate(f, 1):
                # Parse lines like: "0x100: 00 00 80 3F 00 00 00 40"
                match = re.search(r"0x([0-9a-fA-F]+):\s*([\s0-9a-fA-F]+)", line)
                if match:
                    addr = int(match.group(1), 16)
                    hex_bytes = match.group(2).strip().split()
                    # Convert to bytes and write in one operation
                    byte_data = bytes([int(b, 16) for b in hex_bytes])
                    sim.memory.write(addr, byte_data)
                    loaded_count += 1
                    if addr == 0x100:  # Debug: print first data line
                        print(f"  [Debug] Loaded 0x{addr:X}: {byte_data.hex()}")
        print(f"  Memory loaded from memory.txt ({loaded_count} lines).")
    except FileNotFoundError:
        print("  [Warning] memory.txt not found, memory initialized to zeros")
    except Exception as e:
        print(f"  [Warning] Could not load memory.txt: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()
    
    print("--- State loading complete ---")

# =============================================================================
# =============================================================================
# SAVE FUNCTIONS (WRITE FROM SIMULATOR RAM TO FILES)
# =============================================================================

def _save_matrix_file(filepath, header, reg_prefix, reg_array, is_float_file, bits_converter_func=float_to_bits32):
    """Common helper function to write matrix/acc files."""
    try:
        with open(filepath, "w") as f:
            f.write(f"{header}\n")
            for i in range(len(reg_array)): # Loop through 4 registers
                reg_name = f"{reg_prefix}{i}"
                f.write(f"\n{reg_name}:\n")
                for r in range(ROWNUM): # Loop through 4 rows
                    row_data = reg_array[i][r]
                    
                    if is_float_file:
                        # Write format: float (unsigned_integer_32bit)
                        float_parts = [str(round(val, 4)) for val in row_data]
                        
                        # FIX THIS LINE:
                        # Instead of calling float_to_bits32, call the passed function
                        bit_pattern_parts = [str(bits_converter_func(val)) for val in row_data]
                        
                        float_str = ' '.join(float_parts)
                        bit_pattern_str = ', '.join(bit_pattern_parts)
                        f.write(f"  Row {r}: {float_str} ({bit_pattern_str})\n")
                    else:
                        # (Keep 'else' code section as is)
                        int_parts = [str(int(val)) for val in row_data]
                        int_str = ' '.join(int_parts)
                        f.write(f"  Row {r}: {int_str}\n")
        print(f"  {os.path.basename(filepath)} saved.")
    except IOError as e:
        print(f"  [Error] Could not write to {os.path.basename(filepath)}: {e}")


def save_state_to_files(sim):
    """Save state from Simulator objects (RAM) to 7 .txt files."""
    print("--- Saving final state from RAM to files ---")
    script_dir = os.path.dirname(os.path.abspath(__file__))
    
    # 1. Write GPR (THIS SECTION WAS MISSING)
    try:
        # Tạo map ngược từ index -> tên ABI (bỏ 'x' và 'fp')
        idx_to_abi = {v: k for k, v in GPR_MAP.items() if not k.startswith('x') and k != 'fp'}
        
        with open(os.path.join(script_dir, "gpr.txt"), "w") as f:
            f.write("--- General Purpose Registers (GPRs) ---\n")
            for i in range(32):
                val = sim.gpr.read(i)
                # Lấy tên ABI (ví dụ 'a0') hoặc dùng tên 'x' mặc định
                abi_name = idx_to_abi.get(i, f'x{i}')
                # Dùng tên 'x' cho dòng chính
                f.write(f"x{i:<2} ({abi_name:<7}): 0x{val:08x}\n")
        print(f"  gpr.txt saved.")
    except IOError as e: 
        print(f"  [Error] Error writing gpr.txt: {e}")
    except Exception as e:
        print(f"  [Error] Lỗi không xác định khi ghi GPR: {e}")

    # 2. Ghi CSRs (DI CHUYỂN TỪ BÊN NGOÀI VÀO ĐÂY)
    config_csrs = ["mtilem", "mtilen", "mtilek", "xmxrm", "xmfrm", "xmsaten"]
    status_csrs = ["xmcsr", "xmsat", "xmfflags", "xmisa", "xtlenb", "xtrlenb", "xalenb"]
    try:
        with open(os.path.join(script_dir, "config.txt"), "w") as f:
            f.write("--- Configuration CSRs ---\n")
            for name in config_csrs:
                val = sim.csr.read(name)
                f.write(f"{name:<8}: 0x{val:08x}\n")
        print(f"  config.txt saved.")
    except IOError as e: print(f"  [Error] Error writing config.txt: {e}")

    try:
        with open(os.path.join(script_dir, "status.txt"), "w") as f:
            f.write("--- Status CSRs ---\n")
            for name in status_csrs:
                val = sim.csr.read(name)
                f.write(f"{name:<8}: 0x{val:08x}\n")
        print(f"  status.txt saved.")
    except IOError as e: print(f"  [Error] Error writing status.txt: {e}")

    
    # 3. Ghi 4 file Ma trận (PHẦN NÀY ĐÃ ĐÚNG)
    _save_matrix_file(os.path.join(script_dir, "matrix.txt"), 
                    "--- Tile Registers (tr0-tr3) (Integer Only)---", "tr", 
                    sim.matrix_accelerator.tr_int, is_float_file=False)

    # --- (THAY THẾ) LOGIC GHI ACC.TXT (INTEGER) ---
    try:
        with open(os.path.join(script_dir, "acc.txt"), "w") as f:
            f.write("--- Accumulator Registers (acc0-acc3) (Integer Only) ---\n")
            
            # Lặp qua 4 thanh ghi ACC
            for i in range(4):
                reg_name = f"acc{i}"
                f.write(f"\n{reg_name}:\n")
                
                # Lấy đúng bit-width cho thanh ghi INTEGER này
                dest_bits = sim.matrix_accelerator.acc_dest_bits_int[i]
                
                # Xác định tên format
                if dest_bits == 8:
                    bit_width_name = "INT8"
                elif dest_bits == 16:
                    bit_width_name = "INT16"
                else:
                    bit_width_name = "INT32"
                
                # Ghi tiêu đề với thông tin bit-width
                f.write(f"  (Destination: {bit_width_name}, {dest_bits}-bit)\n")
                
                # Lặp qua 4 hàng của thanh ghi
                for r in range(ROWNUM):
                    row_data = sim.matrix_accelerator.acc_int[i][r]
                    
                    # Chuyển sang integer và áp dụng mask theo bit-width
                    int_parts = []
                    bit_pattern_parts = []
                    
                    for val in row_data:
                        int_val = int(val)
                        
                        # Mask theo bit-width
                        if dest_bits == 8:
                            masked_val = int_val & 0xFF
                        elif dest_bits == 16:
                            masked_val = int_val & 0xFFFF
                        else:  # 32-bit
                            masked_val = int_val & 0xFFFFFFFF
                        
                        # Giá trị signed (human-readable)
                        int_parts.append(str(int_val))

                        # Bit pattern: show signed two's-complement interpretation
                        if dest_bits == 8:
                            signed8 = masked_val if masked_val <= 0x7F else masked_val - 0x100
                            bit_pattern_parts.append(str(signed8))
                        elif dest_bits == 16:
                            signed16 = masked_val if masked_val <= 0x7FFF else masked_val - 0x10000
                            bit_pattern_parts.append(str(signed16))
                        else:
                            signed32 = masked_val if masked_val <= 0x7FFFFFFF else masked_val - 0x100000000
                            bit_pattern_parts.append(str(signed32))
                    
                    int_str = ' '.join(int_parts)
                    bit_pattern_str = ', '.join(bit_pattern_parts)
                    f.write(f"  Row {r}: {int_str} ({bit_pattern_str})\n")
        
        print(f"  acc.txt saved.")
    except IOError as e:
        print(f"  [Error] Could not write to acc.txt: {e}")
    # --- KẾT THÚC THAY THẾ ACC.TXT ---
    
    _save_matrix_file(os.path.join(script_dir, "matrix_float.txt"), 
                    "--- Tile Registers (tr0-tr3) (Floating-Point | 32-bit representation)---", "tr", 
                    sim.matrix_accelerator.tr_float, is_float_file=True, 
                    bits_converter_func=float_to_bits32)

# --- (THAY THẾ) LOGIC GHI ACC_FLOAT.TXT ---
    try:
        with open(os.path.join(script_dir, "acc_float.txt"), "w") as f:
            f.write("--- Accumulator Registers (acc0-acc3) (Floating-Point) ---\n")
            
            # Lặp qua 4 thanh ghi ACC
            for i in range(4):
                reg_name = f"acc{i}"
                f.write(f"\n{reg_name}:\n")
                
                # Lấy đúng bit-width cho thanh ghi FLOAT này từ simulator
                dest_bits = sim.matrix_accelerator.acc_dest_bits_float[i]
                
                # Chọn hàm converter dựa trên bit-width
                if dest_bits == 16:
                    bits_converter_func = float_to_bits16
                    bit_width_name = "FP16/BF16"
                elif dest_bits == 8:
                    # Nếu cần hỗ trợ FP8 trong tương lai
                    bits_converter_func = float_to_bits32  # placeholder
                    bit_width_name = "FP8"
                else: # Mặc định là 32-bit
                    bits_converter_func = float_to_bits32
                    bit_width_name = "FP32"
                
                # Ghi tiêu đề với thông tin bit-width
                f.write(f"  (Destination: {bit_width_name}, {dest_bits}-bit)\n")
                
                # Lặp qua 4 hàng của thanh ghi
                for r in range(ROWNUM):
                    row_data = sim.matrix_accelerator.acc_float[i][r]
                    float_parts = [str(round(val, 4)) for val in row_data]
                    
                    # Dùng converter đã chọn để lấy bit pattern
                    bit_pattern_parts = []
                    for val in row_data:
                        bits_unsigned = bits_converter_func(val)
                        
                        # Hiển thị theo đúng độ rộng bit, nhưng dùng signed two's-complement
                        if dest_bits == 16:
                            bits16 = bits_unsigned & 0xFFFF
                            signed16 = bits16 if bits16 <= 0x7FFF else bits16 - 0x10000
                            bit_pattern_parts.append(str(signed16))
                        else:
                            bits32 = bits_unsigned & 0xFFFFFFFF
                            signed32 = bits32 if bits32 <= 0x7FFFFFFF else bits32 - 0x100000000
                            bit_pattern_parts.append(str(signed32))
                    
                    float_str = ' '.join(float_parts)
                    bit_pattern_str = ', '.join(bit_pattern_parts)
                    f.write(f"  Row {r}: {float_str} ({bit_pattern_str})\n")
        
        print(f"  acc_float.txt saved.")
    except IOError as e:
        print(f"  [Error] Could not write to acc_float.txt: {e}")
    # --- END OF ACC_FLOAT.TXT REPLACEMENT ---
    
    # 4. Save Memory to memory.txt
    try:
        with open(os.path.join(script_dir, "memory.txt"), "w", encoding='utf-8') as f:
            f.write("# Format: <Hex Address>: <Hex bytes separated by spaces>\n")
            f.write("# Example: 0x3E8: 0A 14 1E\n")
            f.write("# RAM 1KB (from 0x000 to 0x3FF)\n")
            
            # Write memory in 16-byte lines (0x00 to 0x3F0)
            for addr in range(0, 0x400, 0x10):
                # Read 16 bytes from memory
                bytes_data = sim.memory.read(addr, 16)
                # Convert to hex string with spaces
                hex_str = ' '.join(f'{b:02X}' for b in bytes_data)
                f.write(f"0x{addr:03X}: {hex_str}\n")
        
        print(f"  memory.txt saved.")
    except IOError as e:
        print(f"  [Error] Could not write to memory.txt: {e}")
    except Exception as e:
        print(f"  [Error] Unknown error saving memory.txt: {type(e).__name__}: {e}")
    
    print("--- State saving complete ---")
