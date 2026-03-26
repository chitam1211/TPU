#!/usr/bin/env python3
"""
Test script for Load/Store instruction group - Sequential Testing
Run directly in the iss directory

Tests each load/store pair separately (one pair at a time):
1. mlae32/msae32 - Float32 (tr0)
2. mlae16/msae16 - Float16 (tr1)  
3. mlbe8/msbe8 - Int8 (tr2)
4. mlce32/msce32 - Float32 column (acc0)
5. mlce8/msce8 - Int8 column (acc1)

Usage:
    python test_loadstore.py                    # Interactive mode with fixed values
    python test_loadstore.py --auto             # Auto mode with fixed values
    python test_loadstore.py --random           # Interactive mode with random values
    python test_loadstore.py --auto --random    # Auto mode with random values
"""

import sys
import os
from pathlib import Path
import struct
import random
import argparse

# Add parent directory to sys.path
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR.parent))

# Import binary printing utilities
from iss.binary_print_utils import print_instruction_binary, print_register_binary_512bit

# Test cases definition
TEST_CASES = [
    {
        'name': 'mlae32/msae32',
        'description': 'Load/Store 32-bit float (tr0)',
        'load_instr': 'mlae32 tr0, (x1), x2',
        'store_instr': 'msae32 tr0, (x9), x2',
        'input_addr': 0x100,
        'output_addr': 0x140,
        'register_type': 'tr',
        'register_num': 0,
        'is_float': True,
    },
    {
        'name': 'mlae16/msae16',
        'description': 'Load/Store 16-bit float (tr1)',
        'load_instr': 'mlae16 tr1, (x3), x4',
        'store_instr': 'msae16 tr1, (x11), x4',
        'input_addr': 0x200,
        'output_addr': 0x240,
        'register_type': 'tr',
        'register_num': 1,
        'is_float': True,
    },
    {
        'name': 'mlbe8/msbe8',
        'description': 'Load/Store 8-bit integer (tr2)',
        'load_instr': 'mlbe8 tr2, (x5), x6',
        'store_instr': 'msbe8 tr2, (x12), x6',
        'input_addr': 0x300,
        'output_addr': 0x340,
        'register_type': 'tr',
        'register_num': 2,
        'is_float': False,
    },
    {
        'name': 'mlbe32/msbe32',
        'description': 'Load/Store 32-bit float B matrix (tr3)',
        'load_instr': 'mlbe32 tr3, (x17), x18',
        'store_instr': 'msbe32 tr3, (x19), x18',
        'input_addr': 0x400,
        'output_addr': 0x440,
        'register_type': 'tr',
        'register_num': 3,
        'is_float': True,
    },
    {
        'name': 'mlce32/msce32',
        'description': 'Load/Store 32-bit float column (acc0)',
        'load_instr': 'mlce32 acc0, (x7), x8',
        'store_instr': 'msce32 acc0, (x13), x10',
        'input_addr': 0x100,
        'output_addr': 0x380,
        'register_type': 'acc',
        'register_num': 0,
        'is_float': True,
    },
    {
        'name': 'mlce8/msce8',
        'description': 'Load/Store 8-bit integer column (acc1)',
        'load_instr': 'mlce8 acc1, (x14), x15',
        'store_instr': 'msce8 acc1, (x16), x10',
        'input_addr': 0x300,
        'output_addr': 0x3C0,
        'register_type': 'acc',
        'register_num': 1,
        'is_float': False,
    },
]

# Global GPR state for lookup
GPR_STATE = {
    0: 0,       # zero
    1: 0x100,   # base addr for mlae32 (float32 matrix)
    2: 0x10,    # stride = 16 bytes (4 float32) - used for both load and store
    3: 0x200,   # base addr for mlae16 (float16 data)
    4: 0x08,    # stride = 8 bytes (4 float16) - used for both load and store
    5: 0x300,   # base addr for mlbe8 (int8 data)
    6: 0x04,    # stride = 4 bytes (4 int8) - used for both load and store
    7: 0x100,   # base addr for mlce32 (column load from float32)
    8: 0x10,    # stride for mlce32 column (16 bytes per row)
    9: 0x140,   # output address for msae32
    10: 0x10,   # output stride for column operations (msce32/msce8)
    11: 0x240,  # output address for msae16
    12: 0x340,  # output address for msbe8
    13: 0x380,  # output address for msce32
    14: 0x300,  # base addr for mlce8 (column load from int8)
    15: 0x10,   # stride for mlce8 column (16 bytes per row, not 4!)
    16: 0x3C0,  # output address for msce8
    17: 0x400,  # base addr for mlbe32 (float32 B matrix)
    18: 0x10,   # stride for mlbe32 (16 bytes per row)
    19: 0x440,  # output address for msbe32
}

