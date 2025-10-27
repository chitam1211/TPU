import os
import struct

# =============================================================================
# CÁC HÀM TIỆN ÍCH CHUYỂN ĐỔI KIỂU DỮ LIỆU
# =============================================================================

def float_to_bits32(f):
    """Chuyển đổi giá trị float thành chuỗi bit 32-bit (dưới dạng int)."""
    try:
        # 'f' for float (32-bit), 'I' for unsigned int (32-bit)
        return struct.unpack('I', struct.pack('f', f))[0]
    except (struct.error, OverflowError, TypeError):
        print(f"Warning: Could not convert float {f} to bits. Defaulting to 0.")
        return 0

# =============================================================================
# CÁC HÀM NHẬP LIỆU VÀ GHI FILE
# =============================================================================

def _input_matrix_interactively(matrix_name, expect_float=False):
    """
    Cho phép người dùng nhập ma trận từ terminal.
    expect_float=True: Yêu cầu nhập số thực.
    expect_float=False: Yêu cầu nhập số nguyên.
    """
    data_type = "số thực" if expect_float else "số nguyên"
    print("-" * 30)
    print(f"Nhập các giá trị {data_type} cho ma trận {matrix_name} (cách nhau bởi dấu cách).")
    print("Nhấn Enter trên một dòng trống để kết thúc.")

    matrix_lines = []
    while True:
        try:
            line = input()
            if not line.strip(): break
            matrix_lines.append(line)
        except EOFError: break

    matrix = []
    for line in matrix_lines:
        try:
            if expect_float:
                row = [float(val) for val in line.split()]
            else:
                row = [int(val) for val in line.split()]
            matrix.append(row)
        except ValueError:
            print(f"Lỗi: Dòng '{line}' chứa giá trị {data_type} không hợp lệ. Bỏ qua dòng này.")
            continue
    return matrix

def _write_file(filepath, header, reg_prefix, matrices_to_write, is_float_file):
    """
    Hàm chung để ghi ma trận vào file.
    is_float_file=True: Ghi định dạng float (bit_pattern).
    is_float_file=False: Ghi định dạng integer (decimal).
    """
    # Giá trị mặc định phụ thuộc vào kiểu file
    default_val = 0.0 if is_float_file else 0
    empty_matrix = [[default_val] * 4 for _ in range(4)]

    try:
        with open(filepath, "w") as f:
            f.write(f"{header}\n")

            for i in range(4):
                reg_name = f"{reg_prefix}{i}"
                matrix = matrices_to_write.get(reg_name, empty_matrix)
                f.write(f"\n{reg_name}:\n")

                for r in range(4):
                    row_data = matrix[r] if r < len(matrix) else []
                    while len(row_data) < 4: row_data.append(default_val)

                    if is_float_file:
                        # Ghi định dạng: float (unsigned_integer)
                        float_parts = [str(val) for val in row_data]
                        bit_pattern_parts = [str(float_to_bits32(val)) for val in row_data]
                        float_str = ' '.join(float_parts)
                        bit_pattern_str = ', '.join(bit_pattern_parts)
                        f.write(f"  Row {r}: {float_str} ({bit_pattern_str})\n")
                    else:
                        # Ghi định dạng: integer (decimal)
                        int_parts = [str(int(val)) for val in row_data] # Đảm bảo là int
                        int_str = ' '.join(int_parts)
                        f.write(f"  Row {r}: {int_str}\n")

        print(f"\nĐã cập nhật thành công các thanh ghi vào file '{os.path.basename(filepath)}'")

    except IOError as e:
        print(f"\nLỗi: Không thể ghi vào file {os.path.basename(filepath)}: {e}")

def run_interactive_setup():
    """Hàm chính để chạy công cụ nhập liệu."""
    print("===== Công cụ Cài đặt Ma trận Tương tác (Int & Float) =====")

    tr_int_matrices = {}
    acc_int_matrices = {}
    tr_float_matrices = {}
    acc_float_matrices = {}
    script_dir = os.path.dirname(os.path.abspath(__file__))

    # --- Giai đoạn 1: Nhập Số Nguyên cho Tile Registers (tr) ---
    print("\n--- Thiết lập Thanh ghi Tile Số Nguyên (matrix.txt) ---")
    for i in range(4):
        reg_name = f"tr{i}"
        choice = input(f"Nhập giá trị SỐ NGUYÊN cho {reg_name}? (y/n): ").lower().strip()
        if choice == 'y': tr_int_matrices[reg_name] = _input_matrix_interactively(reg_name, expect_float=False)
    if tr_int_matrices:
        _write_file(os.path.join(script_dir, "matrix.txt"), "--- Tile Registers (tr0-tr3) (Integer Only)---", "tr", tr_int_matrices, is_float_file=False)

    # --- Giai đoạn 2: Nhập Số Nguyên cho Accumulator Registers (acc) ---
    print("\n--- Thiết lập Thanh ghi Tích lũy Số Nguyên (acc.txt) ---")
    for i in range(4):
        reg_name = f"acc{i}"
        choice = input(f"Nhập giá trị SỐ NGUYÊN ban đầu cho {reg_name}? (y/n): ").lower().strip()
        if choice == 'y': acc_int_matrices[reg_name] = _input_matrix_interactively(reg_name, expect_float=False)
    if acc_int_matrices:
        _write_file(os.path.join(script_dir, "acc.txt"), "--- Accumulator Registers (acc0-acc3) (Integer Only)---", "acc", acc_int_matrices, is_float_file=False)

    # --- Giai đoạn 3: Nhập Số Thực cho Tile Registers (tr) ---
    print("\n--- Thiết lập Thanh ghi Tile Số Thực (matrix_float.txt) ---")
    for i in range(4):
        reg_name = f"tr{i}"
        choice = input(f"Nhập giá trị SỐ THỰC cho {reg_name}? (y/n): ").lower().strip()
        if choice == 'y': tr_float_matrices[reg_name] = _input_matrix_interactively(reg_name, expect_float=True)
    if tr_float_matrices:
        _write_file(os.path.join(script_dir, "matrix_float.txt"), "--- Tile Registers (tr0-tr3) (Floating-Point Only)---", "tr", tr_float_matrices, is_float_file=True)

    # --- Giai đoạn 4: Nhập Số Thực cho Accumulator Registers (acc) ---
    print("\n--- Thiết lập Thanh ghi Tích lũy Số Thực (acc_float.txt) ---")
    for i in range(4):
        reg_name = f"acc{i}"
        choice = input(f"Nhập giá trị SỐ THỰC ban đầu cho {reg_name}? (y/n): ").lower().strip()
        if choice == 'y': acc_float_matrices[reg_name] = _input_matrix_interactively(reg_name, expect_float=True)
    if acc_float_matrices:
        _write_file(os.path.join(script_dir, "acc_float.txt"), "--- Accumulator Registers (acc0-acc3) (Floating-Point Only)---", "acc", acc_float_matrices, is_float_file=True)

    print("\n" + "="*42 + "\nHoàn tất cài đặt.\n" + "="*42)

if __name__ == "__main__":
    run_interactive_setup()

