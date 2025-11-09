from .matrix_input import *

# Import các thành phần (components)
from .components import RegisterFile, CSRFile, MatrixAccelerator, MainMemory

class Simulator:
    def __init__(self):
        """Khởi tạo tất cả các thành phần phần cứng trong RAM."""
        self.pc = 0
        self.instructions = []
        
        # 1. Tạo các đối tượng thành phần
        self.gpr = RegisterFile()
        self.csr = CSRFile()
        self.memory = MainMemory()
        # 2. Tạo Bộ tăng tốc và inject các tham chiếu
        #    để nó có thể giao tiếp với GPR, CSR và Memory
        self.matrix_accelerator = MatrixAccelerator(self.csr, self.gpr, self.memory)

    def load_program(self, machine_code_list):
        """Nạp mã máy (danh sách các chuỗi 32-bit) vào bộ nhớ lệnh."""
        self.instructions = machine_code_list
        self.pc = 0 # Reset PC về 0

    def run(self):
        """Vòng lặp CPU chính, chạy trong RAM."""
        print(f"\n--- Bắt đầu Vòng lặp Mô phỏng (Chạy trong RAM) ---")
        while True:
            # 1. Tính toán địa chỉ lệnh
            if self.pc < 0:
                print(f"  [Error] PC âm: {self.pc}. Dừng mô phỏng.")
                break
            instr_index = self.pc // 4 # Mỗi lệnh 4 bytes

            # 2. Kiểm tra kết thúc chương trình
            if instr_index >= len(self.instructions):
                break
            
            # 3. Nạp lệnh
            instruction = self.instructions[instr_index]
            print(f"\nPC: 0x{self.pc:08x} | Executing: {instruction}")
            
            # 4. Giữ PC cũ để kiểm tra lệnh nhảy
            old_pc = self.pc
            
            # 5. Giải mã và Thực thi
            self.decode_and_execute(instruction)
            
            # 6. Cập nhật PC (chỉ khi lệnh không phải là lệnh nhảy)
            if self.pc == old_pc:
                self.pc += 4
        
        print("--- Vòng lặp Mô phỏng Kết thúc ---")

    # --- (SỬA LỖI 1: HÀM NÀY PHẢI NẰM BÊN TRONG CLASS SIMULATOR) ---
    def decode_and_execute(self, instruction):
            """
            Bộ điều phối (Dispatcher) của CPU.
            Gọi đúng phương thức của thành phần dựa trên opcode.
            """
            # --- 1. Trích xuất các trường bit chính ---
            opcode = instruction[25:32]      # bits 6-0
            func3  = instruction[17:20]      # bits 14-12
            uop    = instruction[4:6]        # bits 27-26
            func4  = instruction[0:4]        # bits 31-28
            
            # Chỉ trích xuất d_size cho lệnh Load/Store (vì hàm đó cần)
            d_size_str = instruction[20:22]      # bits 11-10

            print(f"  [Debug] opcode: {opcode}, func3: {func3}, uop: {uop}, func4: {func4}")
            
            # --- 2. Logic Điều phối (Dispatch) ---
            
            # Opcode cho các lệnh Matrix (custom-1)
            if opcode == "0101011":

                # --- NHÓM LỆNH func3 = 000 ---
                if func3 == "000":
                    
                    # A. CONFIG (uop = 00)
                    if uop == "00":
                        print("  -> Dispatching to: MatrixAccelerator (Config)")
                        self.matrix_accelerator.execute_config(instruction)
                    
                    # B. LOAD/STORE (uop = 01)
                    elif uop == "01":
                        print("  -> Dispatching to: MatrixAccelerator (Load/Store)")
                        self.matrix_accelerator.execute_load_store(instruction)

                    # C. MATMUL (uop = 10)
                    elif uop == "10":
                        print("  -> Dispatching to: MatrixAccelerator (Matmul)")
                        # GỌI HÀM THEO YÊU CẦU CỦA BẠN (chỉ 1 tham số)
                        self.matrix_accelerator.execute_matmul(instruction)

                    # D. MISC (uop = 11)
                    elif uop == "11":
                        print("  -> Dispatching to: MatrixAccelerator (MISC)")
                        # Gọi hàm placeholder
                        self.matrix_accelerator.execute_misc(instruction)

                    else:
                        print(f"  -> ERROR: Unknown custom-1 group (func3=000, uop={uop})")

                # --- NHÓM LỆNH func3 = 001 (Element-Wise) ---
                elif func3 == "001":
                    print("  -> Dispatching to: MatrixAccelerator (Element-Wise)")
                    # Gọi hàm placeholder
                    self.matrix_accelerator.execute_element_wise(instruction)

                else:
                    print(f"  -> ERROR: Unknown custom-1 instruction group (func3={func3})")
            
            else:
                print(f"  -> ERROR: Unknown or unsupported instruction opcode: {opcode}")