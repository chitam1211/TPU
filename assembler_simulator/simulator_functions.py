import numpy as np
import torch as pt
import struct
from simulator_variables import *

def print_register_changes(changed_registers):
    """
    Print the registers that were modified by an instruction.
    
    Args:
        changed_registers (list): List of dictionaries containing register type, name, and optional value.
    """
    if not changed_registers:
        print("No registers were modified by this instruction.")
        return
    
    print("Registers modified by the instruction:")
    for reg in changed_registers:
        reg_name = reg.get("name")  # e.g., "md", "rs1", "0x10010000"
        value = reg.get("value", "Not displayed")  # Optional value, if provided
        
        print(f"{reg_name}: Value = {value}")
def logical_right_shift(value, n):
    # Use a mask to ensure the leftmost bits are zero-filled
    mask = (1 << 32) - 1
    return (value >> n) & mask

def apply_floating_point_rounding(value, rounding_mode):
    if rounding_mode == 0b000:
        # Round to Nearest, ties to Even
        return np.round(value, decimals=0)
    elif rounding_mode == 0b001:
        # Round towards Zero
        return np.trunc(value)
    elif rounding_mode == 0b010:
        # Round Down (towards -∞)
        return np.floor(value)
    elif rounding_mode == 0b011:
        # Round Up (towards +∞)
        return np.ceil(value)
    elif rounding_mode == 0b100:
        # Round to Nearest, ties to Max Magnitude
        return np.round(value, decimals=0, mode='max')
    else:
        raise ValueError("Unsupported rounding mode")

def float_to_bin(val, source_type): 
    # Function to convert a floating point number to binary
    if source_type == "fp32":
        # IEEE 754 Single Precision
        return format(struct.unpack('!I', struct.pack('!f', val))[0], '032b')
    elif source_type == "fp16":
        # IEEE 754 Half Precision
        return format(struct.unpack('!H', struct.pack('!e', val))[0], '016b')
    elif source_type == "fp8_e4":
        # FP8 e4m3 format
        return format(float_to_e4m3(val), '08b')
    elif source_type == "fp8_e5":
        # FP8 e5m2 format
        return format(float_to_e5m2(val), '08b')
    else:
        raise ValueError("Unsupported source type")

def float_to_e4m3(val):
    """ Simulate FP8 e4m3fn conversion (4 exponent bits, 3 mantissa bits). """
    if val == 0:
        return 0

    sign = 0 if val >= 0 else 1
    val = abs(val)

    exponent = max(-8, min(7, int(np.floor(np.log2(val)))))
    mantissa = int((val / (2 ** exponent)) * (1 << 3)) & 0x7

    # Reconstruct FP8 e4m3 binary value
    return (sign << 7) | ((exponent + 8) << 3) | mantissa

def float_to_e5m2(source_value):
        """ Simulate FP8 e5m2 conversion (5 exponent bits, 2 mantissa bits). """
        if source_value == 0:
            return 0

        sign = 0 if source_value >= 0 else 1
        source_value = abs(source_value)

        exponent = max(-16, min(15, int(np.floor(np.log2(source_value)))))
        mantissa = int((source_value / (2 ** exponent)) * (1 << 2)) & 0x3

        # Reconstruct FP8 e5m2 binary value
        return (sign << 7) | ((exponent + 16) << 2) | mantissa

import struct

def fp8_e4m3_to_fp16(fp8):
    sign = (fp8 >> 7) & 0x1
    exponent = (fp8 >> 3) & 0xF
    mantissa = fp8 & 0x7

    if exponent == 0b1111:  # Inf or NaN
        new_exponent = 0b11111
        new_mantissa = (mantissa != 0) * 0x200  # Preserve NaN payload
    elif exponent == 0:  # Subnormal or zero
        if mantissa == 0:
            return sign << 15  # Zero
        else:
            # Convert subnormal FP8 to subnormal FP16
            new_exponent = 0
            new_mantissa = (mantissa << 7)  # Align mantissa
    else:
        new_exponent = exponent - 8 + 15
        new_mantissa = mantissa << 7

    fp16 = (sign << 15) | (new_exponent << 10) | new_mantissa
    return fp16

def fp8_e5_to_fp16(fp8):
    sign = (fp8 >> 7) & 0x1
    exponent = (fp8 >> 2) & 0x1F
    mantissa = fp8 & 0x3

    if exponent == 0b11111:  # Inf or NaN
        new_exponent = 0b11111
        new_mantissa = (mantissa != 0) * 0x200  # Preserve NaN payload
    elif exponent == 0:  # Subnormal or zero
        if mantissa == 0:
            return sign << 15  # Zero
        else:
            new_exponent = 0
            new_mantissa = (mantissa << 8)  # Align mantissa
    else:
        new_exponent = exponent - 16 + 15
        new_mantissa = mantissa << 8

    fp16 = (sign << 15) | (new_exponent << 10) | new_mantissa
    return fp16

def fp16_to_fp32(fp16):
    sign = (fp16 >> 15) & 0x1
    exponent = (fp16 >> 10) & 0x1F
    mantissa = fp16 & 0x3FF

    if exponent == 0b11111:  # Inf or NaN
        new_exponent = 0xFF
        new_mantissa = (mantissa != 0) * 0x400000  # Preserve NaN payload
    elif exponent == 0:  # Subnormal or zero
        if mantissa == 0:
            return (-1)**sign * 0.0  # Zero
        else:
            # Convert FP16 subnormal to normalized FP32
            new_exponent = 1
            while (mantissa & 0x400) == 0:
                mantissa <<= 1
                new_exponent -= 1
            mantissa &= 0x3FF  # Remove hidden bit
            new_exponent += 127 - 15
            new_mantissa = mantissa << 13
    else:
        new_exponent = exponent - 15 + 127
        new_mantissa = mantissa << 13

    # Reconstruct FP32 value using raw IEEE 754 formula
    f32= (-1) ** sign * (1 + new_mantissa / (2**23)) * (2 ** (new_exponent - 127))
    return f32

def float32_to_float16(f):
    f32 = struct.unpack('>I', struct.pack('>f', f))[0]
    sign = (f32 >> 31) & 0x1
    exponent = (f32 >> 23) & 0xFF
    mantissa = f32 & 0x7FFFFF

    if exponent == 0xFF:  # Inf or NaN
        new_exponent = 0x1F
        new_mantissa = (mantissa != 0) * 0x200
    elif exponent > 112:  # Normalized
        new_exponent = max(0, min(0x1F, exponent - 127 + 15))
        new_mantissa = mantissa >> 13
    elif exponent >= 103:  # Subnormal
        new_exponent = 0
        new_mantissa = (mantissa | 0x800000) >> (126 - exponent)
    else:  # Underflow to zero
        new_exponent = 0
        new_mantissa = 0

    f16 = (sign << 15) | (new_exponent << 10) | new_mantissa
    return f16

def fp32_to_fp64(fp32):
    sign = (fp32 >> 31) & 0x1
    exponent = (fp32 >> 23) & 0xFF
    mantissa = fp32 & 0x7FFFFF

    if exponent == 0xFF:  # Inf or NaN
        new_exponent = 0x7FF
        new_mantissa = (mantissa != 0) * 0x8000000000000  # Preserve NaN payload
    elif exponent == 0:  # Subnormal or zero
        new_exponent = 0
        new_mantissa = mantissa << 29
    else:
        new_exponent = exponent - 127 + 1023
        new_mantissa = mantissa << 29

    fp64 = (sign << 63) | (new_exponent << 52) | new_mantissa
    return fp64

def bin_to_float(source_value, source_type, target_type):
    if source_type == "fp16" and target_type == "fp8_e4":
        return float_to_e4m3(struct.unpack('!f', struct.pack('!I', int(source_value, 2)))[0])
    elif source_type == "fp16" and target_type == "fp8_e5":
        return float_to_e5m2(struct.unpack('!f', struct.pack('!I', int(source_value, 2)))[0])
    elif source_type == "fp8_e4" and target_type == "fp16":
        return pt.tensor(struct.unpack('!f', struct.pack('!I', int(source_value, 2)))[0], dtype=pt.float16)
    elif source_type == "fp8_e5" and target_type == "fp16":
        return fp8_e5_to_fp16(int(source_value, 2))
    elif source_type == "fp32" and target_type == "fp16":
        return pt.tensor(struct.unpack('!f', struct.pack('!I', int(source_value, 2)))[0], dtype=pt.float16)
    elif source_type == "fp32" and target_type == "bf16":
        return pt.tensor(struct.unpack('!f', struct.pack('!I', int(source_value, 2)))[0], dtype=pt.bfloat16)
    elif source_type == "fp8_e4" and target_type == "fp32":
        return pt.tensor(struct.unpack('!f', struct.pack('!I', int(source_value, 2)))[0], dtype=pt.float32)
    elif source_type == "fp8_e5" and target_type == "fp32":
        return pt.tensor(struct.unpack('!f', struct.pack('!I', int(source_value, 2)))[0], dtype=pt.float32)
    else:
        raise ValueError("Unsupported conversion types")


