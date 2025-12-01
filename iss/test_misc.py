#!/usr/bin/env python3
"""
Test script for Miscellaneous (MISC) instruction group
Run directly in the iss directory

Tests utility matrix operations:
1. mzero - Zero out matrix register
2. mmov.mm - Move matrix to matrix
3. mmovw.x.m - Move matrix element to GPR
4. mmovw.m.x - Move GPR to matrix element
5. mdupw.m.x - Duplicate GPR value to entire matrix
6. mrslidedown - Slide rows down
7. mcslidedown.w - Slide columns down (FP32)

Usage:
    python test_misc.py                    # Interactive mode with fixed values
    python test_misc.py --auto             # Auto mode with fixed values
    python test_misc.py --random           # Interactive mode with random values
    python test_misc.py --auto --random    # Auto mode with random values
"""

import sys
import os
from pathlib import Path
import struct
import argparse

# Add parent directory to sys.path
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR.parent))

# Test cases definition
TEST_CASES = [
    {
        'name': 'mzero',
        'description': 'Zero out matrix register (tr4)',
        'instr': 'mzero tr4',
        'setup': 'fill_tr4_with_values',
        'verify': 'check_all_zeros',
        'target_reg': 'tr4',
        'reg_idx': 4,
        'is_float': True,
    },
    {
        'name': 'mmov.mm',
        'description': 'Copy matrix tr4 to tr5',
        'instr': 'mmov.mm tr5, tr4',
        'setup': 'fill_tr4_with_pattern',
        'verify': 'check_tr5_equals_tr4',
        'source_reg': 'tr4',
        'target_reg': 'tr5',
        'src_idx': 4,
        'dst_idx': 5,
        'is_float': True,
    },
    {
        'name': 'mmovw.x.m',
        'description': 'Move matrix element to GPR (tr4[2] -> x1)',
        'instr': 'mmovw.x.m x1, tr4, x2',
        'setup': 'fill_tr4_with_known_values',
        'verify': 'check_gpr_x1_has_element',
        'target_reg': 'tr4',
        'reg_idx': 4,
        'gpr_rd': 1,
        'gpr_rs1': 2,
        'element_index': 2,  # x2 = 2 -> tr4[0][2]
        'expected_value': 3.0,  # Will be set during setup
        'is_float': True,
    },
    {
        'name': 'mmovw.m.x',
        'description': 'Move GPR to matrix element (x3 -> tr4[1])',
        'instr': 'mmovw.m.x tr4, x3, x4',
        'setup': 'setup_gpr_and_index',
        'verify': 'check_tr4_element_changed',
        'target_reg': 'tr4',
        'reg_idx': 4,
        'gpr_rs2': 3,
        'gpr_rs1': 4,
        'element_index': 1,  # x4 = 1 -> tr4[0][1]
        'gpr_value': 99.5,
        'is_float': True,
    },
    {
        'name': 'mdupw.m.x',
        'description': 'Duplicate GPR value to entire matrix (x5 -> all of tr4)',
        'instr': 'mdupw.m.x tr4, x5',
        'setup': 'setup_gpr_for_duplicate',
        'verify': 'check_all_elements_equal',
        'target_reg': 'tr4',
        'reg_idx': 4,
        'gpr_rs2': 5,
        'dup_value': 42.75,
        'is_float': True,
    },
    {
        'name': 'mrslidedown',
        'description': 'Slide rows down by 1 (tr4 -> tr5)',
        'instr': 'mrslidedown tr5, tr4, 1',
        'setup': 'fill_tr4_with_row_pattern',
        'verify': 'check_rows_slid_down',
        'source_reg': 'tr4',
        'target_reg': 'tr5',
        'src_idx': 4,
        'dst_idx': 5,
        'slide_amount': 1,
        'is_float': True,
    },
    {
        'name': 'mcslidedown.w',
        'description': 'Slide columns down by 1 (FP32, tr4 -> tr5)',
        'instr': 'mcslidedown.w tr5, tr4, 1',
        'setup': 'fill_tr4_with_col_pattern',
        'verify': 'check_cols_slid_down',
        'source_reg': 'tr4',
        'target_reg': 'tr5',
        'src_idx': 4,
        'dst_idx': 5,
        'slide_amount': 1,
        'is_float': True,
    },
]