def get_instruction_params(instr_str):
    """Extract base and stride registers and their values from instruction string.
    Format example: 'mlae32 tr0, (x1), x2' -> base=x1, stride=x2
    """
    import re
    # Match pattern like: instr reg, (xBase), xStride
    match = re.search(r'\((x\d+)\),\s*(x\d+)', instr_str)
    if match:
        base_reg_name = match.group(1)
        stride_reg_name = match.group(2)
        
        base_reg_num = int(base_reg_name[1:])
        stride_reg_num = int(stride_reg_name[1:])
        
        base_val = GPR_STATE.get(base_reg_num, 0)
        stride_val = GPR_STATE.get(stride_reg_num, 0)
        
        return base_reg_name, base_val, stride_reg_name, stride_val
    return None, 0, None, 0


def float32_to_hex(value):
    """Convert float32 to hex string"""
    bytes_val = struct.pack('<f', value)  # Little-endian float
    return ' '.join(f'{b:02X}' for b in bytes_val)


def float16_to_hex(value):
    """Convert float16 to hex string (2 bytes)"""
    try:
        import numpy as np
        f16 = np.float16(value)
        bytes_val = f16.tobytes()
        return ' '.join(f'{b:02X}' for b in bytes_val)
    except ImportError:
        # Fallback if numpy not available
        return "00 3C"  # 1.0 in float16


def int8_to_hex(value):
    """Convert int8 to hex string"""
    return f'{value & 0xFF:02X}'


def hex_to_float32(hex_str):
    """Convert 4-byte hex string to float32"""
    try:
        byte_values = bytes.fromhex(hex_str.replace(' ', ''))
        return struct.unpack('<f', byte_values)[0]
    except (ValueError, struct.error):
        return float('nan')

def hex_to_float16(hex_str):
    """Convert 2-byte hex string to float16"""
    try:
        import numpy as np
        byte_values = bytes.fromhex(hex_str.replace(' ', ''))
        return np.frombuffer(byte_values, dtype=np.float16)[0]
    except (ImportError, ValueError, struct.error):
        return float('nan')

def hex_to_int8(hex_str):
    """Convert 1-byte hex string to int8"""
    try:
        byte_value = int(hex_str, 16)
        return byte_value if byte_value < 128 else byte_value - 256  # Handle signed int
    except ValueError:
        return 0

def hex_to_uint32(hex_str):
    """Convert 4-byte hex string to uint32"""
    try:
        return int(hex_str.replace(' ', ''), 16)
    except ValueError:
        return 0

def hex_to_uint16(hex_str):
    """Convert 2-byte hex string to uint16"""
    try:
        return int(hex_str.replace(' ', ''), 16)
    except ValueError:
        return 0

def hex_to_uint8(hex_str):
    """Convert 1-byte hex string to uint8"""
    try:
        return int(hex_str, 16)
    except ValueError:
        return 0

def int_to_hex_le(val, width_bytes):
    """Convert integer to little-endian hex string (e.g. 0x4214B975 -> '75 B9 14 42')"""
    try:
        val = int(val)
        hex_bytes = []
        for _ in range(width_bytes):
            hex_bytes.append(f"{val & 0xFF:02X}")
            val >>= 8
        return " ".join(hex_bytes)
    except:
        return "00" * width_bytes


