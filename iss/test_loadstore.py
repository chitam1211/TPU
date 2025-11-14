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

Press Enter after each test to continue to next test.
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
    {
        'name': 'mlae32/msae32',
        'description': 'Load/Store 32-bit float (tr0)',
        'load_instr': 'mlae32 tr0, (x1), x2',
        'store_instr': 'msae32 tr0, (x9), x10',
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
        'store_instr': 'msae16 tr1, (x11), x10',
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
        'store_instr': 'msbe8 tr2, (x12), x10',
        'input_addr': 0x300,
        'output_addr': 0x340,
        'register_type': 'tr',
        'register_num': 2,
        'is_float': False,
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
    
    # --- 4. Output region (initially zeros) ---
    for addr in [0x140, 0x150, 0x160, 0x170, 0x240, 0x340, 0x380, 0x390, 0x3A0, 0x3B0, 0x3C0, 0x3D0]:
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
    
    gpr_values = {
        0: 0,       # zero
        1: 0x100,   # base addr for mlae32 (float32 matrix)
        2: 0x10,    # stride = 16 bytes (4 float32)
        3: 0x200,   # base addr for mlae16 (float16 data)
        4: 0x08,    # stride = 8 bytes (4 float16)
        5: 0x300,   # base addr for mlbe8 (int8 data)
        6: 0x04,    # stride = 4 bytes (4 int8)
        7: 0x100,   # base addr for mlce32 (column load from float32)
        8: 0x10,    # stride for column
        9: 0x140,   # output address 1
        10: 0x10,   # output stride
        11: 0x240,  # output address 2
        12: 0x340,  # output address 3
        13: 0x380,  # output address 4
        14: 0x300,  # base addr for mlce8 (column load from int8)
        15: 0x04,   # stride for int8 column
        16: 0x3C0,  # output address 5
    }
    
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


def create_assembly_for_test(test_info):
    """Create assembly.txt with only the current test pair"""
    assembler_dir = SCRIPT_DIR.parent / "assembler"
    assembly_file = assembler_dir / "assembly.txt"
    
    assembly_code = f"""# Test: {test_info['name']}
# {test_info['description']}

# Setup tile dimensions
msettilemi 4
msettileki 4
msettileni 4

# Load instruction
{test_info['load_instr']}

# Store instruction
{test_info['store_instr']}
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


def display_results(test_info):
    """Display results for current test"""
    print("\n" + "="*80)
    print(f"RESULTS: {test_info['name']}")
    print("="*80)
    
    iss_dir = SCRIPT_DIR
    
    # Display register data
    if test_info['register_type'] == 'tr':
        file_name = 'matrix_float.txt' if test_info['is_float'] else 'matrix.txt'
        reg_name = f"tr{test_info['register_num']}"
    else:
        file_name = 'acc_float.txt' if test_info['is_float'] else 'acc.txt'
        reg_name = f"acc{test_info['register_num']}"
    
    file_path = iss_dir / file_name
    print(f"\n[Register: {reg_name}] From {file_name}:")
    
    if file_path.exists():
        with open(file_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
            in_target_reg = False
            for line in lines:
                if f'{reg_name}:' in line:
                    in_target_reg = True
                    print(f"  {line.strip()}")
                elif in_target_reg and line.strip().startswith('Row'):
                    print(f"  {line.strip()}")
                elif in_target_reg and any(f'{r}:' in line for r in ['tr0:', 'tr1:', 'tr2:', 'tr3:', 'acc0:', 'acc1:', 'acc2:', 'acc3:']):
                    break
    
    # Display memory
    memory_file = iss_dir / "memory.txt"
    print(f"\n[Memory] Input/Output comparison:")
    
    if memory_file.exists():
        with open(memory_file, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        
        input_hex = f"0x{test_info['input_addr']:03X}:"
        output_hex = f"0x{test_info['output_addr']:03X}:"
        
        for line in lines:
            if input_hex in line:
                print(f"  Input  {line.strip()}")
            elif output_hex in line:
                print(f"  Output {line.strip()}")
    
    print("\n" + "-"*80)
    print(f"[Expected] Data from {input_hex} should match data at {output_hex}")
    print("-"*80)


def run_single_test(test_info, test_num, total_tests):
    """Run a single test case"""
    print("\n" + "="*80)
    print(f"TEST {test_num}/{total_tests}: {test_info['name']}")
    print(f"Description: {test_info['description']}")
    print("="*80)
    
    # Step 1: Create assembly
    print("\n[Step 1] Creating assembly.txt with test instructions...")
    assembly_file = create_assembly_for_test(test_info)
    print(f"  [OK] Created: {assembly_file}")
    print(f"       - {test_info['load_instr']}")
    print(f"       - {test_info['store_instr']}")
    
    # Step 2: Assemble
    print("\n[Step 2] Assembling...")
    if not run_assembler():
        print("  [ERROR] Assembly failed!")
        return False
    print("  [OK] Assembly successful -> machine_code.txt")
    
    # Step 3: Run simulator
    print("\n[Step 3] Running simulator...")
    if not run_simulator():
        print("  [ERROR] Simulation failed!")
        return False
    print("  [OK] Simulation complete")
    
    # Step 4: Display results
    display_results(test_info)
    
    return True


def main():
    """Main test function"""
    print("\n" + "="*80)
    print("LOAD/STORE INSTRUCTION TEST - SEQUENTIAL MODE")
    print("="*80)
    print("\nThis script will test each load/store pair separately:")
    for i, test in enumerate(TEST_CASES, 1):
        print(f"  {i}. {test['name']:<20} - {test['description']}")
    print("\nPress Enter after each test to continue to the next one.")
    print("="*80)
    
    try:
        # Initial setup (once)
        setup_test_data()
        
        print("\n" + "="*80)
        print("Setup complete! Ready to start testing.")
        print("="*80)
        input("\nPress Enter to start testing...")
        
        # Run each test
        total_tests = len(TEST_CASES)
        for i, test_info in enumerate(TEST_CASES, 1):
            success = run_single_test(test_info, i, total_tests)
            
            if not success:
                print(f"\n[ERROR] Test {i} failed!")
                response = input("\nContinue to next test? (y/n): ")
                if response.lower() != 'y':
                    break
            
            # Ask to continue (except after last test)
            if i < total_tests:
                print("\n" + "="*80)
                input(f"Press Enter to continue to test {i+1}/{total_tests}...")
        
        print("\n" + "="*80)
        print("ALL TESTS COMPLETE!")
        print("="*80)
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