def float32_to_hex(value):
    """Convert float32 to hex string"""
    bytes_val = struct.pack('<f', value)
    return ' '.join(f'{b:02X}' for b in bytes_val)


def float_to_bits32(value):
    """Convert float to 32-bit integer representation"""
    return struct.unpack('I', struct.pack('f', value))[0]


def setup_initial_state():
    """Setup initial state once before all tests"""
    iss_dir = SCRIPT_DIR
    
    print("\n" + "="*80)
    print("INITIAL SETUP: PREPARING REGISTERS")
    print("="*80)
    
    # Setup GPR registers
    print("\n[1] Setting up gpr.txt...")
    gpr_file = iss_dir / "gpr.txt"
    
    abi_names = [
        "zero", "ra", "sp", "gp", "tp",
        "t0", "t1", "t2",
        "s0", "s1",
        "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7",
        "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11",
        "t3", "t4", "t5", "t6"
    ]
    
    # Initialize GPR with default values
    gpr_values = {
        0: 0,       # zero
        1: 0,       # x1 (will be used as rd)
        2: 2,       # x2 = 2 (index for mmovw.x.m test)
        3: 0,       # x3 (will hold float value 99.5)
        4: 1,       # x4 = 1 (index for mmovw.m.x test)
        5: 0,       # x5 (will hold float value 42.75)
    }
    
    with open(gpr_file, 'w', encoding='utf-8') as f:
        f.write("--- General Purpose Registers (GPRs) ---\n")
        for i in range(32):
            val = gpr_values.get(i, 0)
            abi_name = abi_names[i] if i < len(abi_names) else f"x{i}"
            f.write(f"x{i:<2} ({abi_name:<7}): 0x{val:08X}\n")
    
    print(f"    [OK] GPR initialized")
    
    # Initialize matrix registers (tr4-tr7) to zeros
    print("\n[2] Initializing matrix registers...")
    matrix_float_file = iss_dir / "matrix_float.txt"
    
    with open(matrix_float_file, 'w', encoding='utf-8') as f:
        f.write("--- Tile Registers (tr4-tr7) (Floating-Point | 32-bit representation)---\n\n")
        for i in range(4, 8):  # tr4-tr7
            f.write(f"tr{i}:\n")
            for row in range(4):
                f.write(f"  Row {row}: 0.0 0.0 0.0 0.0 (0, 0, 0, 0)\n")
            if i < 7:
                f.write("\n")
    
    print(f"    [OK] Matrix registers initialized")


