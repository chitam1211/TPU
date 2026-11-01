/* Matrix extension (RISC-V Matrix Specification Proposal v0.6.0) for GCC: each instruction
 * is an inline-assembly macro built with the assembler's .insn directive, so a stock
 * riscv64-unknown-elf toolchain is enough; no compiler change.
 *
 * All matrix instructions use major opcode custom-1 (0x2B) and func3 = 000. They are written
 * in the R-type layout of .insn:  func7 = inst[31:25], rs2 = inst[24:20], rs1 = inst[19:15],
 * rd = inst[11:7]. Fields that are not x registers (md, ms1, ms2, sizes) are constants and are
 * passed as "x<number>" so that .insn places the bits; x registers (base, stride, tile size)
 * are left to the compiler with "r" constraints.
 *
 * Matrix registers: TR0-TR3 (tile, A/B) = 0-3, ACC0-ACC3 (accumulator, C) = 4-7.
 * The compiler does not see matrix state: every macro is volatile with a "memory" clobber,
 * so it keeps program order with the surrounding loads and stores.
 */
#ifndef MATRIX_H
#define MATRIX_H

#define TR0  0
#define TR1  1
#define TR2  2
#define TR3  3
#define ACC0 4
#define ACC1 5
#define ACC2 6
#define ACC3 7

/* Element size field (d_size / s_size). */
#define MX_E8  0
#define MX_E32 2

/* Instruction with constant fields only. */
#define MX_INSN(f7, rd, rs1, rs2) \
    __asm__ volatile(".insn r CUSTOM_1, 0, %0, x%1, x%2, x%3" \
                     :: "i"(f7), "i"(rd), "i"(rs1), "i"(rs2) : "memory")

/* Instruction reading x registers in the rs1 and rs2 fields. */
#define MX_INSN_RR(f7, rd, r1, r2) \
    __asm__ volatile(".insn r CUSTOM_1, 0, %0, x%1, %2, %3" \
                     :: "i"(f7), "i"(rd), "r"(r1), "r"(r2) : "memory")

/* Instruction reading an x register in rs1 only (rs2 field = 0). */
#define MX_INSN_R(f7, rd, r1) \
    __asm__ volatile(".insn r CUSTOM_1, 0, %0, x%1, %2, x0" \
                     :: "i"(f7), "i"(rd), "r"(r1) : "memory")

/* --- Configuration: func4 1 = k, 2 = m, 3 = n; uop 00; inst[25] = 1 takes rs1. --- */
#define MSETTILEK(v) MX_INSN_R((1 << 3) | 1, 0, (v))
#define MSETTILEM(v) MX_INSN_R((2 << 3) | 1, 0, (v))
#define MSETTILEN(v) MX_INSN_R((3 << 3) | 1, 0, (v))

/* --- Load / store: func4 0 = A, 1 = B, 2 = C; uop 01; inst[25] = ls (1 = store);
 *     rs1 = base address, rs2 = row stride in bytes; rd field = d_size | md. --- */
#define MX_LS(func4, st, esize, md, base, stride) \
    MX_INSN_RR(((func4) << 3) | (1 << 1) | (st), ((esize) << 3) | (md), (base), (stride))
#define MLAE8(md, base, stride)   MX_LS(0, 0, MX_E8,  md, base, stride)
#define MLBE8(md, base, stride)   MX_LS(1, 0, MX_E8,  md, base, stride)
#define MLAE32(md, base, stride)  MX_LS(0, 0, MX_E32, md, base, stride)
#define MLBE32(md, base, stride)  MX_LS(1, 0, MX_E32, md, base, stride)
#define MLCE32(md, base, stride)  MX_LS(2, 0, MX_E32, md, base, stride)
#define MSCE32(ms3, base, stride) MX_LS(2, 1, MX_E32, ms3, base, stride)

/* --- Matrix multiply, uop 10. size_sup = inst[25:23]: inst[25] is in func7, inst[24:23]
 *     are the top bits of the rs2 field; s_size = inst[19:18] is the top of the rs1 field. --- */
/* Integer int8 -> int32 (func4 0001, s_size 00, d_size 10); variant = size_sup:
 * 0 mmaccu, 1 mmaccus, 2 mmaccsu, 3 mmacc (both signed). md += ms1 * ms2^T. */
#define MX_MMAC(variant, md, ms1, ms2) \
    MX_INSN((1 << 3) | (2 << 1) | (((variant) >> 2) & 1), (MX_E32 << 3) | (md), \
            (MX_E8 << 3) | (ms1), (((variant) & 3) << 3) | (ms2))
#define MMACCU_W_B(md, ms1, ms2)  MX_MMAC(0, md, ms1, ms2)
#define MMACCUS_W_B(md, ms1, ms2) MX_MMAC(1, md, ms1, ms2)
#define MMACCSU_W_B(md, ms1, ms2) MX_MMAC(2, md, ms1, ms2)
#define MMACC_W_B(md, ms1, ms2)   MX_MMAC(3, md, ms1, ms2)

/* FP32 (func4 0000, size_sup 000, s_size 10, d_size 10). md += ms1 * ms2^T. */
#define MFMACC_S(md, ms1, ms2) \
    MX_INSN((0 << 3) | (2 << 1), (MX_E32 << 3) | (md), (MX_E32 << 3) | (ms1), (ms2))

/* --- MISC, uop 11: mzero (func4 0000, imm3 = 0: one register). --- */
#define MZERO(md) MX_INSN((0 << 3) | (3 << 1), (md), 0, 0)

#endif
