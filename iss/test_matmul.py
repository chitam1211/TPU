#!/usr/bin/env python3
"""
Test script for Matrix Multiply-Accumulate (MatMul) instruction group
Run directly in the iss directory

Tests matrix multiplication with accumulation: C = C + A × B^T
1. mme32 - Float32 matmul (acc0)
2. mme16 - Float16 matmul (acc1)
3. mme8  - Int8 matmul (acc2)

Each test:
- Initializes C (accumulator) with known values
- Loads A into tile register
- Loads B into tile register  
- Performs C = C + A × B^T
- Verifies result matches expected calculation

Usage:
    python test_matmul.py                    # Interactive mode with fixed values
    python test_matmul.py --auto             # Auto mode with fixed values
    python test_matmul.py --random           # Interactive mode with random values
    python test_matmul.py --auto --random    # Auto mode with random values
"""

import sys
import os
from pathlib import Path
import struct
import random
import numpy as np

# Add parent directory to sys.path
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR.parent))

# Import real FP8 converters
from iss.converters import float_to_bits8_e5m2, float_to_bits8_e4m3, bits_to_float8_e5m2, bits_to_float8_e4m3, float_to_bits16, bits_to_float16, float_to_bfloat16, bfloat16_to_float

def generate_random_test_matrices():
    rng = np.random.default_rng()
    # Float32
    f32_a = rng.uniform(-10, 10, 16).astype(np.float32).tolist()  # tr4
    f32_b = rng.uniform(-10, 10, 16).astype(np.float32).tolist()  # tr5
    # Float16
    f16_a = rng.uniform(-10, 10, 16).astype(np.float16).tolist()  # tr4
    f16_b = rng.uniform(-10, 10, 16).astype(np.float16).tolist()  # tr5
    # BFloat16 (simulate with float32, but will be truncated later)
    bf16_a = rng.uniform(-10, 10, 16).astype(np.float32).tolist()  # tr4
    bf16_b = rng.uniform(-10, 10, 16).astype(np.float32).tolist()  # tr5
    # FP8 (E5M2, E4M3): use small range to avoid overflow
    fp8_e5_a = rng.uniform(-4, 4, 16).astype(np.float32).tolist()  # tr4
    fp8_e5_b = rng.uniform(-4, 4, 16).astype(np.float32).tolist()  # tr5
    fp8_e4_a = rng.uniform(-4, 4, 16).astype(np.float32).tolist()  # tr4
    fp8_e4_b = rng.uniform(-4, 4, 16).astype(np.float32).tolist()  # tr5
    # Int8
    i8_a = rng.integers(-20, 20, 16, dtype=np.int8).tolist()  # tr4
    i8_b = rng.integers(-20, 20, 16, dtype=np.int8).tolist()  # tr5
    # Unsigned Int8
    u8_a = rng.integers(0, 40, 16, dtype=np.uint8).tolist()  # tr4
    u8_b = rng.integers(0, 40, 16, dtype=np.uint8).tolist()  # tr5
    # Initial C values: giữ nguyên như test đơn giản
    f32_c = [10.0] * 16
    f16_c = [5.0] * 16
    bf16_c = [5.0] * 16
    fp8_e5_c = [2.0] * 16
    fp8_e4_c = [2.0] * 16
    i8_c = [100] * 16
    u8_c = [100] * 16
    return {
        'f32_a': f32_a, 'f32_b': f32_b, 'f32_c': f32_c,
        'f16_a': f16_a, 'f16_b': f16_b, 'f16_c': f16_c,
        'bf16_a': bf16_a, 'bf16_b': bf16_b, 'bf16_c': bf16_c,
        'fp8_e5_a': fp8_e5_a, 'fp8_e5_b': fp8_e5_b, 'fp8_e5_c': fp8_e5_c,
        'fp8_e4_a': fp8_e4_a, 'fp8_e4_b': fp8_e4_b, 'fp8_e4_c': fp8_e4_c,
        'i8_a': i8_a, 'i8_b': i8_b, 'i8_c': i8_c,
        'u8_a': u8_a, 'u8_b': u8_b, 'u8_c': u8_c,
    }

