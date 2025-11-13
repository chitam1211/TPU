import os
import re
import struct
import math
from .definitions import XLEN, ELEN, ROWNUM, ELEMENTS_PER_ROW_TR

from .logic_config import ConfigLogic
from .logic_matmul import MatmulLogic
from .logic_loadstore import LoadStoreLogic
from .logic_elementwise import ElementwiseLogic
from .logic_misc import MiscLogic

class RegisterFile:
    """Đại diện cho 32 thanh ghi GPR."""
    def __init__(self):
        # Khởi tạo 32 GPRs trong RAM
        self.registers = [0] * 32 # Dùng số nguyên (integer) để lưu bit pattern
    
    def read(self, index):
        if index == 0: return 0 # Thanh ghi x0 luôn là 0
        return self.registers[index]
        
    def write(self, index, value):
        if index != 0: # Không cho phép ghi vào x0
            self.registers[index] = value & 0xFFFFFFFF # Đảm bảo là 32-bit

class CSRFile:
    """Đại diện cho các thanh ghi CSR."""
    def __init__(self):
        # Khởi tạo các CSR trong RAM (dùng dict)
        self.csrs = {
            "xmcsr": 0, "mtilem": 0, "mtilen": 0, "mtilek": 0,
            "xmxrm": 0, "xmsat": 0, "xmfflags": 0, "xmfrm": 0, "xmsaten": 0,
            "xmisa": 0xE00003FF, # Giá trị đã tính toán
            "xtlenb": 64, "xtrlenb": 16, "xalenb": 64,
            "mstatus_ms": 0
        }
    
    def read(self, name):
        return self.csrs.get(name, 0)
        
    def write(self, name, value):
            if name in self.csrs:
                # Các thanh ghi URO (Read-Only) sẽ không được ghi
                if name not in ["xmisa", "xtlenb", "xtrlenb", "xalenb"]:
                    self.csrs[name] = value
            else:
                print(f"  [Warning] Cố gắng ghi vào CSR không xác định: {name}")

class MatrixAccelerator(ConfigLogic, MatmulLogic, LoadStoreLogic, ElementwiseLogic, MiscLogic):
    """Đại diện cho bộ tăng tốc ma trận."""
    def __init__(self, csr_file_ref, gpr_file_ref, memory_ref):
        # Lưu một tham chiếu đến CSRs, GPRs và Memory
        self.csr_ref = csr_file_ref 
        self.gpr_ref = gpr_file_ref
        self.memory = memory_ref
        # Khởi tạo các thanh ghi tile/acc trong RAM
        # Cấu trúc: 4 thanh ghi [4 hàng [4 cột]]
        self.tr_int = [[[0]*ELEMENTS_PER_ROW_TR for _ in range(ROWNUM)] for _ in range(4)]
        self.acc_int = [[[0]*ELEMENTS_PER_ROW_TR for _ in range(ROWNUM)] for _ in range(4)]
        self.tr_float = [[[0.0]*ELEMENTS_PER_ROW_TR for _ in range(ROWNUM)] for _ in range(4)]
        self.acc_float = [[[0.0]*ELEMENTS_PER_ROW_TR for _ in range(ROWNUM)] for _ in range(4)]
        
        # Metadata: Lưu destination bit-width cho mỗi accumulator
        # Tách riêng cho int và float vì chúng độc lập
        self.acc_dest_bits_float = [32] * 4  # FP32 by default
        self.acc_dest_bits_int = [32] * 4    # INT32 by default


class MainMemory:
    """Mô phỏng bộ nhớ chính (RAM) của simulator."""
    def __init__(self, size_in_bytes=1024*1024): # 1MB RAM
        self.memory = bytearray(size_in_bytes)
        print(f"  [Init] MainMemory đã khởi tạo ({size_in_bytes // 1024} KB RAM)")

    def read(self, address, num_bytes):
        """Đọc num_bytes từ một địa chỉ."""
        if address + num_bytes > len(self.memory):
            raise MemoryError(f"Lỗi đọc RAM: Địa chỉ 0x{address:X} vượt quá giới hạn")
        return self.memory[address : address + num_bytes]

    def write(self, address, byte_data):
        """Ghi một mảng bytes vào một địa chỉ."""
        num_bytes = len(byte_data)
        if address + num_bytes > len(self.memory):
            raise MemoryError(f"Lỗi ghi RAM: Địa chỉ 0x{address:X} vượt quá giới hạn")
        self.memory[address : address + num_bytes] = byte_data