def generate_random_test_data():
    """Generate random test data for memory"""
    test_data = {}
    
    # --- 1. Float32 matrix 4x4 at 0x100-0x13F ---
    print("\n[Random Data] Generating float32 matrix 4x4...")
    float32_values = [random.uniform(1.0, 100.0) for _ in range(16)]
    
    print(f"  Row 0: {float32_values[0]:.2f}, {float32_values[1]:.2f}, {float32_values[2]:.2f}, {float32_values[3]:.2f}")
    print(f"  Row 1: {float32_values[4]:.2f}, {float32_values[5]:.2f}, {float32_values[6]:.2f}, {float32_values[7]:.2f}")
    print(f"  Row 2: {float32_values[8]:.2f}, {float32_values[9]:.2f}, {float32_values[10]:.2f}, {float32_values[11]:.2f}")
    print(f"  Row 3: {float32_values[12]:.2f}, {float32_values[13]:.2f}, {float32_values[14]:.2f}, {float32_values[15]:.2f}")
    
    for row in range(4):
        addr = 0x100 + row * 0x10
        hex_str = ' '.join([float32_to_hex(float32_values[row*4 + i]) for i in range(4)])
        test_data[addr] = hex_str
    
    # --- 2. Float16 data at 0x200-0x23F ---
    print("\n[Random Data] Generating float16 data...")
    try:
        import numpy as np
        float16_values = [random.uniform(0.5, 50.0) for _ in range(64)]
        print(f"  First 8 values: {', '.join(f'{v:.2f}' for v in float16_values[:8])}")
        
        for line_idx in range(4):
            addr = 0x200 + line_idx * 0x10
            hex_str = ' '.join([float16_to_hex(float16_values[line_idx*8 + i]) for i in range(8)])
            test_data[addr] = hex_str
    except ImportError:
        print("  Warning: numpy not available, using fixed float16 data")
        test_data[0x200] = "00 3C 00 40 00 42 00 44 00 46 00 48 00 4A 00 4C"
        test_data[0x210] = "00 4E 00 50 00 51 00 52 00 53 00 54 00 55 00 56"
        test_data[0x220] = "00 57 00 58 00 59 00 5A 00 5B 00 5C 00 5D 00 5E"
        test_data[0x230] = "00 5F 80 30 00 31 80 31 00 32 80 32 00 33 80 33"
    
    # --- 3. Int8 data at 0x300-0x33F ---
    print("\n[Random Data] Generating int8 data...")
    int8_values = [random.randint(1, 127) for _ in range(64)]
    print(f"  First 16 values: {', '.join(str(v) for v in int8_values[:16])}")
    
    for line_idx in range(4):
        addr = 0x300 + line_idx * 0x10
        hex_str = ' '.join([int8_to_hex(int8_values[line_idx*16 + i]) for i in range(16)])
        test_data[addr] = hex_str
    
    # --- 4. Float32 B matrix at 0x400-0x43F (for mlbe32/msbe32) ---
    print("\n[Random Data] Generating float32 B matrix 4x4...")
    float32_b_values = [random.uniform(1.0, 100.0) for _ in range(16)]
    print(f"  Row 0: {float32_b_values[0]:.2f}, {float32_b_values[1]:.2f}, {float32_b_values[2]:.2f}, {float32_b_values[3]:.2f}")
    
    for row in range(4):
        addr = 0x400 + row * 0x10
        hex_str = ' '.join([float32_to_hex(float32_b_values[row*4 + i]) for i in range(4)])
        test_data[addr] = hex_str
    
    # --- 5. Output region (initially zeros) ---
    for addr in [0x140, 0x150, 0x160, 0x170, 0x240, 0x340, 0x380, 0x390, 0x3A0, 0x3B0, 0x3C0, 0x3D0, 
                 0x440, 0x450, 0x460, 0x470]:  # Added 0x440-0x470 for msbe32 output
        test_data[addr] = "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"
    
    return test_data


def setup_test_data():
    """Prepare test data in memory.txt and gpr.txt (called once at start)"""
    print("\n" + "="*80)
    print("INITIAL SETUP: PREPARING TEST DATA")
    print("="*80)
    
    iss_dir = SCRIPT_DIR
    
    # --- 1. Setup Memory ---
    print("\n[1] Setting up memory.txt...")
    memory_file = iss_dir / "memory.txt"
    
    with open(memory_file, 'r', encoding='utf-8') as f:
        memory_lines = f.readlines()
    
    test_data = generate_random_test_data()
    
    new_memory_lines = []
    for line in memory_lines:
        if line.startswith('#') or not line.strip():
            new_memory_lines.append(line)
            continue
        
        if ':' in line:
            addr_part = line.split(':')[0].strip()
            try:
                addr = int(addr_part, 16)
                if addr in test_data:
                    new_memory_lines.append(f"{addr_part}: {test_data[addr]}\n")
                else:
                    new_memory_lines.append(line)
            except:
                new_memory_lines.append(line)
        else:
            new_memory_lines.append(line)
    
    with open(memory_file, 'w', encoding='utf-8') as f:
        f.writelines(new_memory_lines)
    
    print(f"    [OK] Memory updated with random test data")
    print(f"         - 0x100: Float32 matrix 4x4")
    print(f"         - 0x200: Float16 data")
    print(f"         - 0x300: Int8 data")
    print(f"         - 0x140,0x240,0x340,0x380,0x3C0: Output areas")
    
    # --- 2. Setup GPR ---
    print("\n[2] Setting up gpr.txt...")
    gpr_file = iss_dir / "gpr.txt"
    
    # Use global GPR_STATE
    gpr_values = GPR_STATE
    
    abi_names = [
        "zero", "ra", "sp", "gp", "tp",
        "t0", "t1", "t2",
        "s0", "s1",
        "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7",
        "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11",
        "t3", "t4", "t5", "t6"
    ]
    
    with open(gpr_file, 'w', encoding='utf-8') as f:
        f.write("--- General Purpose Registers (GPRs) ---\n")
        for i in range(32):
            val = gpr_values.get(i, 0)
            abi_name = abi_names[i] if i < len(abi_names) else f"x{i}"
            f.write(f"x{i:<2} ({abi_name:<7}): 0x{val:08X}\n")
    
    print(f"    [OK] GPR configured with base addresses and strides")


