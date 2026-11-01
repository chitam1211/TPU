"""Generate CPU programs and independent architectural expectations for F10.

The model executes instructions in program order without any pipeline timing.
Arithmetic uses the exact integer oracle, not the RTL's alignment algorithm.
Expected retirement and memory traces detect missing/duplicated side effects.
"""
import argparse
import json
import random
from collections import Counter
from pathlib import Path
from gen_fp32_addsub_vectors import reference
from gen_fp32_compare_vectors import reference as compare_reference
from gen_fp32_minmax_vectors import reference as minmax_reference
from gen_fp32_mul_vectors import reference as mul_reference
from gen_fp32_convert_vectors import reference as convert_reference
from gen_fp32_divsqrt_vectors import reference as divsqrt_reference
from gen_fp32_fma_vectors import reference as fma_reference

MASK = 0xffffffff
EDGES = [0xff800000, 0xbf800000, 0x80000001, 0x80000000, 0,
         1, 0x3f800000, 0x7f800000, 0x7f800001, 0x7fc00000,
         0x007fffff, 0x00800000, 0x807fffff, 0x80800000,
         0x7f7fffff, 0xff7fffff, 0xffbfffff, 0xffc00001,
         0x7fbfffff, 0x7fffffff]


def imm(op, rd, rs, value, f3=0):
    return ((value & 4095) << 20) | (rs << 15) | (f3 << 12) | (rd << 7) | op


def store(op, rs, value, base=0):
    return ((value & 0xfe0) << 20) | (rs << 20) | (base << 15) | (2 << 12) | ((value & 31) << 7) | op


def fp(f7, rd, rs1, rs2=0, f3=0):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x53