# Test cases definition
TEST_CASES = [
    {
        'name': 'mfmacc.s',
        'description': 'Float32 Matrix Multiply-Accumulate (FP32xFP32->FP32)',
        'instr': 'mfmacc.s acc0, tr4, tr5',
        'explanation': 'Matrix Float Multiply-ACCumulate Single: acc[i][j] += sum(A[i][k] * B[j][k]) for k=0..K-1',
        'acc_reg': 0,
        'acc_initial': 10.0,
        'tr_a_reg': 4,
        'tr_b_reg': 5,
        'data_type': 'float32',
        'acc_type': 'float32',
        'is_float': True,
    },
    {
        'name': 'mfmacc.h',
        'description': 'Float16 Matrix Multiply-Accumulate (FP16xFP16->FP16)',
        'instr': 'mfmacc.h acc1, tr4, tr5',
        'explanation': 'Matrix Float Multiply-ACCumulate Half: acc[i][j] += sum(A[i][k] * B[j][k]) (FP16 precision)',
        'acc_reg': 1,
        'acc_initial': 5.0,
        'tr_a_reg': 4,
        'tr_b_reg': 5,
        'data_type': 'float16',
        'acc_type': 'float16',
        'is_float': True,
    },
    {
        'name': 'mfmacc.s.h',
        'description': 'FP16->FP32 Widening Multiply-Accumulate (FP16xFP16->FP32)',
        'instr': 'mfmacc.s.h acc2, tr4, tr5',
        'explanation': 'Widening MatMul: FP16 inputs -> FP32 accumulator (higher precision result)',
        'acc_reg': 2,
        'acc_initial': 5.0,
        'tr_a_reg': 4,
        'tr_b_reg': 5,
        'data_type': 'float16',
        'acc_type': 'float32',
        'is_float': True,
    },
    {
        'name': 'mfmacc.s.bf16',
        'description': 'BF16->FP32 Widening Multiply-Accumulate (BF16xBF16->FP32)',
        'instr': 'mfmacc.s.bf16 acc3, tr4, tr5',
        'explanation': 'Widening MatMul: BFloat16 inputs -> FP32 accumulator (ML inference common)',
        'acc_reg': 3,
        'acc_initial': 5.0,
        'tr_a_reg': 4,
        'tr_b_reg': 5,
        'data_type': 'bfloat16',
        'acc_type': 'float32',
        'is_float': True,
    },
    {
        'name': 'mfmacc.bf16.e5',
        'description': 'FP8(E5M2)->BF16 Multiply-Accumulate',
        'instr': 'mfmacc.bf16.e5 acc2, tr6, tr7',
        'explanation': 'FP8 E5M2 MatMul: 8-bit float (5-bit exp, 2-bit mantissa) -> BF16 accumulator',
        'acc_reg': 2,
        'acc_initial': 5.0,
        'tr_a_reg': 6,
        'tr_b_reg': 7,
        'data_type': 'fp8_e5m2',
        'acc_type': 'bfloat16',
        'is_float': True,
        'tr_uses_int_storage': True,  # FP8 loaded into tr_int
    },
    {
        'name': 'mfmacc.bf16.e4',
        'description': 'FP8(E4M3)->BF16 Multiply-Accumulate',
        'instr': 'mfmacc.bf16.e4 acc3, tr6, tr7',
        'explanation': 'FP8 E4M3 MatMul: 8-bit float (4-bit exp, 3-bit mantissa) -> BF16 accumulator',
        'acc_reg': 3,
        'acc_initial': 5.0,
        'tr_a_reg': 6,
        'tr_b_reg': 7,
        'data_type': 'fp8_e4m3',
        'acc_type': 'bfloat16',
        'is_float': True,
        'tr_uses_int_storage': True,  # FP8 loaded into tr_int
    },
    {
        'name': 'mmacc.w.b',
        'description': 'INT8 SignedxSigned Matrix Multiply-Accumulate (sxs->INT32)',
        'instr': 'mmacc.w.b acc2, tr6, tr7',
        'explanation': 'Integer MatMul: signed INT8 x signed INT8 -> INT32 accumulator (quantized inference)',
        'acc_reg': 2,
        'acc_initial': 100,
        'tr_a_reg': 6,
        'tr_b_reg': 7,
        'data_type': 'int8',
        'acc_type': 'int32',
        'is_float': False,
    },
    {
        'name': 'mmaccu.w.b',
        'description': 'UINT8 UnsignedxUnsigned Matrix Multiply-Accumulate (uxu->INT32)',
        'instr': 'mmaccu.w.b acc3, tr6, tr7',
        'explanation': 'Integer MatMul: unsigned UINT8 x unsigned UINT8 -> INT32 accumulator',
        'acc_reg': 3,
        'acc_initial': 100,
        'tr_a_reg': 6,
        'tr_b_reg': 7,
        'data_type': 'uint8',
        'acc_type': 'int32',
        'is_float': False,
    },
    {
        'name': 'mmaccus.w.b',
        'description': 'Mixed UINT8xINT8 Matrix Multiply-Accumulate (uxs->INT32)',
        'instr': 'mmaccus.w.b acc0, tr6, tr7',
        'explanation': 'Mixed MatMul: unsigned A (UINT8) x signed B (INT8) -> INT32 accumulator',
        'acc_reg': 0,
        'acc_initial': 100,
        'tr_a_reg': 6,
        'tr_b_reg': 7,
        'data_type': 'uint8',
        'acc_type': 'int32',
        'is_float': False,
    },
    {
        'name': 'mmaccsu.w.b',
        'description': 'Mixed INT8xUINT8 Matrix Multiply-Accumulate (sxu->INT32)',
        'instr': 'mmaccsu.w.b acc1, tr6, tr7',
        'explanation': 'Mixed MatMul: signed A (INT8) x unsigned B (UINT8) -> INT32 accumulator',
        'acc_reg': 1,
        'acc_initial': 100,
        'tr_a_reg': 6,
        'tr_b_reg': 7,
        'data_type': 'int8',
        'acc_type': 'int32',
        'is_float': False,
    },
]


def float32_to_hex(value):
    """Convert float32 to hex string"""
    bytes_val = struct.pack('<f', value)
    return ' '.join(f'{b:02X}' for b in bytes_val)


def float16_to_hex(value):
    """Convert float16 to hex string (2 bytes)"""
    try:
        import numpy as np
        f16 = np.float16(value)
        bytes_val = f16.tobytes()
        return ' '.join(f'{b:02X}' for b in bytes_val)
    except ImportError:
        return "00 3C"  # 1.0 in float16


def bfloat16_to_hex(value):
    """Convert bfloat16 to hex string (2 bytes)
    BFloat16: truncate float32 to 16 bits (keep sign + exponent + 7 bits mantissa)
    """
    f32_bytes = struct.pack('<f', value)
    # Take upper 2 bytes of float32 (big-endian order for BF16)
    bf16_bytes = f32_bytes[2:4]
    return ' '.join(f'{b:02X}' for b in bf16_bytes)


def fp8_e5m2_to_hex(value):
    """Convert FP8 E5M2 to hex string (1 byte) using real converter"""
    bits = float_to_bits8_e5m2(value)
    return f'{bits:02X}'


def fp8_e4m3_to_hex(value):
    """Convert FP8 E4M3 to hex string (1 byte) using real converter"""
    bits = float_to_bits8_e4m3(value)
    return f'{bits:02X}'


def int8_to_hex(value):
    """Convert int8 to hex string"""
    return f'{value & 0xFF:02X}'


def uint8_to_hex(value):
    """Convert uint8 to hex string"""
    return f'{value & 0xFF:02X}'