def create_assembly_for_test(test_info, instruction_type='all'):
    """Create assembly.txt with load, store, or both instructions."""
    assembler_dir = SCRIPT_DIR.parent / "assembler"
    assembly_file = assembler_dir / "assembly.txt"

    load_part = f"# Load instruction\n{test_info['load_instr']}"
    store_part = f"# Store instruction\n{test_info['store_instr']}"

    if instruction_type == 'load':
        instruction_body = load_part
    elif instruction_type == 'store':
        instruction_body = store_part
    else:
        instruction_body = f"{load_part}\n\n{store_part}"
    
    assembly_code = f"""# Test: {test_info['name']}
# Part: {instruction_type.upper()}

# Setup tile dimensions
msettilemi 4
msettileki 4
msettileni 4

{instruction_body}
"""
    
    with open(assembly_file, 'w', encoding='utf-8') as f:
        f.write(assembly_code)
    
    return assembly_file


def run_assembler():
    """Run assembler to generate machine code"""
    assembler_dir = SCRIPT_DIR.parent / "assembler"
    
    import subprocess
    result = subprocess.run(
        ['python', 'assembler.py'],
        cwd=str(assembler_dir),
        capture_output=True,
        text=True
    )
    
    return result.returncode == 0


def run_simulator():
    """Run simulator"""
    tpu_dir = SCRIPT_DIR.parent
    
    import subprocess
    env = os.environ.copy()
    env['PYTHONIOENCODING'] = 'utf-8'
    
    result = subprocess.run(
        ['python', '-m', 'iss.run_simulator'],
        cwd=str(tpu_dir),
        capture_output=True,
        text=True,
        encoding='utf-8',
        errors='replace',
        env=env
    )
    
    return result.returncode == 0


