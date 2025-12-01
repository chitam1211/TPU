#!/usr/bin/env python3
"""
Test script for Element-Wise instruction group
Run directly in the iss directory

Tests element-wise operations on accumulator registers:
1. Integer operations: madd.w, msub.w, mmul.w, mmax.w, mmin.w, shifts
2. Float operations: mfadd.s, mfsub.s, mfmul.s, mfmax.s, mfmin.s (FP32)
3. Float operations: mfadd.h, mfsub.h, mfmul.h, mfmax.h, mfmin.h (FP16)

Each test:
- Initializes two accumulator registers with known values
- Performs element-wise operation: md = ms2 op ms1
- Verifies result matches expected calculation

Random mode generates different test values each run for robustness testing.
All random values are within safe ranges to avoid overflow/precision issues.

Usage:
    python test_elementwise.py                    # Interactive mode with fixed values
    python test_elementwise.py --auto             # Auto mode with fixed values
    python test_elementwise.py --random           # Interactive mode with random values
    python test_elementwise.py --auto --random    # Auto mode with random values

"""

import sys
import os
from pathlib import Path
import struct
import random

# Add parent directory to sys.path
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR.parent))

# Test cases definition
TEST_CASES = [
    # Integer operations (INT32)
    {
        'name': 'madd.w',
        'description': 'Element-wise Integer Addition (INT32)',
        'instr': 'madd.w acc0, acc2, acc1',  # md, ms2, ms1
        'md_reg': 0,
        'ms1_reg': 1,
        'ms2_reg': 2,
        'ms1_init': 10,
        'ms2_init': 5,
        'operation': lambda a, b: a + b,
        'is_float': False,
        'data_type': 'int32',
    },
    {
        'name': 'msub.w',
        'description': 'Element-wise Integer Subtraction (INT32)',
        'instr': 'msub.w acc0, acc2, acc1',  # md, ms2, ms1
        'md_reg': 0,
        'ms1_reg': 1,
        'ms2_reg': 2,
        'ms1_init': 20,
        'ms2_init': 8,
        'operation': lambda a, b: a - b,
        'is_float': False,
        'data_type': 'int32',
    },
    {
        'name': 'mmul.w',
        'description': 'Element-wise Integer Multiplication (INT32)',
        'instr': 'mmul.w acc0, acc2, acc1',  # md, ms2, ms1
        'md_reg': 0,
        'ms1_reg': 1,
        'ms2_reg': 2,
        'ms1_init': 3,
        'ms2_init': 4,
        'operation': lambda a, b: a * b,
        'is_float': False,
        'data_type': 'int32',
    },
    {
        'name': 'mmax.w',
        'description': 'Element-wise Integer Maximum (INT32)',
        'instr': 'mmax.w acc0, acc2, acc1',  # md, ms2, ms1
        'md_reg': 0,
        'ms1_reg': 1,
        'ms2_reg': 2,
        'ms1_init': 15,
        'ms2_init': 10,
        'operation': lambda a, b: max(a, b),
        'is_float': False,
        'data_type': 'int32',
    },
    {
        'name': 'mmin.w',
        'description': 'Element-wise Integer Minimum (INT32)',
        'instr': 'mmin.w acc0, acc2, acc1',  # md, ms2, ms1
        'md_reg': 0,
        'ms1_reg': 1,
        'ms2_reg': 2,
        'ms1_init': 15,
        'ms2_init': 10,
        'operation': lambda a, b: min(a, b),
        'is_float': False,
        'data_type': 'int32',
    },
    # Float32 operations
    {
        'name': 'mfadd.s',
        'description': 'Element-wise Float Addition (FP32)',
        'instr': 'mfadd.s acc0, acc2, acc1',  # md, ms2, ms1
        'md_reg': 0,
        'ms1_reg': 1,
        'ms2_reg': 2,
        'ms1_init': 10.5,
        'ms2_init': 5.25,
        'operation': lambda a, b: a + b,
        'is_float': True,
        'data_type': 'float32',
    },
    {
        'name': 'mfsub.s',
        'description': 'Element-wise Float Subtraction (FP32)',
        'instr': 'mfsub.s acc0, acc2, acc1',  # md, ms2, ms1
        'md_reg': 0,
        'ms1_reg': 1,
        'ms2_reg': 2,
        'ms1_init': 20.0,
        'ms2_init': 8.5,
        'operation': lambda a, b: a - b,
        'is_float': True,
        'data_type': 'float32',
    },
    {
        'name': 'mfmul.s',
        'description': 'Element-wise Float Multiplication (FP32)',
        'instr': 'mfmul.s acc0, acc2, acc1',  # md, ms2, ms1
        'md_reg': 0,
        'ms1_reg': 1,
        'ms2_reg': 2,
        'ms1_init': 3.5,
        'ms2_init': 2.0,
        'operation': lambda a, b: a * b,
        'is_float': True,
        'data_type': 'float32',
    },
    {
        'name': 'mfmax.s',
        'description': 'Element-wise Float Maximum (FP32)',
        'instr': 'mfmax.s acc0, acc2, acc1',  # md, ms2, ms1
        'md_reg': 0,
        'ms1_reg': 1,
        'ms2_reg': 2,
        'ms1_init': 15.5,
        'ms2_init': 10.2,
        'operation': lambda a, b: max(a, b),
        'is_float': True,
        'data_type': 'float32',
    },
    {
        'name': 'mfmin.s',
        'description': 'Element-wise Float Minimum (FP32)',
        'instr': 'mfmin.s acc0, acc2, acc1',  # md, ms2, ms1
        'md_reg': 0,
        'ms1_reg': 1,
        'ms2_reg': 2,
        'ms1_init': 15.5,
        'ms2_init': 10.2,
        'operation': lambda a, b: min(a, b),
        'is_float': True,
        'data_type': 'float32',
    },
    # Float16 operations
    {
        'name': 'mfadd.h',
        'description': 'Element-wise Float Addition (FP16)',
        'instr': 'mfadd.h acc1, acc3, acc2',  # md, ms2, ms1
        'md_reg': 1,
        'ms1_reg': 2,
        'ms2_reg': 3,
        'ms1_init': 5.5,
        'ms2_init': 3.25,
        'operation': lambda a, b: a + b,
        'is_float': True,
        'data_type': 'float16',
    },
    {
        'name': 'mfsub.h',
        'description': 'Element-wise Float Subtraction (FP16)',
        'instr': 'mfsub.h acc1, acc3, acc2',  # md, ms2, ms1
        'md_reg': 1,
        'ms1_reg': 2,
        'ms2_reg': 3,
        'ms1_init': 10.0,
        'ms2_init': 4.5,
        'operation': lambda a, b: a - b,
        'is_float': True,
        'data_type': 'float16',
    },
    {
        'name': 'mfmul.h',
        'description': 'Element-wise Float Multiplication (FP16)',
        'instr': 'mfmul.h acc1, acc3, acc2',  # md, ms2, ms1
        'md_reg': 1,
        'ms1_reg': 2,
        'ms2_reg': 3,
        'ms1_init': 2.5,
        'ms2_init': 3.0,
        'operation': lambda a, b: a * b,
        'is_float': True,
        'data_type': 'float16',
    },
    
    # Matrix register tests (tr4-tr7)
    {
        'name': 'madd.w (tile)',
        'description': 'Element-wise Integer Addition with Tile Registers (INT32)',
        'instr': 'madd.w tr4, tr6, tr5',
        'md_reg': 4,
        'ms1_reg': 5,
        'ms2_reg': 6,
        'ms1_init': 15,
        'ms2_init': 25,
        'operation': lambda a, b: a + b,
        'is_float': False,
        'data_type': 'int32',
        'use_matrix_regs': True,
    },
    {
        'name': 'msub.w (tile)',
        'description': 'Element-wise Integer Subtraction with Tile Registers (INT32)',
        'instr': 'msub.w tr4, tr6, tr5',
        'md_reg': 4,
        'ms1_reg': 5,
        'ms2_reg': 6,
        'ms1_init': 10,
        'ms2_init': 30,
        'operation': lambda a, b: a - b,
        'is_float': False,
        'data_type': 'int32',
        'use_matrix_regs': True,
    },
    {
        'name': 'mfadd.s (tile)',
        'description': 'Element-wise Float Addition with Tile Registers (FP32)',
        'instr': 'mfadd.s tr4, tr6, tr5',
        'md_reg': 4,
        'ms1_reg': 5,
        'ms2_reg': 6,
        'ms1_init': 5.5,
        'ms2_init': 10.25,
        'operation': lambda a, b: a + b,
        'is_float': True,
        'data_type': 'float32',
        'use_matrix_regs': True,
    },
    {
        'name': 'mfmul.h (tile)',
        'description': 'Element-wise Float Multiplication with Tile Registers (FP16)',
        'instr': 'mfmul.h tr5, tr7, tr6',
        'md_reg': 5,
        'ms1_reg': 6,
        'ms2_reg': 7,
        'ms1_init': 2.5,
        'ms2_init': 3.0,
        'operation': lambda a, b: a * b,
        'is_float': True,
        'data_type': 'float16',
        'use_matrix_regs': True,
    },
    
    # Shift operations (INT32)
    {
        'name': 'msrl.w',
        'description': 'Logical Shift Right (INT32)',
        'instr': 'msrl.w acc0, acc2, acc1',  # md, ms2, ms1
        'md_reg': 0,
        'ms1_reg': 1,
        'ms2_reg': 2,
        'ms1_init': 2,  # Shift amount
        'ms2_init': 16,  # Value to shift
        'operation': lambda ms2, ms1: (ms2 & 0xFFFFFFFF) >> ms1,  # ms2 >> ms1 (unsigned)
        'is_float': False,
        'data_type': 'int32',
    },
    {
        'name': 'msll.w',
        'description': 'Logical Shift Left (INT32)',
        'instr': 'msll.w acc1, acc3, acc2',  # md, ms2, ms1
        'md_reg': 1,
        'ms1_reg': 2,
        'ms2_reg': 3,
        'ms1_init': 3,  # Shift amount
        'ms2_init': 8,  # Value to shift
        'operation': lambda ms2, ms1: (ms2 << ms1) & 0xFFFFFFFF,  # ms2 << ms1 (wrap 32-bit)
        'is_float': False,
        'data_type': 'int32',
    },
    {
        'name': 'msra.w',
        'description': 'Arithmetic Shift Right (INT32)',
        'instr': 'msra.w acc2, acc0, acc3',  # md, ms2, ms1
        'md_reg': 2,
        'ms1_reg': 3,
        'ms2_reg': 0,
        'ms1_init': 2,  # Shift amount  
        'ms2_init': -16,  # Negative value to shift (test sign extension)
        'operation': lambda ms2, ms1: ms2 >> (ms1 & 0x1F) if ms2 >= 0 else (ms2 >> (ms1 & 0x1F)) | ~(0xFFFFFFFF >> (ms1 & 0x1F)),  # Arithmetic shift
        'is_float': False,
        'data_type': 'int32',
    },
    
    # Unsigned min/max operations (INT32)
    {
        'name': 'mumax.w',
        'description': 'Unsigned Maximum (INT32)',
        'instr': 'mumax.w acc3, acc1, acc2',  # md, ms2, ms1
        'md_reg': 3,
        'ms1_reg': 2,
        'ms2_reg': 1,
        'ms1_init': 0xFFFFFF00,  # Large unsigned value
        'ms2_init': 100,
        'operation': lambda a, b: max((a & 0xFFFFFFFF), (b & 0xFFFFFFFF)),  # Unsigned comparison
        'is_float': False,
        'data_type': 'int32',
    },
    {
        'name': 'mumin.w',
        'description': 'Unsigned Minimum (INT32)',
        'instr': 'mumin.w acc0, acc2, acc1',  # md, ms2, ms1
        'md_reg': 0,
        'ms1_reg': 1,
        'ms2_reg': 2,
        'ms1_init': 0xFFFFFF00,  # Large unsigned value
        'ms2_init': 100,
        'operation': lambda a, b: min((a & 0xFFFFFFFF), (b & 0xFFFFFFFF)),  # Unsigned comparison
        'is_float': False,
        'data_type': 'int32',
    },
]