def setup_test_data(test_info, use_random=False):
    """Setup test data based on test requirements"""
    iss_dir = SCRIPT_DIR
    
    # Setup matrix registers
    matrix_float_file = iss_dir / "matrix_float.txt"
    
    # Determine what data to write based on setup type
    setup_type = test_info.get('setup', '')
    
    if setup_type == 'fill_tr4_with_values':
        # Fill tr4 with sequential or random values for mzero test
        if use_random:
            import random
            tr4_data = [[random.uniform(1.0, 100.0) for _ in range(4)] for _ in range(4)]
            print(f"    [Setup] tr4 filled with random values")
        else:
            tr4_data = [
                [1.0, 2.0, 3.0, 4.0],
                [5.0, 6.0, 7.0, 8.0],
                [9.0, 10.0, 11.0, 12.0],
                [13.0, 14.0, 15.0, 16.0]
            ]
            print(f"    [Setup] tr4 filled with values 1-16")
        write_matrix_register(matrix_float_file, 4, tr4_data)  # tr4
    
    elif setup_type == 'fill_tr4_with_pattern':
        # Fill tr4 with a pattern for mmov.mm test
        if use_random:
            import random
            tr4_data = [[random.uniform(10.0, 50.0) for _ in range(4)] for _ in range(4)]
            print(f"    [Setup] tr4 filled with random pattern, tr5 zeroed")
        else:
            tr4_data = [
                [10.5, 20.5, 30.5, 40.5],
                [11.5, 21.5, 31.5, 41.5],
                [12.5, 22.5, 32.5, 42.5],
                [13.5, 23.5, 33.5, 43.5]
            ]
            print(f"    [Setup] tr4 filled with pattern, tr5 zeroed")
        write_matrix_register(matrix_float_file, 4, tr4_data)
        # Zero out tr5
        tr5_data = [[0.0] * 4 for _ in range(4)]
        write_matrix_register(matrix_float_file, 5, tr5_data)
    
    elif setup_type == 'fill_tr4_with_known_values':
        # Fill tr4 with known values for element access
        if use_random:
            import random
            tr4_data = [[random.uniform(1.0, 50.0) for _ in range(4)] for _ in range(4)]
        else:
            tr4_data = [
                [1.0, 2.0, 3.0, 4.0],
                [5.0, 6.0, 7.0, 8.0],
                [9.0, 10.0, 11.0, 12.0],
                [13.0, 14.0, 15.0, 16.0]
            ]
        write_matrix_register(matrix_float_file, 4, tr4_data)
        # Update expected value in test_info
        element_idx = test_info['element_index']
        row = element_idx // 4
        col = element_idx % 4
        test_info['expected_value'] = tr4_data[row][col]
        print(f"    [Setup] tr4 filled, element[{element_idx}] = {test_info['expected_value']:.2f}")
    
    elif setup_type == 'setup_gpr_and_index':
        # Setup GPR x3 with value to write, x4 with index
        if use_random:
            import random
            test_info['gpr_value'] = random.uniform(50.0, 150.0)
        gpr_file = iss_dir / "gpr.txt"
        setup_gpr(gpr_file, test_info['gpr_rs2'], test_info['gpr_value'])
        setup_gpr(gpr_file, test_info['gpr_rs1'], test_info['element_index'])
        # Fill tr4 with zeros
        tr4_data = [[0.0] * 4 for _ in range(4)]
        write_matrix_register(matrix_float_file, 4, tr4_data)
        print(f"    [Setup] GPR x{test_info['gpr_rs2']}={test_info['gpr_value']:.2f}, x{test_info['gpr_rs1']}={test_info['element_index']}")
    
    elif setup_type == 'setup_gpr_for_duplicate':
        # Setup GPR x5 with value to duplicate
        if use_random:
            import random
            test_info['dup_value'] = random.uniform(20.0, 80.0)
        gpr_file = iss_dir / "gpr.txt"
        setup_gpr(gpr_file, test_info['gpr_rs2'], test_info['dup_value'])
        # Fill tr4 with zeros
        tr4_data = [[0.0] * 4 for _ in range(4)]
        write_matrix_register(matrix_float_file, 4, tr4_data)
        print(f"    [Setup] GPR x{test_info['gpr_rs2']}={test_info['dup_value']:.2f}, tr4 zeroed")
    
    elif setup_type == 'fill_tr4_with_row_pattern':
        # mrslidedown: slide ROWS down
        # File stores COLUMN-MAJOR, so we need to setup the LOGICAL row pattern
        # Logical matrix (what we want):  Physical file storage (column-major):
        #   Row 0: [1, 2, 3, 4]              Row 0: [1, 5, 9, 13]  (column 0)
        #   Row 1: [5, 6, 7, 8]       -->    Row 1: [2, 6, 10, 14] (column 1)
        #   Row 2: [9, 10, 11, 12]           Row 2: [3, 7, 11, 15] (column 2)
        #   Row 3: [13, 14, 15, 16]          Row 3: [4, 8, 12, 16] (column 3)
        
        # write_matrix_register writes row-by-row to file, which becomes column-major
        # So to get logical row pattern, write the TRANSPOSE
        tr4_data = [
            [1.0, 5.0, 9.0, 13.0],    # File row 0 = logical column 0
            [2.0, 6.0, 10.0, 14.0],   # File row 1 = logical column 1
            [3.0, 7.0, 11.0, 15.0],   # File row 2 = logical column 2
            [4.0, 8.0, 12.0, 16.0]    # File row 3 = logical column 3
        ]
        write_matrix_register(matrix_float_file, 4, tr4_data)
        tr5_data = [[0.0] * 4 for _ in range(4)]
        write_matrix_register(matrix_float_file, 5, tr5_data)
        # Save LOGICAL matrix for verification (transpose of file data)
        test_info['tr4_logical'] = [
            [1.0, 2.0, 3.0, 4.0],
            [5.0, 6.0, 7.0, 8.0],
            [9.0, 10.0, 11.0, 12.0],
            [13.0, 14.0, 15.0, 16.0]
        ]
        print(f"    [Setup] tr4 with logical row pattern (rows: 1-4, 5-8, 9-12, 13-16)")
    
    elif setup_type == 'fill_tr4_with_col_pattern':
        # mcslidedown.w: slide COLUMNS down
        # File stores COLUMN-MAJOR, which matches our column pattern!
        # Logical matrix (what we want):  Physical file storage (column-major):
        #   Col 0: [1, 2, 3, 4]              Row 0: [1, 2, 3, 4]    (column 0)
        #   Col 1: [5, 6, 7, 8]       -->    Row 1: [5, 6, 7, 8]    (column 1)
        #   Col 2: [9, 10, 11, 12]           Row 2: [9, 10, 11, 12] (column 2)
        #   Col 3: [13, 14, 15, 16]          Row 3: [13, 14, 15, 16](column 3)
        
        # For column pattern, file rows directly represent logical columns!
        tr4_data = [
            [1.0, 2.0, 3.0, 4.0],      # File row 0 = logical column 0
            [5.0, 6.0, 7.0, 8.0],      # File row 1 = logical column 1
            [9.0, 10.0, 11.0, 12.0],   # File row 2 = logical column 2
            [13.0, 14.0, 15.0, 16.0]   # File row 3 = logical column 3
        ]
        write_matrix_register(matrix_float_file, 4, tr4_data)
        tr5_data = [[0.0] * 4 for _ in range(4)]
        write_matrix_register(matrix_float_file, 5, tr5_data)
        # Save LOGICAL matrix for verification (column-major, so same as file)
        test_info['tr4_logical'] = [row[:] for row in tr4_data]  # Deep copy
        print(f"    [Setup] tr4 with logical column pattern (cols: 1-4, 5-8, 9-12, 13-16)")


