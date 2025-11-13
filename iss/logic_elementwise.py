# Import các hàm tiện ích
from .converters import *
from .definitions import ROWNUM, ELEMENTS_PER_ROW_TR
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from typing import List
    from .components import CSRFile

# Hằng số (giả định)
INT32_MAX = 0x7FFFFFFF
INT32_MIN = -0x80000000
UINT32_MAX = 0xFFFFFFFF
INT8_MAX = 127
INT8_MIN = -128
UINT8_MAX = 255
UINT8_MIN = 0
rows = ROWNUM # = 4
cols_32bit = ELEMENTS_PER_ROW_TR # = 4
cols_16bit = cols_32bit * 2 # = 8
cols_8bit = cols_32bit * 4 # = 16

class ElementwiseLogic:
    """
    Mixin class for element-wise operations.
    
    Expected attributes (provided by MatrixAccelerator):
        - tr_int: List[List[List[int]]] - Tile registers (integer)
        - tr_float: List[List[List[float]]] - Tile registers (float)
        - acc_int: List[List[List[int]]] - Accumulator registers (integer)
        - acc_float: List[List[List[float]]] - Accumulator registers (float)
        - csr_ref: CSRFile - Reference to CSR registers
        - rownum: int - Number of rows in matrix
        - elements_per_row_tr: int - Elements per row in TR
    """

    def _execute_ew_integer(self, instruction, func4, ctrl, md_idx, ms1_idx, ms2_idx):
        """Thực thi Nhóm 5.5.1: Lệnh số học số nguyên (uop=01)."""
        
        # Đọc kích thước tile (M, N) từ CSR 
        M = self.csr_ref.read('mtilem')
        N = self.csr_ref.read('mtilen')
        
        # Kiểm tra chế độ bão hòa (saturation) 
        saturation_enabled = (self.csr_ref.read('xmsaten') == 1)
        
        # Xác định chế độ: matrix-matrix hay matrix-vector 
        is_matrix_matrix = (ctrl == "111")
        vector_row_idx = int(ctrl, 2) # Dùng cho chế độ .mv.i 

        print(f"    - Executing EW-Integer (M={M}, N={N})")

        # Lặp qua từng phần tử của tile (M x N)
        for i in range(M):
            for j in range(N):
                # Lấy toán hạng 2 (luôn là matrix)
                val2 = self.acc_int[ms2_idx][i][j]
                
                # Lấy toán hạng 1 (matrix hoặc vector)
                if is_matrix_matrix:
                    val1 = self.acc_int[ms1_idx][i][j]
                else:
                    val1 = self.acc_int[ms1_idx][vector_row_idx][j] # 

                # Thực hiện phép toán dựa trên func4
                res = 0
                if func4 == "0000": # madd.w 
                    res = val1 + val2
                elif func4 == "0001": # msub.w 
                    res = val1 - val2
                elif func4 == "0010": # mmul.w 
                    res = val1 * val2
                elif func4 == "0100": # mmax.w 
                    res = max(val1, val2)
                elif func4 == "0101": # mumax.w 
                    # Chuyển sang unsigned để so sánh
                    u_val1 = val1 & 0xFFFFFFFF
                    u_val2 = val2 & 0xFFFFFFFF
                    res = u_val1 if u_val1 > u_val2 else u_val2
                elif func4 == "0110": # mmin.w 
                    res = min(val1, val2)
                elif func4 == "0111": # mumin.w 
                    u_val1 = val1 & 0xFFFFFFFF
                    u_val2 = val2 & 0xFFFFFFFF
                    res = u_val1 if u_val1 < u_val2 else u_val2
                elif func4 == "1000": # msrl.w 
                    shift_amount = val1 & 0x1F # Chỉ dùng 5 bit thấp
                    res = (val2 & 0xFFFFFFFF) >> shift_amount
                elif func4 == "1001": # msll.w 
                    shift_amount = val1 & 0x1F
                    res = val2 << shift_amount
                elif func4 == "1010": # msra.w 
                    shift_amount = val1 & 0x1F
                    res = val2 >> shift_amount # Dịch phải số học (Python tự xử lý)
                else:
                    print(f"    [Warning] EW-Integer instruction with func4={func4} is not supported.")
                    continue

                # Xử lý bão hòa (Saturation) 
                if saturation_enabled:
                    if res > INT32_MAX:
                        res = INT32_MAX
                        self.csr_ref.write('xmsat', 1)
                    elif res < INT32_MIN:
                        res = INT32_MIN
                        self.csr_ref.write('xmsat', 1)
                
                # Ghi kết quả (wrap-around nếu không bão hòa)
                self.acc_int[md_idx][i][j] = res & 0xFFFFFFFF


    def _execute_ew_float(self, instruction, func4, ctrl, md_idx, ms1_idx, ms2_idx, s_size, d_size):
            """Thực thi Nhóm 5.5.2: Lệnh số học số thực (uop=10)."""
            
            # --- 1. Xác định độ chính xác (Precision) ---
            # Theo Bảng 6, các lệnh này có s_size = d_size 
            float_to_bits = None
            bits_to_float = None

            if s_size == "01": # Lệnh .h (fp16) 
                float_to_bits = float_to_bits16
                bits_to_float = bits_to_float16
            elif s_size == "10": # Lệnh .s (fp32)
                float_to_bits = float_to_bits32
                bits_to_float = bits_to_float32
            else:
                print(f"  [Error] Invalid s_size/d_size for EW-Float: {s_size}")
                return

            # --- 2. Đọc cấu hình Tile ---
            M = self.csr_ref.read('mtilem')
            N = self.csr_ref.read('mtilen')
            
            # Xác định chế độ: matrix-matrix hay matrix-vector
            is_matrix_matrix = (ctrl == "111") 
            vector_row_idx = int(ctrl, 2) % ROWNUM 

            print(f"    - Executing EW-Float (M={M}, N={N}, Precision={s_size})")

            # --- 3. Vòng lặp tính toán ---
            for i in range(M):
                for j in range(N):
                    # Đọc giá trị đầy đủ (Python float 64-bit) từ RAM
                    val2_full = self.acc_float[ms2_idx][i][j]
                    
                    if is_matrix_matrix:
                        val1_full = self.acc_float[ms1_idx][i][j]
                    else:
                        # Logic matrix-vector: ms2[i,j] op ms1[vector_row_idx, j]
                        val1_full = self.acc_float[ms1_idx][vector_row_idx][j] 

                    # --- 4. Mô phỏng độ chính xác (Precision Simulation) ---
                    # Chuyển đổi các toán hạng nguồn về đúng độ chính xác (fp16/fp32)
                    val1_quantized = bits_to_float(float_to_bits(val1_full))
                    val2_quantized = bits_to_float(float_to_bits(val2_full))
                    
                    # Đọc giá trị ACC cũ (md) và cũng làm tròn nó
                    c_old_quantized = bits_to_float(float_to_bits(self.acc_float[md_idx][i][j]))
                    
                    res_full = 0.0
                    
                    # --- 5. Thực hiện phép toán ---
                    if func4 == "0000": # mfadd 
                        res_full = val2_quantized + val1_quantized
                    elif func4 == "0001": # mfsub
                        res_full = val2_quantized - val1_quantized
                    elif func4 == "0010": # mfmul 
                        res_full = val2_quantized * val1_quantized
                    elif func4 == "0011": # mfmax 
                        res_full = max(val2_quantized, val1_quantized)
                    elif func4 == "0100": # mfmin 
                        res_full = min(val2_quantized, val1_quantized)
                    else:
                        print(f"    [Warning] EW-Float instruction with func4={func4} is not supported.")
                        continue
                    
                    # --- 6. Ghi kết quả (Làm tròn về độ chính xác ĐÍCH) ---
                    # Phép toán float-point được làm tròn sau khi cộng vào acc 
                    res_quantized = bits_to_float(float_to_bits(res_full))
                    self.acc_float[md_idx][i][j] = res_quantized

    # --- HÀM DISPATCHER CHÍNH ---
    def execute_element_wise(self, instruction):
        """
        Giải mã và điều phối các lệnh Element-Wise (func3=001).
        """
        # --- 1. Giải mã các trường chung ---
        uop        = instruction[4:6]        # bits 27-26
        func4      = instruction[0:4]        # bits 31-28
        ctrl       = instruction[6:9]        # bits 25-23 (dùng cho imm3 hoặc ctrl)
        ms2_bin    = instruction[9:12]
        s_size_str = instruction[12:14]
        ms1_bin    = instruction[14:17]
        d_size_str = instruction[20:22]
        md_bin     = instruction[22:25]
        
        # Chuyển đổi index. Tất cả EW đều dùng acc register 
        try:
            md_idx  = int(md_bin, 2) - 4
            ms1_idx = int(ms1_bin, 2) - 4
            ms2_idx = int(ms2_bin, 2) - 4
            if (md_idx < 0 or ms1_idx < 0 or ms2_idx < 0):
                raise IndexError()
        except (IndexError, ValueError):
             print(f"  [Error] Element-Wise instruction requires acc registers (4-7).")
             return

        # --- 1.5 Reject unsupported sizes (64-bit) ---
        if s_size_str == "11" or d_size_str == "11":
            print("  -> ERROR: 64-bit element-wise operations are NOT supported (ELEN=32).")
            print(f"     func4={func4}, uop={uop}, s_size={s_size_str}, d_size={d_size_str}")
            print("     Use 8/16/32-bit variants for ML workloads")
            return

        # --- 1.6 Whitelist supported func4 encodings ---
        # For integer uop=01: support basic arithmetic and shifts
        supported_int_func4 = {"0000","0001","0010","0100","0101","0110","0111","1000","1001","1010"}
        # For float uop=10: support add/sub/mul/max/min (s_size: 01 or 10)
        supported_float_func4 = {"0000","0001","0010","0011","0100"}

        # --- 2. Điều phối (Dispatch) dựa trên uop ---
        # Nhóm Integer Arithmetic 
        if uop == "01":
            if func4 not in supported_int_func4:
                print(f"  -> ERROR: Unsupported/ambiguous EW-Integer func4={func4}")
                print("     Only basic madd/msub/mmul/mmax/mmin and shifts are supported.")
                return
            print("  -> Dispatching to: EW-Integer")
            self._execute_ew_integer(instruction, func4, ctrl, md_idx, ms1_idx, ms2_idx)
        
        # Nhóm Float Arithmetic 
        elif uop == "10":
            if func4 not in supported_float_func4:
                print(f"  -> ERROR: Unsupported/ambiguous EW-Float func4={func4}")
                print("     Only mfadd/mfsub/mfmul/mfmax/mfmin are supported (fp16/fp32).")
                return
            print("  -> Dispatching to: EW-Float")
            self._execute_ew_float(instruction, func4, ctrl, md_idx, ms1_idx, ms2_idx, s_size_str, d_size_str)
        else:
            print(f"  -> ERROR: Unknown Element-Wise instruction (uop={uop})")