def generate_random_values(test_info):
    """Generate random test values based on data type"""
    if test_info['data_type'] == 'int32':
        # Integer: -100 to 100 to avoid overflow
        ms1_val = random.randint(-100, 100)
        ms2_val = random.randint(-100, 100)
    elif test_info['data_type'] == 'float32':
        # Float32: -50.0 to 50.0
        ms1_val = random.uniform(-50.0, 50.0)
        ms2_val = random.uniform(-50.0, 50.0)
    elif test_info['data_type'] == 'float16':
        # Float16: realistic ML range (weights/activations typically -10 to 10)
        # Matches typical neural network value ranges
        ms1_val = random.uniform(-10.0, 10.0)
        ms2_val = random.uniform(-10.0, 10.0)
    else:
        ms1_val = 0
        ms2_val = 0
    
    return ms1_val, ms2_val


def setup_test_data():
    """Prepare test data - only need to initialize GPR and tile configuration"""
    print("\n" + "="*80)
    print("INITIAL SETUP: PREPARING TEST DATA")
    print("="*80)
    
    iss_dir = SCRIPT_DIR
    
    # --- Setup Config (Tile Size) ---
    print("\n[0] Setting up config.txt (Tile Configuration)...")
    config_file = iss_dir / "config.txt"
    with open(config_file, 'w', encoding='utf-8') as f:
        f.write("--- Configuration CSRs ---\n")
        f.write("mtilem  : 0x00000004\n")  # M=4
        f.write("mtilen  : 0x00000004\n")  # N=4
        f.write("mtilek  : 0x00000004\n")  # K=4
        f.write("xmxrm   : 0x00000000\n")
        f.write("xmfrm   : 0x00000000\n")
        f.write("xmsaten : 0x00000000\n")
    print("    [OK] Tile configured: M=4, N=4, K=4")
    
    # --- Setup GPR ---
    print("\n[1] Setting up gpr.txt...")
    gpr_file = iss_dir / "gpr.txt"
    
    gpr_values = {0: 0}  # zero register
    
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
    
    print(f"    [OK] GPR configured")