def verify_test(test_info):
    """Automatically verify if input matches output in memory (with tolerance for Floats)"""
    iss_dir = SCRIPT_DIR
    memory_file = iss_dir / "memory.txt"
    
    if not memory_file.exists():
        return False, "memory.txt not found"
    
    with open(memory_file, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    # Parse memory to get input and output data
    memory_data = {}
    for line in lines:
        if ':' in line and not line.startswith('#'):
            parts = line.split(':', 1)
            try:
                addr = int(parts[0].strip(), 16)
                data = parts[1].strip()
                memory_data[addr] = data
            except:
                continue
    
    # Get input and output addresses
    input_addr = test_info['input_addr']
    output_addr = test_info['output_addr']
    test_name = test_info['name']
    
    # --- Helper to compare values with tolerance ---
    import math
    def is_close(val1_hex, val2_hex, dtype):
        if val1_hex == val2_hex: return True
        
        try:
            if dtype == 'f32':
                v1 = hex_to_float32(val1_hex)
                v2 = hex_to_float32(val2_hex)
                # Allow small error due to float conversion round-trips
                # 1e-5 is sufficient for single precision round-trip noise
                return math.isclose(v1, v2, rel_tol=1e-5, abs_tol=1e-5)
            elif dtype == 'f16':
                v1 = hex_to_float16(val1_hex)
                v2 = hex_to_float16(val2_hex)
                # Float16 has lower precision, allow larger tolerance
                return math.isclose(v1, v2, rel_tol=1e-3, abs_tol=1e-3)
            else:
                return val1_hex == val2_hex
        except:
            return False

    # Check if this is a column operation
    is_column_op = 'mlc' in test_name or 'msc' in test_name
    
    # Determine Data Type for tolerance check
    dtype = 'int'
    if 'e32' in test_name: dtype = 'f32'
    elif 'e16' in test_name: dtype = 'f16'

    if is_column_op:
        # Determine stride and bytes per row
        if 'ce32' in test_name:
            stride = 0x10
            bytes_per_row = 16
            elem_size = 4
        elif 'ce8' in test_name:
            stride = 0x10
            bytes_per_row = 4
            elem_size = 1
        else:
            stride = 0x10
            bytes_per_row = 16
            elem_size = 4
        
        mismatches = []
        all_match = True
        
        for row in range(4):
            in_addr = input_addr + row * stride
            out_addr = output_addr + row * stride
            
            input_data = memory_data.get(in_addr, "")
            output_data = memory_data.get(out_addr, "")
            
            # Split into bytes
            in_bytes = input_data.split()
            out_bytes = output_data.split()
            
            # Compare element by element
            row_match = True
            for i in range(0, bytes_per_row, elem_size):
                if i + elem_size > len(in_bytes) or i + elem_size > len(out_bytes):
                    row_match = False; break
                
                val_in = ' '.join(in_bytes[i:i+elem_size])
                val_out = ' '.join(out_bytes[i:i+elem_size])
                
                if not is_close(val_in, val_out, dtype):
                    row_match = False
                    break
            
            if not row_match:
                all_match = False
                # Reconstruct full row string for display
                in_str = ' '.join(in_bytes[:bytes_per_row])
                out_str = ' '.join(out_bytes[:bytes_per_row])
                mismatches.append(f"Row {row}: Input '{in_str}' != Output '{out_str}'")
        
        if all_match:
            return True, "All rows match ✓"
        else:
            return False, "Mismatch found:\n    " + "\n    ".join(mismatches)
    
    else:
        # Row operations
        if 'e32' in test_name:
            stride = 0x10; bytes_per_row = 16; elem_size = 4
        elif 'e16' in test_name:
            stride = 0x08; bytes_per_row = 8; elem_size = 2
        elif 'e8' in test_name:
            stride = 0x04; bytes_per_row = 4; elem_size = 1
        else:
            stride = 0x10; bytes_per_row = 16; elem_size = 4
        
        # Collect all output data
        output_all_bytes = []
        for row in range(4):
            out_addr = output_addr + row * stride
            if out_addr in memory_data:
                output_all_bytes.extend(memory_data[out_addr].split())
        
        if not output_all_bytes and output_addr in memory_data:
            output_all_bytes = memory_data[output_addr].split()
        
        mismatches = []
        all_match = True
        
        for row in range(4):
            in_addr = input_addr + row * stride
            input_data = memory_data.get(in_addr, "")
            in_bytes = input_data.split()[:bytes_per_row]
            
            start_idx = row * bytes_per_row
            end_idx = start_idx + bytes_per_row
            out_bytes = output_all_bytes[start_idx:end_idx]
            
            # Compare element by element
            row_match = True
            if len(in_bytes) != len(out_bytes):
                row_match = False
            else:
                for i in range(0, bytes_per_row, elem_size):
                    val_in = ' '.join(in_bytes[i:i+elem_size])
                    val_out = ' '.join(out_bytes[i:i+elem_size])
                    
                    if not is_close(val_in, val_out, dtype):
                        row_match = False
                        break
            
            if not row_match:
                all_match = False
                in_str = ' '.join(in_bytes)
                out_str = ' '.join(out_bytes)
                mismatches.append(f"Row {row}: Input '{in_str}' != Output '{out_str}'")
        
        if all_match:
            return True, "All rows match ✓"
        else:
            return False, "Mismatch found:\n    " + "\n    ".join(mismatches)


def display_register_state(test_info, success):
    """Displays the state of the target register after a load operation."""
    print("\n" + "-"*80)
    print("[Verification of LOAD Operation]")
    
    # Print binary instruction
    print_instruction_binary(test_info['load_instr'])

    if not success:
        print("  ✗ FAIL - Simulator failed to run.")
        print("-"*80)
        return False

    iss_dir = SCRIPT_DIR
    
    # --- 1. Display Instruction Parameters (Base, Stride) ---
    base_reg, base_val, stride_reg, stride_val = get_instruction_params(test_info['load_instr'])
    if base_reg:
        print(f"  Instruction Parameters:")
        print(f"    - Base Address ({base_reg}) : 0x{base_val:03X}")
        print(f"    - Stride       ({stride_reg}) : 0x{stride_val:02X}")
    
    # --- 2. Display Source Memory Data ---
    memory_file = iss_dir / "memory.txt"
    input_addr = test_info['input_addr']
    test_name = test_info['name']
    
    # Determine format helpers
    if 'e32' in test_name:
        bytes_per_el, el_per_row, hex_to_val, val_format = (4, 4, hex_to_float32, "{: >10.4f}")
        hex_to_uint = hex_to_uint32
    elif 'e16' in test_name:
        bytes_per_el, el_per_row, hex_to_val, val_format = (2, 4, hex_to_float16, "{: >10.4f}")
        hex_to_uint = hex_to_uint16
    elif 'e8' in test_name:
        bytes_per_el, el_per_row, hex_to_val, val_format = (1, 4, hex_to_int8, "{: >4d}")
        hex_to_uint = hex_to_uint8
    else:
        bytes_per_el, el_per_row, hex_to_val, val_format = (4, 4, hex_to_float32, "{: >10.4f}")
        hex_to_uint = hex_to_uint32

    print(f"\n  [Memory Source Data] (Address: 0x{input_addr:03X}):")
    if memory_file.exists():
        with open(memory_file, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        memory_data = {}
        for line in lines:
            if ':' in line and not line.startswith('#'):
                parts = line.split(':', 1)
                try:
                    addr = int(parts[0].strip(), 16)
                    memory_data[addr] = parts[1].strip().split()
                except:
                    continue
        
        for i in range(4):
            addr = input_addr + i * stride_val
            hex_list = memory_data.get(addr, [])
            vals_str = []
            int_vals = []
            for j in range(el_per_row):
                start, end = j * bytes_per_el, (j + 1) * bytes_per_el
                chunk = hex_list[start:end]
                if chunk:
                    hex_chunk = " ".join(chunk)
                    vals_str.append(val_format.format(hex_to_val(hex_chunk)))
                    # Convert to LE Hex string
                    int_val = hex_to_uint(hex_chunk)
                    int_vals.append(int_to_hex_le(int_val, bytes_per_el))
            
            display_vals = " ".join(vals_str) if vals_str else "N/A"
            display_int_vals = "(" + ", ".join(int_vals) + ")" if int_vals else ""
            print(f"    Row {i}: {display_vals} {display_int_vals}")
    else:
        print("    (memory.txt not found)")

    # --- 3. Display Register Content ---
    iss_dir = SCRIPT_DIR
    
    # Determine which register and file to check
    reg_type = test_info['register_type']
    reg_num = test_info['register_num']

    # Handle alias: tr4-tr7 are actually acc0-acc3 and stored in acc files
    if reg_type == 'tr' and reg_num >= 4:
        reg_file_prefix = 'acc'
        reg_name_prefix = 'acc' # In acc file, they are named acc0, acc1...
        reg_num = reg_num - 4  # tr4->acc0, tr5->acc1, tr6->acc2, tr7->acc3
    elif reg_type == 'tr':
        reg_file_prefix = 'matrix'
        reg_name_prefix = 'tr'
    else: # acc (acc0-acc3 directly)
        reg_file_prefix = 'acc'
        reg_name_prefix = 'acc'

    is_float = test_info['is_float']
    file_name = f"{reg_file_prefix}_float.txt" if is_float else f"{reg_file_prefix}.txt"
    reg_name_to_find = f"{reg_name_prefix}{reg_num}"
    file_path = iss_dir / file_name

    print(f"\n  [Register Content After LOAD] (Target: {reg_name_to_find}, File: {file_name}):")
    
    if not file_path.exists():
        print("  ✗ FAIL - Register state file not found!")
        print("-"*80)
        return False

    with open(file_path, 'r', encoding='utf-8') as f:
        lines = f.readlines()
        in_reg_block = False
        found = False
        for line in lines:
            if line.strip().startswith(reg_name_to_find + ':'):
                in_reg_block = True
                found = True
                print(f"  {line.strip()}")
            elif in_reg_block and (line.strip().startswith('Row') or line.strip().startswith('(')):
                print(f"    {line.strip()}")
            elif in_reg_block and ':' in line and not line.strip().startswith('('):
                break
    
    if not found:
        print("  ✗ FAIL - Register block not found in file.")
        print("-"*80)
        return False
        
    print("\n  ✓ PASS - LOAD instruction executed and register state was saved.")
    print("    (Visual inspection: Compare [Memory Source Data] with [Register Content])")
    print("-"*80)
    return True

def display_and_verify_memory(test_info, success):
    """Displays the final memory comparison and verifies the store operation."""
    print("\n" + "-"*80)
    print("[Verification of STORE Operation]")
    
    # Print binary instruction
    print_instruction_binary(test_info['store_instr'])

    if not success:
        print("  ✗ FAIL - Simulator failed to run for STORE.")
        print("-"*80)
        return False
    
    iss_dir = SCRIPT_DIR

    # --- Display Instruction Parameters ---
    base_reg, base_val, stride_reg, stride_val = get_instruction_params(test_info['store_instr'])
    if base_reg:
        print(f"  Instruction Parameters:")
        print(f"    - Base Address ({base_reg}) : 0x{base_val:03X}")
        print(f"    - Stride       ({stride_reg}) : 0x{stride_val:02X}")
        
    # Determine format helpers (Moved up for use in Expected Data display)
    test_name = test_info['name']
    if 'e32' in test_name:
        stride, bytes_per_el, el_per_row, hex_to_val, val_format = (0x10, 4, 4, hex_to_float32, "{: >10.4f}")
    elif 'e16' in test_name:
        stride, bytes_per_el, el_per_row, hex_to_val, val_format = (0x08, 2, 4, hex_to_float16, "{: >10.4f}")
    elif 'e8' in test_name:
        stride, bytes_per_el, el_per_row, hex_to_val, val_format = (0x04, 1, 4, hex_to_int8, "{: >4d}")
    else: # Default for column ops
        stride, bytes_per_el, el_per_row, hex_to_val, val_format = (0x10, 4, 4, hex_to_float32, "{: >10.4f}")

    # --- 1. Display Expected Data from Register ---
    # Determine which register and file to read
    reg_type = test_info['register_type']
    reg_num = test_info['register_num']
    is_float = test_info['is_float']

    # Handle alias: tr4-tr7 are actually acc0-acc3
    if reg_type == 'tr' and reg_num >= 4:
        reg_file_prefix = 'acc'
        reg_name_prefix = 'acc'
        reg_num = reg_num - 4  # tr4->acc0, tr5->acc1, etc.
    elif reg_type == 'tr':
        reg_file_prefix = 'matrix'
        reg_name_prefix = 'tr'
    else:
        reg_file_prefix = 'acc'
        reg_name_prefix = 'acc'

    file_name = f"{reg_file_prefix}_float.txt" if is_float else f"{reg_file_prefix}.txt"
    reg_name_to_find = f"{reg_name_prefix}{reg_num}"
    file_path = iss_dir / file_name
    
    print(f"\n  [Expected Data from Register] (Source: {reg_name_to_find}, File: {file_name}):")
    if file_path.exists():
        with open(file_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
            in_reg_block = False
            for line in lines:
                if line.strip().startswith(reg_name_to_find + ':'):
                    in_reg_block = True
                    # Print register header
                    print(f"    {line.strip()}")
                elif in_reg_block and line.strip().startswith('('):
                     # Print type info line
                     print(f"    {line.strip()}")
                elif in_reg_block and line.strip().startswith('Row'):
                    # Parse row data: "Row 0: 1.23 4.56 ... (123, 456, ...)"
                    try:
                        parts = line.split('(')
                        float_part = parts[0].strip() # "Row 0: 1.23 4.56 ..."
                        int_part = parts[1].strip().rstrip(')') # "123, 456, ..."
                        
                        # Process ints to hex
                        int_strs = int_part.split(',')
                        hex_strs = []
                        for s in int_strs:
                            hex_strs.append(int_to_hex_le(s.strip(), bytes_per_el))
                        
                        hex_display = "(" + ", ".join(hex_strs) + ")"
                        print(f"    {float_part} {hex_display}")
                    except:
                        print(f"    {line.strip()}")
                elif in_reg_block and ':' in line and not line.strip().startswith('('):
                    break
    else:
        print("    (Register file not found)")

    # --- 2. Display Memory Output ---
    memory_file = iss_dir / "memory.txt"
    
    if not memory_file.exists():
        print("  ✗ FAIL - memory.txt not found!")
        print("-"*80)
        return False

    with open(memory_file, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    memory_data = {}
    for line in lines:
        if ':' in line and not line.startswith('#'):
            parts = line.split(':', 1)
            try:
                addr = int(parts[0].strip(), 16)
                memory_data[addr] = parts[1].strip().split()
            except:
                continue

    input_addr_base = test_info['input_addr']
    output_addr_base = test_info['output_addr']

    # input_lines = [] # Removed Input Data Display
    output_lines = []

    for i in range(4): # For each row
        # in_addr = input_addr_base + i * stride # Removed
        out_addr = output_addr_base + i * stride
        # in_hex_list = memory_data.get(in_addr, []) # Removed
        out_hex_list = memory_data.get(out_addr, [])
        # in_values_str = [] # Removed
        out_values_str = []

        for j in range(el_per_row):
            start, end = j * bytes_per_el, (j + 1) * bytes_per_el
            # chunk_in = in_hex_list[start:end] # Removed
            # if chunk_in: in_values_str.append(val_format.format(hex_to_val(" ".join(chunk_in)))) # Removed
            chunk_out = out_hex_list[start:end]
            if chunk_out: out_values_str.append(val_format.format(hex_to_val(" ".join(chunk_out))))

        # in_display_vals = " ".join(in_values_str) if in_values_str else "N/A" # Removed
        out_display_vals = " ".join(out_values_str) if out_values_str else "N/A"
        # in_hex_display = " ".join(in_hex_list) if in_hex_list else "N/A" # Removed
        out_hex_display = " ".join(out_hex_list) if out_hex_list else "N/A"
        
        # input_lines.append(f"  {i:<4} | 0x{in_addr:03X} | {in_display_vals:<38} | {in_hex_display}") # Removed
        output_lines.append(f"  {i:<4} | 0x{out_addr:03X} | {out_display_vals:<38} | {out_hex_display}")

    header = f"  {'Row':<4} | {'Addr':<6} | {'Values':<38} | {'Hex Data'}"
    separator = "  " + "-"*5 + "+" + "-"*8 + "+" + "-"*41 + "+" + "-"*len(header)

    # print("\n[Memory] Input Data (from source addresses):") # Removed
    # print(header); print(separator) # Removed
    # for line in input_lines: print(line) # Removed

    print("\n[Memory] Output Data (at destination addresses):")
    print(header); print(separator)
    for line in output_lines: print(line)

    success_verify, message = verify_test(test_info)
    print("\n[Final Verification]:")
    if success_verify:
        print(f"  ✓ PASS - {message}")
    else:
        print(f"  ✗ FAIL - {message}")
    
    print("-"*80)
    return success_verify


def run_single_test(test_info, test_num, total_tests):
    """Run a single test case by splitting LOAD and STORE operations."""
    print("\n" + "="*80)
    print(f"TEST {test_num}/{total_tests}: {test_info['name']}")
    print(f"Description: {test_info['description']}")
    print("="*80)
    
    # --- Part 1: Test LOAD instruction ---
    print("\n--- Part 1: Testing LOAD instruction ---")
    print(f"  Instruction: {test_info['load_instr']}")
    
    # Create assembly for LOAD
    create_assembly_for_test(test_info, instruction_type='load')
    print("\n[Step 1.1] Assembling LOAD instruction...")
    if not run_assembler():
        print("  [ERROR] Assembly failed!")
        return False
    print("  [OK] Assembly successful.")

    # Run simulator for LOAD
    print("\n[Step 1.2] Running simulator for LOAD...")
    sim_success_load = run_simulator()
    
    # Display and verify register state after LOAD
    load_passed = display_register_state(test_info, sim_success_load)
    if not load_passed:
        print("\n[HALT] LOAD part failed. Stopping test.")
        return False
        
    # Automatically proceed to STORE part

    # --- Part 2: Test STORE instruction ---
    print("\n--- Part 2: Testing STORE instruction ---")
    print(f"  Instruction: {test_info['store_instr']}")
    print("  (Simulator will use the register state saved from the LOAD part)")

    # Create assembly for STORE
    create_assembly_for_test(test_info, instruction_type='store')
    print("\n[Step 2.1] Assembling STORE instruction...")
    if not run_assembler():
        print("  [ERROR] Assembly failed!")
        return False
    print("  [OK] Assembly successful.")

    # Run simulator for STORE
    print("\n[Step 2.2] Running simulator for STORE...")
    sim_success_store = run_simulator()

    # Display and verify final memory state after STORE
    store_passed = display_and_verify_memory(test_info, sim_success_store)
    
    return store_passed


def main():
    """Main test function"""
    # Parse command line arguments
    parser = argparse.ArgumentParser(description='Test Load/Store instructions')
    parser.add_argument('--auto', action='store_true', help='Run in automated mode (no user input)')
    parser.add_argument('--random', action='store_true', help='Use random test data')
    args = parser.parse_args()
    
    auto_mode = args.auto
    random_mode = args.random
    
    print("\n" + "="*80)
    print("LOAD/STORE INSTRUCTION TEST - " + ("AUTO MODE" if auto_mode else "SEQUENTIAL MODE"))
    print("="*80)
    print("\nThis script will test each load/store pair separately:")
    for i, test in enumerate(TEST_CASES, 1):
        print(f"  {i}. {test['name']:<20} - {test['description']}")
    if not auto_mode:
        print("\nPress Enter after each test to continue to the next one.")
    print("="*80)
    
    try:
        # Initial setup (once)
        setup_test_data()
        
        print("\n" + "="*80)
        print("Setup complete! Ready to start testing.")
        print("="*80)
        
        if not auto_mode:
            input("\nPress Enter to start testing...")
        
        # Run each test
        total_tests = len(TEST_CASES)
        passed_tests = 0
        failed_tests = 0
        
        for i, test_info in enumerate(TEST_CASES, 1):
            success = run_single_test(test_info, i, total_tests)
            
            if success:
                passed_tests += 1
            else:
                failed_tests += 1
            
            if not success:
                print(f"\n[ERROR] Test {i} failed!")
            
            # Interactive pause between tests (unless in auto mode or last test)
            if not auto_mode and i < total_tests:
                input(f"\nPress Enter to continue to test {i+1}/{total_tests}...")
        
        print("\n" + "="*80)
        print("ALL TESTS COMPLETE!")
        print("="*80)
        print(f"\n[SUMMARY]")
        print(f"  ✓ Passed: {passed_tests}/{total_tests}")
        print(f"  ✗ Failed: {failed_tests}/{total_tests}")
        
        if not auto_mode:
            print("\nOutput files:")
            print(f"  - {SCRIPT_DIR / 'matrix.txt'}")
            print(f"  - {SCRIPT_DIR / 'matrix_float.txt'}")
            print(f"  - {SCRIPT_DIR / 'acc.txt'}")
            print(f"  - {SCRIPT_DIR / 'acc_float.txt'}")
            print(f"  - {SCRIPT_DIR / 'memory.txt'}")
        
        return 0
        
    except KeyboardInterrupt:
        print("\n\n[INTERRUPTED] Test stopped by user.")
        return 1
    except Exception as e:
        print(f"\n[ERROR] {e}")
        import traceback
        traceback.print_exc()
        return 1


if __name__ == '__main__':
    sys.exit(main())