def binary_to_data_Matrix(line, current_address):
    pc1 = current_address
    changed_registers = []
    
    func = line[0:4]
    uop = line[4:6]
    ctrl = line[6]
    func3 = line[17:20]
    opcode = line[25:32]
    print("Function:", func, "UOP:", uop, "Control:", ctrl, "Func3:", func3)
    # md = line[7:9]
    # d_size = line[9:10]
    # ms1 = line[15:17]
    # s_size = line[18:19]
    # ms2 = line[20:22]
    # imm3_ctrl = line[23:25]
    
    # TABLE 2: Matrix Configuration Instructions
    if func == "0000" and func3 == "000" and uop == "00":
        # mrelease
        MATRIX_REGISTER["mi"] = 0
        MATRIX_REGISTER["ki"] = 0
        MATRIX_REGISTER["ni"] = 0
        
        MSTATUS["MS"]["value"] = "01"
        changed_registers.append({"name": "mi", "value": 0},
                                {"name": "ki", "value": 0},
                                {"name": "ni", "value": 0},
                                {"name": "MS", "value": "01"}
                                )   
    elif func == "0001" and func3 == "000" and uop == "00":
        if ctrl == "0":
            # msettileki imm
            uimm10 = line[7:17]
            MATRIX_REGISTER["ki"] = int(uimm10, 2)
            changed_registers.append({"name": "ki", "value": int(imm10, 2)})
        elif ctrl == "1":
            # msettilek rs1
            rs1 = line[12:17]
            MATRIX_REGISTER["mi"] = int(REGISTERS[rs1]["value"],2)
            changed_registers.append({"name": "ki", "value": REGISTERS[rs1]["value"]})
            
    elif func == "0010" and func3 == "000" and uop == "00":

        if ctrl == "0":
            # msettilemi imm
            uimm10 = line[7:17]
            MATRIX_REGISTER["mi"] = int(uimm10, 2)
            changed_registers.append({"name": "mi", "value": int(uimm10, 2)})
        else:
            # msettilem rs1
            rs1 = line[12:17]
            changed_registers.append({"name": "mi", "value": REGISTERS[rs1]["value"]})
            
    elif func == "0011" and func3 == "000" and uop == "00":
        
        if ctrl == "0":
            # msettileni imm
            uimm10 = line[7:17]
            MATRIX_REGISTER["ni"] = int(uimm10, 2)
            changed_registers.append({"name": "ni", "value": int(imm10, 2)})
        else:
            # msettilen rs1
            rs1 = line[12:17]
            MATRIX_REGISTER["ni"] = REGISTERS[rs1]["value"]    
            changed_registers.append({"name": "ni", "value": REGISTERS[rs1]["value"]})
        
    # TABLE 3: Matrix MISC Instructions  
    elif func == "0000" and uop == "11" and func3 == "000":
        # mzero acc0
        uimm3 = line[6:9]
        md = line[22:25]
        md_v = int(md, 2)
        inst = int(uimm3, 2)
        if md_v + inst <= 7:
            for i in range (inst):
                if md <= 4:
                    MATRIX_REGISTER[md]["value"] = np.zeros((4, 4, 32), dtype=np.uint8)
                elif md <= 7:
                    MATRIX_REGISTER[md]["value"] = np.zeros((4, 4, 128), dtype=np.uint8)
                    
            changed_registers.append({"name": MATRIX_REGISTER[md]["name"], "value": MATRIX_REGISTER[md]["value"]})
        else:
            raise ValueError("Invalid matrix register index")
    
    elif func == "0001" and uop == "11" and func3 == "000":
        # mmov.mm mdm ms1
        ms1 = line[14:17]
        md = line[22:25]
        if md in range(0,4) and ms1 in range(0,4):
            MATRIX_REGISTER[md]["value"] = MATRIX_REGISTER[ms1]["value"]
        elif md in range(4,8) and ms1 in range(4,8):
            MATRIX_REGISTER[md]["value"] = MATRIX_REGISTER[ms1]["value"]
        else:
            min_len = min(TRLEN, ARLEN)
            if md in range(0,4):
                MATRIX_REGISTER[md]["value"][:min_len] = MATRIX_REGISTER[ms1]["value"][:min_len]
            else:
                MATRIX_REGISTER[md]["value"][:min_len] = MATRIX_REGISTER[ms1]["value"][:min_len]
        changed_registers.append({"name": MATRIX_REGISTER[md]["name"], "value": MATRIX_REGISTER[md]["value"]})
    elif func == "0010" and uop == "11" and func3 == "000":
        #  mmov<b/h/w/d>.x.m rd, ms2, rs1
        ctrl = line[7:9]
        ms2 = line[9:12]
        rs1 = line[12:17]
        rd = line[20:25]
        
        index = REGISTERS[rs1]["value"]
        
        if ctrl == "00":  # Byte
            element_per_row = 16
            element = MATRIX_REGISTER[ms2]["value"][index // element_per_row][index % element_per_row] & 0xFF
            if element & 0x80:  # Check if the sign bit is set
                element |= ~0xFF  # Sign-extend to 32 bits
        elif ctrl == "01":  # Halfword (16-bit)
            element_per_row = 8
            element = MATRIX_REGISTER[ms2]["value"][index // element_per_row][index % element_per_row] & 0xFFFF
            if element & 0x8000:  # Check if the sign bit is set
                element |= ~0xFFFF  # Sign-extend to 32 bits
        elif ctrl == "10":  # Word (32-bit)
            element_per_row = 4
            element = MATRIX_REGISTER[ms2]["value"][index // element_per_row][index % element_per_row]
        elif ctrl == "11":  # Doubleword (64-bit)
            element_per_row = 2
            element = MATRIX_REGISTER[ms2]["value"][index // element_per_row][index % element_per_row] & 0xFFFFFFFF
        changed_registers.append({"name": MATRIX_REGISTER[ms2]["name"], "value": MATRIX_REGISTER[ms2]["value"]})
        
        REGISTERS[rd]["value"] = element
        changed_registers.append({"name": MATRIX_REGISTER[rd]["name"], "value": element})
    elif func == "0100" and uop == "11" and func3 == "000":
        ctrl = line[7:9]
        ms2 = line[9:12]
        ms1 = line[14:17]
        md = line[22:25]
        
        ms2_v = int(line[20:22],2) 
        ms1_v = int(line[15:17],2) 
        md_v = int(line[7:9],2)
        if not ((0 <= md_v < 4 and 0 <= ms1_v < 4 and 0 <= ms2_v < 4) 
                or (4 <= md_v < 8 and 4 <= ms1_v < 8 and 4 <= ms2_v < 8)):
            raise ValueError("Matrix register do not match")
        
        if ctrl == "00":
            # mpack.mm md, ms2, ms1
            MATRIX_REGISTER[md]["value"][:, :MATRIX_REGISTER[ms2]["value"].shape[1]//2] = MATRIX_REGISTER[ms2]["value"][:, :MATRIX_REGISTER[ms2]["value"].shape[1]//2]
            MATRIX_REGISTER[md]["value"][:, MATRIX_REGISTER[ms2]["value"].shape[1]//2:] = MATRIX_REGISTER[ms1]["value"][:, :MATRIX_REGISTER[ms1]["value"].shape[1]//2]
        elif ctrl == "01":
            # mpackhl.mm md, ms2, ms1
            MATRIX_REGISTER[md]["value"][:, :MATRIX_REGISTER[ms2]["value"].shape[1]//2] = MATRIX_REGISTER[ms2]["value"][:, MATRIX_REGISTER[ms2]["value"].shape[1]//2:]
            MATRIX_REGISTER[md]["value"][:, MATRIX_REGISTER[ms2]["value"].shape[1]//2:] = MATRIX_REGISTER[ms1]["value"][:, :MATRIX_REGISTER[ms1]["value"].shape[1]//2]
        elif ctrl == "10":
            # mpackhh.mm md, ms2, ms1
            MATRIX_REGISTER[md]["value"][:, :MATRIX_REGISTER[ms2]["value"].shape[1]//2] = MATRIX_REGISTER[ms2]["value"][:, MATRIX_REGISTER[ms2]["value"].shape[1]//2:]
            MATRIX_REGISTER[md]["value"][:, MATRIX_REGISTER[ms2]["value"].shape[1]//2:] = MATRIX_REGISTER[ms1]["value"][:, MATRIX_REGISTER[ms1]["value"].shape[1]//2:]
        changed_registers.append({"name": MATRIX_REGISTER[md]["name"], "value": MATRIX_REGISTER[md]["value"]})
    elif func == "0011" and uop == "11" and func3 == "000":
        if ctrl == 1:
            rs2 = line[7:12]
            d_size = line[20:22]
            md = line[22:25]
            
            element = REGISTERS[rs2]["value"]
            
            if ctrl == 1:
                # mmov<b/h/w/d>.m.x md, rs2, rs1
                rs1 = line[12:17]
                if d_size == "00":  # Byte
                    element_per_row = 16
                    row = REGISTERS[rs1]["value"] // element_per_row
                    col = REGISTERS[rs1]["value"] % element_per_row
                    MATRIX_REGISTER[md]["value"][row][col] = element & 0xFF
                elif d_size == "01":  # Halfword
                    element_per_row = 8
                    row = REGISTERS[rs1]["value"] // element_per_row
                    col = REGISTERS[rs1]["value"] % element_per_row
                    MATRIX_REGISTER[md]["value"][row][col] = element & 0xFFFF
                elif d_size == "10":  # Word
                    element_per_row = 4
                    row = REGISTERS[rs1]["value"] // element_per_row
                    col = REGISTERS[rs1]["value"] % element_per_row
                    MATRIX_REGISTER[md]["value"][row][col] = element
                elif d_size == "11":  # Doubleword
                    element_per_row = 2
                    row = REGISTERS[rs1]["value"] // element_per_row
                    col = REGISTERS[rs1]["value"] % element_per_row
                    
                    if element & 0x80000000:
                        element |= ~0xFFFFFFFF
                    MATRIX_REGISTER[md]["value"][row][col] = element
                changed_registers.append({"name": MATRIX_REGISTER[md]["name"], "value": MATRIX_REGISTER[md]["value"]})
            elif ctrl == 0:
                #mdup.b/h/w/d md, rs1
                if d_size == "00":  # Byte
                    element_per_row = 128 // 8
                elif d_size == "01":  # Halfword
                    element_per_row = 128 // 16
                elif d_size == "10":  # Word
                    element_per_row = 128 // 32
                elif d_size == "11":  # Doubleword
                    element_per_row = 128 // 64
                    
                element = element & element_per_row
                
                for row in range(len(MATRIX_REGISTER[md]["value"])):
                    for col in range(len(MATRIX_REGISTER[md]["value"][row])):
                        MATRIX_REGISTER[md]["value"][row][col] = element
                changed_registers.append({"name": MATRIX_REGISTER[md]["name"], "value": MATRIX_REGISTER[md]["value"]})
    elif func == "0101" and uop == "11" and func3 == "000":
        # mrslidedown
        uimm3 = int(line[6:9], 2) & 0b11
        ms1 = line[14:17]
        md = line[22:25]
        
        ms1_v = int(line[15:17],2) 
        md_v = int(line[7:9],2)
        if not ((0 <= md_v < 4 and 0 <= ms1_v < 4) 
                or (4 <= md_v < 8 and 4 <= ms1_v < 8)):
            raise ValueError("Matrix register do not match")
        
        MATRIX_REGISTER[md]["value"] = np.roll(MATRIX_REGISTER[ms1]["value"], -uimm3, axis=0)
        MATRIX_REGISTER[md]["value"][ROWNUM - uimm3:] = np.zeros_like(MATRIX_REGISTER[md]["value"][0])
        changed_registers.append({"name": MATRIX_REGISTER[md]["name"], "value": MATRIX_REGISTER[md]["value"]})
    elif func == "0110" and uop == "11" and func3 == "000":
        # mrslideup
        uimm3 = int(line[6:9], 2) & 0b11
        ms1 = line[14:17]
        md = line[22:25]
        
        ms1_v = int(line[15:17],2) 
        md_v = int(line[7:9],2)
        if not ((0 <= md_v < 4 and 0 <= ms1_v < 4) 
                or (4 <= md_v < 8 and 4 <= ms1_v < 8)):
            raise ValueError("Matrix register do not match")
        
        MATRIX_REGISTER[md]["value"] = np.roll(MATRIX_REGISTER[ms1]["value"], uimm3, axis=0)
        MATRIX_REGISTER[md]["value"][:uimm3] = np.zeros_like(MATRIX_REGISTER[md]["value"][0])
        changed_registers.append({"name": MATRIX_REGISTER[md]["name"], "value": MATRIX_REGISTER[md]["value"]})
    elif func == "0111" and uop == "11" and func3 == "000":
        uimm3 = int(line[6:9], 2) & 0b11
        s_size = line[12:14]
        ms1 = line[14:17]
        d_size = line[20:22]
        md = line[22:25]
        
        ms1_v = int(ms1, 2) 
        md_v = int(md, 2)
        if d_size != s_size:
            raise ValueError("Size mismatch")
        if not ((0 <= md_v < 4 and 0 <= ms1_v < 4) 
                or (4 <= md_v < 8 and 4 <= ms1_v < 8)):
            raise ValueError("Matrix register do not match")
        
        if s_size == "00":
            # mslidedown.b → 8 bits
            element_per_row = 128 // 8
        elif s_size == "01":
            # mslidedown.h → 16 bits
            element_per_row = 128 // 16
        elif s_size == "10":
            # mslidedown.w → 32 bits
                element_per_row = 128 // 32
        elif s_size == "11":
            # mslidedown.d → 64 bits
            element_per_row = 128 // 64 

        # Perform matrix row slide down, element by element
        for i in range(ROWNUM - uimm3):
            for elem in range(element_per_row):
                MATRIX_REGISTER[md]["value"][i][elem] = MATRIX_REGISTER[ms1]["value"][i + uimm3][elem]

        # Zero the last 'uimm3' rows, element by element
        for i in range(ROWNUM - uimm3, ROWNUM):
            MATRIX_REGISTER[md]["value"][i] = [0] * element_per_row
        changed_registers.append({"name": MATRIX_REGISTER[md]["name"], "value": MATRIX_REGISTER[md]["value"]})
    elif func == "1000" and uop == "11" and func3 == "000":
        uimm3 = int(line[6:9], 2) & 0b11
        s_size = line[12:14]
        ms1 = line[14:17]
        d_size = line[20:22]
        md = line[22:25]
        
        ms1_v = int(ms1, 2) 
        md_v = int(md, 2)
        if d_size != s_size:
            raise ValueError("Size mismatch")
        if not ((0 <= md_v < 4 and 0 <= ms1_v < 4) 
                or (4 <= md_v < 8 and 4 <= ms1_v < 8)):
            raise ValueError("Matrix register do not match")
        
        if s_size == "00":
            # mslideup.b → 8 bits
            element_per_row = 128 // 8  # 4 elements per 32-bit row
        elif s_size == "01":
            # mslideup.h → 16 bits
            element_per_row = 128 // 16  # 2 elements per row
        elif s_size == "10":
            # mslideup.w → 32 bits
            element_per_row = 128 // 32  # 1 element per row
        elif s_size == "11":
            # mslideup.d → 64 bits
            element_per_row = 128 // 64  # 0.5 elements (needs 2 slots)

        # Perform matrix row slide up, element by element
        for i in range(uimm3, ROWNUM):
            for elem in range(element_per_row):
                MATRIX_REGISTER[md]["value"][i][elem] = MATRIX_REGISTER[ms1]["value"][i - uimm3][elem]

        # Zero the first 'uimm3' rows, element by element
        for i in range(uimm3):
            MATRIX_REGISTER[md]["value"][i] = [[0] * element_per_row]
        changed_registers.append({"name": MATRIX_REGISTER[md]["name"], "value": MATRIX_REGISTER[md]["value"]})
    elif func == "1001" and uop == "11" and func3 == "000":
        #mrbca.mv.i md, ms1, imm
        uimm3 = int(line[6:9], 2) & 0b11
        ms1 = line[14:17]
        md = line[22:25]
        
        ms1_v = int(ms1, 2) 
        md_v = int(md, 2)
        if not (4 <= md_v < 8 and 4 <= ms1_v < 8):
            raise ValueError("Matrix register do not match") #only accept acummulate resigter
        
        # Extract the row from source accumulator register
        source_row = MATRIX_REGISTER[ms1]["value"][uimm3]

        # Broadcast the row to all rows of the destination accumulator
        for i in range(ROWNUM):
            MATRIX_REGISTER[md]["value"][i] = source_row.copy()
        changed_registers.append({"name": MATRIX_REGISTER[md]["name"], "value": MATRIX_REGISTER[md]["value"]})
    elif func == "1010" and uop == "11" and func3 == "000":
        
        uimm3 = int(line[6:9], 2) & 0b11
        ms1 = line[14:17]
        md = line[22:25]
        ctrl = line[7:9]

        ms1_v = int(ms1, 2)
        md_v = int(md, 2)

        if not (4 <= md_v < 8 and 4 <= ms1_v < 8):
            raise ValueError("Matrix register do not match")
        
        if ctrl == "00":
            # mcbcab.mv.i
            source_value = MATRIX_REGISTER[ms1]["value"][uimm3] & 0xFF
            for i in range(ROWNUM):
                for j in range(4):
                    for k in range (0, 24, 8):
                        MATRIX_REGISTER[md]["value"][i][j][k:k+7] = source_value[i]
        
        elif ctrl == "01":
            # mcbcah.mv.i - half
            # Handle half-word matrix column broadcast
            source_value = MATRIX_REGISTER[ms1]["value"][uimm3] & 0xFFFF
            for i in range(ROWNUM):
                for j in range(4):
                    for k in range (0, 16, 16):
                        MATRIX_REGISTER[md]["value"][i][j][k:k+15] = source_value[i]

        elif ctrl == "10":
            # mcbcaw.mv.i - word
            # Handle word-level matrix column broadcast
            source_value = MATRIX_REGISTER[ms1]["value"][uimm3]
            for i in range(ROWNUM):
                for j in range(4):
                    MATRIX_REGISTER[md]["value"][i][j] = source_value[i]
        
        elif ctrl == "11":
            # mcbcad.mv.i - double
            # Handle double-word matrix column broadcast
            source_value = (MATRIX_REGISTER[ms1]["value"][uimm3] << 32) | MATRIX_REGISTER[ms1]["value"][uimm3 + 1]
            for i in range(ROWNUM):
                for j in range(0, 2, 2):
                    MATRIX_REGISTER[md]["value"][i][j] = source_value[i][0:31]
                    MATRIX_REGISTER[md]["value"][i][j] = source_value[i][32:63]
        changed_registers.append({"name": MATRIX_REGISTER[md]["name"], "value": MATRIX_REGISTER[md]["value"]})
        
        # TABLE 4: Matrix Multiplication Instructions
        # If the result doesn’t fully fit in md (e.g., matrix size mismatch)
        # only the lower columns are updated — the rest are zeroed
    elif func == "0000" and uop == "01" and func3 == "000":
        # mfnacc
        size_sup = line[6:9]
        ms2 = line[9:12]
        s_size = line[12:14]
        ms1 = line[14:17]
        d_size = line[20:22]
        md_ms3 = line[22:25]


        ms1_v = int(ms1, 2)
        ms2_v = int(ms2, 2)
        md_ms3_v = int(md_ms3, 2)

        if (ms1_v not in range(0, 4) or ms2_v not in range(0, 4) or md_ms3_v not in range(4, 8)):
            raise ValueError("Invalid matrix register name")

        if size_sup == "000" and s_size == "00" and d_size == "01":
            # mfnacc.h.e5
            if XMISA["mmf8f16"]["value"] == 0:
                raise ValueError("mmf8f16 extension is not supported")
    
            source_type = "fp8_e5"
            
            # lower half
            start_col, end_col = len(MATRIX_REGISTER[md_ms3]["value"][0]) // 2, len(MATRIX_REGISTER[md_ms3]["value"][0])
            
            for i in range(ROWNUM):
                for j in range(start_col, end_col):
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j]
                    b_value = MATRIX_REGISTER[ms2]["value"][j][i]
                    acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]

                    # Convert FP8 e5m2 to FP16
                    a_fp16 = bin_to_float(a_value, source_type, "fp16")
                    b_fp16 = bin_to_float(b_value, source_type, "fp16")
                    
                    # Perform FP16 multiplication and accumulation
                    product = a_fp16 * b_fp16
                    acc_value += product

                    # Handle floating-point rounding
                    rounding_mode = int(XMCSR_FIELD["xmfrm"]["value"], 2)
                    
                    # Assume acc_value is already in FP16 format
                    acc_value = apply_floating_point_rounding(acc_value, rounding_mode)

                    MATRIX_REGISTER[md_ms3]["value"][i][j] = (float_to_bin(acc_value, "fp16") & 0xFF) & 0xFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
        elif size_sup == "001" and s_size == "00" and d_size == "01":
            # mfnacc.h.e4
            if XMISA["mmf8f16"]["value"] == 0:
                raise ValueError("mmf8f16 extension is not supported")
            
            source_type = "fp8_e4"
            
            #lower half
            start_col, end_col = len(MATRIX_REGISTER[md]["value"][0]) // 2, len(MATRIX_REGISTER[md]["value"][0])

            for i in range(ROWNUM):
                for j in range(start_col, end_col):
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j]
                    b_value = MATRIX_REGISTER[ms2]["value"][j][i]
                    acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]

                    # Convert FP8 e5m2 to FP16
                    a_fp16 = bin_to_float(a_value, source_type, "fp16")
                    b_fp16 = bin_to_float(b_value, source_type, "fp16")
                    
                    # Perform FP16 multiplication and accumulation
                    product = a_fp16 * b_fp16
                    acc_value += product

                    # Handle floating-point rounding
                    rounding_mode = int(XMCSR_FIELD["xmfrm"]["value"], 2)
                    
                    # Assume acc_value is already in FP16 format
                    acc_value = apply_floating_point_rounding(acc_value, rounding_mode)

                    MATRIX_REGISTER[md_ms3]["value"][i][j] = (float_to_bin(acc_value, "fp16") & 0xFF) & 0xFFFF
        
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
        elif size_sup == "100" and s_size == "00" and d_size == "01":
            # mfmacc.bf16.e5
            if XMISA["mmf8bf16"]["value"] == 0:
                raise ValueError("mmf8bf16 extension is not supported")
            
            source_type = "fp8_e5"
            # lower half
            start_col, end_col = len(MATRIX_REGISTER[md]["value"][0]) // 2, len(MATRIX_REGISTER[md]["value"][0])
            
            for i in range(ROWNUM):
                for j in range(start_col, end_col):
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j]
                    b_value = MATRIX_REGISTER[ms2]["value"][j][i]
                    acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]

                    # Convert FP8 e5m2 to FP16
                    a_bf16 = bin_to_float(a_value, source_type, "bf16")
                    b_bf16 = bin_to_float(b_value, source_type, "bf16")
                    
                    # Perform FP16 multiplication and accumulation
                    product = a_bf16 * b_bf16
                    acc_value += product

                    # Handle floating-point rounding
                    rounding_mode = int(XMCSR_FIELD["xmfrm"]["value"], 2)
                    
                    # Assume acc_value is already in FP16 format
                    acc_value = apply_floating_point_rounding(acc_value, rounding_mode)

                    MATRIX_REGISTER[md_ms3]["value"][i][j] = (float_to_bin(acc_value, "bf16") & 0xFF) & 0xFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
        elif size_sup == "101" and s_size == "00" and d_size == "01":
            # mfmacc.bf16.e4
            if XMISA["mmf8bf16"]["value"] == 0:
                raise ValueError("mmf8bf16 extension is not supported")
            
            source_type = "fp8_e4"
            # lower half
            start_col, end_col = len(MATRIX_REGISTER[md]["value"][0]) // 2, len(MATRIX_REGISTER[md]["value"][0])
            
            for i in range(ROWNUM):
                for j in range(start_col, end_col):
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j]
                    b_value = MATRIX_REGISTER[ms2]["value"][j][i]
                    acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]

                    # Convert FP8 e5m2 to FP16
                    a_bf16 = bin_to_float(a_value, source_type, "bf16")
                    b_bf16 = bin_to_float(b_value, source_type, "bf16")
                    
                    # Perform FP16 multiplication and accumulation
                    product = a_bf16 * b_bf16
                    acc_value += product

                    # Handle floating-point rounding
                    rounding_mode = int(XMCSR_FIELD["xmfrm"]["value"], 2)
                    
                    # Assume acc_value is already in FP16 format
                    acc_value = apply_floating_point_rounding(acc_value, rounding_mode)

                    MATRIX_REGISTER[md_ms3]["value"][i][j] = (float_to_bin(acc_value, "bf16") & 0xFF) & 0xFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
        elif size_sup == "000" and s_size == "00" and d_size == "10":
            # mfmacc.s.e5
            if XMISA["mmf8f32"]["value"] == 0:
                raise ValueError("mmf8f32 extension is not supported")
            source_type = "fp8_e5"
            
            #lower half
            start_col, end_col = len(MATRIX_REGISTER[md]["value"][0]) // 2, len(MATRIX_REGISTER[md]["value"][0])

            for i in range(ROWNUM):
                for j in range(4):
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j]
                    b_value = MATRIX_REGISTER[ms2]["value"][j][i]
                    acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]

                    # Convert FP8 e5m2 to FP16
                    a_fp32 = bin_to_float(a_value, source_type, "fp32")
                    b_fp32 = bin_to_float(b_value, source_type, "fp32")
                    
                    # Perform FP16 multiplication and accumulation
                    product = a_fp32 * b_fp32
                    acc_value += product

                    # Handle floating-point rounding
                    rounding_mode = int(XMCSR_FIELD["xmfrm"]["value"], 2)
                    
                    # Assume acc_value is already in FP16 format
                    acc_value = apply_floating_point_rounding(acc_value, rounding_mode)

                    MATRIX_REGISTER[md_ms3]["value"][i][j] = (float_to_bin(acc_value, "fp32") & 0xFF) & 0xFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
        elif size_sup == "001" and s_size == "00" and d_size == "10":
            # mfmacc.s.e4
            if XMISA["mmf8f32"]["value"] == 0:
                raise ValueError("mmf8f32 extension is not supported")
            
            source_type = "fp8_e4"
            
            #lower half
            start_col, end_col = len(MATRIX_REGISTER[md]["value"][0]) // 2, len(MATRIX_REGISTER[md]["value"][0])

            for i in range(ROWNUM):
                for j in range(4):
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j]
                    b_value = MATRIX_REGISTER[ms2]["value"][j][i]
                    acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]

                    # Convert FP8 e5m2 to FP16
                    a_fp32 = bin_to_float(a_value, source_type, "fp32")
                    b_fp32 = bin_to_float(b_value, source_type, "fp32")
                    
                    # Perform FP16 multiplication and accumulation
                    product = a_fp32 * b_fp32
                    acc_value += product

                    # Handle floating-point rounding
                    rounding_mode = int(XMCSR_FIELD["xmfrm"]["value"], 2)
                    
                    # Assume acc_value is already in FP16 format
                    acc_value = apply_floating_point_rounding(acc_value, rounding_mode)

                    MATRIX_REGISTER[md_ms3]["value"][i][j] = (float_to_bin(acc_value, "fp32") & 0xFF) & 0xFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
        elif size_sup == "000" and s_size == "01" and d_size == "01":
            # mfmacc.h
            if XMISA["mmf16f16"]["value"] == 0:
                raise ValueError("mmf16f16 extension is not supported")
            
            source_type = "fp16"
            
            for i in range(ROWNUM):
                for j in range():
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j]
                    b_value = MATRIX_REGISTER[ms2]["value"][j][i]
                    acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]

                    # Convert FP8 e5m2 to FP16
                    a_fp16 = bin_to_float(a_value, source_type, "fp16")
                    b_fp16 = bin_to_float(b_value, source_type, "fp16")
                    
                    # Perform FP16 multiplication and accumulation
                    product = a_fp16 * b_fp16
                    acc_value += product

                    # Handle floating-point rounding
                    rounding_mode = int(XMCSR_FIELD["xmfrm"]["value"], 2)
                    
                    # Assume acc_value is already in FP16 format
                    acc_value = apply_floating_point_rounding(acc_value, rounding_mode)

                    MATRIX_REGISTER[md_ms3]["value"][i][j] = (float_to_bin(acc_value, "fp16") & 0xFF) & 0xFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
        elif size_sup == "000" and s_size == "01" and d_size == "10":
            # mfmacc.s.h
            if XMISA["mmf16f32"]["value"] == 0:
                raise ValueError("mmf16f32 extension is not supported")
            
            source_type == "fp16"
            
            for i in range(ROWNUM):
                for j in range(4):
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j]
                    b_value = MATRIX_REGISTER[ms2]["value"][j][i]
                    acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]

                    # Convert FP16 to FP32
                    a_fp32 = bin_to_float(a_value, source_type, "fp32")
                    b_fp32 = bin_to_float(b_value, source_type, "fp32")
                    
                    # Perform FP32 multiplication and accumulation
                    product = a_fp32 * b_fp32
                    acc_value += product

                    # Handle floating-point rounding
                    rounding_mode = int(XMCSR_FIELD["xmfrm"]["value"], 2)
                    
                    # Assume acc_value is already in FP16 format
                    acc_value = apply_floating_point_rounding(acc_value, rounding_mode)

                    MATRIX_REGISTER[md_ms3]["value"][i][j] = (float_to_bin(acc_value, "fp32") & 0xFF) & 0xFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
        elif size_sup == "001" and s_size == "01" and d_size == "10":
            #  mfmacc.s.bf16
            if XMISA["mmbf16f32"]["value"] == 0:
                raise ValueError("mmbf16f32 extension is not supported")
            
            source_type == "bf16"
            
            for i in range(ROWNUM):
                for j in range(4):
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j]
                    b_value = MATRIX_REGISTER[ms2]["value"][j][i]
                    acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]

                    # Convert FP16 to FP32
                    a_fp32 = bin_to_float(a_value, source_type, "fp32")
                    b_fp32 = bin_to_float(b_value, source_type, "fp32")
                    
                    # Perform FP32 multiplication and accumulation
                    product = a_fp32 * b_fp32
                    acc_value += product

                    # Handle floating-point rounding
                    rounding_mode = int(XMCSR_FIELD["xmfrm"]["value"], 2)
                    
                    # Assume acc_value is already in FP16 format
                    acc_value = apply_floating_point_rounding(acc_value, rounding_mode)

                    MATRIX_REGISTER[md_ms3]["value"][i][j] = (float_to_bin(acc_value, "fp32") & 0xFF) & 0xFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
        elif size_sup == "001" and s_size == "10" and d_size == "10":
            # mfmacc.s.tf32
            # not supported
            raise ValueError("mfmacc.s.tf32 instruction is not supported")
        elif size_sup == "000" and s_size == "10" and d_size == "10":
            #  mfmacc.s
            if XMISA["mmf32f32"]["value"] == 0:
                raise ValueError("mmf32f32 extension is not supported")

            source_type == "fp32"
            
            for i in range(ROWNUM):
                for j in range(4):
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j]
                    b_value = MATRIX_REGISTER[ms2]["value"][j][i]
                    acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]

                    # Convert FP16 to FP32
                    a_fp32 = bin_to_float(a_value, source_type, "fp32")
                    b_fp32 = bin_to_float(b_value, source_type, "fp32")
                    
                    # Perform FP32 multiplication and accumulation
                    product = a_fp32 * b_fp32
                    acc_value += product

                    # Handle floating-point rounding
                    rounding_mode = int(XMCSR_FIELD["xmfrm"]["value"], 2)
                    
                    # Assume acc_value is already in FP16 format
                    acc_value = apply_floating_point_rounding(acc_value, rounding_mode)

                    MATRIX_REGISTER[md_ms3]["value"][i][j] = (float_to_bin(acc_value, "fp32") & 0xFF) & 0xFFFF
        
        changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
        # When ELEN=32, mfmacc.d is reserved    
        # elif size_sup == "000" and s_size == "10" and d_size == "11":
        #     # mfmacc.d.s
        #     if XMISA["mmf32f64"]["value"] == 0:
        #         raise ValueError("mmf32f64 extension is not supported")
            
        # elif size_sup == "000" and s_size == "11" and d_size == "11":
        #     # mfmacc.d
        #     if XMISA["mmf64f64"]["value"] == 0:
        #         raise ValueError("mmf64f64 extension is not supported")
            
    elif func == "0001" and uop == "01" and func3 == "000":
        # mmacc
        size_sup = line[6:9]
        ms2 = line[9:12]
        s_size = line[12:14]
        ms1 = line[14:17]
        d_size = line[20:22]
        md_ms3 = line[22:25]
        
        ms1_v = int(ms1, 2)
        ms2_v = int(ms2, 2)
        md_ms3_v = int(md_ms3, 2)
        
        if (ms1_v not in range(0, 4) 
                or ms2_v not in range(0, 4) 
                or md_ms3_v not in range(4, 8)):
                raise ValueError("Invalid matrix register name")
        
        # As integer matrix multiplication operation with non-widen or widen output is
        # uncommon in AI scenarios, the matrix instruction set does not include such
        # instructions by default.The hardware can extend the mmacc.<b/h/w/d> or
        # mmacc.<h/w/d>.<b/h/w> instructions as needed.
        
        # If xmsaten equals 1, the output should be saturated.
        # Otherwise, the mmacc operations ignore the overflow and wrap around the result .
        
        #mmacc.w.q/mmaccu.w.q/mmaccus.w.q/mmaccsu.w.q are illegal if 'mmi4i32' of xmisa register is 0.
        if size_sup == "011" and s_size == "00" and d_size == "10":
            #  mmacc.w.b
            if XMISA["mmi4i32"]["value"] == 0:
                raise ValueError("mmi4i32 extension is not supported")
            
            for i in range(ROWNUM):
                for j in range(TRLEN):
                    acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j] & 0xFF
                    b_value = MATRIX_REGISTER[ms2]["value"][j][i] & 0xFF

                    # Signed multiplication and accumulation
                    product = int.from_bytes(a_value.to_bytes(1, 'little', signed=True), 'little') * \
                            int.from_bytes(b_value.to_bytes(1, 'little', signed=True), 'little')
                    acc_value += product

                    # Handle saturation if xmsaten is enabled
                    if XMCSR_FIELD["xmsaten"]["value"] == 1:
                        acc_value = min(max(acc_value, -(2 ** 31)), 2 ** 31 - 1)

                    # Store the final result back to accumulator
                    MATRIX_REGISTER[md_ms3]["value"][i][j] = acc_value & 0xFFFFFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
        elif size_sup == "000" and s_size == "00" and d_size == "10":
            #  mmaccu.w.b
            if XMISA["mmi8i32"]["value"] == 0:
                raise ValueError("mmi8i32 extension is not supported")
            
            for i in range(ROWNUM):
                for j in range(4):
                    acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j] & 0xFF
                    b_value = MATRIX_REGISTER[ms2]["value"][j][i] & 0xFF

                    # Unsigned multiplication and accumulation
                    product = a_value * b_value
                    acc_value += product

                    # Handle saturation if xmsaten is enabled
                    if XMCSR_FIELD["xmsaten"]["value"] == 1:
                        acc_value = min(max(acc_value, 0), 2 ** 32 - 1)

                    # Store the final result back to accumulator
                    MATRIX_REGISTER[md_ms3]["value"][i][j] = acc_value & 0xFFFFFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
        elif size_sup == "001" and s_size == "00" and d_size == "10":
            # mmaccus.w.b
            if XMISA["mmi8i32"]["value"] == 0:
                raise ValueError("mmi8i32 extension is not supported")
            
            for i in range(ROWNUM):
                for j in range(4):
                    acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]

                    # Unsigned 8-bit from ms1
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j] & 0xFF

                    # Signed 8-bit from ms2
                    b_value = int.from_bytes(
                        MATRIX_REGISTER[ms2]["value"][j][i].to_bytes(1, 'little', signed=True),
                        'little'
                    )

                    # Mixed unsigned-signed multiplication and accumulation
                    product = a_value * b_value
                    acc_value += product

                    # Handle saturation if xmsaten is enabled
                    if XMCSR_FIELD["xmsaten"]["value"] == 1:
                        acc_value = min(max(acc_value, -(2 ** 31)), 2 ** 31 - 1)

                    # Store the final result back to the accumulator
                    MATRIX_REGISTER[md]["value"][i][j] = acc_value & 0xFFFFFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
            
        elif size_sup == "010" and s_size == "00" and d_size == "10":
            # mmaccsu.w.b
            if XMISA["mmi8i32"]["value"] == 0:
                raise ValueError("mmi8i32 extension is not supported")

            for i in range(ROWNUM):
                for j in range(4):
                    # Load current accumulator value
                    acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]
                    # Get signed 8-bit value from ms1
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j] & 0xFF
                    # Get unsigned 8-bit value from ms2
                    b_value = MATRIX_REGISTER[ms2]["value"][j][i] & 0xFF

                    # Convert `a_value` to signed
                    signed_a = int.from_bytes(a_value.to_bytes(1, 'little', signed=True), 'little')

                    # Mixed signed-unsigned multiplication and accumulation
                    product = signed_a * b_value
                    acc_value += product

                    # Apply saturation if xmsaten is enabled
                    if XMCSR_FIELD["xmsaten"]["value"] == 1:
                        acc_value = min(max(acc_value, -(2 ** 31)), 2 ** 31 - 1)

                    # Store the final result back to the accumulator
                    MATRIX_REGISTER[md_ms3]["value"][i][j] = acc_value & 0xFFFFFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
        elif size_sup == "011" and s_size == "00" and d_size == "10":
            # pmmacc.w.b
            if XMISA["mmi4i32"]["value"] == 0:
                raise ValueError("mmi4i32 extension is not supported")

            # Parallel execution — split rows across PEs
            for pe in range(16):  # 16 PEs handling rows in parallel 
                for i in range(pe, ROWNUM, 16):  # Distribute rows to each PE
                    for j in range(4):
                        # Load accumulator value
                        acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]
                        # Get signed 8-bit values from ms1 and ms2
                        a_value = MATRIX_REGISTER[ms1]["value"][i][j] & 0xFF
                        b_value = MATRIX_REGISTER[ms2]["value"][j][i] & 0xFF

                        # Convert to signed
                        signed_a = int.from_bytes(a_value.to_bytes(1, 'little', signed=True), 'little')
                        signed_b = int.from_bytes(b_value.to_bytes(1, 'little', signed=True), 'little')

                        # Matrix multiply and accumulate
                        product = signed_a * signed_b
                        acc_value += product

                        # Apply saturation if enabled
                        if XMCSR_FIELD["xmsaten"]["value"] == 1:
                            acc_value = min(max(acc_value, -(2 ** 31)), 2 ** 31 - 1)

                        # Store result back to accumulator register
                        MATRIX_REGISTER[md_ms3]["value"][i][j] = acc_value & 0xFFFFFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
            
        elif size_sup == "101" and s_size == "00" and d_size == "10":
            # pmmaaccus.w.b
            if XMISA["mmi8i32"]["value"] == 0:
                raise ValueError("mmi8i32 extension is not supported")

            # Parallel execution across 16 Processing Elements (PEs)
            for pe in range(16):  # 16 PEs handling rows in parallel
                for i in range(pe, ROWNUM, 16):  # Each PE processes every 16th row
                    for j in range(4):
                        # Load current accumulator value
                        acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]

                        # Get unsigned 8-bit value from ms1
                        a_value = MATRIX_REGISTER[ms1]["value"][i][j] & 0xFF
                        # Get signed 8-bit value from ms2
                        b_value = MATRIX_REGISTER[ms2]["value"][j][i] & 0xFF

                        # Convert ms2 value to signed
                        signed_b = int.from_bytes(b_value.to_bytes(1, 'little', signed=True), 'little')

                        # Mixed unsigned-signed multiplication and accumulation
                        product = a_value * signed_b
                        acc_value += product

                        # Apply saturation if xmsaten is enabled
                        if XMCSR_FIELD["xmsaten"]["value"] == 1:
                            acc_value = min(max(acc_value, -(2 ** 31)), 2 ** 31 - 1)

                        # Store the final result back to the matrix register
                        MATRIX_REGISTER[md_ms3]["value"][i][j] = acc_value & 0xFFFFFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
            
        elif size_sup == "110" and s_size == "00" and d_size == "10":
            # pmmaccsu.w.b
            if XMISA["mmi8i32"]["value"] == 0:
                raise ValueError("mmi8i32 extension is not supported")

            # Parallel execution — distribute rows across 16 PEs
            for pe in range(16):  # 16 PEs working in parallel
                for i in range(pe, ROWNUM, 16):  # Each PE handles 1 row every 16 rows
                    for j in range(4):
                        # Load the current accumulator value
                        acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]

                        # Get signed 8-bit value from ms1
                        a_value = MATRIX_REGISTER[ms1]["value"][i][j] & 0xFF
                        # Get unsigned 8-bit value from ms2
                        b_value = MATRIX_REGISTER[ms2]["value"][j][i] & 0xFF

                        # Convert ms1 value to signed
                        signed_a = int.from_bytes(a_value.to_bytes(1, 'little', signed=True), 'little')

                        # Mixed signed-unsigned multiplication and accumulation
                        product = signed_a * b_value
                        acc_value += product

                        # Apply saturation if xmsaten is enabled (clamp to signed 32-bit range)
                        if XMCSR_FIELD["xmsaten"]["value"] == 1:
                            acc_value = min(max(acc_value, -(2 ** 31)), 2 ** 31 - 1)

                        # Store the final accumulated result back to the accumulator
                        MATRIX_REGISTER[md_ms3]["value"][i][j] = acc_value & 0xFFFFFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
            
        # As integer matrix multiplication operation with non-widen or widen output is
        # uncommon in AI scenarios, the matrix instruction set does not include such
        # instructions by default.The hardware can extend the mmacc.<b/h/w/d> or
        # mmacc.<h/w/d>.<b/h/w> instructions as needed
        elif size_sup == "011" and s_size == "01" and d_size == "11":
            # mmacc.d.h
            if XMISA["mmi8i32"]["value"] == 0:
                raise ValueError("mmi8i32 extension is not supported")

            for i in range(ROWNUM):
                for j in range(4):
                    # Load accumulator, ms1, ms2 values
                    acc_value = MATRIX_REGISTER[md]["value"][i][j]
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j] & 0xFFFF
                    b_value = MATRIX_REGISTER[ms2]["value"][j][i] & 0xFFFF

                    # Signed multiplication and accumulation (16-bit -> 64-bit)
                    product = int.from_bytes(
                        a_value.to_bytes(2, 'little', signed=True), 'little'
                    ) * int.from_bytes(
                        b_value.to_bytes(2, 'little', signed=True), 'little'
                    )
                    acc_value += product

                    # Handle saturation if xmsaten is enabled
                    if XMCSR_FIELD["xmsaten"]["value"] == 1:
                        acc_value = min(max(acc_value, -(2 ** 63)), (2 ** 63) - 1)

                    # Store back result to accumulator (64-bit mask)
                    MATRIX_REGISTER[md_ms3]["value"][i][j] = acc_value & 0xFFFFFFFFFFFFFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
            
        elif size_sup == "000" and s_size == "01" and d_size == "11":
            # mmaccu.d.h
            if XMISA["mmi8i32"]["value"] == 0:
                raise ValueError("mmi8i32 extension is not supported")

            for i in range(ROWNUM):
                for j in range(4):
                    # Load accumulator, ms1, ms2 values
                    acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j] & 0xFFFF
                    b_value = MATRIX_REGISTER[ms2]["value"][j][i] & 0xFFFF

                    # Unsigned multiplication and accumulation (16-bit -> 64-bit)
                    product = a_value * b_value
                    acc_value += product

                    # Handle saturation if xmsaten is enabled
                    if XMCSR_FIELD["xmsaten"]["value"] == 1:
                        acc_value = min(acc_value, (2 ** 64) - 1)

                    # Store back result to accumulator (64-bit mask)
                    MATRIX_REGISTER[md_ms3]["value"][i][j] = acc_value & 0xFFFFFFFFFFFFFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
            
        elif size_sup == "001" and s_size == "01" and d_size == "11":
            # mmaccus.d.h
            if XMISA["mmi8i32"]["value"] == 0:
                raise ValueError("mmi8i32 extension is not supported")

            for i in range(ROWNUM):
                for j in range(4):
                    # Load accumulator, ms1, ms2 values
                    acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j] & 0xFFFF  # unsigned 16-bit
                    b_value = int.from_bytes(
                        MATRIX_REGISTER[ms2]["value"][j][i].to_bytes(2, 'little', signed=True),
                        'little'
                    )  # signed 16-bit

                    # Unsigned-Signed multiplication and accumulation
                    product = a_value * b_value
                    acc_value += product

                    # Handle saturation if xmsaten is enabled
                    if XMCSR_FIELD["xmsaten"]["value"] == 1:
                        acc_value = min(max(acc_value, -(2 ** 63)), (2 ** 63) - 1)

                    # Store back result to accumulator (64-bit mask)
                    MATRIX_REGISTER[md_ms3]["value"][i][j] = acc_value & 0xFFFFFFFFFFFFFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
            
        elif size_sup == "010" and s_size == "01" and d_size == "11":
            #  mmaccsu.d.h
            if XMISA["mmi8i32"]["value"] == 0:
                raise ValueError("mmi8i32 extension is not supported")

            for i in range(ROWNUM):
                for j in range(4):
                    # Load accumulator, ms1 (signed), ms2 (unsigned) values
                    acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j] & 0xFFFF
                    b_value = MATRIX_REGISTER[ms2]["value"][j][i] & 0xFFFF

                    # Convert a_value to signed 16-bit
                    a_value_signed = a_value if a_value < 0x8000 else a_value - 0x10000

                    # Mixed signed-unsigned multiplication and accumulation
                    product = a_value_signed * b_value
                    acc_value += product

                    # Handle saturation if xmsaten is enabled
                    if XMCSR_FIELD["xmsaten"]["value"] == 1:
                        acc_value = min(max(acc_value, -(2 ** 63)), (2 ** 63) - 1)

                    # Store back result to accumulator (64-bit signed mask)
                    MATRIX_REGISTER[md_ms3]["value"][i][j] = acc_value & 0xFFFFFFFFFFFFFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
            
        elif size_sup == "011" and s_size == "00" and d_size == "10":
            #  mmacc.w.bp
            if XMISA["mmi4i32"]["value"] == 0:
                raise ValueError("mmi4i32 extension is not supported")

            for i in range(ROWNUM):
                for j in range(4 // 2):  # Partial update — only first half columns
                    # Load accumulator, ms1, ms2 values
                    acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j] & 0xFF
                    b_value = MATRIX_REGISTER[ms2]["value"][j][i] & 0xFF

                    # Convert a_value and b_value to signed 8-bit
                    a_value_signed = a_value if a_value < 0x80 else a_value - 0x100
                    b_value_signed = b_value if b_value < 0x80 else b_value - 0x100

                    # Perform signed multiplication and accumulate
                    product = a_value_signed * b_value_signed
                    acc_value += product

                    # Handle saturation if xmsaten is enabled
                    if XMCSR_FIELD["xmsaten"]["value"] == 1:
                        acc_value = min(max(acc_value, -(2 ** 31)), (2 ** 31) - 1)

                    # Store back partial result to the accumulator
                    MATRIX_REGISTER[md_ms3]["value"][i][j] = acc_value & 0xFFFFFFFF

            # Keep the upper half of the accumulator unchanged
            for i in range(ROWNUM):
                for j in range(4 // 2, 4):
                    MATRIX_REGISTER[md_ms3]["value"][i][j] &= 0xFFFFFFFF
            changed_registers.append({"name": MATRIX_REGISTER[md_ms3]["name"], "value": MATRIX_REGISTER[md_ms3]["value"]})
            
        elif size_sup == "000" and s_size == "00" and d_size == "10":
            # mmaccu.w.bp
            if XMISA["mmi4i32"]["value"] == 0:
                raise ValueError("mmi4i32 extension is not supported")

            for i in range(ROWNUM):
                # Process only first half of the columns (partial write)
                for j in range(4 // 2):
                    # Load accumulator, ms1, and ms2 values
                    acc_value = MATRIX_REGISTER[md_ms3]["value"][i][j]
                    a_value = MATRIX_REGISTER[ms1]["value"][i][j] & 0xFF
                    b_value = MATRIX_REGISTER[ms2]["value"][j][i] & 0xFF

                    # Perform unsigned multiplication and accumulation
                    product = a_value * b_value
                    acc_value += product

                    # Handle saturation if xmsaten is enabled
                    if XMCSR_FIELD["xmsaten"]["value"] == 1:
                        acc_value = min(acc_value, (2 ** 32) - 1)  # Saturate at 32-bit unsigned max

                    # Store back partial result to the accumulator
                    MATRIX_REGISTER[md_ms3]["value"][i][j] = acc_value & 0xFFFFFFFF

            # Keep the upper half of the accumulator unchanged
            for i in range(ROWNUM):
                for j in range(4 // 2, 4):
                    MATRIX_REGISTER[md_ms3]["value"][i][j] &= 0xFFFFFFFF
        changed_registers.append({"name": md_ms3, "value": MATRIX_REGISTER[md_ms3]["value"]})
    # TABLE 5: Matrix Load/Store Instructions
    if func == "0000" and uop == "01" and func3 == "000":
        rs2 = line[7:12]
        rs1 = line[12:17]
        d_size = line[20:22]
        md_ms3 = line[22:25]
        
        base_addr = REGISTERS[rs1]["value"]
        row_stride = REGISTERS[rs2]["value"]
        
        if d_size == "00":
            #  mlae8
            element_size = 8
            elements_per_row = TRLEN // (8 // 8)
        elif d_size == "01":
            # mlae16
            element_size = 16
            elements_per_row = TRLEN // (16// 8)
        elif d_size == "10":
            # mlae32
            element_size = 32
            elements_per_row = TRLEN // (32 // 8)

        elif d_size == "11":
            # mlae64
            element_size = 64
            elements_per_row = TRLEN // (64 // 8)
    
        # Perform the matrix load
        for row in range(ROWNUM):
            for element in range(elements_per_row):
                # Calculate memory address for each element
                mem_addr = base_addr + row * row_stride + element * (element_size // 8)

                # Load full element value (byte-by-byte for flexibility)
                value = 0
                for byte_offset in range(element_size // 8):
                    byte_addr = f"0x{mem_addr + byte_offset:X}"
                    value |= (MEMORIES.get(byte_addr, 0) << (byte_offset * 8))

                # Store the loaded value into the matrix register
                MATRIX_REGISTER[md_ms3]["value"][row][element] = value
        changed_registers.append({"name": md_ms3, "value": MATRIX_REGISTER[md_ms3]["value"]})
    elif func == "0001" and uop == "01" and func3 == "000":
        rs2 = line[7:12]
        rs1 = line[12:17]
        d_size = line[20:22]
        md_ms3 = line[22:25]
        
        base_addr = REGISTERS[rs1]["value"]
        row_stride = REGISTERS[rs2]["value"]
        
        if d_size == "00":
            #  mlae8
            element_size = 8
            elements_per_row = TRLEN // (8 // 8)
        elif d_size == "01":
            # mlae16
            element_size = 16
            elements_per_row = TRLEN // (16// 8)
        elif d_size == "10":
            # mlae32
            element_size = 32
            elements_per_row = TRLEN // (32 // 8)

        elif d_size == "11":
            # mlae64
            element_size = 64
            elements_per_row = TRLEN // (64 // 8)
            
        # Perform the matrix load (B matrix load style)
        for row in range(ROWNUM):
            for col in range(COLNUM):
                mem_addr = base_addr + row * row_stride + col * (element_size // 8)
                value = 0
                for byte_offset in range(element_size // 8):
                    byte_addr = mem_addr + byte_offset
                    value |= (MEMORIES.get(f"0x{byte_addr:X}", 0) << (byte_offset * 8))
                MATRIX_REGISTER[md_ms3]["value"][row][col] = value
        changed_registers.append({"name": md_ms3, "value": MATRIX_REGISTER[md_ms3]["value"]})
    #TABLE 6: Matrix Element-Wise Instructions
    elif func == "0000" and uop == "00" and func3 == "001":
        # Extract registers
        ms1 = line[14:17]
        md = line[22:25]
        ctrl = line[6:9]
        s_size = line[12:14]
        d_size = line[20:22]

        # mfcvtl.h.e4
        if ctrl == "000" and s_size == "00" and d_size == "01":
            if XMISA["mmf8f16"]["value"] == 0 or XMISA["mfew"]["value"] == 0:
                raise ValueError("mmf8f16 or mfew extension is not supported")
        
            for i in range(ROWNUM):
                for j in range(2, 4):
                    # Load 8-bit value from ms1
                    value = MATRIX_REGISTER[ms1]["value"][i][j] & 0xFF
                    value = bin_to_float(value, "fp8_e4", "fp16")
                    MATRIX_REGISTER[md]["value"][i][j] = value
                    
        
        if ctrl == "111" and s_size == "10" and d_size == "10":
            # mn4cliphu: Pack 32-bit fixed-point to 8-bit unsigned, write to second quarter of md
            if XMISA["mmi4i32"]["value"] == 0 or XMISA["miew"]["value"] == 0:
                raise ValueError("mmi4i32 or miew extension is not supported")
            
            for i in range(ROWNUM):  # 4 rows
                # Process only the element corresponding to the second quarter
                j = 1  # Index 1 is the second quarter in a 4-element row (0, 1, 2, 3)
                
                # Use the source value from ms2 (values to pack) and shift amount from ms1
                source_value = MATRIX_REGISTER[ms2]["value"][i][j]
                
                # Extract the scaling shift amount from ms1 (5 bits for 32-bit source)
                shift_amount = MATRIX_REGISTER[ms1]["value"][i][j] & 0x1F
                
                # To avoid negative shifts, if shift_amount is zero, use source_value directly
                if shift_amount == 0:
                    scaled_value = source_value
                else:
                    # Perform shifting with rounding: shift right by shift_amount,
                    # then add 1 if the bit just below the shift position is set
                    scaled_value = (source_value >> shift_amount) + ((source_value >> (shift_amount - 1)) & 1)
                
                # Apply saturation to clamp scaled_value within 8-bit unsigned range (0 to 255)
                if scaled_value > 255:
                    scaled_value = 255
                    XMCSR_FIELD["xmsat"]["value"] = 1
                elif scaled_value < 0:
                    scaled_value = 0
                    XMCSR_FIELD["xmsat"]["value"] = 1
                
                # Write back the computed scaled value into the second quarter of md
                # For a 4x4 matrix (4 elements per row), second quarter is index 1
                MATRIX_REGISTER[md]["value"][i][j] = scaled_value & 0xFF  # Mask to 8-bit
            
        elif ctrl != "111" and s_size == "10" and d_size == "10":
            # mn4cliphu.w.mv.i: Matrix conversion with immediate vector broadcast.
            # A row from ms1 is selected by uimm3 and broadcasted as shift amounts.
            # The computed (scaled) value from ms2 is written into the second quarter of md.
            if XMISA["mmi4i32"]["value"] == 0 or XMISA["miew"]["value"] == 0:
                raise ValueError("mmi4i32 or miew extension is not supported")
            
            # Extract a 3-bit immediate (uimm3) to select a row from ms1.
            uimm3 = int(line[23:26], 2)
            # Ensure uimm3 is within valid row range (0–3 for 4 rows)
            uimm3 = min(uimm3, ROWNUM - 1)
            # Broadcast row from ms1 (shift amounts)
            broadcast_row = MATRIX_REGISTER[ms1]["value"][uimm3]
            
            for i in range(ROWNUM):  # 4 rows
                # Process only the second quarter (index 1)
                j = 1  # Second quarter in a 4-element row (0, 1, 2, 3)
                
                # Use the source value from ms2 and broadcasted shift amount from ms1
                source_value = MATRIX_REGISTER[ms2]["value"][i][j]
                shift_amount = broadcast_row[j] & 0x1F  # 5-bit shift for 32-bit source
                
                # To avoid negative shifts, if shift_amount is zero, use source_value directly
                if shift_amount == 0:
                    scaled_value = source_value
                else:
                    # Perform shifting with rounding: shift right by shift_amount,
                    # then add 1 if the bit just below the shift position is set
                    scaled_value = (source_value >> shift_amount) + ((source_value >> (shift_amount - 1)) & 1)
                
                # Apply saturation to clamp scaled_value within 8-bit unsigned range
                if scaled_value > 255:
                    scaled_value = 255
                    XMCSR_FIELD["xmsat"]["value"] = 1
                elif scaled_value < 0:
                    scaled_value = 0
                    XMCSR_FIELD["xmsat"]["value"] = 1
                
                # Write back the computed scaled value into the second quarter of md (index 1)
                MATRIX_REGISTER[md]["value"][i][j] = scaled_value & 0xFF  # Mask to 8-bit
        elif ctrl == "111" and s_size == "01" and d_size == "01":
            # mfadd.h.mm: Element-wise FP16 addition: md = ms1 + ms2
            if XMISA["mmf16f16"]["value"] == 0:
                raise ValueError("mmf16f16 extension is not supported")
            
            for i in range(ROWNUM):
                for j in range(4):
                    # Extract the stored 32-bit values from source registers.
                    # The actual FP16 value is in the lower 16 bits.
                    a_val_int = MATRIX_REGISTER[ms1]["value"][i][j]
                    b_val_int = MATRIX_REGISTER[ms2]["value"][i][j]
                    
                    a_fp16_bits = a_val_int & 0xFFFF
                    b_fp16_bits = b_val_int & 0xFFFF
                    
                    # Convert the 16-bit binary (little-endian) to FP16 using NumPy.
                    a_fp16 = np.frombuffer(a_fp16_bits.to_bytes(2, byteorder='little'), dtype=np.float16)[0]
                    b_fp16 = np.frombuffer(b_fp16_bits.to_bytes(2, byteorder='little'), dtype=np.float16)[0]
                    
                    # Perform the FP16 addition.
                    result_fp16 = a_fp16 + b_fp16
                    
                    # Convert the FP16 result back into its 16-bit binary representation.
                    result_bytes = np.float16(result_fp16).tobytes()
                    result_int = int.from_bytes(result_bytes, byteorder='little')
                    
                    # NaN-box the result: place the 16-bit result in the lower half of a 32-bit word,
                    # and set the upper 16 bits to all ones.
                    nan_boxed_result = (0xFFFF << 16) | result_int
                    
                    MATRIX_REGISTER[md]["value"][i][j] = nan_boxed_result
        elif ctrl != "111" and s_size == "01" and d_size == "01":
        # mfadd.h.mv.i
            if XMISA["mmf16f16"]["value"] == 0:
                raise ValueError("mmf16f16 extension is not supported")
            
            b_index = int(ctrl, 2)
            for i in range(ROWNUM):
                
                for j in range(4):
                    # Extract the stored 32-bit values from source registers.
                    # The actual FP16 value is in the lower 16 bits.
                    a_val = MATRIX_REGISTER[ms1]["value"][i][j]
                    b_val = MATRIX_REGISTER[ms2]["value"][b_index][j]
                
                    a_fp16_bits = a_val & 0xFFFF
                    b_fp16_bits = b_val & 0xFFFF
                    
                    # Convert the 16-bit binary (little-endian) to FP16 using NumPy.
                    a_fp16 = np.frombuffer(a_fp16_bits.to_bytes(2, byteorder='little'), dtype=np.float16)[0]
                    b_fp16 = np.frombuffer(b_fp16_bits.to_bytes(2, byteorder='little'), dtype=np.float16)[0]
                    
                    # Perform the FP16 addition.
                    result_fp16 = a_fp16 + b_fp16
                    
                    # Convert the FP16 result back into its 16-bit binary representation.
                    result_bytes = np.float16(result_fp16).tobytes()
                    result_int = int.from_bytes(result_bytes, byteorder='little')
                    
                    # NaN-box the result: place the 16-bit result in the lower half of a 32-bit word,
                    # and set the upper 16 bits to all ones.
                    nan_boxed_result = (0xFFFF << 16) | result_int
                    
                    MATRIX_REGISTER[md]["value"][i][j] = nan_boxed_result
        changed_registers.append({"name": md, "value": MATRIX_REGISTER[md]["value"]})
    
    elif func == "0100" and uop == "01" and func3 == "001":
        ctrl = line[6:9]
        ms2 = line[9:12]
        ms1 = line[14:17]
        md = line[22:25]
        
        if ctrl == "111" and s_size == "01" and d_size == "01":
            # mfmin.s.mm
            if XMISA["mmf32f32"]["value"] == 0:
                raise ValueError("mmf32f32 extension is not supported")

            for i in range(ROWNUM):
                for j in range(4):
                    # Extract the stored 32-bit values from source registers.
                    a_val = MATRIX_REGISTER[ms1]["value"][i][j]
                    b_val = MATRIX_REGISTER[ms2]["value"][i][j]
                    
                    a_val = int(pt.tensor(a_val, dtype=pt.float32).item())
                    b_val = int(pt.tensor(b_val, dtype=pt.float32).item())
                    # Perform the FP32 max
                    result_fp32 = max(a_val, b_val)
                    
                    MATRIX_REGISTER[md]["value"][i][j] = np.float32(result_fp32)
                    
        elif ctrl != "111" and s_size == "01" and d_size == "01":
            # mfmin.s.mv.i
            if XMISA["mmf32f32"]["value"] == 0:
                raise ValueError("mmf32f32 extension is not supported")
            
            b_index = int(ctrl, 2)
            b_broadcast = MATRIX_REGISTER[ms2]["value"][b_index]
            for i in range(ROWNUM):
                for j in range(4):
                    # Extract the stored 32-bit values from source registers.
                    a_val = MATRIX_REGISTER[ms1]["value"][i][j]
                    b_val = b_broadcast[j]
                    
                    a_val = int(pt.tensor(a_val, dtype=pt.float32).item())
                    b_val = int(pt.tensor(b_val, dtype=pt.float32).item())
                    # Perform the FP32 max
                    result_fp32 = max(a_val, b_val)
                    
                    MATRIX_REGISTER[md]["value"][i][j] = np.float32(result_fp32)
            changed_registers.append({"name": md, "value": MATRIX_REGISTER[md]["value"]})

    print_register_changes(changed_registers)
    
    if pc1 != current_address:
        return current_address
    else:
        pc1 = int(pc1) + 4
        return str(pc1)
    

def PrintMemory(output_file_path):
    with open(output_file_path, "w") as output_file:
        base_address = 0x10010000
        for i in range(0, len(MEMORIES), 8):
            output_file.write(f"0x{base_address + i * 4:08X}    ")
            for j in range(0, 32, 4):
                output_file.write(f"{MEMORIES.get(base_address + i + j, 0):08X} ")
            output_file.write("\n")