def reset_matrix_registers(test_info):
    """Reset matrix/memory for matrix register tests"""
    iss_dir = Path(__file__).parent
    
    # Setup memory.txt with initial values
    memory_file = iss_dir / 'memory.txt'
    ms1_val = test_info['ms1_init']
    ms2_val = test_info['ms2_init']
    
    with open(memory_file, 'w', encoding='utf-8') as f:
        f.write("--- Memory (Byte-Addressable) ---\n")
        # Matrix 1 at address 0 (4x4 matrix = 64 bytes for int32)
        for row in range(4):
            for col in range(4):
                addr = row * 16 + col * 4
                if test_info['is_float']:
                    bits = struct.unpack('I', struct.pack('f', float(ms1_val)))[0]
                    f.write(f"0x{addr:08X}: 0x{bits:08X}\n")
                else:
                    val = int(ms1_val) & 0xFFFFFFFF
                    f.write(f"0x{addr:08X}: 0x{val:08X}\n")
        
        # Matrix 2 at address 64
        for row in range(4):
            for col in range(4):
                addr = 64 + row * 16 + col * 4
                if test_info['is_float']:
                    bits = struct.unpack('I', struct.pack('f', float(ms2_val)))[0]
                    f.write(f"0x{addr:08X}: 0x{bits:08X}\n")
                else:
                    val = int(ms2_val) & 0xFFFFFFFF
                    f.write(f"0x{addr:08X}: 0x{val:08X}\n")
    
    # Initialize tile registers instead of memory for tile register tests
    if test_info['is_float']:
        matrix_file = iss_dir / 'matrix_float.txt'
    else:
        matrix_file = iss_dir / 'matrix.txt'
    
    # Build values for source registers
    ms1_val = test_info['ms1_init']
    ms2_val = test_info['ms2_init']
    md_val = 0.0 if test_info['is_float'] else 0
    
    # Map register numbers to values
    reg_values = {
        test_info['ms1_reg']: ms1_val,
        test_info['ms2_reg']: ms2_val,
        test_info['md_reg']: md_val,
    }
    
    # Write matrix file
    with open(matrix_file, 'w', encoding='utf-8') as f:
        if test_info['is_float']:
            f.write("--- Tile Registers (tr0-tr7) (Floating-Point | 32-bit representation)---\n")
        else:
            f.write("--- Tile Registers (tr0-tr7) (Integer Only)---\n")
        
        for tr_idx in range(8):
            f.write(f"\ntr{tr_idx}:\n")
            value = reg_values.get(tr_idx, md_val)  # Default to 0
            
            if test_info['is_float']:
                for row in range(4):
                    f.write(f"  Row {row}: {value} {value} {value} {value}\n")
            else:
                for row in range(4):
                    value_int = int(value) if isinstance(value, (int, float)) else 0
                    f.write(f"  Row {row}: {value_int} {value_int} {value_int} {value_int}\n")


