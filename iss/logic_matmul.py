# iss/logic_matmul.py
# Import các hàm tiện ích từ file converters.py mới
from .converters import *

class MatmulLogic:
    def execute_matmul(self, instruction):
        """Thực thi các lệnh nhân ma trận (ĐÃ SỬA LỖI GIẢI MÃ)."""
        
        # 1. Giải mã Lệnh
        func4 = instruction[0:4]
        size_sup = instruction[6:9]
        s_size = instruction[12:14] # bits 19-18
        d_size = instruction[20:22] # bits 11-10
        ms1_idx = int(instruction[14:17], 2)
        ms2_idx = int(instruction[9:12], 2)
        md_idx = int(instruction[22:25], 2) - 4 # (acc0-3)
        tr_source1_name = f"tr{ms1_idx}"; tr_source2_name = f"tr{ms2_idx}"; acc_dest_name = f"acc{md_idx}"
        
        # 2. Xác định các thuộc tính & Hàm chuyển đổi (Converters)
        
        # Gán giá trị mặc định (cho mfmacc.s)
        float_to_source_bits = float_to_bits32
        bits_to_source_float = bits_to_float32
        float_to_dest_bits = float_to_bits32
        bits_to_dest_float = bits_to_float32
        source_bits, dest_bits = 32, 32
        instr_name, is_float_op = "mfmacc.s", True

        # --- NHÓM LỆNH FLOAT (func4 = 0000) ---
        if func4 == "0000":
            is_float_op = True
            
            # (fp8 -> bf16) s_size="00", d_size="01" - CHỈ HỖ TRỢ BF16, KHÔNG HỖ TRỢ FP16
            if s_size == "00" and d_size == "01":
                if size_sup == "100":
                    instr_name = "mfmacc.bf16.e5"
                    float_to_source_bits = float_to_bits8_e5m2
                    bits_to_source_float = bits_to_float8_e5m2
                    float_to_dest_bits = float_to_bfloat16
                    bits_to_dest_float = bfloat16_to_float
                elif size_sup == "101":
                    instr_name = "mfmacc.bf16.e4"
                    float_to_source_bits = float_to_bits8_e4m3
                    bits_to_source_float = bits_to_float8_e4m3
                    float_to_dest_bits = float_to_bfloat16
                    bits_to_dest_float = bfloat16_to_float
                else:
                    # LOẠI BỎ mfmacc.h.e5 (size_sup=000) và mfmacc.h.e4 (size_sup=001)
                    print(f"  -> ERROR: Unsupported instruction (encoding conflict)")
                    print(f"     s_size={s_size}, d_size={d_size}, size_sup={size_sup}")
                    print(f"     mfmacc.h.e5/e4 are NOT supported due to encoding conflicts!")
                    print(f"     Use mfmacc.bf16.e5/e4 instead.")
                    return
                
                source_bits, dest_bits = 8, 16

            # (fp8 -> 32-bit) s_size="00", d_size="10" - KHÔNG HỖ TRỢ DO ENCODING CONFLICT
            elif s_size == "00" and d_size == "10":
                # LOẠI BỎ mfmacc.s.e5 (size_sup=000) và mfmacc.s.e4 (size_sup=001)
                print(f"  -> ERROR: Unsupported instruction (encoding conflict)")
                print(f"     s_size={s_size}, d_size={d_size}, size_sup={size_sup}")
                print(f"     mfmacc.s.e5/e4 are NOT supported due to encoding conflicts!")
                print(f"     Use mfmacc.bf16.e5/e4 → mfmacc.s conversion if needed.")
                return
            
            # (fp16/bf16 -> fp16) s_size="01", d_size="01"
            elif s_size == "01" and d_size == "01":
                if size_sup == "000": # mfmacc.h
                    instr_name = "mfmacc.h"
                    float_to_source_bits = float_to_bits16
                    bits_to_source_float = bits_to_float16
                    float_to_dest_bits = float_to_bits16
                    bits_to_dest_float = bits_to_float16
                    source_bits, dest_bits = 16, 16
                else:
                    print(f"  -> ERROR: Unsupported instruction")
                    print(f"     s_size={s_size}, d_size={d_size}, size_sup={size_sup}")
                    print(f"     Only mfmacc.h (size_sup=000) is supported for FP16→FP16")
                    return
            
            # (fp16/bf16 -> fp32) s_size="01", d_size="10"
            elif s_size == "01" and d_size == "10":
                if size_sup == "000":
                    instr_name = "mfmacc.s.h"
                    float_to_source_bits = float_to_bits16
                    bits_to_source_float = bits_to_float16
                elif size_sup == "001":
                    instr_name = "mfmacc.s.bf16"
                    float_to_source_bits = float_to_bfloat16
                    bits_to_source_float = bfloat16_to_float
                else:
                    print(f"  -> ERROR: Unsupported instruction")
                    print(f"     s_size={s_size}, d_size={d_size}, size_sup={size_sup}")
                    print(f"     Only mfmacc.s.h and mfmacc.s.bf16 are supported")
                    return
                
                # (Đích là fp32, giữ nguyên mặc định)
                source_bits, dest_bits = 16, 32

            # (fp32 -> fp32) s_size="10", d_size="10"
            elif s_size == "10" and d_size == "10":
                if size_sup == "000": # mfmacc.s
                    instr_name = "mfmacc.s"
                    # (Tất cả mặc định đều là fp32, không cần làm gì)
                else:
                    # LOẠI BỎ mfmacc.s.tf32 (size_sup=001)
                    print(f"  -> ERROR: Unsupported instruction")
                    print(f"     s_size={s_size}, d_size={d_size}, size_sup={size_sup}")
                    print(f"     mfmacc.s.tf32 is NOT supported (TensorFloat-32 not implemented)")
                    print(f"     Use mfmacc.s (FP32) instead.")
                    return
            
            # LOẠI BỎ tất cả lệnh FP64 (d_size="11")
            elif d_size == "11":
                print(f"  -> ERROR: FP64 instructions are NOT supported")
                print(f"     s_size={s_size}, d_size={d_size}, size_sup={size_sup}")
                print(f"     mfmacc.d.s and mfmacc.d are not needed for ML workloads")
                print(f"     Use FP32 precision instead.")
                return
            
            else:
                print(f"  -> ERROR: Unknown or unsupported float instruction")
                print(f"     s_size={s_size}, d_size={d_size}, size_sup={size_sup}")
                return

        # --- NHÓM LỆNH INTEGER (func4 = 0001) ---
        elif func4 == "0001":
            is_float_op = False
            # (int8 -> int32) s_size="00", d_size="10" - CHỈ HỖ TRỢ 4 LỆNH CHUẨN
            if s_size == "00" and d_size == "10":
                if size_sup == "000":
                    instr_name = "mmaccu.w.b" 
                elif size_sup == "001":
                    instr_name = "mmaccus.w.b" 
                elif size_sup == "010":
                    instr_name = "mmaccsu.w.b" 
                elif size_sup == "011":
                    instr_name = "mmacc.w.b"
                else:
                    # LOẠI BỎ packed variants (pmmacc.*, size_sup >= 100)
                    print(f"  -> ERROR: Unsupported integer instruction")
                    print(f"     s_size={s_size}, d_size={d_size}, size_sup={size_sup}")
                    print(f"     Packed variants (pmmacc.*) are NOT supported")
                    print(f"     Use standard mmacc.w.b variants (size_sup=000-011)")
                    return
                
                source_bits, dest_bits = 8, 32
            
            # LOẠI BỎ INT16→INT64 (s_size="01", d_size="11")
            elif s_size == "01" and d_size == "11":
                print(f"  -> ERROR: INT16→INT64 instructions are NOT supported")
                print(f"     s_size={s_size}, d_size={d_size}, size_sup={size_sup}")
                print(f"     mmacc.d.h variants are not needed for neural networks")
                print(f"     Use INT8→INT32 (mmacc.w.b) instead.")
                return
            
            # LOẠI BỎ bit-packed (func4=0010)
            else:
                print(f"  -> ERROR: Unknown or unsupported integer instruction")
                print(f"     s_size={s_size}, d_size={d_size}, size_sup={size_sup}")
                return
        
        # LOẠI BỎ func4=0010 (bit-packed mmacc.w.bp)
        elif func4 == "0010":
            print(f"  -> ERROR: Bit-packed instructions are NOT supported")
            print(f"     func4={func4}, mmacc.w.bp format is unclear in spec")
            return

        # --- CÁC LỆNH KHÔNG ĐƯỢC HỖ TRỢ ---
        else:
            print(f"  -> ERROR: Unsupported instruction type")
            print(f"     func4={func4} is not recognized")
            print(f"     Only 10 safe instructions are supported (see docstring)")
            return

        # --- LƯU LẠI KIỂU DỮ LIỆU CỦA THANH GHI ĐÍCH ---
        if is_float_op:
            self.acc_dest_bits[md_idx] = dest_bits
        else:
            self.acc_dest_bits[md_idx] = 32 # Giả sử int-dest luôn là 32-bit

        # In thông tin Widen Factor
        widen_factor = dest_bits // source_bits if source_bits > 0 else 1
        print(f"  -> Executing: {instr_name} on {tr_source1_name}, {tr_source2_name} -> {acc_dest_name}")
        print(f"    - Widen Factor: {widen_factor}x ({source_bits}-bit source -> {dest_bits}-bit dest)")
        print(f"    - is_float_op: {is_float_op}")

        # 3. Đọc Trạng thái
        M = self.csr_ref.read('mtilem')
        N = self.csr_ref.read('mtilen')
        K = self.csr_ref.read('mtilek')
        if M*N*K == 0: 
            print("  [Warning] Tile dimensions are zero. Skipping.")
            return

        # Đọc mảng đầy đủ từ RAM
        if is_float_op:
            mat_A_full = self.tr_float[ms1_idx]
            mat_B_full = self.tr_float[ms2_idx]
            mat_C_old = self.acc_float[md_idx]
        else:
            mat_A_full = self.tr_int[ms1_idx]
            mat_B_full = self.tr_int[ms2_idx]
            mat_C_old = self.acc_int[md_idx]
        
