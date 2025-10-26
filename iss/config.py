import os
import re
#from VARIABLES import XLEN # Chỉ cần import hằng số nếu cần

# --- CÁC HÀM PHỤ TRỢ ĐỂ ĐỌC/GHI FILE ---

def _get_script_dir():
    """Lấy đường dẫn thư mục chứa file hiện tại một cách an toàn."""
    return os.path.dirname(os.path.abspath(__file__))

def _read_gpr_value(reg_index_str):
    """
    Đọc file gpr.txt để lấy giá trị hiện tại của một thanh ghi GPR.
    
    Args:
        reg_index_str (str): Chỉ số 5-bit của thanh ghi (ví dụ: "01011" cho x11).
        
    Returns:
        int: Giá trị của thanh ghi. Trả về 0 nếu không tìm thấy.
    """
    reg_num_to_find = int(reg_index_str, 2)
    file_path = os.path.join(_get_script_dir(), "gpr.txt")
    
    try:
        with open(file_path, "r") as f:
            for line in f:
                # Tìm dòng có dạng "x11 (a1...): 0x..."
                match = re.search(r"x(\d+)\s*\(.+\):\s*(0x[0-9a-fA-F]+)", line)
                if match:
                    reg_num = int(match.group(1))
                    if reg_num == reg_num_to_find:
                        reg_val_hex = match.group(2)
                        print(f"     [File IO] Read from gpr.txt: x{reg_num_to_find} = {reg_val_hex}")
                        return int(reg_val_hex, 16)
    except FileNotFoundError:
        print(f"     [File IO] Warning: gpr.txt not found. Assuming register value is 0.")
        return 0
    except Exception as e:
        print(f"     [File IO] Error reading gpr.txt: {e}. Assuming register value is 0.")
        return 0
        
    print(f"     [File IO] Warning: Register x{reg_num_to_find} not found in gpr.txt. Assuming value is 0.")
    return 0

def _update_csr_value(csr_name, new_value_int, target_file="config.txt"):
    """
    Cập nhật giá trị của một CSR trong tệp được chỉ định (config.txt hoặc status.txt).
    """
    file_path = os.path.join(_get_script_dir(), target_file)
    lines = []
    found = False
    
    try:
        with open(file_path, "r") as f:
            lines = f.readlines()
    except FileNotFoundError:
        print(f"     [File IO] Warning: {file_path} not found. A new file will be created.")
        # Nếu file không tồn tại, tạo tiêu đề phù hợp
        if "config" in target_file:
            lines.append("--- Configuration CSRs ---\n")
        else:
            lines.append("--- Status CSRs ---\n")

    # Tìm và thay thế dòng tương ứng
    for i, line in enumerate(lines):
        if line.strip().startswith(csr_name):
            addr_part_match = re.search(r"(\(0x[0-9a-fA-F]+\))", line)
            addr_part = f" {addr_part_match.group(1)}" if addr_part_match else ""
            lines[i] = f"{csr_name:<8}{addr_part}: 0x{new_value_int:08x}\n"
            found = True
            break
    
    # Nếu không tìm thấy, thêm dòng mới
    if not found:
         lines.append(f"{csr_name:<8}: 0x{new_value_int:08x}\n")

    try:
        with open(file_path, "w") as f:
            f.writelines(lines)
        print(f"     [File IO] Wrote to {target_file}: {csr_name} = 0x{new_value_int:08x}")
    except IOError as e:
        print(f"     [File IO] Error writing to {target_file}: {e}")

# --- HÀM XỬ LÝ CHÍNH ---

def handle_config_instruction(instruction):
    """
    Giải mã và thực thi các lệnh Configuration.
    Hàm này giờ đây trực tiếp đọc từ gpr.txt và ghi vào config.txt/status.txt.
    """
    func4 = instruction[0:4]
    ctrl_bit_25 = instruction[6]

    # 1. Lệnh MRELEASE
    if func4 == "0000":
        print(f"  -> Executing: mrelease")
        # Hoạt động: Cập nhật một thanh ghi trạng thái (ví dụ)
        _update_csr_value('mstatus_ms', 1, target_file="status.txt")
        print(f"     (Simulated: mstatus.MS -> 01)")

    # 2. Lệnh MSETTILEK
    elif func4 == "0001":
        if ctrl_bit_25 == '0': # msettileki
            imm10_bin = instruction[7:17]
            imm_val = int(imm10_bin, 2)
            print(f"  -> Executing: msettileki {imm_val}")
            _update_csr_value('mtilek', imm_val, target_file="config.txt")
        elif ctrl_bit_25 == '1': # msettilek
            rs1_bin = instruction[12:17]
            rs1_num = int(rs1_bin, 2)
            print(f"  -> Executing: msettilek x{rs1_num}")
            val_from_gpr = _read_gpr_value(rs1_bin)
            _update_csr_value('mtilek', val_from_gpr, target_file="config.txt")

    # 3. Lệnh MSETTILEM
    elif func4 == "0010":
        if ctrl_bit_25 == '0': # msettilemi
            imm10_bin = instruction[7:17]
            imm_val = int(imm10_bin, 2)
            print(f"  -> Executing: msettilemi {imm_val}")
            _update_csr_value('mtilem', imm_val, target_file="config.txt")
        elif ctrl_bit_25 == '1': # msettilem
            rs1_bin = instruction[12:17]
            rs1_num = int(rs1_bin, 2)
            print(f"  -> Executing: msettilem x{rs1_num}")
            val_from_gpr = _read_gpr_value(rs1_bin)
            _update_csr_value('mtilem', val_from_gpr, target_file="config.txt")

    # 4. Lệnh MSETTILEN
    elif func4 == "0011":
        if ctrl_bit_25 == '0': # msettileni
            imm10_bin = instruction[7:17]
            imm_val = int(imm10_bin, 2)
            print(f"  -> Executing: msettileni {imm_val}")
            _update_csr_value('mtilen', imm_val, target_file="config.txt")
        elif ctrl_bit_25 == '1': # msettilen
            rs1_bin = instruction[12:17]
            rs1_num = int(rs1_bin, 2)
            print(f"  -> Executing: msettilen x{rs1_num}")
            val_from_gpr = _read_gpr_value(rs1_bin)
            _update_csr_value('mtilen', val_from_gpr, target_file="config.txt")

    else:
        print(f"  -> ERROR: Unknown configuration instruction with func4={func4}")

