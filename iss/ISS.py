import os
from config import handle_config_instruction
from matmul import handle_matmul_instruction # <<< THÊM IMPORT MỚI
from matrix_input import *
def decode_and_execute(instruction):
    """
    Hàm điều phối (Dispatcher) không trạng thái.
    Nhiệm vụ: Giải mã các bit chính và gọi hàm xử lý tương ứng.
    """
    # Các trường bit chính để xác định nhóm lệnh (đánh số từ MSB=0 đến LSB=31)
    opcode = instruction[25:32]      # bits 6-0
    func3  = instruction[17:20]      # bits 14-12
    uop    = instruction[4:6]        # bits 27-26
    func4  = instruction[0:4]        # bits 31-28 (cần cho matmul)

    print(f"  [Debug] opcode: {opcode}, func3: {func3}, uop: {uop}, func4: {func4}")
    
    # --- Bắt đầu logic điều phối ---
    
    # Kiểm tra Opcode chính = custom-1 (0101011)
    if opcode == "0101011":
        # Nhóm 1: Configuration Instructions
        if uop == "00" and func3 == "000":
            print("  -> Dispatching to: Configuration Handler")
            handle_config_instruction(instruction)
        
        # --- KHỐI LOGIC MỚI CHO MATRIX MULTIPLICATION ---
        # Dựa trên Bảng 4, nhóm lệnh này có uop=01 và func4=0000
        elif uop == "01" and func3 == "000" and func4 == "0000":
            print("  -> Dispatching to: Matrix Multiplication Handler")
            handle_matmul_instruction(instruction)
        
        # (Trong tương lai, bạn có thể thêm các nhóm lệnh khác ở đây)
        # Ví dụ cho nhóm lệnh Integer Matrix Multiplication (func4=0001)
        # elif uop == "01" and func3 == "000" and func4 == "0001":
        #     print("  -> Dispatching to: Integer Matrix Multiplication Handler")
        #     handle_integer_matmul_instruction(instruction)
            
        else:
            print(f"  -> ERROR: Unknown instruction group for custom-1 opcode (uop={uop}, func3={func3}, func4={func4})")
    
    # (Trong tương lai, bạn có thể thêm logic cho các opcode cơ bản khác của RISC-V)
    # elif opcode == "0010011": # Opcode for I-type instructions like ADDI
    #     handle_i_type_instruction(instruction)
        
    else:
        print(f"  -> ERROR: Unknown or unsupported instruction opcode: {opcode}")

# =============================================================================
# CÁC HÀM CÒN LẠI (Simulator, main) KHÔNG THAY ĐỔI
# Chúng được giữ lại để bạn có bối cảnh hoàn chỉnh của tệp ISS.py
# =============================================================================

def Simulator(instruction_list):
    """
    Vòng lặp CPU chính.
    """
    print(f"\n--- Starting Simulation ({len(instruction_list)} instructions) ---")
    
    for instruction_index, instruction in enumerate(instruction_list):
        pc_address = instruction_index * 4
        print(f"\nPC: 0x{pc_address:08x} | Executing: {instruction}")
        decode_and_execute(instruction)
        
    print("\n--- Simulation Finished ---")

def main():
    """
    Hàm chính để nạp mã máy và khởi chạy simulator.
    """
    input_file_path = r"F:\TPU\TPU\assembler\machine_code.txt"
    
    try:
        with open(input_file_path, "r") as f:
            instructions = [line.strip() for line in f if line.strip() and not line.startswith('#')]
    except FileNotFoundError:
        print(f"FATAL ERROR: Input file not found at '{input_file_path}'")
        return

    if not instructions:
        print(f"Warning: Input file '{input_file_path}' is empty. Nothing to simulate.")
        return

    print("="*50)
    print("RISC-V Matrix Extension Simulator")
    print(f"Loaded {len(instructions)} instructions.")
    #run_interactive_setup()
    print("="*50)
    
    Simulator(instructions)
    print("\n--- Simulation Complete ---")

if __name__ == "__main__":
    main()