# 4. Thực hiện Tính toán (MÔ PHỎNG ĐỘ CHÍNH XÁC)
        mat_C_new = [[mat_C_old[r][c] for c in range(N)] for r in range(M)]
        print("    - Starting computation loop (with precision simulation)...")
        for m in range(M):
            for n in range(N):
                if is_float_op:
                    c_old_bits = float_to_dest_bits(mat_C_old[m][n])
                    c_old_quantized = bits_to_dest_float(c_old_bits)
                else:
                    c_old_quantized = float(int(mat_C_old[m][n]))

                dot_product = 0.0
                for k in range(K):
                    a_full_precision = mat_A_full[m][k]
                    b_full_precision = mat_B_full[n][k]

                    if is_float_op:
                        a_bits = float_to_source_bits(a_full_precision)
                        b_bits = float_to_source_bits(b_full_precision)
                        a_quantized = bits_to_source_float(a_bits)
                        b_quantized = bits_to_source_float(b_bits)
                        dot_product += a_quantized * b_quantized
                    else:
                        # LOGIC SIGNED/UNSIGNED
                        a_int8 = int(a_full_precision) & 0xFF
                        b_int8 = int(b_full_precision) & 0xFF
                        
                        a_val = 0
                        b_val = 0

                        # Kiểm tra instr_name để quyết định kiểu dữ liệu
                        if instr_name == "mmaccu.w.b": # unsigned * unsigned
                            a_val = a_int8
                            b_val = b_int8
                        elif instr_name == "mmaccus.w.b": # unsigned * signed
                            a_val = a_int8
                            b_val = b_int8 - 256 if b_int8 > 127 else b_int8
                        elif instr_name == "mmaccsu.w.b": # signed * unsigned
                            a_val = a_int8 - 256 if a_int8 > 127 else a_int8
                            b_val = b_int8
                        else: # Mặc định là 'mmacc.w.b' (signed * signed)
                            a_val = a_int8 - 256 if a_int8 > 127 else a_int8
                            b_val = b_int8 - 256 if b_int8 > 127 else b_int8
                            
                        dot_product += a_val * b_val

                # Cập nhật thanh ghi tích lũy (ACC)
                if not is_float_op:
                    mat_C_new[m][n] = c_old_quantized + dot_product # (int add)
                else: 
                    c_new_full = c_old_quantized + dot_product
                    c_new_bits = float_to_dest_bits(c_new_full)
                    c_new_quantized = bits_to_dest_float(c_new_bits)
                    mat_C_new[m][n] = c_new_quantized
        
        print(f"    - Computation complete.")

        # 5. Ghi Trạng thái Mới
        if is_float_op:
            self.acc_float[md_idx] = mat_C_new
        else:
            self.acc_int[md_idx] = mat_C_new
            
        print(f"    - {acc_dest_name} (in RAM) updated.")
