# iss/logic_loadstore.py
import struct
from .definitions import ROWNUM, ELEMENTS_PER_ROW_TR
# Import các hàm tiện ích
from .converters import bits_to_float16, float_to_bits16, bits_to_float32, float_to_bits32

class LoadStoreLogic:

    def _get_eew_and_format(self, d_size_str, is_float=True):
        """
        Helper: Lấy EEW (bit), số byte, và chuỗi format của 'struct'.
        CHỈ HỖ TRỢ 8/16/32-bit. 64-bit MÂU THUẪN VỚI ELEN=32.
        """
        if d_size_str == "00": 
            return 8, 1, 'b'  # 8-bit (signed byte, INT8)
        elif d_size_str == "01": 
            return 16, 2, 'e'  # 16-bit (FP16/BF16)
        elif d_size_str == "10": 
            return 32, 4, 'f'  # 32-bit (FP32)
        elif d_size_str == "11":
            # ERROR: 64-bit không được hỗ trợ
            return None, None, None
        else:
            raise ValueError(f"Invalid d_size: {d_size_str}")

    def execute_load_store(self, instruction):
        """
        Thực thi các lệnh Load/Store.
        CHỈ HỖ TRỢ 32 LỆNH (func4=0000-0110, d_size=00/01/10).
        """
        
        # --- 1. Giải mã ---
        func4      = instruction[0:4]
        ls_bit     = instruction[6]
        rs2_bin    = instruction[7:12]
        rs1_bin    = instruction[12:17]
        md_ms3_bin = instruction[22:25]
        d_size_str = instruction[20:22]
        
        # --- 2. Kiểm tra d_size trước (reject 64-bit ngay lập tức) ---
        if d_size_str == "11":
            print(f"  -> ERROR: 64-bit load/store is NOT supported")
            print(f"     Reason: ELEN=32, but instruction requests 64-bit elements")
            print(f"     func4={func4}, ls={'Load' if ls_bit=='0' else 'Store'}, d_size={d_size_str}")
            if func4 == "0000":
                print(f"     Instruction: {'mlae64' if ls_bit=='0' else 'msae64'}")
            elif func4 == "0001":
                print(f"     Instruction: {'mlbe64' if ls_bit=='0' else 'msbe64'}")
            elif func4 == "0010":
                print(f"     Instruction: {'mlce64' if ls_bit=='0' else 'msce64'}")
            elif func4 == "0011":
                print(f"     Instruction: {'mlme64' if ls_bit=='0' else 'msme64'}")
            elif func4 == "0100":
                print(f"     Instruction: {'mlate64' if ls_bit=='0' else 'msate64'}")
            elif func4 == "0101":
                print(f"     Instruction: {'mlbte64' if ls_bit=='0' else 'msbte64'}")
            elif func4 == "0110":
                print(f"     Instruction: {'mlcte64' if ls_bit=='0' else 'mscte64'}")
            print(f"     Neural networks do not use FP64/INT64")
            print(f"     Use 32-bit (FP32) for training, 8/16-bit for inference")
            return
        
        # --- 3. Kiểm tra whole register operations (func4=0011) ---
        if func4 == "0011":
            print(f"  -> ERROR: Whole register load/store (mlme*/msme*) is NOT supported")
            print(f"     func4={func4}, ls={'Load' if ls_bit=='0' else 'Store'}, d_size={d_size_str}")
            if d_size_str == "00":
                print(f"     Instruction: {'mlme8' if ls_bit=='0' else 'msme8'}")
            elif d_size_str == "01":
                print(f"     Instruction: {'mlme16' if ls_bit=='0' else 'msme16'}")
            elif d_size_str == "10":
                print(f"     Instruction: {'mlme32' if ls_bit=='0' else 'msme32'}")
            print(f"     Reason: Spec unclear about memory layout and semantics")
            print(f"     Use mlae*/mlbe*/mlce* for matrix load/store instead")
            return
        
        # --- 4. Lấy các giá trị ---
        base_addr  = self.gpr_ref.read(int(rs1_bin, 2))
        row_stride = self.gpr_ref.read(int(rs2_bin, 2))
        reg_idx    = int(md_ms3_bin, 2)
        
        # 8-bit là int, 16/32-bit là float
        is_float = (d_size_str != "00")
        eew, num_bytes, fmt = self._get_eew_and_format(d_size_str, is_float)

        # --- 5. Đọc CSRs để lấy Kích thước Tile ---
        M = self.csr_ref.read('mtilem')
        N = self.csr_ref.read('mtilen')
        K = self.csr_ref.read('mtilek')

        is_load = (ls_bit == '0')
        
        # --- 6. Logic điều phối (Dispatch) dựa trên func4 ---
        
        # mlae8/16/32 / msae8/16/32 (Matrix A, non-transposed)
        if func4 == "0000":
            if reg_idx > 3: raise ValueError("Invalid register for mlae/msae (must be tr0-tr3)")
            rows, cols = M, K
            target_reg = self.tr_float[reg_idx] if is_float else self.tr_int[reg_idx]
            
            # Tên lệnh dựa trên d_size
            instr_suffix = {
                "00": "8",
                "01": "16", 
                "10": "32"
            }[d_size_str]
            instr_name = f"{'mla' if is_load else 'msa'}e{instr_suffix}"
            
            print(f"  -> Executing {instr_name} (M={M}, K={K}, element_size={eew}-bit)")
            for i in range(rows):
                for j in range(cols):
                    mem_addr = base_addr + (i * row_stride) + (j * num_bytes)
                    if is_load:
                        byte_data = self.memory.read(mem_addr, num_bytes)
                        val = struct.unpack(fmt, byte_data)[0]
                        target_reg[i][j] = val
                    else: # Store
                        val = target_reg[i][j]
                        byte_data = struct.pack(fmt, val)
                        self.memory.write(mem_addr, byte_data)

        # mlbe8/16/32 / msbe8/16/32 (Matrix B, non-transposed)
        elif func4 == "0001":
            if reg_idx > 3: raise ValueError("Invalid register for mlbe/msbe (must be tr0-tr3)")
            rows, cols = N, K
            target_reg = self.tr_float[reg_idx] if is_float else self.tr_int[reg_idx]
            
            instr_suffix = {
                "00": "8",
                "01": "16", 
                "10": "32"
            }[d_size_str]
            instr_name = f"{'mlb' if is_load else 'msb'}e{instr_suffix}"
            
            print(f"  -> Executing {instr_name} (N={N}, K={K}, element_size={eew}-bit)")
            for i in range(rows):
                for j in range(cols):
                    mem_addr = base_addr + (i * row_stride) + (j * num_bytes)
                    if is_load:
                        byte_data = self.memory.read(mem_addr, num_bytes)
                        val = struct.unpack(fmt, byte_data)[0]
                        target_reg[i][j] = val
                    else: # Store
                        val = target_reg[i][j]
                        byte_data = struct.pack(fmt, val)
                        self.memory.write(mem_addr, byte_data)

        # mlce8/16/32 / msce8/16/32 (Matrix C, non-transposed)
        elif func4 == "0010":
            if reg_idx < 4: raise ValueError("Invalid register for mlce/msce (must be acc0-acc3)")
            rows, cols = M, N
            target_reg = self.acc_float[reg_idx - 4] if is_float else self.acc_int[reg_idx - 4]
            
            instr_suffix = {
                "00": "8",
                "01": "16", 
                "10": "32"
            }[d_size_str]
            instr_name = f"{'mlc' if is_load else 'msc'}e{instr_suffix}"
            
            print(f"  -> Executing {instr_name} (M={M}, N={N}, element_size={eew}-bit)")
            for i in range(rows):
                for j in range(cols):
                    mem_addr = base_addr + (i * row_stride) + (j * num_bytes)
                    if is_load:
                        byte_data = self.memory.read(mem_addr, num_bytes)
                        val = struct.unpack(fmt, byte_data)[0]
                        target_reg[i][j] = val
                    else: # Store
                        val = target_reg[i][j]
                        byte_data = struct.pack(fmt, val)
                        self.memory.write(mem_addr, byte_data)

        # mlate8/16/32 / msate8/16/32 (Matrix A, Transposed)
        elif func4 == "0100":
            if reg_idx > 3: raise ValueError("Invalid register for mlate/msate (must be tr0-tr3)")
            rows, cols = M, K # Kích thước thanh ghi (M x K)
            target_reg = self.tr_float[reg_idx] if is_float else self.tr_int[reg_idx]
            
            instr_suffix = {
                "00": "8",
                "01": "16", 
                "10": "32"
            }[d_size_str]
            instr_name = f"{'mla' if is_load else 'msa'}te{instr_suffix}"
            
            print(f"  -> Executing {instr_name} (M={M}, K={K}, Transposed, element_size={eew}-bit)")
            for i in range(rows): # Lặp qua M
                for j in range(cols): # Lặp qua K
                    # Đọc/Ghi theo cột (K x M) trong memory
                    mem_addr = base_addr + (j * row_stride) + (i * num_bytes)
                    if is_load:
                        byte_data = self.memory.read(mem_addr, num_bytes)
                        val = struct.unpack(fmt, byte_data)[0]
                        target_reg[i][j] = val
                    else: # Store
                        val = target_reg[i][j]
                        byte_data = struct.pack(fmt, val)
                        self.memory.write(mem_addr, byte_data)

        # mlbte8/16/32 / msbte8/16/32 (Matrix B, Transposed)
        elif func4 == "0101":
            if reg_idx > 3: raise ValueError("Invalid register for mlbte/msbte (must be tr0-tr3)")
            rows, cols = N, K
            target_reg = self.tr_float[reg_idx] if is_float else self.tr_int[reg_idx]
            
            instr_suffix = {
                "00": "8",
                "01": "16", 
                "10": "32"
            }[d_size_str]
            instr_name = f"{'mlb' if is_load else 'msb'}te{instr_suffix}"
            
            print(f"  -> Executing {instr_name} (N={N}, K={K}, Transposed, element_size={eew}-bit)")
            for i in range(rows): # Lặp qua N
                for j in range(cols): # Lặp qua K
                    mem_addr = base_addr + (j * row_stride) + (i * num_bytes)
                    if is_load:
                        byte_data = self.memory.read(mem_addr, num_bytes)
                        val = struct.unpack(fmt, byte_data)[0]
                        target_reg[i][j] = val
                    else: # Store
                        val = target_reg[i][j]
                        byte_data = struct.pack(fmt, val)
                        self.memory.write(mem_addr, byte_data)

        # mlcte8/16/32 / mscte8/16/32 (Matrix C, Transposed)
        elif func4 == "0110":
            if reg_idx < 4: raise ValueError("Invalid register for mlcte/mscte (must be acc0-acc3)")
            rows, cols = M, N
            target_reg = self.acc_float[reg_idx - 4] if is_float else self.acc_int[reg_idx - 4]
            
            instr_suffix = {
                "00": "8",
                "01": "16", 
                "10": "32"
            }[d_size_str]
            instr_name = f"{'mlc' if is_load else 'msc'}te{instr_suffix}"
            
            print(f"  -> Executing {instr_name} (M={M}, N={N}, Transposed, element_size={eew}-bit)")
            for i in range(rows): # Lặp qua M
                for j in range(cols): # Lặp qua N
                    mem_addr = base_addr + (j * row_stride) + (i * num_bytes)
                    if is_load:
                        byte_data = self.memory.read(mem_addr, num_bytes)
                        val = struct.unpack(fmt, byte_data)[0]
                        target_reg[i][j] = val
                    else: # Store
                        val = target_reg[i][j]
                        byte_data = struct.pack(fmt, val)
                        self.memory.write(mem_addr, byte_data)
        
        else:
            print(f"  -> ERROR: Unknown or unsupported Load/Store instruction")
            print(f"     func4={func4}, ls={'Load' if ls_bit=='0' else 'Store'}, d_size={d_size_str}")
            print(f"     Only func4=0000-0110 (with d_size=00/01/10) are supported")
            print(f"     See loadstore_analysis.md for details")