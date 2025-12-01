# iss/logic_misc.py
import struct
from typing import TYPE_CHECKING

# Import các hàm tiện ích (nếu bạn đã tách chúng ra 'converters.py')
from .converters import (
    bits_to_float16, float_to_bits16,
    bits_to_float32, float_to_bits32,
    bits_to_signed_int8, bits_to_signed_int32
)

if TYPE_CHECKING:
    # Type hints for Pylance - these attributes come from MatrixAccelerator
    from typing import Any, List

class MiscLogic:
    """
    Mixin class for miscellaneous matrix operations.
    
    Expected attributes (provided by MatrixAccelerator):
        - tr_int: List[List[List[int]]] - Tile registers (integer)
        - tr_float: List[List[List[float]]] - Tile registers (float)
        - acc_int: List[List[List[int]]] - Accumulator registers (integer)
        - acc_float: List[List[List[float]]] - Accumulator registers (float)
        - gpr_ref: RegisterFile - Reference to GPR registers
        - csr_ref: CSRFile - Reference to CSR registers
        - memory: MainMemory - Reference to main memory
        - rownum: int - Number of rows in matrix
        - elements_per_row_tr: int - Elements per row in TR
        - elements_per_row_acc: int - Elements per row in ACC
    """

    # --- HÀM HELPER ĐỂ XỬ LÝ THANH GHI (TR/ACC) ---

    def _get_reg_array_by_idx(self, reg_idx, is_float=False):
        """Helper: Gets the correct register array (tr/acc, int/float) based on a 0-7 index.
        SPECS: tr0-tr3 = acc0-acc3 (alias), tr4-tr7 = pure tile registers"""
        if reg_idx < 4: # Accumulation Register (acc0-acc3, aka tr0-tr3)
            return self.acc_float[reg_idx] if is_float else self.acc_int[reg_idx]
        else: # Tile Register (tr4-tr7)
            return self.get_matrix_reg_float(reg_idx) if is_float else self.get_matrix_reg_int(reg_idx)

    def _get_reg_dims_by_idx(self, reg_idx):
        """Helper: Gets (rows, cols) for a register index 0-7."""
        if reg_idx < 4: # Accumulator Register (acc0-acc3, aka tr0-tr3)
            return (self.rownum, self.elements_per_row_acc)
        else: # Tile Register (tr4-tr7)
            return (self.rownum, self.elements_per_row_tr)
    
    def _zero_register(self, reg_idx):
        """Helper: Zeros out all elements of a given register (both int and float views).
        SPECS: tr0-tr3 = acc0-acc3 (alias), only tr4-tr7 are separate tile registers"""
        # Lấy kích thước vật lý của thanh ghi
        acc_rows, acc_cols = self._get_reg_dims_by_idx(0) # Kích thước ACC (index 0-3)
        tr_rows, tr_cols = self._get_reg_dims_by_idx(4)   # Kích thước TR (index 4-7)
        
        if reg_idx < 4: # acc0-acc3 (aka tr0-tr3)
            self.acc_int[reg_idx]   = [[0] * acc_cols for _ in range(acc_rows)]
            self.acc_float[reg_idx] = [[0.0] * acc_cols for _ in range(acc_rows)]
        else: # tr4-tr7 only
            idx = reg_idx - 4
            self.tr_int[idx]   = [[0] * tr_cols for _ in range(tr_rows)]
            self.tr_float[idx] = [[0.0] * tr_cols for _ in range(tr_rows)]

    # --- CÁC HÀM THỰC THI CON (SUB-EXECUTORS) ---

    def _exec_mzero(self, md_idx, ctrl_imm3):
        """Thực thi CHỈ mzero (loại bỏ mzero2r/4r/8r)"""
        if ctrl_imm3 != 0b000:
            print(f"  -> ERROR: Only mzero (ctrl=000) is supported")
            print(f"     ctrl={ctrl_imm3:03b}")
            print(f"     mzero2r/4r/8r are NOT supported (optimization variants)")
            print(f"     Use multiple mzero instructions instead")
            return
        
        print(f"    - Executing mzero (md={md_idx})")
        self._zero_register(md_idx)

    def _exec_mmov_mm(self, md_idx, ms1_idx, s_size_str, d_size_str):
        """Thực thi mmov.mm md, ms1."""
        print(f"    - Executing mmov.mm (md={md_idx}, ms1={ms1_idx})")
        
        rows_ms1, cols_ms1 = self._get_reg_dims_by_idx(ms1_idx)
        rows_md, cols_md = self._get_reg_dims_by_idx(md_idx)
        
        # Kích thước hiệu dụng là kích thước nhỏ nhất
        rows = min(rows_ms1, rows_md)
        cols = min(cols_ms1, cols_md)
        
        # mmov.mm copies entire matrix - copy both int and float views
        # to maintain data integrity regardless of how data is interpreted
        src_int = self._get_reg_array_by_idx(ms1_idx, is_float=False)
        src_float = self._get_reg_array_by_idx(ms1_idx, is_float=True)
        dest_int = self._get_reg_array_by_idx(md_idx, is_float=False)
        dest_float = self._get_reg_array_by_idx(md_idx, is_float=True)
        
        for i in range(rows):
            for j in range(cols):
                dest_int[i][j] = src_int[i][j]
                dest_float[i][j] = src_float[i][j]

    def _exec_mmov_x_m(self, rd_idx, ms2_idx, rs1_val, ctrl_size):
        """Thực thi CHỈ mmovw.x.m (loại bỏ mmovb/h/d.x.m)"""
        # CHỈ hỗ trợ FP32 (ctrl_size=10)
        if ctrl_size != 0b10:
            print(f"  -> ERROR: Only mmovw.x.m (32-bit) is supported")
            print(f"     ctrl_size={ctrl_size:02b}")
            if ctrl_size == 0b00:
                print(f"     mmovb.x.m (8-bit) is NOT supported")
            elif ctrl_size == 0b01:
                print(f"     mmovh.x.m (16-bit) is NOT supported")
            elif ctrl_size == 0b11:
                print(f"     mmovd.x.m (64-bit) has ENCODING CONFLICT with mmovb.x.m!")
            print(f"     Use mmovw.x.m (FP32) only")
            return
        
        eew = 32
        print(f"    - Executing mmovw.x.m (rd={rd_idx}, ms2={ms2_idx}, rs1_val={rs1_val})")
        
        src_array = self._get_reg_array_by_idx(ms2_idx, is_float=True)
        rows, cols_phys = self._get_reg_dims_by_idx(ms2_idx)
        
        # Tính toán index từ rs1 
        elements_per_row_logical = cols_phys # FP32: 1 element per physical slot
        row_idx = rs1_val // elements_per_row_logical
        col_idx = rs1_val % elements_per_row_logical
        
        if row_idx >= rows:
            print(f"    [Warning] mmovw.x.m index (row={row_idx}) out of bounds")
            return

        val_to_write = float_to_bits32(src_array[row_idx][col_idx])
        self.gpr_ref.write(rd_idx, val_to_write)

    def _exec_mmov_m_x_or_mdup(self, md_idx, rs2_val, rs1_val, ctrl_bit_25, d_size_str):
        """Thực thi CHỈ mmovw.m.x hoặc mdupw.m.x (loại bỏ 8/16/64-bit variants)"""
        # CHỈ hỗ trợ FP32 (d_size=10)
        if d_size_str != "10":
            print(f"  -> ERROR: Only FP32 (32-bit) operations are supported")
            print(f"     d_size={d_size_str}")
            if d_size_str == "00":
                print(f"     mmovb/mdupb.m.x (8-bit) are NOT supported")
            elif d_size_str == "01":
                print(f"     mmovh/mduph.m.x (16-bit) are NOT supported")
            elif d_size_str == "11":
                print(f"     mmovd/mdupd.m.x (64-bit) are NOT supported")
            print(f"     Use mmovw/mdupw.m.x (FP32) only")
            return
        
        eew = 32
        dest_array = self._get_reg_array_by_idx(md_idx, is_float=True)
        rows, cols_phys = self._get_reg_dims_by_idx(md_idx)

        if ctrl_bit_25 == '1': # mmovw.m.x: Ghi 1 phần tử 
            print(f"    - Executing mmovw.m.x (md={md_idx}, rs1_val={rs1_val})")
            elements_per_row = cols_phys # FP32: 1 element per slot
            row_idx = rs1_val // elements_per_row
            col_idx = rs1_val % elements_per_row

            if row_idx >= rows:
                print(f"    [Warning] mmovw.m.x index (row={row_idx}) out of bounds")
                return

            dest_array[row_idx][col_idx] = bits_to_float32(rs2_val)

        else: # mdupw.m.x: Sao chép rs2 ra toàn bộ thanh ghi
            print(f"    - Executing mdupw.m.x (md={md_idx})")
            val = bits_to_float32(rs2_val)
            for i in range(rows):
                for j in range(cols_phys):
                    dest_array[i][j] = val

    def _exec_slide(self, md_idx, ms1_idx, imm3, slide_type):
        """
        Thực thi slide operations (mrslidedown, mcslidedown.w)
        slide_type: 'row_down', 'col_down'
        """
        print(f"    - Executing {slide_type} (md={md_idx}, ms1={ms1_idx}, imm3={imm3})")
        
        src_array = self._get_reg_array_by_idx(ms1_idx, is_float=True)
        dest_array = self._get_reg_array_by_idx(md_idx, is_float=True)
        rows, cols = self._get_reg_dims_by_idx(md_idx)
        
        if slide_type == 'row_down':
            # Slide rows down by imm3 positions
            for i in range(rows):
                src_row = (i - imm3) % rows
                for j in range(cols):
                    dest_array[i][j] = src_array[src_row][j]
        
        elif slide_type == 'col_down':
            # Slide columns down by imm3 positions
            for i in range(rows):
                for j in range(cols):
                    src_col = (j - imm3) % cols
                    dest_array[i][j] = src_array[i][src_col]

    # --- HÀM DISPATCHER CHÍNH ---
    def execute_misc(self, instruction):
        """
        Giải mã và điều phối các lệnh MISC (func3=000, uop=11).
        CHỈ HỖ TRỢ 7 LỆNH CỐT LÕI.
        """
        # 1. Giải mã các trường bit
        func4       = instruction[0:4]
        uop         = instruction[4:6]
        ctrl_imm3_bin = instruction[6:9]     # bits 25-23
        ctrl_bit_25 = instruction[6]
        ctrl_size_xm = int(instruction[7:9], 2) # bits 24-23 for mmov.x.m
        
        ms2_bin     = instruction[9:12]
        s_size_str  = instruction[12:14]
        ms1_bin     = instruction[14:17]
        rs1_bin     = instruction[12:17]     # GPR rs1
        d_size_str  = instruction[20:22]
        rd_bin      = instruction[20:25]     # GPR rd
        md_bin      = instruction[22:25]
        rs2_bin_gpr = instruction[7:12]      # GPR rs2

        # 2. Chuyển đổi các giá trị
        ctrl_imm3 = int(ctrl_imm3_bin, 2)
        md_idx    = int(md_bin, 2)
        ms1_idx   = int(ms1_bin, 2)
        ms2_idx   = int(ms2_bin, 2)
        rd_idx    = int(rd_bin, 2)
        rs1_val   = self.gpr_ref.read(int(rs1_bin, 2))
        rs2_val   = self.gpr_ref.read(int(rs2_bin_gpr, 2))
        
        # 3. Điều phối (Dispatch) - CHỈ 7 LỆNH
        
        # Lệnh 1: mzero
        if func4 == "0000" and uop == "11": 
            self._exec_mzero(md_idx, ctrl_imm3)
        
        # Lệnh 2: mmov.mm
        elif func4 == "0001" and uop == "11": 
            self._exec_mmov_mm(md_idx, ms1_idx, s_size_str, d_size_str)
            
        # Lệnh 5: mmovw.x.m
        elif func4 == "0010" and uop == "11": 
            self._exec_mmov_x_m(rd_idx, ms2_idx, rs1_val, ctrl_size_xm)
            
        # Lệnh 3,4: mmovw.m.x or mdupw.m.x
        elif func4 == "0011" and uop == "11": 
            self._exec_mmov_m_x_or_mdup(md_idx, rs2_val, rs1_val, ctrl_bit_25, d_size_str)
        
        # Lệnh 6: mrslidedown
        elif func4 == "0101" and uop == "11":
            if s_size_str == "00" and d_size_str == "00":
                self._exec_slide(md_idx, ms1_idx, ctrl_imm3, 'row_down')
            else:
                print(f"  -> ERROR: Only mrslidedown (s_size=00, d_size=00) is supported")
                print(f"     s_size={s_size_str}, d_size={d_size_str}")
                print(f"     mrslideup is NOT supported (use mrslidedown instead)")
                return
        
        # Lệnh 7: mcslidedown.w
        elif func4 == "0111" and uop == "11":
            if s_size_str == "10" and d_size_str == "10":
                self._exec_slide(md_idx, ms1_idx, ctrl_imm3, 'col_down')
            else:
                print(f"  -> ERROR: Only mcslidedown.w (FP32, s_size=10, d_size=10) is supported")
                print(f"     s_size={s_size_str}, d_size={d_size_str}")
                if s_size_str == "00":
                    print(f"     mcslidedown.b (8-bit) is NOT supported")
                elif s_size_str == "01":
                    print(f"     mcslidedown.h (16-bit) is NOT supported")
                elif s_size_str == "11":
                    print(f"     mcslidedown.d (64-bit) is NOT supported")
                print(f"     Use mcslidedown.w (FP32) only")
                return
        
        # LOẠI BỎ các lệnh không được hỗ trợ
        elif func4 == "0100" and uop == "11":
            print(f"  -> ERROR: Pack operations (mpack*) are NOT supported")
            print(f"     func4={func4}, uop={uop}")
            print(f"     Not needed for standard neural networks")
            return
        
        elif func4 == "0101" and uop == "10":
            print(f"  -> ERROR: mbce8 broadcast is NOT supported")
            print(f"     func4={func4}, uop={uop}")
            print(f"     Use mdupw.m.x for broadcasting")
            return
        
        elif func4 == "0110":
            if uop == "10":
                print(f"  -> ERROR: mrbc.mv.i broadcast is NOT supported")
                print(f"     Use mdupw.m.x for broadcasting")
                return
            elif uop == "11":
                print(f"  -> ERROR: mrslideup is NOT supported")
                print(f"     Use mrslidedown with appropriate offset")
                return
        
        elif func4 == "0111" and uop == "10":
            print(f"  -> ERROR: mcbce8.mv.i broadcast is NOT supported")
            print(f"     Use mdupw.m.x for broadcasting")
            return
        
        elif func4 == "1000" and uop == "11":
            print(f"  -> ERROR: mcslideup.* operations are NOT supported")
            print(f"     Use mcslidedown.w with appropriate offset")
            return
        
        elif func4 == "1001" or func4 == "1010":
            print(f"  -> ERROR: Advanced broadcast operations (mrbca, mcbca*) are NOT supported")
            print(f"     func4={func4}")
            print(f"     Use mdupw.m.x for broadcasting")
            return
        
        else:
            print(f"  -> ERROR: Unknown or unsupported MISC instruction")
            print(f"     func4={func4}, uop={uop}")
            print(f"     Only 7 core MISC instructions are supported (see docstring)")
            return