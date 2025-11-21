# iss/logic_loadstore.py
import struct
from typing import TYPE_CHECKING
from .definitions import ROWNUM, ELEMENTS_PER_ROW_TR
# Import utility functions
from .converters import bits_to_float16, float_to_bits16, bits_to_float32, float_to_bits32

if TYPE_CHECKING:
    from typing import List
    from .components import RegisterFile, MainMemory

class LoadStoreLogic:
    """
    Mixin class for load/store operations.
    
    Expected attributes (provided by MatrixAccelerator):
        - tr_int: List[List[List[int]]] - Tile registers (integer)
        - tr_float: List[List[List[float]]] - Tile registers (float)
        - acc_int: List[List[List[int]]] - Accumulator registers (integer)
        - acc_float: List[List[List[float]]] - Accumulator registers (float)
        - gpr_ref: RegisterFile - Reference to GPR registers
        - memory: MainMemory - Reference to main memory
        - rownum: int - Number of rows in matrix
        - elements_per_row_tr: int - Elements per row in TR
    """

    def _bytes_to_value(self, byte_data, format_type):
        """
        Convert bytes to value based on format_type.
        format_type: 'i8', 'f16', 'f32'
        """
        if format_type == 'i8':
            # 8-bit signed integer
            return struct.unpack('<b', byte_data)[0]  # little-endian signed byte
        elif format_type == 'f16':
            # 16-bit float - convert via bits
            bits = struct.unpack('<H', byte_data)[0]  # little-endian unsigned short
            return bits_to_float16(bits)
        elif format_type == 'f32':
            # 32-bit float
            return struct.unpack('<f', byte_data)[0]  # little-endian float
        else:
            raise ValueError(f"Unknown format_type: {format_type}")
    
    def _value_to_bytes(self, value, format_type):
        """
        Convert value to bytes based on format_type.
        """
        if format_type == 'i8':
            return struct.pack('<b', int(value))
        elif format_type == 'f16':
            bits = float_to_bits16(value)
            return struct.pack('<H', bits)
        elif format_type == 'f32':
            return struct.pack('<f', value)
        else:
            raise ValueError(f"Unknown format_type: {format_type}")

    def _get_eew_and_format(self, d_size_str, is_float=True):
        """
        Helper: Get EEW (bits), number of bytes, and format info.
        ONLY SUPPORTS 8/16/32-bit. 64-bit CONFLICTS WITH ELEN=32.
        Returns: (eew, num_bytes, format_type)
        format_type: 'i8', 'f16', 'f32' to determine unpacking method
        
        Returns:
            tuple: (int | None, int | None, str | None)
        """
        if d_size_str == "00": 
            return 8, 1, 'i8'  # 8-bit signed integer
        elif d_size_str == "01": 
            return 16, 2, 'f16'  # 16-bit float (FP16) - requires custom conversion
        elif d_size_str == "10": 
            return 32, 4, 'f32'  # 32-bit float
        elif d_size_str == "11":
            # ERROR: 64-bit not supported
            return None, None, None
        else:
            raise ValueError(f"Invalid d_size: {d_size_str}")

    def execute_load_store(self, instruction):
        """
        Execute Load/Store instructions.
        ONLY SUPPORTS 32 INSTRUCTIONS (func4=0000-0110, d_size=00/01/10).
        """
        
        # --- 1. Decode ---
        func4      = instruction[0:4]
        ls_bit     = instruction[6]
        rs2_bin    = instruction[7:12]
        rs1_bin    = instruction[12:17]
        md_ms3_bin = instruction[22:25]
        d_size_str = instruction[20:22]
        
        # --- 2. Check d_size first (reject 64-bit immediately) ---
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
        
        # --- 3. Check whole register operations (func4=0011) ---
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
        
        # --- 4. Get values ---
        base_addr  = self.gpr_ref.read(int(rs1_bin, 2))
        row_stride = self.gpr_ref.read(int(rs2_bin, 2))
        reg_idx    = int(md_ms3_bin, 2)
        
        # 8-bit is int, 16/32-bit is float
        is_float = (d_size_str != "00")
        eew, num_bytes, format_type = self._get_eew_and_format(d_size_str, is_float)
        
        # Check if valid (should not happen due to earlier checks, but for type safety)
        if num_bytes is None or format_type is None:
            print(f"  -> ERROR: Invalid data size configuration")
            return

        # --- 5. Read CSRs to get Tile dimensions ---
        M = self.csr_ref.read('mtilem')
        N = self.csr_ref.read('mtilen')
        K = self.csr_ref.read('mtilek')

        is_load = (ls_bit == '0')
        
        # --- 6. Dispatch logic based on func4 ---
        
        # mlae8/16/32 / msae8/16/32 (Matrix A, non-transposed)
        if func4 == "0000":
            if reg_idx > 3: raise ValueError("Invalid register for mlae/msae (must be tr0-tr3)")
            rows, cols = M, K
            target_reg = self.tr_float[reg_idx] if is_float else self.tr_int[reg_idx]
            
            # Instruction name based on d_size
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
                        val = self._bytes_to_value(byte_data, format_type)
                        target_reg[i][j] = val
                    else: # Store
                        val = target_reg[i][j]
                        byte_data = self._value_to_bytes(val, format_type)
                        self.memory.write(mem_addr, byte_data)
                        if i == 0 and j == 0:
                            print(f"     [Debug] Stored [{i},{j}] to 0x{mem_addr:X}: val={val}, bytes={byte_data.hex() if isinstance(byte_data, (bytes, bytearray)) else 'NOT_BYTES'}")

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
                        val = self._bytes_to_value(byte_data, format_type)
                        target_reg[i][j] = val
                    else: # Store
                        val = target_reg[i][j]
                        byte_data = self._value_to_bytes(val, format_type)
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
            # Column-major layout: iterate columns first, then elements within column
            for j in range(cols):  # For each column
                for i in range(rows):  # For each element in column
                    mem_addr = base_addr + (j * row_stride) + (i * num_bytes)
                    if is_load:
                        byte_data = self.memory.read(mem_addr, num_bytes)
                        val = self._bytes_to_value(byte_data, format_type)
                        target_reg[i][j] = val
                    else: # Store
                        val = target_reg[i][j]
                        byte_data = self._value_to_bytes(val, format_type)
                        self.memory.write(mem_addr, byte_data)

        # mlate8/16/32 / msate8/16/32 (Matrix A, Transposed)
        elif func4 == "0100":
            if reg_idx > 3: raise ValueError("Invalid register for mlate/msate (must be tr0-tr3)")
            rows, cols = M, K # Register dimensions (M x K)
            target_reg = self.tr_float[reg_idx] if is_float else self.tr_int[reg_idx]
            
            instr_suffix = {
                "00": "8",
                "01": "16", 
                "10": "32"
            }[d_size_str]
            instr_name = f"{'mla' if is_load else 'msa'}te{instr_suffix}"
            
            print(f"  -> Executing {instr_name} (M={M}, K={K}, Transposed, element_size={eew}-bit)")
            for i in range(rows): # Loop through M
                for j in range(cols): # Loop through K
                    # Read/Write column-wise (K x M) in memory
                    mem_addr = base_addr + (j * row_stride) + (i * num_bytes)
                    if is_load:
                        byte_data = self.memory.read(mem_addr, num_bytes)
                        val = self._bytes_to_value(byte_data, format_type)
                        target_reg[i][j] = val
                    else: # Store
                        val = target_reg[i][j]
                        byte_data = self._value_to_bytes(val, format_type)
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
                        val = self._bytes_to_value(byte_data, format_type)
                        target_reg[i][j] = val
                    else: # Store
                        val = target_reg[i][j]
                        byte_data = self._value_to_bytes(val, format_type)
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
                        val = self._bytes_to_value(byte_data, format_type)
                        target_reg[i][j] = val
                    else: # Store
                        val = target_reg[i][j]
                        byte_data = self._value_to_bytes(val, format_type)
                        self.memory.write(mem_addr, byte_data)
        
        else:
            print(f"  -> ERROR: Unknown or unsupported Load/Store instruction")
            print(f"     func4={func4}, ls={'Load' if ls_bit=='0' else 'Store'}, d_size={d_size_str}")
            print(f"     Only func4=0000-0110 (with d_size=00/01/10) are supported")
            print(f"     See loadstore_analysis.md for details")