def generate_simple_test_matrices():
    """Generate simple test matrices for easy verification"""
    
    # Float32: Simple values for manual verification
    # Matrix A (4x4): [1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12], [13, 14, 15, 16]
    # Matrix B (4x4): [1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1] (identity)
    # Expected: A × B^T = A (since B is identity)
    
    f32_a = [
        1.0, 2.0, 3.0, 4.0,
        5.0, 6.0, 7.0, 8.0,
        9.0, 10.0, 11.0, 12.0,
        13.0, 14.0, 15.0, 16.0
    ]
    
    f32_b = [
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0
    ]
    
    # Float16: Same pattern
    f16_a = [float(i+1) for i in range(16)]
    f16_b = [1.0 if i % 5 == 0 else 0.0 for i in range(16)]  # identity
    
    # BFloat16: Similar to FP16 but smaller values
    bf16_a = [float(i+1) for i in range(16)]
    bf16_b = [1.0 if i % 5 == 0 else 0.0 for i in range(16)]  # identity
    
    # FP8 (E5M2 and E4M3): Very small values to avoid overflow
    fp8_e5_a = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0]
    fp8_e5_b = [1.0 if i % 5 == 0 else 0.0 for i in range(16)]
    
    fp8_e4_a = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0]
    fp8_e4_b = [1.0 if i % 5 == 0 else 0.0 for i in range(16)]
    
    # Int8: Smaller values to avoid overflow
    # A: [1, 2, 3, 4], [5, 6, 7, 8], [-1, -2, -3, -4], [-5, -6, -7, -8]
    # B: identity
    i8_a = [1, 2, 3, 4, 5, 6, 7, 8, -1, -2, -3, -4, -5, -6, -7, -8]
    i8_b = [1 if i % 5 == 0 else 0 for i in range(16)]
    
    # Unsigned Int8: All positive
    u8_a = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    u8_b = [1 if i % 5 == 0 else 0 for i in range(16)]
    
    # Initial C values (will be added to result)
    f32_c = [10.0] * 16  # All 10.0
    f16_c = [5.0] * 16   # All 5.0
    bf16_c = [5.0] * 16  # All 5.0
    fp8_e5_c = [2.0] * 16  # Small value for FP8
    fp8_e4_c = [2.0] * 16  # Small value for FP8
    i8_c = [100] * 16    # All 100
    u8_c = [100] * 16    # All 100
    
    return {
        'f32_a': f32_a, 'f32_b': f32_b, 'f32_c': f32_c,
        'f16_a': f16_a, 'f16_b': f16_b, 'f16_c': f16_c,
        'bf16_a': bf16_a, 'bf16_b': bf16_b, 'bf16_c': bf16_c,
        'fp8_e5_a': fp8_e5_a, 'fp8_e5_b': fp8_e5_b, 'fp8_e5_c': fp8_e5_c,
        'fp8_e4_a': fp8_e4_a, 'fp8_e4_b': fp8_e4_b, 'fp8_e4_c': fp8_e4_c,
        'i8_a': i8_a, 'i8_b': i8_b, 'i8_c': i8_c,
        'u8_a': u8_a, 'u8_b': u8_b, 'u8_c': u8_c,
    }