def r4(op, rd, rs1, rs2, rs3, f3=0, fmt=0):
    return (rs3 << 27) | (fmt << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


FMADD, FMSUB, FNMSUB, FNMADD = 0x43, 0x47, 0x4b, 0x4f


def csr(addr, op, rd, source):
    return (addr << 20) | (source << 15) | (op << 12) | (rd << 7) | 0x73


def branch(rs1, rs2, offset):
    return (((offset >> 12) & 1) << 31) | (((offset >> 5) & 63) << 25) | (rs2 << 20) | (rs1 << 15) | (((offset >> 1) & 15) << 8) | (((offset >> 11) & 1) << 7) | 0x63


def sext(value, width):
    return value - (1 << width) if value & (1 << (width - 1)) else value


def classify(value):
    # Ordered magnitude ranges, independently of the RTL's exponent case tree.
    magnitude, negative = value & 0x7fffffff, value >> 31
    if magnitude > 0x7f800000:
        return 512 if magnitude >= 0x7fc00000 else 256
    if magnitude == 0x7f800000:
        return 1 if negative else 128
    if magnitude == 0:
        return 8 if negative else 16
    if magnitude < 0x00800000:
        return 4 if negative else 32
    return 2 if negative else 64


class Program:
    def __init__(self, name):
        self.name, self.code, self.data = name, [], [0] * 256

    def emit(self, *instructions):
        self.code.extend(instructions)

    def fl(self, rd, bits, slot=None):
        slot = rd if slot is None else slot
        self.data[slot] = bits
        self.emit(imm(7, rd, 0, slot * 4, 2))

    def lw(self, rd, bits, slot=None):
        slot = 32 + rd if slot is None else slot
        self.data[slot] = bits
        self.emit(imm(3, rd, 0, slot * 4, 2))

    def finish(self):
        # Final store is observable even when no FP writes occur in the test.
        self.emit(imm(0x13, 31, 0, 0x123), store(0x23, 31, 1020))


def execute(p):
    x, f, mem, fcsr = [0]*32, [0]*32, p.data.copy(), 0
    pc, trace, memory, coverage = 0, [], [], Counter()
    while pc < 4 * len(p.code):
        assert len(trace) < 512, 'Program did not terminate'
        ins = p.code[pc // 4]
        op, rd, f3 = ins & 127, (ins >> 7) & 31, (ins >> 12) & 7
        r1, r2, f7 = (ins >> 15) & 31, (ins >> 20) & 31, ins >> 25
        result, wx, wf, next_pc = 0, 0, 0, pc + 4
        if op == 0x13 and f3 == 0:
            result, wx = (x[r1] + sext(ins >> 20, 12)) & MASK, 1
        elif op == 0x37:
            result, wx = ins & 0xfffff000, 1
        elif op in (3, 7):
            address = (x[r1] + sext(ins >> 20, 12)) & MASK
            assert address % 4 == 0 and address < 1024
            result = mem[address // 4]
            wx, wf = int(op == 3), int(op == 7)
            memory.append((0, address, 0))
            if wf: coverage['FLW'] += 1
        elif op in (0x23, 0x27):
            offset = ((ins >> 25) << 5) | rd
            address = (x[r1] + sext(offset, 12)) & MASK
            assert address % 4 == 0 and address < 1024
            data = f[r2] if op == 0x27 else x[r2]
            mem[address // 4] = data
            memory.append((1, address, data))
            if op == 0x27: coverage['FSW'] += 1
        elif op == 0x53:
            if f7 in (0, 4):
                mode = (fcsr >> 5) if f3 == 7 else f3
                result, flags, illegal = reference(f[r1], f[r2], int(f7 == 4), mode)
                wf = int(not illegal)
                fcsr |= flags
                coverage['FADD.S' if f7 == 0 else 'FSUB.S'] += 1
            elif f7 == 8:
                mode = (fcsr >> 5) if f3 == 7 else f3
                result, flags, illegal = mul_reference(f[r1], f[r2], mode)
                wf = int(not illegal)
                fcsr |= flags
                coverage['FMUL.S'] += 1
            elif f7 == 12 or (f7 == 44 and r2 == 0):
                mode = (fcsr >> 5) if f3 == 7 else f3
                result, flags, illegal = divsqrt_reference(f[r1], f[r2], int(f7 == 44), mode)
                wf = int(not illegal)
                fcsr |= flags
                coverage['FDIV.S' if f7 == 12 else 'FSQRT.S'] += 1
            elif f7 in (96, 104) and r2 in (0, 1):
                mode = (fcsr >> 5) if f3 == 7 else f3
                to_float = int(f7 == 104)
                source = x[r1] if to_float else f[r1]
                result, flags, illegal = convert_reference(source, to_float, r2, mode)
                wf, wx = (int(not illegal), 0) if to_float else (0, int(not illegal))
                fcsr |= flags
                coverage[('FCVT.S.' if to_float else 'FCVT.') +
                         ('WU' if r2 and to_float else 'W' if to_float else
                          'WU.S' if r2 else 'W.S')] += 1
            elif f7 == 16 and f3 in (0, 1, 2):
                sign = [f[r2] >> 31, 1 - (f[r2] >> 31), (f[r1] ^ f[r2]) >> 31][f3]
                result, wf = (f[r1] & 0x7fffffff) | (sign << 31), 1
                coverage[['FSGNJ.S', 'FSGNJN.S', 'FSGNJX.S'][f3]] += 1
            elif f7 == 80 and f3 in (0, 1, 2):
                result, flags = compare_reference(f[r1], f[r2], f3)
                wx = 1
                fcsr |= flags
                coverage[['FLE.S', 'FLT.S', 'FEQ.S'][f3]] += 1
            elif f7 == 20 and f3 in (0, 1):
                result, flags = minmax_reference(f[r1], f[r2], bool(f3))
                wf = 1
                fcsr |= flags
                coverage[['FMIN.S', 'FMAX.S'][f3]] += 1
            elif f7 == 112 and r2 == 0 and f3 in (0, 1):
                result, wx = (f[r1] if f3 == 0 else classify(f[r1])), 1
                coverage['FMV.X.W' if f3 == 0 else 'FCLASS.S'] += 1
            elif f7 == 120 and r2 == 0 and f3 == 0:
                result, wf = x[r1], 1
                coverage['FMV.W.X'] += 1
            # Unsupported OP-FP encodings: current checkpoint suppresses effects.
        elif op in (FMADD, FMSUB, FNMSUB, FNMADD):
            # Only fmt=S is RV32F; other formats have no architectural effect here.
            if (ins >> 25) & 3 == 0:
                mode = (fcsr >> 5) if f3 == 7 else f3
                result, flags, illegal = fma_reference(f[r1], f[r2], f[ins >> 27],
                                                       (op >> 3) & 1, (op >> 2) & 1, mode)
                wf = int(not illegal)
                fcsr |= flags
                coverage[{FMADD: 'FMADD.S', FMSUB: 'FMSUB.S', FNMSUB: 'FNMSUB.S', FNMADD: 'FNMADD.S'}[op]] += 1
        elif op == 0x73:
            address, operation = ins >> 20, f3 & 3
            assert address in (1, 2, 3) and operation
            old = [0, fcsr & 31, fcsr >> 5, fcsr][address]
            operand = r1 if f3 & 4 else x[r1]
            result, wx = old, 1
            if operation == 1 or r1 != 0:
                new = operand if operation == 1 else (old | operand if operation == 2 else old & ~operand)
                if address == 1: fcsr = (fcsr & 0xe0) | (new & 31)
                elif address == 2: fcsr = (fcsr & 31) | ((new & 7) << 5)
                else: fcsr = new & 255
            coverage[['', 'CSRRW', 'CSRRS', 'CSRRC', '', 'CSRRWI', 'CSRRSI', 'CSRRCI'][f3]] += 1
        elif op == 0x63:
            offset = ((ins >> 31) << 12) | (((ins >> 7) & 1) << 11) | (((ins >> 25) & 63) << 5) | (((ins >> 8) & 15) << 1)
            if x[r1] == x[r2]: next_pc = pc + sext(offset, 13)
        else:
            raise AssertionError(hex(ins))
        if wx and rd: x[rd] = result
        if wf: f[rd] = result
        trace.append((pc, ins, wx, wf, rd, result, fcsr))
        pc = next_pc
    return trace, memory, mem, coverage


def programs():
    # Checkpoint A: arithmetic + CSR works on CPU before relying on misc ops.
    p = Program('a_addsub_csr')
    for rd, value in enumerate([0x3fc00000,0x40100000,0x3f800000,0x33800000,
                                0x7f7fffff,0x7f800000,0xff800000,0x7f800001], 1):
        p.fl(rd, value)
    p.emit(fp(0,0,1,2), fp(4,9,0,1), store(0x27,0,512), store(0x27,9,516))
    for mode in range(5):
        p.emit(csr(2,5,10,mode), fp(0,10,3,4,7), store(0x27,10,520+mode*8),
               fp(0,11,3,4,mode), store(0x27,11,524+mode*8), csr(1,2,11,0))
    p.emit(csr(1,5,0,0), fp(0,12,3,4), csr(1,2,12,0),
           fp(0,13,5,5), csr(1,2,13,0), fp(0,14,6,7), csr(1,2,14,0),
           fp(4,15,8,3), csr(1,2,15,0))
    p.finish(); yield p

    p = Program('b_move_hazards')
    p.emit(csr(1,5,0,31))
    for i, bits in enumerate(EDGES):
        rd = i % 30 + 1
        p.lw(rd,bits,64+i)
        p.emit(fp(120,rd,rd), fp(112,rd,rd), store(0x23,rd,512+i*4))
    p.emit(fp(120,0,1), fp(112,0,0), fp(120,31,0), fp(112,2,31),
           csr(1,2,3,0), store(0x27,0,700), store(0x23,0,704))
    p.finish(); yield p

    p = Program('c_sign_hazards')
    p.emit(csr(1,5,0,21))
    for i,bits in enumerate(EDGES): p.fl(i,bits,64+i)
    for i in range(20):
        for mode in range(3):
            p.emit(fp(16,25,i,(i+1)%20,mode), fp(112,25,25), store(0x23,25,512+((i*3+mode)%100)*4))
    p.emit(fp(16,0,0,0,1), fp(16,31,0,0,2), csr(1,2,26,0))
    p.finish(); yield p

    p = Program('d_classify')
    p.emit(csr(1,5,0,31))
    for i,bits in enumerate(EDGES):
        p.fl(0,bits,64+i)
        p.emit(fp(112,1,0,0,1), store(0x23,1,512+i*4))
    p.emit(fp(112,0,0,0,1), csr(1,2,2,0))
    p.finish(); yield p

    p = Program('demo_f10')
    p.fl(1,0x3fc00000,0); p.fl(2,0x40100000,1)
    p.emit(fp(0,3,1,2),fp(4,4,3,1),fp(112,5,3),fp(120,5,5),
           fp(16,6,5,5,1),fp(16,7,1,6,0),fp(16,8,7,6,2),fp(112,6,8,0,1),
           store(0x27,8,512),store(0x23,6,516),store(0x27,4,520),store(0x27,3,524))
    p.finish(); yield p

    p = Program('csr_all_forms')
    p.lw(1,0xffffffff); p.lw(2,0); p.lw(3,0x55)
    for address in (1,2,3):
        for operation in (1,2,3,5,6,7):
            for source in (0,1,2,3):
                p.emit(csr(address,operation,4,source),csr(3,2,5,0))
            p.emit(csr(address,operation,0,3))
    p.finish(); yield p

    p = Program('rounding_specials')
    for i,bits in enumerate([0x80000000,0,0x00800000,0x007fffff,0x3f800001,
                             0x3f800000,0x33800000,0xbf800000,0xb3800000,0x7fc12345],1):
        p.fl(i,bits)
    for mode in range(5):
        p.emit(csr(2,5,0,mode))
        for left,right,sub in ((1,2,0),(5,6,1),(3,4,1),(7,6,0),(8,9,0),(10,6,1)):
            p.emit(fp(4 if sub else 0,0,left,right,7),store(0x27,0,512),csr(1,2,1,0))
    # Reserved rm is a documented no-write policy, not an illegal-trap claim.
    for mode in (5,6,7):
        p.emit(csr(2,5,0,mode),fp(0,0,6,7,7),store(0x27,0,516))
    p.emit(fp(0,0,6,7,5),fp(4,0,6,7,6),store(0x27,0,520))
    p.finish(); yield p

    p = Program('flush_unsupported')
    p.fl(1,0x3f800000); p.fl(2,0x7f800001)
    # Each taken branch cancels the sequential instruction and all its effects.
    for skipped in [fp(0,0,2,1),fp(120,0,0),fp(112,3,2),csr(3,5,0,31),store(0x27,2,600)]:
        p.emit(branch(0,0,8),skipped)
    # Bad fixed fields and adjacent encodings must not alias supported ops.
    # funct7 0x18 is unassigned; 0x2c with rs2!=0 is a malformed FSQRT.S.
    p.emit(fp(112,3,2,1,0),fp(112,3,2,1,1),fp(120,3,2,1,0),
           fp(120,3,2,0,1),fp(16,3,2,1,3),fp(24,3,2,1),fp(44,3,2,1),fp(1,3,2,1),
           csr(1,2,4,0),store(0x27,0,512),store(0x23,3,516))
    p.finish(); yield p

    rng=random.Random(0x23521419)
    for batch in range(12):
        p=Program(f'random_{batch:02d}')
        for i in range(32):
            p.fl(i,rng.choice(EDGES) if i<20 else rng.getrandbits(32),i)
            p.lw(i,rng.getrandbits(32),32+i)
        for _ in range(100):
            d,a,b=(rng.randrange(32) for _ in range(3))
            kind=rng.randrange(10)
            if kind<2: p.emit(fp(4*kind,d,a,b,rng.randrange(5)))
            elif kind<5: p.emit(fp(16,d,a,b,kind-2))
            elif kind==5: p.emit(fp(112,d,a))
            elif kind==6: p.emit(fp(120,d,a))
            elif kind==7: p.emit(fp(112,d,a,0,1))
            elif kind==8: p.emit(store(0x27,a,512+4*rng.randrange(100)))
            else: p.emit(csr(rng.randrange(1,4),rng.choice([1,2,3,5,6,7]),d,a))
        p.finish(); yield p


def multiplication_programs():
    p = Program('fmul_rounding_flags')
    values = [0x3fc00000, 0x40000000, 0x7f7fffff, 0x00800000,
              0x007fffff, 0x00000001, 0x3f000000, 0x7f800000,
              0x00000000, 0x7fa00001, 0x7fc12345, 0xbf800001,
              0x3f7fffff, 0x00800001, 0x3f7ffffe]
    for i, bits in enumerate(values, 1): p.fl(i, bits, i)
    for mode in range(5):
        p.emit(csr(2, 5, 0, mode))
        # (4,13) and (14,15) sit on the after-rounding tininess boundary.
        for a, b in ((1,2),(3,2),(4,7),(5,7),(6,7),(8,9),(10,1),(11,1),(12,1),(4,13),(14,15)):
            p.emit(fp(8,0,a,b,7), store(0x27,0,512+4*mode), csr(1,2,13,0))
    p.emit(csr(2,5,0,0), fp(8,14,1,2,0), fp(8,15,14,7,0),
           fp(112,16,15), store(0x23,16,900))
    p.finish(); yield p

    p = Program('fmul_illegal_rm')
    p.fl(1,0x3fc00000,1); p.fl(2,0x40000000,2)
    p.emit(csr(2,5,0,5), fp(8,3,1,2,7), csr(2,5,0,6), fp(8,3,1,2,7),
           csr(2,5,0,7), fp(8,3,1,2,7), fp(8,3,1,2,5), fp(8,3,1,2,6),
           store(0x27,3,512), csr(1,2,4,0))
    p.finish(); yield p


def conversion_programs():
    float_inputs = [0x3fc00000, 0xbfc00000, 0x7f800000, 0x7fc00000,
                    0x4f000000, 0x00000001, 0xbf000000, 0xff800000]
    int_inputs = [0, 1, 0x00ffffff, 0x01000001,
                  0x7fffffff, 0x80000000, 0xffffffff, 0x12345678]
    for to_float in (0, 1):
        for unsigned in (0, 1):
            name = ('fcvt_s_wu' if unsigned else 'fcvt_s_w') if to_float else \
                   ('fcvt_wu_s' if unsigned else 'fcvt_w_s')
            p = Program(name)
            for index, bits in enumerate(int_inputs if to_float else float_inputs, 1):
                if to_float: p.lw(index, bits, 32+index)
                else: p.fl(index, bits, index)
            for mode in range(5):
                p.emit(csr(2,5,0,mode))
                for index in range(1,9):
                    p.emit(csr(1,5,0,0), fp(104 if to_float else 96,9,index,unsigned,7),
                           store(0x27 if to_float else 0x23,9,512+4*index),
                           csr(1,2,10,0))
            p.finish(); yield p

    p = Program('fcvt_illegal_rm')
    p.fl(1,0x3fc00000,1); p.lw(1,0x01000001,33)
    for mode in (5,6,7):
        p.emit(csr(2,5,0,mode))
        for f7 in (96,104):
            for unsigned in (0,1):
                p.emit(fp(f7,2,1,unsigned,7))
    p.emit(fp(96,2,1,0,5),fp(104,2,1,1,6),
           store(0x23,2,512),store(0x27,2,516),csr(1,2,3,0))
    p.finish(); yield p

    # Consecutive conversions and arithmetic exercise both register-bank hazards.
    p = Program('fcvt_mixed_hazards')
    p.lw(1,0x01000001,33)
    p.emit(fp(104,2,1,0,0), fp(0,3,2,2,0), fp(96,4,3,0,0),
           fp(104,5,4,1,0), fp(8,6,5,2,0), fp(96,7,6,1,0),
           store(0x27,6,512), store(0x23,7,516), csr(1,2,8,0))
    p.finish(); yield p

def divsqrt_programs():
    p = Program('fdiv_rounding_flags')
    values = [0x3f800000, 0x40400000, 0x7f7fffff, 0x3f000000,
              0x00800000, 0x00000001, 0x40000000, 0x00000000,
              0x7f800000, 0x7fa00001, 0x3f7fffff, 0x7e800000, 0xbfc00000]
    for i, bits in enumerate(values, 1): p.fl(i, bits, i)
    pairs = ((1,2),(13,2),(3,4),(5,7),(6,7),(11,12),(1,8),(8,8),(9,9),(10,1),(8,1))
    for mode in range(5):
        p.emit(csr(2, 5, 0, mode))
        for a, b in pairs:
            p.emit(fp(12,0,a,b,7), store(0x27,0,512+4*mode), csr(1,2,14,0))
    p.emit(csr(2,5,0,0), fp(12,15,1,2,0), fp(12,16,15,2,0), fp(112,17,16), store(0x23,17,900))
    p.finish(); yield p

    p = Program('fsqrt_rounding_flags')
    values = [0x40800000, 0x40000000, 0x3f800000, 0x00000001, 0x007fffff,
              0x7f7fffff, 0x80000000, 0x00000000, 0xbf800000, 0x7f800000,
              0xff800000, 0x7fa00001, 0x7fc00000, 0x3f800001]
    for i, bits in enumerate(values, 1): p.fl(i, bits, i)
    for mode in range(5):
        p.emit(csr(2, 5, 0, mode))
        for a in range(1, 15):
            p.emit(fp(44,0,a,0,7), store(0x27,0,512+4*mode), csr(1,2,15,0))
    p.finish(); yield p

    p = Program('fdivsqrt_illegal_rm')
    p.fl(1,0x40400000,1); p.fl(2,0x40000000,2); p.fl(3,0x3f800000,3)
    for mode in (5,6,7):
        p.emit(csr(2,5,0,mode), fp(12,3,1,2,7), fp(44,3,1,0,7))
    p.emit(fp(12,3,1,2,5), fp(44,3,1,0,6), fp(12,3,1,2,7),
           store(0x27,3,512), csr(1,2,4,0))
    p.finish(); yield p

    # Long-latency producers feeding FP, integer, store and CSR consumers.
    p = Program('fdivsqrt_hazards')
    p.fl(1,0x40400000,1); p.fl(2,0x40000000,2); p.lw(5,0x41100000,37)
    p.emit(csr(1,5,0,0), csr(2,5,0,0),
           fp(12,3,1,2,7), fp(44,4,3,0,7), fp(0,5,4,3,7), fp(12,6,5,4,7),
           fp(112,7,6), store(0x27,6,512), csr(1,2,8,0),
           fp(120,9,5), fp(44,10,9,0,7), fp(8,11,10,10,7), fp(12,0,11,10,7),
           fp(44,0,0,0,7), fp(80,12,0,10,2), store(0x23,12,516),
           fp(12,13,1,2,1), csr(2,5,0,3), fp(12,14,1,2,7), fp(12,15,13,14,7),
           fp(44,16,15,31,7), store(0x27,16,520), csr(3,2,17,0), store(0x23,17,524))
    # A taken branch must cancel a long-latency op before it starts.
    p.emit(branch(0,0,8), fp(12,1,1,8,0), store(0x27,1,528))
    p.finish(); yield p

    rng = random.Random(0x23521422)
    for batch in range(4):
        p = Program(f'divsqrt_random_{batch:02d}')
        for i in range(32):
            p.fl(i, rng.choice(EDGES) if i < 12 else rng.getrandbits(32), i)
        for _ in range(110):
            d, a, b = (rng.randrange(32) for _ in range(3))
            kind = rng.randrange(8)
            mode = rng.choice([0,1,2,3,4,7])
            if kind < 3: p.emit(fp(12,d,a,b,mode))
            elif kind < 5: p.emit(fp(44,d,a,0,mode))
            elif kind == 5: p.emit(fp(rng.choice([0,4,8]),d,a,b,mode))
            elif kind == 6: p.emit(store(0x27,a,512+4*rng.randrange(100)))
            else: p.emit(csr(rng.randrange(1,4),rng.choice([1,2,3,5,6,7]),d,a))
        p.emit(csr(3,2,1,0), store(0x23,1,1016))
        p.finish(); yield p


def fma_programs():
    values = [0x40000000, 0x40400000, 0x3f800000, 0x40c00000, 0x3eaaaaab,
              0x7f7fffff, 0x00800000, 0x3f7fffff, 0x7f800000, 0x00000000,
              0x7fc00000, 0x7fa00001, 0xbf800000, 0x00000001]
    # 2*3+-1, exact cancellation 2*3-6, single rounding of 1/3*3-1, then specials.
    groups = (('fmadd_fmsub_rounding_flags', (FMADD, FMSUB),
               ((1,2,3),(1,2,4),(5,2,3),(6,1,10),(7,8,10),(9,10,11))),
              ('fnmsub_fnmadd_rounding_flags', (FNMSUB, FNMADD),
               ((1,2,3),(1,2,4),(5,2,3),(9,3,9),(3,3,12),(14,5,13))))
    for name, ops, triples in groups:
        p = Program(name)
        for i, bits in enumerate(values, 1): p.fl(i, bits, i)
        for mode in range(5):
            p.emit(csr(2, 5, 0, mode))
            for op in ops:
                for a, b, c in triples:
                    p.emit(r4(op,0,a,b,c,7), store(0x27,0,512+4*mode), csr(1,2,15,0))
        p.finish(); yield p

    p = Program('fma_illegal_rm')
    p.fl(1,0x40000000,1); p.fl(2,0x40400000,2); p.fl(3,0x3f800000,3)
    for mode in (5,6,7):
        p.emit(csr(2,5,0,mode))
        for op in (FMADD, FMSUB, FNMSUB, FNMADD):
            p.emit(r4(op,4,1,2,3,7))
    p.emit(r4(FMADD,4,1,2,3,5), r4(FNMADD,4,1,2,3,6),
           store(0x27,4,512), csr(1,2,5,0))
    p.finish(); yield p

    # rs3 must wait for every kind of FP producer, including a load right before it.
    p = Program('fma_rs3_hazards')
    p.fl(1,0x40000000,1); p.fl(2,0x40400000,2); p.lw(5,0x3f800000,37)
    p.emit(csr(1,5,0,0), csr(2,5,0,0),
           fp(12,3,1,2,7), r4(FMADD,4,1,2,3,7))
    p.fl(6,0x3fc00000,6)
    p.emit(r4(FMADD,7,1,1,6,7),
           fp(120,8,5), r4(FNMADD,9,2,2,8,7),
           r4(FMADD,10,9,1,9,7), r4(FMSUB,11,1,2,10,7),
           r4(FMADD,0,1,2,0,7), r4(FNMSUB,12,0,0,0,7),
           fp(0,13,1,2,7), r4(FMADD,14,1,1,13,7),
           fp(44,16,14,0,7), r4(FMSUB,17,16,16,14,7),
           # fmt=D is not RV32F: no write, no flags.
           r4(FMADD,15,1,2,3,0,1),
           fp(112,18,14), store(0x23,18,512), store(0x27,11,516), store(0x27,12,520),
           store(0x27,15,524), store(0x27,17,528), csr(3,2,19,0), store(0x23,19,532))
    p.emit(branch(0,0,8), r4(FMADD,1,1,1,1,0), store(0x27,1,536))
    p.finish(); yield p

    rng = random.Random(0x23521426)
    for batch in range(4):
        p = Program(f'fma_random_{batch:02d}')
        for i in range(32):
            p.fl(i, rng.choice(EDGES) if i < 12 else rng.getrandbits(32), i)
        for _ in range(110):
            d, a, b, c = (rng.randrange(32) for _ in range(4))
            kind = rng.randrange(8)
            mode = rng.choice([0,1,2,3,4,7])
            if kind < 4: p.emit(r4(rng.choice((FMADD,FMSUB,FNMSUB,FNMADD)),d,a,b,c,mode))
            elif kind == 4: p.emit(fp(rng.choice([0,4,8]),d,a,b,mode))
            elif kind == 5: p.emit(fp(16,d,a,b,rng.randrange(3)))
            elif kind == 6: p.emit(store(0x27,a,512+4*rng.randrange(100)))
            else: p.emit(csr(rng.randrange(1,4),rng.choice([1,2,3,5,6,7]),d,a))
        p.emit(csr(3,2,1,0), store(0x23,1,1016))
        p.finish(); yield p


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--include-compare', action='store_true', help='include F13 comparison programs')
    parser.add_argument('--include-minmax', action='store_true', help='include F15 min/max and F13 programs')
    parser.add_argument('--include-mul', action='store_true', help='include F16 multiplication and earlier programs')
    parser.add_argument('--include-convert', action='store_true', help='include F20 conversions and earlier programs')
    parser.add_argument('--include-divsqrt', action='store_true', help='include F22 divide/sqrt and earlier programs')
    parser.add_argument('--include-fma', action='store_true', help='include F26 fused multiply-add and earlier programs')
    args=parser.parse_args(); args.output.mkdir(parents=True,exist_ok=True)
    manifests=[]; total=Counter()
    args.include_divsqrt |= args.include_fma
    args.include_convert |= args.include_divsqrt
    args.include_mul |= args.include_convert
    args.include_minmax |= args.include_mul
    args.include_compare |= args.include_minmax
    selected = list(programs())
    if args.include_compare:
        from gen_f13_programs import comparison_programs
        selected.extend(comparison_programs())
    if args.include_minmax:
        from gen_f15_programs import minmax_programs
        selected.extend(minmax_programs())
    if args.include_mul:
        selected.extend(multiplication_programs())
    if args.include_convert:
        selected.extend(conversion_programs())
    if args.include_divsqrt:
        selected.extend(divsqrt_programs())
    if args.include_fma:
        selected.extend(fma_programs())
    for p in selected:
        assert len(p.code)<256,(p.name,len(p.code))
        trace,mem,final,coverage=execute(p)
        # Fixed expected values anchor the demo independently of the model.
        if p.name=='demo_f10': assert final[128:132]==[0x3fc00000,0x40,0x40100000,0x40700000]
        image=p.code+[0x0000006f]+[0x13]*(255-len(p.code))
        with (args.output/(p.name+'.txt')).open('w',encoding='ascii',newline='\n') as out:
            out.write(f'{len(trace)} {len(mem)}\n')
            for value in image+p.data: out.write(f'{value:08x}\n')
            for row in trace+mem: out.write(' '.join(f'{v:08x}' for v in row)+'\n')
            for value in final: out.write(f'{value:08x}\n')
        if p.name=='demo_f10':
            (args.output/'demo_f10.hex').write_text(''.join(f'{v:08x}\n' for v in image),encoding='ascii')
            (args.output/'demo_f10_data.hex').write_text(''.join(f'{v:08x}\n' for v in p.data),encoding='ascii')
        manifests.append({'name':p.name,'retired':len(trace),'memory_requests':len(mem),'coverage':dict(coverage)})
        total.update(coverage)
    (args.output/'manifest.json').write_text(json.dumps({'cases':manifests,'coverage':dict(total)},indent=2)+'\n',encoding='utf-8')
    checkpoint = 'F26' if args.include_fma else 'F22' if args.include_divsqrt else 'F20' if args.include_convert else ('F16' if args.include_mul else ('F15' if args.include_minmax else ('F13' if args.include_compare else 'F10')))
    print(f'{checkpoint}_PROGRAMS_GENERATED cases={len(manifests)} retirement_checks={sum(p["retired"] for p in manifests)}')


if __name__=='__main__': main()
