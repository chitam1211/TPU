import sys
import os
from pathlib import Path
SCRIPT_DIR = Path(__file__).resolve().parent

# Import các thành phần của trình mô phỏng
from .iss import Simulator
from .state_manager import load_state_from_files, save_state_to_files
from .matrix_input import run_interactive_setup
from .reset_state import reset_all_files_to_default  # Import hàm reset

def main():
    """
    Hàm chính để điều phối toàn bộ quá trình mô phỏng.
    """
    
    # Xác định các đường dẫn file
    root_dir = SCRIPT_DIR.parent 
    assembler_dir = root_dir / "assembler"
    iss_dir = SCRIPT_DIR 
    machine_code_file = assembler_dir / "machine_code.txt"

    # --- Xử lý cờ (flags) ---
    if len(sys.argv) > 1:
        # Xử lý cờ --setup
        if sys.argv[1] in ['--setup', '-s']:
            print("--- Chạy Chế độ Cài đặt (Setup Mode) ---")
            run_interactive_setup()
            print("\nCài đặt hoàn tất. Chạy lại chương trình mà không có cờ '--setup' để mô phỏng.")
            return # Thoát sau khi setup

        # Xử lý cờ --reset
        if sys.argv[1] in ['--reset', '-r']:
            print("--- Chạy Chế độ Reset ---")
            reset_all_files_to_default()
            print("Reset hoàn tất. Bắt đầu mô phỏng với trạng thái sạch.")

    # --- 1. Khởi tạo Simulator (Tạo các đối tượng trong RAM) ---
    print("--- 1. Khởi tạo Simulator (Trong RAM) ---")
    my_simulator = Simulator()
    
    # --- 2. Nạp Trạng thái từ File vào RAM ---
    # (Hàm này sẽ đọc 7 file .txt và điền dữ liệu vào my_simulator)
    load_state_from_files(my_simulator)

    # --- 3. Đọc Mã máy (Input) ---
    print(f"--- 2. Đọc Mã máy từ '{machine_code_file}' ---")
    try:
        with open(machine_code_file, "r") as f:
            instructions = [line.strip() for line in f if line.strip() and not line.startswith('#')]
        if not instructions:
            print(f"Warning: File mã máy '{machine_code_file}' trống.")
            return
        my_simulator.load_program(instructions)
        print(f"Đã nạp {len(instructions)} lệnh.")
    except FileNotFoundError:
        print(f"LỖI: Không tìm thấy file '{machine_code_file}'.")
        print("Bạn đã chạy file assembler/assembler.py để tạo ra nó chưa?")
        return
    except Exception as e:
        print(f"LỖI khi đọc file mã máy: {e}")
        return

    # --- 4. Chạy Mô phỏng (Hoàn toàn trong RAM) ---
    print("--- 3. Bắt đầu Vòng lặp Mô phỏng (Chạy trong RAM) ---")
    my_simulator.run()
    
    # --- 5. Lưu Trạng thái cuối cùng từ RAM ra File ---
    print("--- 4. Lưu Trạng thái Cuối cùng từ RAM ra Files ---")
    save_state_to_files(my_simulator)
    
    print("\n--- Mô phỏng Hoàn tất ---")

if __name__ == "__main__":
    main()
# python -m iss.run_simulator
# python -m iss.run_simulator -r # Chạy chế độ reset