def setup_test_data(random_mode=False, random_matrices=None):
    """Prepare test data in memory.txt, matrix.txt, and acc.txt"""
    print("\n" + "="*80)
    print("INITIAL SETUP: PREPARING TEST DATA")
    print("="*80)
    
    iss_dir = SCRIPT_DIR
    matrices = random_matrices if random_mode and random_matrices is not None else generate_simple_test_matrices()
    
    # --- 1. Setup Memory for Load Operations ---
    print("\n[1] Setting up memory.txt for matrix loading...")
    memory_file = iss_dir / "memory.txt"
    
    with open(memory_file, 'r', encoding='utf-8') as f:
        memory_lines = f.readlines()
    
    test_data = {}
    
    # Float32 matrices at 0x100-0x13F (A) and 0x140-0x17F (B)
    print("  - Float32 Matrix A at 0x100-0x13F")
    for row in range(4):
        addr = 0x100 + row * 0x10
        hex_str = ' '.join([float32_to_hex(matrices['f32_a'][row*4 + i]) for i in range(4)])
        test_data[addr] = hex_str
    
    print("  - Float32 Matrix B at 0x140-0x17F")
    for row in range(4):
        addr = 0x140 + row * 0x10
        hex_str = ' '.join([float32_to_hex(matrices['f32_b'][row*4 + i]) for i in range(4)])
        test_data[addr] = hex_str
    
    # Float16 matrices at 0x200-0x21F (A) and 0x220-0x23F (B)
    print("  - Float16 Matrix A at 0x200-0x21F")
    try:
        for row in range(4):
            addr = 0x200 + row * 0x08
            hex_str = ' '.join([float16_to_hex(matrices['f16_a'][row*4 + i]) for i in range(4)])
            test_data[addr] = hex_str
        
        print("  - Float16 Matrix B at 0x220-0x23F")
        for row in range(4):
            addr = 0x220 + row * 0x08
            hex_str = ' '.join([float16_to_hex(matrices['f16_b'][row*4 + i]) for i in range(4)])
            test_data[addr] = hex_str
    except ImportError:
        print("  Warning: numpy not available, using placeholder float16 data")
        test_data[0x200] = "00 3C 00 40 00 40 00 42"
        test_data[0x208] = "00 44 00 46 00 48 00 4A"
        test_data[0x210] = "00 4C 00 4E 00 50 00 51"
        test_data[0x218] = "00 52 00 53 00 54 00 55"
        test_data[0x220] = "00 3C 00 00 00 00 00 00"
        test_data[0x228] = "00 00 00 3C 00 00 00 00"
        test_data[0x230] = "00 00 00 00 00 3C 00 00"
        test_data[0x238] = "00 00 00 00 00 00 00 3C"
    
    # Int8 matrices at 0x300-0x30F (A) and 0x310-0x31F (B)
    # Also used for UINT8 and FP8 (all 8-bit formats share same addresses)
    print("  - Int8/UInt8/FP8 Matrix A at 0x300-0x30F")
    for row in range(4):
        addr = 0x300 + row * 0x04
        # Write INT8 data (will be overwritten by UINT8/FP8 if needed during specific tests)
        hex_str = ' '.join([int8_to_hex(matrices['i8_a'][row*4 + i]) for i in range(4)])
        test_data[addr] = hex_str
    
    print("  - Int8/UInt8/FP8 Matrix B at 0x310-0x31F")
    for row in range(4):
        addr = 0x310 + row * 0x04
        hex_str = ' '.join([int8_to_hex(matrices['i8_b'][row*4 + i]) for i in range(4)])
        test_data[addr] = hex_str
    
    # Note: BFloat16, FP8 E5M2, E4M3, and UINT8 share addresses with FP16 and INT8
    # The actual data loaded depends on which test is running
    # We'll update memory dynamically before each test that needs different data
    
    # DEBUG: Print test_data to verify all addresses are present
    print(f"\n    [DEBUG] test_data addresses: {sorted(test_data.keys())}")
    fp16_addrs = [a for a in test_data.keys() if 0x200 <= a <= 0x240]
    print(f"    [DEBUG] FP16 addresses in test_data: {[hex(a) for a in sorted(fp16_addrs)]}")
    for addr in sorted(fp16_addrs):
        print(f"    [DEBUG] {hex(addr)}: {test_data[addr]}")
    
    # REBUILD memory.txt from scratch with test_data
    # Fill 0x000-0x3FF with zeros, then overlay test_data
    memory_dict = {}
    
    # Initialize all memory to zeros (in 16-byte lines for addresses not in test_data)
    for addr in range(0x000, 0x400, 0x10):
        if addr not in test_data:
            memory_dict[addr] = "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"
    
    # Overlay test_data (which may have 4-byte or 8-byte lines)
    for addr, data in test_data.items():
        memory_dict[addr] = data
    
    # Write sorted memory
    new_memory_lines = ["# Memory State (Hex Format)\n", "# Address: Byte0 Byte1 Byte2 Byte3 ...\n\n"]
    for addr in sorted(memory_dict.keys()):
        new_memory_lines.append(f"0x{addr:03X}: {memory_dict[addr]}\n")
    
    with open(memory_file, 'w', encoding='utf-8') as f:
        f.writelines(new_memory_lines)
        f.flush()
        os.fsync(f.fileno())
    
    print(f"    [OK] Memory rebuilt with {len(memory_dict)} lines")
    
    # --- 2. Setup GPR ---
    print("\n[2] Setting up gpr.txt...")
    gpr_file = iss_dir / "gpr.txt"
    
    gpr_values = {
        0: 0,       # zero
        # Float32 matrices (16 bytes/row)
        1: 0x100,   # base addr for float32 A
        2: 0x10,    # stride for float32 (16 bytes)
        3: 0x140,   # base addr for float32 B
        # Float16 matrices (8 bytes/row) - reuse for BF16
        4: 0x200,   # base addr for float16/bfloat16 A
        5: 0x08,    # stride for float16/bfloat16 (8 bytes)
        6: 0x220,   # base addr for float16/bfloat16 B
        # Int8 matrices (4 bytes/row) - reuse for UINT8 and FP8
        7: 0x300,   # base addr for int8/uint8/fp8 A
        8: 0x04,    # stride for int8/uint8/fp8 (4 bytes)
        9: 0x310,   # base addr for int8/uint8/fp8 B
        # Additional addresses (for separation if needed)
        10: 0x200,  # bfloat16 A (same as FP16)
        11: 0x220,  # bfloat16 B (same as FP16)
        12: 0x300,  # fp8_e5m2 A (same as INT8)
        13: 0x310,  # fp8_e5m2 B (same as INT8)
        14: 0x300,  # fp8_e4m3 A (same as INT8)
        15: 0x310,  # fp8_e4m3 B (same as INT8)
        16: 0x300,  # uint8 A (same as INT8)
        17: 0x310,  # uint8 B (same as INT8)
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
    
    print(f"    [OK] GPR configured")
    
    # --- 3. Initialize Accumulators ---
    print("\n[3] Initializing accumulator registers...")
    
    # Float accumulators
    acc_float_file = iss_dir / "acc_float.txt"
    with open(acc_float_file, 'w', encoding='utf-8') as f:
        f.write("--- Accumulator Registers (acc0-acc3) (Float Only) ---\n\n")
        
        # acc0: Float32, initialize with 10.0
        f.write("acc0:\n")
        f.write("  (Destination: FP32, 32-bit)\n")
        for row in range(4):
            values = [10.0] * 4
            int_repr = [struct.unpack('I', struct.pack('f', v))[0] for v in values]
            f.write(f"  Row {row}: {' '.join(f'{v:.4f}' for v in values)} "
                   f"({', '.join(str(i) for i in int_repr)})\n")
        
        # acc1: Float16, initialize with 5.0
        f.write("\nacc1:\n")
        f.write("  (Destination: FP16, 16-bit)\n")
        for row in range(4):
            values = [5.0] * 4
            f.write(f"  Row {row}: {' '.join(f'{v:.4f}' for v in values)}\n")
        
        # acc2: FP32 (for widening operations), initialize with 5.0
        f.write("\nacc2:\n")
        f.write("  (Destination: FP32, 32-bit)\n")
        for row in range(4):
            values = [5.0] * 4
            int_repr = [struct.unpack('I', struct.pack('f', v))[0] for v in values]
            f.write(f"  Row {row}: {' '.join(f'{v:.4f}' for v in values)} "
                   f"({', '.join(str(i) for i in int_repr)})\n")
        
        # acc3: FP32 (for BF16 widening), initialize with 5.0
        f.write("\nacc3:\n")
        f.write("  (Destination: FP32, 32-bit)\n")
        for row in range(4):
            values = [5.0] * 4
            int_repr = [struct.unpack('I', struct.pack('f', v))[0] for v in values]
            f.write(f"  Row {row}: {' '.join(f'{v:.4f}' for v in values)} "
                   f"({', '.join(str(i) for i in int_repr)})\n")
    
    # Int accumulators
    acc_file = iss_dir / "acc.txt"
    with open(acc_file, 'w', encoding='utf-8') as f:
        f.write("--- Accumulator Registers (acc0-acc3) (Integer Only) ---\n\n")
        
        # acc0: INT32 (for mmaccus.w.b), initialize with 100
        f.write("acc0:\n")
        f.write("  (Destination: INT32, 32-bit)\n")
        for row in range(4):
            values = [100] * 4
            f.write(f"  Row {row}: {' '.join(str(v) for v in values)} "
                   f"({', '.join(str(v) for v in values)})\n")
        f.write("\n")
        
        # acc1: INT32 (for mmaccsu.w.b), initialize with 100
        f.write("acc1:\n")
        f.write("  (Destination: INT32, 32-bit)\n")
        for row in range(4):
            values = [100] * 4
            f.write(f"  Row {row}: {' '.join(str(v) for v in values)} "
                   f"({', '.join(str(v) for v in values)})\n")
        f.write("\n")
        
        # acc2: INT32 (for mmacc.w.b), initialize with 100
        f.write("acc2:\n")
        f.write("  (Destination: INT32, 32-bit)\n")
        for row in range(4):
            values = [100] * 4
            f.write(f"  Row {row}: {' '.join(str(v) for v in values)} "
                   f"({', '.join(str(v) for v in values)})\n")
        
        # acc3: INT32 (for mmaccu.w.b), initialize with 100
        f.write("\nacc3:\n")
        f.write("  (Destination: INT32, 32-bit)\n")
        for row in range(4):
            values = [100] * 4
            f.write(f"  Row {row}: {' '.join(str(v) for v in values)} "
                   f"({', '.join(str(v) for v in values)})\n")
    
    print(f"    [OK] Accumulators initialized")
    print(f"         - acc0 (float32): all 10.0")
    print(f"         - acc1 (float16): all 5.0")
    print(f"         - acc2, acc3 (float32): all 5.0 (for widening)")
    print(f"         - acc0-3 (int32): all 100")


def update_memory_for_test(test_info, random_mode=False, random_matrices=None):
    """Update memory with appropriate data for the current test"""
    iss_dir = SCRIPT_DIR
    memory_file = iss_dir / "memory.txt"
    matrices = random_matrices if random_mode and random_matrices is not None else generate_simple_test_matrices()
    data_type = test_info['data_type']
    test_name = test_info['name']

    # Read current memory
    with open(memory_file, 'r', encoding='utf-8') as f:
        memory_lines = f.readlines()
    
    # Determine addresses and data based on data type
    updates = {}
    
    # Handle mixed-sign integer cases first, as they are special
    if test_name == 'mmaccus.w.b': # uxs (UINT8 x INT8)
        # Load UINT8 Matrix A
        for row in range(4):
            addr = 0x300 + row * 0x04
            hex_str = ' '.join([uint8_to_hex(matrices['u8_a'][row*4 + i]) for i in range(4)])
            updates[addr] = hex_str
        # Load INT8 Matrix B
        for row in range(4):
            addr = 0x310 + row * 0x04
            hex_str = ' '.join([int8_to_hex(matrices['i8_b'][row*4 + i]) for i in range(4)])
            updates[addr] = hex_str
    elif test_name == 'mmaccsu.w.b': # sxu (INT8 x UINT8)
        # Load INT8 Matrix A
        for row in range(4):
            addr = 0x300 + row * 0x04
            hex_str = ' '.join([int8_to_hex(matrices['i8_a'][row*4 + i]) for i in range(4)])
            updates[addr] = hex_str
        # Load UINT8 Matrix B
        for row in range(4):
            addr = 0x310 + row * 0x04
            hex_str = ' '.join([uint8_to_hex(matrices['u8_b'][row*4 + i]) for i in range(4)])
            updates[addr] = hex_str
    elif data_type == 'float16':
        # Restore FP16 data (may have been overwritten by BF16)
        for row in range(4):
            addr = 0x200 + row * 0x08
            hex_str = ' '.join([float16_to_hex(matrices['f16_a'][row*4 + i]) for i in range(4)])
            updates[addr] = hex_str
        for row in range(4):
            addr = 0x220 + row * 0x08
            hex_str = ' '.join([float16_to_hex(matrices['f16_b'][row*4 + i]) for i in range(4)])
            updates[addr] = hex_str
    
    elif data_type == 'bfloat16':
        # Update 0x200-0x21F with BF16 data
        for row in range(4):
            addr = 0x200 + row * 0x08
            hex_str = ' '.join([bfloat16_to_hex(matrices['bf16_a'][row*4 + i]) for i in range(4)])
            updates[addr] = hex_str
        for row in range(4):
            addr = 0x220 + row * 0x08
            hex_str = ' '.join([bfloat16_to_hex(matrices['bf16_b'][row*4 + i]) for i in range(4)])
            updates[addr] = hex_str
    
    elif data_type == 'fp8_e5m2':
        # Update 0x300-0x30F with FP8 E5M2 data
        for row in range(4):
            addr = 0x300 + row * 0x04
            hex_str = ' '.join([fp8_e5m2_to_hex(matrices['fp8_e5_a'][row*4 + i]) for i in range(4)])
            updates[addr] = hex_str
        for row in range(4):
            addr = 0x310 + row * 0x04
            hex_str = ' '.join([fp8_e5m2_to_hex(matrices['fp8_e5_b'][row*4 + i]) for i in range(4)])
            updates[addr] = hex_str
    
    elif data_type == 'fp8_e4m3':
        # Update 0x300-0x30F with FP8 E4M3 data
        for row in range(4):
            addr = 0x300 + row * 0x04
            hex_str = ' '.join([fp8_e4m3_to_hex(matrices['fp8_e4_a'][row*4 + i]) for i in range(4)])
            updates[addr] = hex_str
        for row in range(4):
            addr = 0x310 + row * 0x04
            hex_str = ' '.join([fp8_e4m3_to_hex(matrices['fp8_e4_b'][row*4 + i]) for i in range(4)])
            updates[addr] = hex_str
    
    elif data_type == 'int8':
        # Restore INT8 data (may have been overwritten by FP8/UINT8)
        for row in range(4):
            addr = 0x300 + row * 0x04
            hex_str = ' '.join([int8_to_hex(matrices['i8_a'][row*4 + i]) for i in range(4)])
            updates[addr] = hex_str
        for row in range(4):
            addr = 0x310 + row * 0x04
            hex_str = ' '.join([int8_to_hex(matrices['i8_b'][row*4 + i]) for i in range(4)])
            updates[addr] = hex_str
    
    elif data_type == 'uint8':
        # Update 0x300-0x30F with UINT8 data
        for row in range(4):
            addr = 0x300 + row * 0x04
            hex_str = ' '.join([uint8_to_hex(matrices['u8_a'][row*4 + i]) for i in range(4)])
            updates[addr] = hex_str
        for row in range(4):
            addr = 0x310 + row * 0x04
            hex_str = ' '.join([uint8_to_hex(matrices['u8_b'][row*4 + i]) for i in range(4)])
            updates[addr] = hex_str
    
    # If no updates needed, return
    if not updates:
        return
    
    # Apply updates to memory
    new_memory_lines = []
    for line in memory_lines:
        if ':' in line and not line.startswith('#'):
            try:
                addr_part = line.split(':')[0].strip()
                addr = int(addr_part, 16)
                if addr in updates:
                    new_memory_lines.append(f"{addr_part}: {updates[addr]}\n")
                    # Remove from updates so we don't add it again
                    del updates[addr]
                else:
                    new_memory_lines.append(line)
            except:
                new_memory_lines.append(line)
        else:
            new_memory_lines.append(line)

    # In case an address was not in the original file, add it.
    # This can happen if the file was empty or didn't have the 0x3xx range
    for addr, data in sorted(updates.items()):
        new_memory_lines.append(f"0x{addr:03X}: {data}\n")
    
    # Write back to memory file
    with open(memory_file, 'w', encoding='utf-8') as f:
        f.writelines(new_memory_lines)
        f.flush()  # Force write to disk
        os.fsync(f.fileno())  # Ensure OS writes to disk


def reset_accumulator(test_info):
    """Reset all accumulators to their default initial values by rewriting the files."""
    iss_dir = Path(__file__).parent
    
    # Define the default initial state for ALL float accumulators
    acc_initial_states_float = {
        0: 10.0,  # For mfmacc.s
        1: 5.0,   # For mfmacc.h
        2: 5.0,   # For widening matmuls like mfmacc.s.h
        3: 5.0,   # For widening matmuls like mfmacc.s.bf16
    }
    
    # Define the default initial state for ALL integer accumulators
    acc_initial_states_int = {
        0: 100,   # For mmaccus.w.b
        1: 100,   # For mmaccsu.w.b
        2: 100,   # For mmacc.w.b
        3: 100,   # For mmaccu.w.b
    }

    # Helper to write a float accumulator block
    def write_float_acc_block(f, acc_num, initial_val):
        acc_types = {0: "FP32", 1: "FP16", 2: "FP32", 3: "FP32"}
        acc_type = acc_types.get(acc_num, "FP32")
        f.write(f"acc{acc_num}:\n")
        f.write(f"  (Destination: {acc_type}, 32-bit)\n")
        for i in range(4):
            val_str = f"{initial_val:.4f}"
            row_data = ' '.join([val_str] * 4)
            bits = struct.unpack('I', struct.pack('f', float(initial_val)))[0]
            bits_str = ', '.join([str(bits)] * 4)
            f.write(f"  Row {i}: {row_data} ({bits_str})\n")
        f.write("\n")

    # Helper to write an integer accumulator block
    def write_int_acc_block(f, acc_num, initial_val):
        f.write(f"acc{acc_num}:\n")
        f.write("  (Destination: INT32, 32-bit)\n")
        for i in range(4):
            val_str = str(int(initial_val))
            row_data = ' '.join([val_str] * 4)
            f.write(f"  Row {i}: {row_data} ({row_data})\n")
        f.write("\n")

    # Rewrite the float accumulator file completely
    acc_float_file = iss_dir / 'acc_float.txt'
    with open(acc_float_file, 'w', encoding='utf-8') as f:
        f.write("--- Accumulator Registers (acc0-acc3) (Float Only) ---\n\n")
        for acc_num, initial_val in acc_initial_states_float.items():
            write_float_acc_block(f, acc_num, initial_val)
        f.flush()
        os.fsync(f.fileno())
    
    # Rewrite the integer accumulator file completely
    acc_file = iss_dir / 'acc.txt'
    with open(acc_file, 'w', encoding='utf-8') as f:
        f.write("--- Accumulator Registers (acc0-acc3) (Integer Only) ---\n\n")
        for acc_num, initial_val in acc_initial_states_int.items():
            write_int_acc_block(f, acc_num, initial_val)
        f.flush()
        os.fsync(f.fileno())



def create_assembly_for_test(test_info):
    """Create assembly.txt with load + matmul instructions"""
    assembler_dir = SCRIPT_DIR.parent / "assembler"
    assembly_file = assembler_dir / "assembly.txt"
    
    # Determine which registers and addresses to use based on data type
    data_type = test_info['data_type']
    
    if data_type == 'float32':
        load_a_base, load_a_stride = 'x1', 'x2'
        load_b_base, load_b_stride = 'x3', 'x2'
        load_instr = 'mlae32'
    elif data_type == 'float16':
        load_a_base, load_a_stride = 'x4', 'x5'
        load_b_base, load_b_stride = 'x6', 'x5'
        load_instr = 'mlae16'
    elif data_type == 'bfloat16':
        load_a_base, load_a_stride = 'x10', 'x5'
        load_b_base, load_b_stride = 'x11', 'x5'
        load_instr = 'mlae16'  # BF16 uses same load as FP16 (16-bit)
    elif data_type == 'fp8_e5m2':
        load_a_base, load_a_stride = 'x12', 'x8'
        load_b_base, load_b_stride = 'x13', 'x8'
        load_instr = 'mlbe8'  # FP8 uses 8-bit load
    elif data_type == 'fp8_e4m3':
        load_a_base, load_a_stride = 'x14', 'x8'
        load_b_base, load_b_stride = 'x15', 'x8'
        load_instr = 'mlbe8'  # FP8 uses 8-bit load
    elif data_type == 'int8':
        load_a_base, load_a_stride = 'x7', 'x8'
        load_b_base, load_b_stride = 'x9', 'x8'
        load_instr = 'mlbe8'
    elif data_type == 'uint8':
        load_a_base, load_a_stride = 'x16', 'x8'
        load_b_base, load_b_stride = 'x17', 'x8'
        load_instr = 'mlbe8'  # UINT8 uses 8-bit load
    else:
        raise ValueError(f"Unsupported data type: {data_type}")
    
    tr_a = f"tr{test_info['tr_a_reg']}"
    tr_b = f"tr{test_info['tr_b_reg']}"
    
    assembly_code = f"""# Test: {test_info['name']}
# {test_info['description']}
# Operation: C = C + A × B^T

# Setup tile dimensions
msettilemi 4
msettileki 4
msettileni 4

# Load Matrix A into {tr_a}
{load_instr} {tr_a}, ({load_a_base}), {load_a_stride}

# Load Matrix B into {tr_b}
{load_instr} {tr_b}, ({load_b_base}), {load_b_stride}

# Perform matrix multiply-accumulate
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


def verify_matmul_result(test_info, random_mode=False, random_matrices=None):
    """Verify matrix multiplication result with hardware-like precision simulation."""
    iss_dir = SCRIPT_DIR
    
    # Read accumulator file
    if test_info['is_float']:
        acc_file = iss_dir / 'acc_float.txt'
    else:
        acc_file = iss_dir / 'acc.txt'
    
    if not acc_file.exists():
        return False, f"{acc_file.name} not found"
    
    with open(acc_file, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    # Parse accumulator result from file
    acc_reg = f"acc{test_info['acc_reg']}"
    result_matrix = []
    in_target = False
    
    for line in lines:
        if f'{acc_reg}:' in line:
            in_target = True
            continue
        if in_target and line.strip().startswith('Row'):
            parts = line.split(':')[1].split('(')[0].strip().split()
            try:
                row_values = [float(x) if test_info['is_float'] else int(x) for x in parts]
                result_matrix.append(row_values)
            except (ValueError, IndexError):
                continue
        if in_target and any(f'acc{i}:' in line for i in range(4) if i != test_info['acc_reg']):
            break
    
    if len(result_matrix) != 4:
        return False, f"Could not parse result matrix (got {len(result_matrix)} rows)"
    
    # --- Reference Calculation with Quantization ---
    matrices = random_matrices if random_mode and random_matrices is not None else generate_simple_test_matrices()
    data_type = test_info['data_type']
    acc_type = test_info.get('acc_type', data_type)
    
    # Get initial C values
    if test_info['name'] == 'mfmacc.s':
        initial_c = [10.0] * 16
    elif test_info['name'] in ['mfmacc.h', 'mfmacc.s.h', 'mfmacc.s.bf16', 'mfmacc.bf16.e5', 'mfmacc.bf16.e4']:
        initial_c = [5.0] * 16
    elif acc_type == 'int32':
        initial_c = [100] * 16
    else:
        initial_c = [0.0] * 16
    
    # Get matrix A and B keys
    a_key, b_key = '', ''
    # Handle mixed-precision types by name
    if test_info['name'] == 'mmaccus.w.b': # uxs
        a_key, b_key = 'u8_a', 'i8_b'
    elif test_info['name'] == 'mmaccsu.w.b': # sxu
        a_key, b_key = 'i8_a', 'u8_b'
    else: # Handle standard types
        type_map_keys = {
            'float32': ('f32_a', 'f32_b'), 'float16': ('f16_a', 'f16_b'),
            'bfloat16': ('bf16_a', 'bf16_b'), 'fp8_e5m2': ('fp8_e5_a', 'fp8_e5_b'),
            'fp8_e4m3': ('fp8_e4_a', 'fp8_e4_b'), 'int8': ('i8_a', 'i8_b'),
            'uint8': ('u8_a', 'u8_b')
        }
        if data_type in type_map_keys:
            a_key, b_key = type_map_keys[data_type]
        else:
            return False, f"Unknown data type for verification: {data_type}"

    matrix_a_list = matrices[a_key]
    matrix_b_list = matrices[b_key]

    np_a = np.array(matrix_a_list, dtype=np.float64).reshape(4, 4)
    np_b = np.array(matrix_b_list, dtype=np.float64).reshape(4, 4)
    np_c_initial = np.array(initial_c, dtype=np.float64).reshape(4, 4)

    if test_info['is_float']:
        # Define quantization functions
        def quantize(val, dtype):
            if dtype == 'float16': return bits_to_float16(float_to_bits16(val))
            if dtype == 'bfloat16': return bfloat16_to_float(float_to_bfloat16(val))
            if dtype == 'fp8_e5m2': return bits_to_float8_e5m2(float_to_bits8_e5m2(val))
            if dtype == 'fp8_e4m3': return bits_to_float8_e4m3(float_to_bits8_e4m3(val))
            return np.float32(val) # Default for float32

        v_quantize = np.vectorize(quantize)

        # 1. Quantize inputs based on their type
        input_b_type = data_type
        if test_info['name'] == 'mmaccsu.w.b': input_b_type = 'uint8'
        elif test_info['name'] == 'mmaccus.w.b': input_b_type = 'int8'
        
        quantized_a = v_quantize(np_a, data_type)
        quantized_b = v_quantize(np_b, input_b_type)

        # 2. Perform matmul
        intermediate_result = np.matmul(quantized_a, quantized_b.T)

        # 3. Quantize initial acc and add intermediate result
        quantized_c_initial = v_quantize(np_c_initial, acc_type)
        expected_matrix_unquantized = quantized_c_initial + intermediate_result

        # 4. Quantize the final sum to accumulator's precision
        expected_matrix = v_quantize(expected_matrix_unquantized, acc_type)
        tolerance = 1e-6 # Use a tight tolerance
    else:
        # For integer math, the original calculation should be exact
        expected_matrix = np_c_initial + np.matmul(np_a, np_b.T)
        tolerance = 0
    
    # Compare results
    errors = []
    for i in range(4):
        for j in range(4):
            expected = expected_matrix[i, j]
            actual = result_matrix[i][j]
            
            if not test_info['is_float']:
                expected = round(expected)

            if abs(expected - actual) > tolerance:
                errors.append(f"[{i}][{j}]: expected {expected:.4f}, got {actual:.4f}")
    
    if not errors:
        return True, "Matrix multiplication correct!"
    else:
        return False, "Errors:\n    " + "\n    ".join(errors[:5])


def display_results(test_info, random_mode=False, random_matrices=None):
    """Display results for current test"""
    print("\n" + "="*80)
    print(f"RESULTS: {test_info['name']}")
    print("="*80)
    
    iss_dir = SCRIPT_DIR
    
    # Determine file paths
    if test_info.get('tr_uses_int_storage', False):
        tr_file = iss_dir / 'matrix.txt'
    elif test_info['is_float']:
        tr_file = iss_dir / 'matrix_float.txt'
    else:
        tr_file = iss_dir / 'matrix.txt'

    if test_info['is_float']:
        acc_file = iss_dir / 'acc_float.txt'
    else:
        acc_file = iss_dir / 'acc.txt'

    # Helper function to read a matrix from a file
    def read_matrix(file_path, reg_num, test_info):
        matrix = []
        if not file_path.exists(): return matrix
        with open(file_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        reg_label = f"tr{reg_num}:"
        in_reg = False
        for line in lines:
            if reg_label in line:
                in_reg = True
                continue
            if in_reg and line.strip().startswith('Row'):
                parts = line.split(':')[1].split('(')[0].strip().split()
                try:
                    # Logic to handle different data types
                    if test_info.get('tr_uses_int_storage', False):
                        int_values = [int(float(p)) for p in parts]
                        if test_info['data_type'] == 'fp8_e5m2':
                            row_values = [bits_to_float8_e5m2(val) for val in int_values]
                        elif test_info['data_type'] == 'fp8_e4m3':
                            row_values = [bits_to_float8_e4m3(val) for val in int_values]
                        else:  # int8, uint8
                            row_values = [float(v) for v in int_values]
                    else: # float32, float16
                        row_values = [float(p) for p in parts]
                    matrix.append(row_values)
                except (ValueError, IndexError):
                    continue
            if in_reg and line.strip() and not line.strip().startswith('Row') and "tr" in line:
                break
        return matrix

    # Read matrices A and B from the appropriate tile register file
    mat_a = read_matrix(tr_file, test_info['tr_a_reg'], test_info)
    mat_b = read_matrix(tr_file, test_info['tr_b_reg'], test_info)

    # 1. Print Tile Register A
    print(f"\n[tr{test_info['tr_a_reg']} (A) used in computation]:")
    if mat_a:
        for r in range(len(mat_a)):
            row_vals = [f"{v:.4f}" for v in mat_a[r]]
            print(f"  Row {r}: {' '.join(row_vals)}")
    else:
        print("  [Could not read matrix from file]")

    # 2. Print Tile Register B
    print(f"\n[tr{test_info['tr_b_reg']} (B) used in computation]:")
    if mat_b:
        for r in range(len(mat_b)):
            row_vals = [f"{v:.4f}" for v in mat_b[r]]
            print(f"  Row {r}: {' '.join(row_vals)}")
    else:
        print("  [Could not read matrix from file]")

    # 3. Print Initial Accumulator State
    print(f"\n[Accumulator acc{test_info['acc_reg']} before operation]:")
    initial_val = test_info['acc_initial']
    for r in range(4):
        row_vals = [f"{initial_val:.4f}" if test_info['is_float'] else str(int(initial_val))] * 4
        print(f"  Row {r}: {' '.join(row_vals)}")

    # 4. Compute and Print Intermediate Result (A x B^T)
    print("\n[Intermediate: A × B^T] (before accumulation):")
    intermediate = None
    if mat_a and mat_b:
        try:
            import numpy as np
            arr_a = np.array(mat_a)
            arr_b = np.array(mat_b)
            intermediate = np.matmul(arr_a, arr_b.T)

            # Quantize intermediate result to the accumulator's precision for display
            acc_type = test_info['acc_type']
            quantized_intermediate = np.copy(intermediate)

            if not test_info['is_float']:
                quantized_intermediate = quantized_intermediate.round().astype(int)
            elif acc_type == 'float16':
                vectorized_quantize = np.vectorize(lambda x: bits_to_float16(float_to_bits16(x)))
                quantized_intermediate = vectorized_quantize(intermediate)
            elif acc_type == 'bfloat16':
                vectorized_quantize = np.vectorize(lambda x: bfloat16_to_float(float_to_bfloat16(x)))
                quantized_intermediate = vectorized_quantize(intermediate)
            elif acc_type == 'float32':
                quantized_intermediate = intermediate.astype(np.float32)

            for r in range(quantized_intermediate.shape[0]):
                if test_info['is_float']:
                    row_vals = [f"{v:.4f}" for v in quantized_intermediate[r]]
                else:
                    row_vals = [str(v) for v in quantized_intermediate[r]]
                print(f"  Row {r}: {' '.join(row_vals)}")

        except Exception as e:
            print(f"  [Error] Could not compute intermediate result: {e}")
    else:
        print("  [Skipped] Missing matrix A or B.")

    # 5. Print Final Accumulator State
    print(f"\n[Accumulator: acc{test_info['acc_reg']}] From {acc_file.name}:")
    if acc_file.exists():
        with open(acc_file, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        acc_reg_label = f"acc{test_info['acc_reg']}"
        in_target_block = False
        for line in lines:
            if f'{acc_reg_label}:' in line:
                in_target_block = True
                print(f"  {line.strip()}") # Print "accX:"
            elif in_target_block and (line.strip().startswith('(') or line.strip().startswith('Row')):
                 print(f"    {line.strip()}")
            elif in_target_block and (line.strip() == "" or "acc" in line):
                break
    else:
        print(f"  [File not found: {acc_file}]")
    
    # Verification
    print("\n" + "-"*80)
    print("[VERIFICATION]")
    success, message = verify_matmul_result(test_info, random_mode, random_matrices)
    
    if success:
        print(f"  [OK] PASS - {message}")
    else:
        print(f"  [X] FAIL - {message}")
    
    print("-"*80)
    
    return success


def run_single_test(test_info, test_num, total_tests, random_mode=False, random_matrices=None):
    """Run a single test case"""
    print("\n" + "="*80)
    print(f"TEST {test_num}/{total_tests}: {test_info['name']}")
    print(f"Description: {test_info['description']}")
    print("="*80)
    
    # Print instruction details
    print("\n" + "-"*80)
    print("[INSTRUCTION INFO]")
    print(f"  Instruction: {test_info['name']}")
    print(f"  Format    : {test_info['name'].split('.')[0]}.* md, ms1, ms2")
    print(f"  Assembly  : {test_info['instr']}")
    print(f"  Operation : {test_info.get('explanation', 'N/A')}")
    print(f"  Input Type: {test_info['data_type'].upper()}")
    print(f"  Acc Type  : {test_info['acc_type'].upper()}")
    print("-"*80)
    
    # Step 0: Update memory with appropriate data for this test
    print("\n[Step 0] Updating memory for this test...")
    update_memory_for_test(test_info, random_mode, random_matrices)
    print("  [OK] Memory updated")
    
    # Step 0.5: Reset accumulator to initial value
    print("\n[Step 0.5] Resetting accumulator...")
    reset_accumulator(test_info)
    print(f"  [OK] acc{test_info['acc_reg']} reset to {test_info['acc_initial']}")
    
    # Step 1: Create assembly
    print("\n[Step 1] Creating assembly.txt...")
    assembly_file = create_assembly_for_test(test_info)
    print(f"  [OK] Created: {assembly_file}")
    print(f"       - Load A, Load B, {test_info['instr']}")
    
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
    
    # Step 4: Display results and verify
    passed = display_results(test_info, random_mode, random_matrices)
    
    return passed


def main():
    """Main test function"""
    import sys
    auto_run = '--auto' in sys.argv or '-a' in sys.argv
    random_mode = '--random' in sys.argv

    print("\n" + "="*80)
    print("MATRIX MULTIPLY-ACCUMULATE TEST")
    if random_mode:
        print("Running in RANDOMIZED mode.")
    print("="*80)
    print("\nThis script tests matrix multiplication: C = C + A × B^T")
    print("\nTest cases:")
    for i, test in enumerate(TEST_CASES, 1):
        print(f"  {i}. {test['name']:<10} - {test['description']}")
    if not auto_run:
        print("\nPress Enter after each test to continue to the next one.")
    else:
        print("\n[AUTO MODE] Running all tests automatically...")
    print("="*80)
    
    try:
        random_matrices = None
        if random_mode:
            print("\nGenerating random matrices for testing...")
            random_matrices = generate_random_test_matrices()
            print("  [OK] Random matrices generated.")

        # Initial setup (once)
        setup_test_data(random_mode, random_matrices)
        
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
            success = run_single_test(test_info, i, total_tests, random_mode, random_matrices)
            
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