def reset_accumulator(test_info):
    """Reset accumulator registers to initial values before each test"""
    iss_dir = Path(__file__).parent
    
    # Determine which file to update
    if test_info['is_float']:
        acc_file = iss_dir / 'acc_float.txt'
    else:
        acc_file = iss_dir / 'acc.txt'
    
    if not acc_file.exists():
        return
    
    # Read current file
    with open(acc_file, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    # Build initial values for each accumulator
    ms1_val = test_info['ms1_init']
    ms2_val = test_info['ms2_init']
    md_val = 0.0 if test_info['is_float'] else 0  # Destination starts at 0
    
    # Map register numbers to values
    reg_values = {
        test_info['ms1_reg']: ms1_val,
        test_info['ms2_reg']: ms2_val,
        test_info['md_reg']: md_val,
    }
    
    # Process file and update values
    new_lines = []
    current_reg_idx = None
    
    for line in lines:
        # Check if this is a register header
        for reg_idx in range(4):
            if f'acc{reg_idx}:' in line:
                current_reg_idx = reg_idx
                new_lines.append(line)
                break
        else:
            # Check if this is a row data line
            if current_reg_idx is not None and line.strip().startswith('Row'):
                row_num = line.split()[1].rstrip(':')
                
                # Get value for this register (default to 0)
                val = reg_values.get(current_reg_idx, 0.0 if test_info['is_float'] else 0)
                
                if test_info['is_float']:
                    # Float format: "Row 0: 10.5 10.5 10.5 10.5 (1093140480, 1093140480, 1093140480, 1093140480)"
                    val_str = f"{val:.1f}"
                    row_data = ' '.join([val_str] * 4)
                    # Get bit patterns for float values
                    bits = struct.unpack('I', struct.pack('f', val))[0]
                    bits_str = ', '.join([str(bits)] * 4)
                    new_lines.append(f"  Row {row_num}: {row_data} ({bits_str})\n")
                else:
                    # Int format: "Row 0: 10 10 10 10 (10, 10, 10, 10)"
                    val_str = str(int(val))
                    row_data = ' '.join([val_str] * 4)
                    vals_str = ', '.join([val_str] * 4)
                    new_lines.append(f"  Row {row_num}: {row_data} ({vals_str})\n")
            else:
                new_lines.append(line)
    
    # Write back
    with open(acc_file, 'w', encoding='utf-8') as f:
        f.writelines(new_lines)
        f.flush()
        os.fsync(f.fileno())


def create_assembly_for_test(test_info):
    """Create assembly.txt with element-wise operation"""
    assembler_dir = SCRIPT_DIR.parent / "assembler"
    assembly_file = assembler_dir / "assembly.txt"
    
    # Check if using matrix registers
    use_matrix = test_info.get('use_matrix_regs', False)
    
    if use_matrix:
        # For matrix register tests
        assembly_code = f"""# Test: {test_info['name']} (Matrix Registers)
# {test_info['description']}
# Operation: md = ms2 op ms1

# Setup tile dimensions (4x4)
msettilemi 4
msettileki 4
msettileni 4

# Perform element-wise operation
{test_info['instr']}
"""
    else:
        # For accumulator tests
        assembly_code = f"""# Test: {test_info['name']}
# {test_info['description']}
# Operation: md = ms2 op ms1

# Setup tile dimensions (4x4)
msettilemi 4
msettileki 4
msettileni 4

# Perform element-wise operation
{test_info['instr']}
"""
    
    with open(assembly_file, 'w', encoding='utf-8') as f:
        f.write(assembly_code)
        f.flush()
        os.fsync(f.fileno())
    
    # Add small delay to ensure file is written
    import time
    time.sleep(0.01)
    
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


def run_simulator(debug=False):
    """Run simulator"""
    tpu_dir = SCRIPT_DIR.parent
    
    import subprocess
    env = os.environ.copy()
    env['PYTHONIOENCODING'] = 'utf-8'
    env['PYTHONLEGACYWINDOWSSTDIO'] = 'utf-8'  # Force UTF-8 on Windows
    
    result = subprocess.run(
        ['python', '-m', 'iss.run_simulator'],
        cwd=str(tpu_dir),
        capture_output=True,
        encoding='utf-8',
        errors='replace',  # Replace invalid characters instead of failing
        env=env
    )
    
    # Debug: print full simulator output for debugging
    if debug and result.stdout:
        print("\n[SIMULATOR FULL OUTPUT]")
        print(result.stdout)
        print("[END SIMULATOR OUTPUT]\n")
    
    return result.returncode == 0


def verify_elementwise_result(test_info):
    """Verify element-wise operation result"""
    iss_dir = SCRIPT_DIR
    
    # Check if using matrix registers
    use_matrix = test_info.get('use_matrix_regs', False)
    
    if use_matrix:
        # Read from matrix.txt or matrix_float.txt
        if test_info['is_float']:
            matrix_file = iss_dir / 'matrix_float.txt'
        else:
            matrix_file = iss_dir / 'matrix.txt'
        
        if not matrix_file.exists():
            return False, f"{matrix_file.name} not found"
        
        with open(matrix_file, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        
        # Parse matrix result
        tr_reg = f"tr{test_info['md_reg']}"
        result_matrix = []
        in_target = False
        
        for line in lines:
            if f'{tr_reg}:' in line:
                in_target = True
                continue
            if in_target and line.strip().startswith('Row'):
                # Extract numbers from "Row X: a b c d (...)"
                parts = line.split(':')[1].split('(')[0].strip().split()
                try:
                    if test_info['is_float']:
                        row_values = [float(x) for x in parts]
                    else:
                        row_values = []
                        for x in parts:
                            val = int(x)
                            if val > 0x7FFFFFFF:
                                val = val - 0x100000000
                            row_values.append(val)
                    result_matrix.append(row_values)
                except:
                    continue
            if in_target and any(f'tr{i}:' in line for i in range(8) if i != test_info['md_reg']):
                break
    else:
        # Read from acc.txt or acc_float.txt (original logic)
        if test_info['is_float']:
            acc_file = iss_dir / 'acc_float.txt'
        else:
            acc_file = iss_dir / 'acc.txt'
        
        if not acc_file.exists():
            return False, f"{acc_file.name} not found"
        
        with open(acc_file, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        
        # Parse accumulator result
        acc_reg = f"acc{test_info['md_reg']}"
        result_matrix = []
        in_target = False
        
        for line in lines:
            if f'{acc_reg}:' in line:
                in_target = True
                continue
            if in_target and line.strip().startswith('Row'):
                # Extract numbers from "Row X: a b c d (...)"
                parts = line.split(':')[1].split('(')[0].strip().split()
                try:
                    if test_info['is_float']:
                        row_values = [float(x) for x in parts]
                    else:
                        # Parse as signed int32
                        row_values = []
                        for x in parts:
                            val = int(x)
                            # Convert unsigned to signed int32
                            if val > 0x7FFFFFFF:
                                val = val - 0x100000000
                            row_values.append(val)
                    result_matrix.append(row_values)
                except:
                    continue
            if in_target and any(f'acc{i}:' in line for i in range(4) if i != test_info['md_reg']):
                break
    
    if len(result_matrix) != 4:
        return False, f"Could not parse result matrix (got {len(result_matrix)} rows)"
    
    # Expected: ms2 op ms1 for all elements
    ms1_val = test_info['ms1_init']
    ms2_val = test_info['ms2_init']
    operation = test_info['operation']
    expected = operation(ms2_val, ms1_val)  # md = ms2 op ms1, so operation(ms2, ms1)
    
    # Tolerance based on data type (ML-realistic settings)
    if test_info['data_type'] == 'float32':
        tolerance = 0.1  # FP32 precision
    elif test_info['data_type'] == 'float16':
        tolerance = 0.3  # FP16 has lower precision (10-bit mantissa)
    else:
        tolerance = 0  # Exact for integers
    
    # Check all elements
    errors = []
    is_unsigned_op = test_info.get('name', '').startswith('mumax') or test_info.get('name', '').startswith('mumin')
    
    for i in range(4):
        for j in range(4):
            actual = result_matrix[i][j]
            
            if test_info['is_float']:
                # Use relative tolerance for large values (e.g., multiplication results)
                if abs(expected) > 10:
                    # ML-realistic: 1% for FP32, 5% for FP16 (balances precision & practicality)
                    rel_tol = 0.05 if test_info['data_type'] == 'float16' else 0.01
                    if abs(expected - actual) > abs(expected) * rel_tol:
                        errors.append(f"[{i}][{j}]: expected {expected:.4f}, got {actual:.4f}")
                else:
                    # Absolute tolerance for small values
                    if abs(expected - actual) > tolerance:
                        errors.append(f"[{i}][{j}]: expected {expected:.4f}, got {actual:.4f}")
            else:
                # For unsigned operations, convert to unsigned for comparison
                if is_unsigned_op:
                    actual_unsigned = actual & 0xFFFFFFFF
                    expected_unsigned = expected & 0xFFFFFFFF
                    if expected_unsigned != actual_unsigned:
                        errors.append(f"[{i}][{j}]: expected {expected_unsigned}, got {actual_unsigned}")
                else:
                    if expected != actual:
                        errors.append(f"[{i}][{j}]: expected {expected}, got {actual}")
    
    if not errors:
        return True, f"Element-wise operation correct! All elements = {expected}"
    else:
        return False, "Errors:\n    " + "\n    ".join(errors[:5])  # Show first 5 errors


def display_results(test_info):
    """Display results for current test"""
    print("\n" + "="*80)
    print(f"RESULTS: {test_info['name']}")
    print("="*80)
    
    iss_dir = SCRIPT_DIR
    use_matrix = test_info.get('use_matrix_regs', False)
    
    if use_matrix:
        # Display matrix registers
        if test_info['is_float']:
            matrix_file = iss_dir / 'matrix_float.txt'
        else:
            matrix_file = iss_dir / 'matrix.txt'
        
        print(f"\n[Source Registers] From {matrix_file.name}:")
        
        if matrix_file.exists():
            with open(matrix_file, 'r', encoding='utf-8') as f:
                lines = f.readlines()
                show_regs = [
                    f"tr{test_info['ms1_reg']}",
                    f"tr{test_info['ms2_reg']}",
                ]
                current_reg = None
                
                for line in lines:
                    # Check if this is a register label line
                    is_reg_line = any(f'tr{i}:' in line for i in range(8))
                    
                    for r in show_regs:
                        if f'{r}:' in line:
                            current_reg = r
                            print(f"  {line.strip()}")
                            break
                    else:
                        # If we're in a register we want to show
                        if current_reg and line.strip().startswith('Row'):
                            print(f"    {line.strip()}")
                        # Stop if we hit a different register
                        elif current_reg and is_reg_line:
                            current_reg = None
        
        print(f"\n[Destination Register: tr{test_info['md_reg']}] From {matrix_file.name}:")
        
        if matrix_file.exists():
            with open(matrix_file, 'r', encoding='utf-8') as f:
                lines = f.readlines()
                tr_reg = f"tr{test_info['md_reg']}"
                in_target = False
                
                # Print type annotation first
                if test_info['is_float']:
                    print(f"  {tr_reg}:")
                    print(f"    (Destination: {test_info['data_type'].upper()}, 32-bit)")
                else:
                    print(f"  {tr_reg}:")
                    print(f"    (Destination: INT32, 32-bit)")
                
                for line in lines:
                    if f'{tr_reg}:' in line:
                        in_target = True
                        # Skip the register label since we already printed it
                        continue
                    elif in_target and line.strip().startswith('Row'):
                        # Parse the row to add signed notation for integers
                        if not test_info['is_float']:
                            parts = line.split(':')
                            if len(parts) >= 2:
                                row_label = parts[0].strip()
                                numbers_str = parts[1].strip().split()
                                # Convert to signed integers
                                signed_vals = []
                                for num_str in numbers_str:
                                    val = int(num_str)
                                    if val > 0x7FFFFFFF:
                                        signed_val = val - 0x100000000
                                    else:
                                        signed_val = val
                                    signed_vals.append(signed_val)
                                # Format output with both unsigned and signed
                                unsigned_str = ' '.join(numbers_str)
                                signed_str = ', '.join(map(str, signed_vals))
                                print(f"    {row_label}: {unsigned_str} ({signed_str})")
                        else:
                            print(f"    {line.strip()}")
                    elif in_target and any(f'tr{i}:' in line for i in range(8)):
                        break
    else:
        # Display accumulator registers (original logic)
        if test_info['is_float']:
            acc_file = iss_dir / 'acc_float.txt'
        else:
            acc_file = iss_dir / 'acc.txt'
        
        print(f"\n[Source Registers] From {acc_file.name}:")
        
        if acc_file.exists():
            with open(acc_file, 'r', encoding='utf-8') as f:
                lines = f.readlines()
                show_regs = [
                    f"acc{test_info['ms1_reg']}",
                    f"acc{test_info['ms2_reg']}",
                ]
                current_reg = None
                
                for line in lines:
                    # Check if this is a register label line
                    is_reg_line = any(f'acc{i}:' in line for i in range(4))
                    
                    # Check for register labels
                    for r in show_regs:
                        if f'{r}:' in line:
                            current_reg = r
                            print(f"  {line.strip()}")
                            break
                    else:
                        # If we're in a register we want to show
                        if current_reg and line.strip().startswith('Row'):
                            print(f"    {line.strip()}")
                        # Stop if we hit a different register
                        elif current_reg and is_reg_line:
                            current_reg = None
        
        print(f"\n[Destination Register: acc{test_info['md_reg']}] From {acc_file.name}:")
        
        if acc_file.exists():
            with open(acc_file, 'r', encoding='utf-8') as f:
                lines = f.readlines()
                acc_reg = f"acc{test_info['md_reg']}"
                in_target = False
                
                for line in lines:
                    if f'{acc_reg}:' in line:
                        in_target = True
                        print(f"  {line.strip()}")
                    elif in_target and line.strip().startswith('Row'):
                        print(f"    {line.strip()}")
                    elif in_target and any(f'acc{i}:' in line for i in range(4)):
                        break
    
    # Verification
    print("\n" + "-"*80)
    print("[VERIFICATION]")
    success, message = verify_elementwise_result(test_info)
    
    if success:
        print(f"  [OK] PASS - {message}")
    else:
        print(f"  [X] FAIL - {message}")
    
    print("-"*80)
    
    return success


def run_single_test(test_info, test_num, total_tests, use_random=False):
    """Run a single test case"""
    print("\n" + "="*80)
    print(f"TEST {test_num}/{total_tests}: {test_info['name']}")
    print(f"Description: {test_info['description']}")
    print("="*80)
    
    # Generate random values if requested
    if use_random:
        ms1_val, ms2_val = generate_random_values(test_info)
        test_info['ms1_init'] = ms1_val
        test_info['ms2_init'] = ms2_val
        print(f"\n[Random Mode] Generated: ms1={ms1_val}, ms2={ms2_val}")
    
    # Check if using matrix registers
    use_matrix = test_info.get('use_matrix_regs', False)
    
    if use_matrix:
        # Step 1: Setup memory and matrix registers
        print("\n[Step 1] Setting up memory and matrix registers...")
        reset_matrix_registers(test_info)
        print(f"  [OK] Memory[0] = {test_info['ms1_init']} (matrix 1)")
        print(f"       Memory[64] = {test_info['ms2_init']} (matrix 2)")
        print(f"       tr{test_info['md_reg']} = 0 (destination)")
    else:
        # Step 1: Reset accumulators to initial values
        print("\n[Step 1] Resetting accumulators...")
        reset_accumulator(test_info)
        print(f"  [OK] acc{test_info['ms1_reg']} = {test_info['ms1_init']}")
        print(f"       acc{test_info['ms2_reg']} = {test_info['ms2_init']}")
        print(f"       acc{test_info['md_reg']} = 0")
    
    # Step 2: Create assembly
    print("\n[Step 2] Creating assembly.txt...")
    assembly_file = create_assembly_for_test(test_info)
    print(f"  [OK] Created: {assembly_file}")
    print(f"       - {test_info['instr']}")
    
    # Step 3: Assemble
    print("\n[Step 3] Assembling...")
    if not run_assembler():
        print("  [ERROR] Assembly failed!")
        return False
    print("  [OK] Assembly successful -> machine_code.txt")
    
    # Step 4: Run simulator
    print("\n[Step 4] Running simulator...")
    # Debug for tile tests
    debug_sim = test_info.get('md_reg', 0) >= 4
    if not run_simulator(debug=debug_sim):
        print("  [ERROR] Simulation failed!")
        return False
    print("  [OK] Simulation complete")
    
    # Step 5: Display results and verify
    passed = display_results(test_info)
    
    return passed


def main():
    """Main test function"""
    import sys
    auto_run = '--auto' in sys.argv or '-a' in sys.argv
    use_random = '--random' in sys.argv or '-r' in sys.argv
    
    print("\n" + "="*80)
    print("ELEMENT-WISE OPERATION TEST")
    print("="*80)
    print("\nThis script tests element-wise operations: md = ms2 op ms1")
    print("\nTest cases:")
    for i, test in enumerate(TEST_CASES, 1):
        print(f"  {i:2}. {test['name']:<15} - {test['description']}")
    if not auto_run:
        print("\nPress Enter after each test to continue to the next one.")
    else:
        print("\n[AUTO MODE] Running all tests automatically...")
    if use_random:
        print("[RANDOM MODE] Using random test values for each run")
    print("="*80)
    
    try:
        # Initial setup (once)
        setup_test_data()
        
        print("\n" + "="*80)
        print("Setup complete! Ready to start testing.")
        print("="*80)
        if not auto_run:
            input("\nPress Enter to start testing...")
        else:
            print("\n[AUTO MODE] Starting tests...")
        
        # Run each test
        total_tests = len(TEST_CASES)
        passed_tests = 0
        failed_tests = 0
        
        for i, test_info in enumerate(TEST_CASES, 1):
            # Make a copy to avoid modifying original
            test_copy = test_info.copy()
            success = run_single_test(test_copy, i, total_tests, use_random)
            
            if success:
                passed_tests += 1
            else:
                failed_tests += 1
            
            if not success:
                print(f"\n[WARNING] Test {i} failed!")
            
            # Ask to continue (except after last test)
            if i < total_tests:
                print("\n" + "="*80)
                if not auto_run:
                    input(f"Press Enter to continue to test {i+1}/{total_tests}...")
                else:
                    print(f"[AUTO MODE] Continuing to test {i+1}/{total_tests}...")
        
        print("\n" + "="*80)
        print("ALL TESTS COMPLETE!")
        print("="*80)
        print(f"\n[SUMMARY]")
        print(f"  [OK] Passed: {passed_tests}/{total_tests}")
        print(f"  [X] Failed: {failed_tests}/{total_tests}")
        print("\nOutput files:")
        print(f"  - {SCRIPT_DIR / 'acc.txt'}")
        print(f"  - {SCRIPT_DIR / 'acc_float.txt'}")
        
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