def write_matrix_register(matrix_file, reg_index, data):
    """Write data to a specific tile register in matrix_float.txt"""
    # reg_index: 0-3 for tr4-tr7
    if not matrix_file.exists():
        # Create new file
        lines = ["--- Tile Registers (tr4-tr7) (Float Only) ---\n\n"]
        for i in range(4):
            lines.append(f"tr{i}:\n")
            lines.append(f"  (Destination: FP32, 32-bit)\n")
            for row in range(4):
                lines.append(f"  Row {row}: 0.0 0.0 0.0 0.0\n")
            lines.append("\n")
        with open(matrix_file, 'w', encoding='utf-8') as f:
            f.writelines(lines)
    
    # Read current file
    with open(matrix_file, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    # Update the target register
    new_lines = []
    current_reg = None
    reg_name = f"tr{reg_index}"
    
    for line in lines:
        if f'{reg_name}:' in line:
            current_reg = reg_name
            new_lines.append(line)
        elif current_reg and line.strip().startswith('(Destination'):
            new_lines.append(line)
        elif current_reg and line.strip().startswith('Row'):
            row_num = int(line.split()[1].rstrip(':'))
            row_data = data[row_num]
            row_str = ' '.join(f'{v:.4f}' if isinstance(v, float) else str(v) for v in row_data)
            bits = [struct.unpack('I', struct.pack('f', float(v)))[0] for v in row_data]
            bits_str = ', '.join(str(b) for b in bits)
            new_lines.append(f"  Row {row_num}: {row_str} ({bits_str})\n")
        elif current_reg and any(f'tr{i}:' in line for i in range(4)):
            current_reg = None
            new_lines.append(line)
        else:
            new_lines.append(line)
    
    # Write back
    with open(matrix_file, 'w', encoding='utf-8') as f:
        f.writelines(new_lines)
        f.flush()
        os.fsync(f.fileno())
    
    # Longer delay to ensure file is fully written
    import time
    time.sleep(0.5)


def setup_gpr(gpr_file, reg_idx, value):
    """Setup a GPR register with a value"""
    if isinstance(value, float):
        int_val = float_to_bits32(value)
    else:
        int_val = int(value)
    
    # Read current file
    with open(gpr_file, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    # Update the register
    new_lines = []
    for line in lines:
        if line.strip().startswith(f'x{reg_idx} '):
            # Extract ABI name
            parts = line.split('(')
            if len(parts) > 1:
                abi_name = parts[1].split(')')[0]
                new_lines.append(f"x{reg_idx:<2} ({abi_name:<7}): 0x{int_val:08X}\n")
            else:
                new_lines.append(line)
        else:
            new_lines.append(line)
    
    # Write back
    with open(gpr_file, 'w', encoding='utf-8') as f:
        f.writelines(new_lines)
        f.flush()
        os.fsync(f.fileno())
    
    # Longer delay to ensure file is fully written before subprocess reads
    import time
    time.sleep(0.5)
    
    # Verify write by reading back
    with open(gpr_file, 'r', encoding='utf-8') as f:
        for line in f:
            if line.strip().startswith(f'x{reg_idx} '):
                written_val = int(line.split(':')[1].strip(), 16)
                if written_val != int_val:
                    print(f"  [WARNING] GPR x{reg_idx} verification failed! Expected 0x{int_val:08X}, got 0x{written_val:08X}")
                break  # Increased from 0.01


def create_assembly_for_test(test_info):
    """Create assembly.txt with the test instruction"""
    assembler_dir = SCRIPT_DIR.parent / "assembler"
    assembly_file = assembler_dir / "assembly.txt"
    
    assembly_code = f"""# Test: {test_info['name']}
# {test_info['description']}

# Setup tile dimensions
msettilemi 4
msettileki 4
msettileni 4

# Test instruction
{test_info['instr']}
"""
    
    with open(assembly_file, 'w', encoding='utf-8') as f:
        f.write(assembly_code)
        f.flush()
        os.fsync(f.fileno())
    
    # Ensure file is written before assembler reads it
    import time
    time.sleep(0.2)
    
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
    
    # Ensure machine_code.txt is written before simulator reads it
    if result.returncode == 0:
        import time
        time.sleep(0.2)
    
    return result.returncode == 0


def run_simulator():
    """Run simulator - allow it to save state so we can read results"""
    tpu_dir = SCRIPT_DIR.parent
    
    import subprocess
    env = os.environ.copy()
    env['PYTHONIOENCODING'] = 'utf-8'
    # DON'T set NO_SAVE_STATE - we need simulator to save results
    
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
    """Verify test results based on test type"""
    iss_dir = SCRIPT_DIR
    verify_type = test_info.get('verify', '')
    
    if verify_type == 'check_all_zeros':
        # Read tr4 and check all zeros
        matrix_file = iss_dir / "matrix_float.txt"
        data = read_matrix_register(matrix_file, 4)  # tr4
        
        all_zero = all(all(abs(v) < 0.001 for v in row) for row in data)
        if all_zero:
            return True, "All elements are zero ✓"
        else:
            non_zero = [(i, j, data[i][j]) for i in range(4) for j in range(4) if abs(data[i][j]) >= 0.001]
            return False, f"Found non-zero elements: {non_zero[:3]}"
    
    elif verify_type == 'check_tr5_equals_tr4':
        # Read tr4 and tr5, compare
        matrix_file = iss_dir / "matrix_float.txt"
        tr4_data = read_matrix_register(matrix_file, 4)
        tr5_data = read_matrix_register(matrix_file, 5)
        
        matches = all(all(abs(tr4_data[i][j] - tr5_data[i][j]) < 0.001 for j in range(4)) for i in range(4))
        if matches:
            return True, "tr5 equals tr4 ✓"
        else:
            diffs = [(i, j, tr4_data[i][j], tr5_data[i][j]) 
                     for i in range(4) for j in range(4) 
                     if abs(tr4_data[i][j] - tr5_data[i][j]) >= 0.001]
            return False, f"Mismatch: {diffs[:3]}"
    
    elif verify_type == 'check_gpr_x1_has_element':
        # Read GPR x1 and check if it has expected value
        gpr_file = iss_dir / "gpr.txt"
        gpr_val = read_gpr(gpr_file, test_info['gpr_rd'])
        
        # Convert to float
        import struct
        actual_float = struct.unpack('f', struct.pack('I', gpr_val))[0]
        expected_float = test_info['expected_value']
        
        if abs(actual_float - expected_float) < 0.001:
            return True, f"GPR x{test_info['gpr_rd']} = {actual_float:.4f} ✓"
        else:
            return False, f"Expected {expected_float:.4f}, got {actual_float:.4f}"
    
    elif verify_type == 'check_tr4_element_changed':
        # Check if tr4[element_index] has the new value
        matrix_file = iss_dir / "matrix_float.txt"
        tr4_data = read_matrix_register(matrix_file, 4)
        
        idx = test_info['element_index']
        row = idx // 4
        col = idx % 4
        actual = tr4_data[row][col]
        expected = test_info['gpr_value']
        
        if abs(actual - expected) < 0.001:
            return True, f"tr4[{row}][{col}] = {actual:.4f} ✓"
        else:
            return False, f"Expected {expected:.4f}, got {actual:.4f}"
    
    elif verify_type == 'check_all_elements_equal':
        # Check if all elements of tr4 equal dup_value
        matrix_file = iss_dir / "matrix_float.txt"
        tr4_data = read_matrix_register(matrix_file, 4)
        expected = test_info['dup_value']
        
        all_match = all(all(abs(v - expected) < 0.001 for v in row) for row in tr4_data)
        if all_match:
            return True, f"All elements = {expected:.4f} ✓"
        else:
            diffs = [(i, j, tr4_data[i][j]) for i in range(4) for j in range(4) 
                     if abs(tr4_data[i][j] - expected) >= 0.001]
            return False, f"Not all equal: {diffs[:3]}"
    
    elif verify_type == 'check_rows_slid_down':
        # Check if PHYSICAL rows (file rows) slid down correctly
        # With column-major storage, mrslidedown slides PHYSICAL rows
        # tr5_file[i] = tr4_file[(i - slide) % 4]
        matrix_file = iss_dir / "matrix_float.txt"
        tr4_logical = test_info.get('tr4_logical')
        if tr4_logical is None:
            return False, "tr4_logical not saved"
        
        # Read tr5 from file
        tr5_file = read_matrix_register(matrix_file, 5)
        slide = test_info['slide_amount']
        
        # Convert logical to file format (transpose)
        tr4_file = [[tr4_logical[j][i] for j in range(4)] for i in range(4)]
        
        # Verify physical row slide
        errors = []
        for i in range(4):  # For each physical row
            src_row = (i - slide) % 4
            for j in range(4):  # For each element
                expected = tr4_file[src_row][j]
                actual = tr5_file[i][j]
                if abs(actual - expected) >= 0.001:
                    errors.append(f"PhysRow{i}[{j}]={actual:.1f}, expected PhysRow{src_row}[{j}]={expected:.1f}")
        
        if not errors:
            return True, f"Physical rows slid down by {slide} ✓"
        else:
            return False, f"Errors:\n    " + "\n    ".join(errors[:5])
    
    elif verify_type == 'check_cols_slid_down':
        # Check if LOGICAL columns slid down correctly  
        # CRITICAL: File stores column-major
        # - File row i = storage of logical column i
        # - mcslidedown.w slides within each column
        # - So each file row should be rotated independently
        matrix_file = iss_dir / "matrix_float.txt"
        tr4_logical = test_info.get('tr4_logical')  # Each row = one logical column
        if tr4_logical is None:
            return False, "tr4_logical not saved"
        
        # Read tr5 from file
        tr5_file = read_matrix_register(matrix_file, 5)
        slide = test_info['slide_amount']
        
        # Expected: each column (file row) slides independently
        # tr5_file[col][elem] = tr4_file[col][(elem - slide) % 4]
        errors = []
        for col in range(4):  # For each logical column (file row)
            for elem in range(4):  # For each element in that column
                src_elem = (elem - slide) % 4
                expected = tr4_logical[col][src_elem]
                actual = tr5_file[col][elem]
                if abs(actual - expected) >= 0.001:
                    errors.append(f"Col{col}[{elem}]={actual:.1f}, expected Col{col}[{src_elem}]={expected:.1f}")
        
        if not errors:
            return True, f"Logical columns slid down by {slide} ✓"
        else:
            return False, f"Errors:\n    " + "\n    ".join(errors[:5])
    
    else:
        return False, f"Unknown verify type: {verify_type}"


def read_matrix_register(matrix_file, reg_index):
    """Read data from a specific tile register"""
    if not matrix_file.exists():
        return [[0.0] * 4 for _ in range(4)]
    
    with open(matrix_file, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    reg_name = f"tr{reg_index}"
    data = []
    in_target = False
    
    for line in lines:
        if f'{reg_name}:' in line:
            in_target = True
            continue
        if in_target and line.strip().startswith('Row'):
            parts = line.split(':')[1].split('(')[0].strip().split()
            row_values = [float(x) for x in parts]
            data.append(row_values)
        if in_target and any(f'tr{i}:' in line for i in range(4, 8)):  # tr4-tr7
            break
    
    return data if len(data) == 4 else [[0.0] * 4 for _ in range(4)]


def read_gpr(gpr_file, reg_idx):
    """Read a GPR register value"""
    with open(gpr_file, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    for line in lines:
        if line.strip().startswith(f'x{reg_idx} '):
            # Extract hex value
            parts = line.split(':')
            if len(parts) > 1:
                hex_str = parts[1].strip()
                return int(hex_str, 16)
    
    return 0


def display_results(test_info):
    """Display results for current test"""
    print("\n" + "="*80)
    print(f"RESULTS: {test_info['name']}")
    print("="*80)
    
    iss_dir = SCRIPT_DIR
    
    # Display relevant registers based on test type
    if 'target_reg' in test_info:
        # For slide tests (test 6 & 7), display the RESULT register from file
        # For other tests, read from file as normal
        matrix_file = iss_dir / "matrix_float.txt"
        # Use dst_idx for slide operations, reg_idx for others
        reg_idx = test_info.get('dst_idx') or test_info.get('reg_idx', 4)
        print(f"\n[Register: {test_info['target_reg']} - RESULT after simulation]")
        data = read_matrix_register(matrix_file, reg_idx)
        for i, row in enumerate(data):
            print(f"  Row {i}: {' '.join(f'{v:8.4f}' for v in row)}")
    
    if 'source_reg' in test_info and test_info['source_reg'] != test_info.get('target_reg'):
        # For slide tests, display LOGICAL view of source register
        if 'tr4_logical' in test_info:
            print(f"\n[Register: {test_info['source_reg']} - LOGICAL view (before simulation)]")
            data = test_info['tr4_logical']
            # Check if this is row or column pattern
            if 'row' in test_info.get('setup', ''):
                # Row pattern - display as rows
                for i, row in enumerate(data):
                    print(f"  Logical Row {i}: {' '.join(f'{v:6.1f}' for v in row)}")
            else:
                # Column pattern - display as columns (transpose)
                for j in range(4):
                    col = [data[j][i] for i in range(4)]
                    print(f"  Logical Col {j}: {' '.join(f'{v:6.1f}' for v in col)}")
        else:
            # For non-slide tests, read from file
            matrix_file = iss_dir / "matrix_float.txt"
            src_idx = test_info.get('src_idx', 4)
            print(f"\n[Register: {test_info['source_reg']}]")
            data = read_matrix_register(matrix_file, src_idx)
            for i, row in enumerate(data):
                print(f"  Row {i}: {' '.join(f'{v:8.4f}' for v in row)}")
    
    if 'gpr_rd' in test_info:
        gpr_file = iss_dir / "gpr.txt"
        val = read_gpr(gpr_file, test_info['gpr_rd'])
        val_float = struct.unpack('f', struct.pack('I', val))[0]
        print(f"\n[GPR x{test_info['gpr_rd']}]: 0x{val:08X} ({val_float:.4f})")
    
    # Verification
    print("\n" + "-"*80)
    print("[VERIFICATION]")
    success, message = verify_test(test_info)
    
    if success:
        print(f"  ✓ PASS - {message}")
    else:
        print(f"  ✗ FAIL - {message}")
    
    print("-"*80)
    
    return success


def run_single_test(test_info, test_num, total_tests, use_random=False):
    """Run a single test case"""
    print("\n" + "="*80)
    print(f"TEST {test_num}/{total_tests}: {test_info['name']}")
    print(f"Description: {test_info['description']}")
    print("="*80)
    
    # Step 0: Setup test data
    print("\n[Step 0] Setting up test data...")
    setup_test_data(test_info, use_random=use_random)
    print("  [OK] Setup complete")
    
    # Step 1: Create assembly
    print("\n[Step 1] Creating assembly.txt...")
    assembly_file = create_assembly_for_test(test_info)
    print(f"  [OK] Created: {assembly_file}")
    print(f"       - {test_info['instr']}")
    
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
    
    # CRITICAL: Wait for simulator subprocess to finish saving files
    import time
    time.sleep(1.0)
    
    # Step 4: Display results and verify
    passed = display_results(test_info)
    
    return passed


def main():
    """Main test function"""
    # Parse command line arguments
    parser = argparse.ArgumentParser(description='Test Miscellaneous (MISC) instructions')
    parser.add_argument('--auto', action='store_true', help='Run in automated mode (no user input)')
    parser.add_argument('--random', action='store_true', help='Use random test data')
    args = parser.parse_args()
    
    auto_mode = args.auto
    random_mode = args.random
    
    print("\n" + "="*80)
    print("MISCELLANEOUS INSTRUCTION TEST - " + ("AUTO MODE" if auto_mode else "SEQUENTIAL MODE"))
    print("="*80)
    print("\nThis script tests utility matrix operations:")
    for i, test in enumerate(TEST_CASES, 1):
        print(f"  {i}. {test['name']:<20} - {test['description']}")
    if not auto_mode:
        print("\nPress Enter after each test to continue to the next one.")
    print("="*80)
    
    try:
        # Initial setup (once)
        setup_initial_state()
        
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
            success = run_single_test(test_info, i, total_tests, use_random=random_mode)
            
            if success:
                passed_tests += 1
            else:
                failed_tests += 1
            
            if not success:
                print(f"\n[WARNING] Test {i} failed!")
                # Continue to next test in both modes
            
            # Ask to continue (except after last test)
            if i < total_tests and not auto_mode:
                print("\n" + "="*80)
                input(f"Press Enter to run test {i+1}/{total_tests}...")
        
        print("\n" + "="*80)
        print("ALL TESTS COMPLETE!")
        print("="*80)
        print(f"\n[SUMMARY]")
        print(f"  ✓ Passed: {passed_tests}/{total_tests}")
        print(f"  ✗ Failed: {failed_tests}/{total_tests}")
        
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
