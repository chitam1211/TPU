#!/usr/bin/env python3
"""Generate the matrix regression programs for tb/matrix/tb_matrix_regress.sv.

Each case is one program covering a group of matrix instructions (Matrix Extension v0.6.0
encoding, as decoded by rtl/matrix_if/matrix_dispatch.sv), run on the RV32IF core with no NOP
padding, so the pipeline interlocks (stall, register hazards, shared data port) are exercised.
A case writes:
  <out>/<case>/mem.hex   program at 0x0000, input data at 0x1000 ($readmemh, one byte per line)
  <out>/<case>/expect.txt  words whose value follows from simple integer rules (address value
                           comment), checked against the final RAM; the rest of the state is
                           compared with the golden dump of the current RTL
  <out>/<case>/asm.txt   one line per program word
Memory map: code 0x0000-0x0FFF, inputs 0x1000-0x17FF, outputs 0x1800-0x3FEF, TOHOST 0x3FF0.

Usage: gen_matrix_regress.py OUTDIR [--seed S]
"""
import argparse
import random
import struct
from pathlib import Path

IN, OUT, TOHOST = 0x1000, 0x1800, 0x3FF0
OPC_MX = 0x2B


def f2u(x):
    return struct.unpack("<I", struct.pack("<f", x))[0]


# ---------------------------------------------------------------- RV32IF encoders
def r_type(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def i_type(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def s_type(imm, rs2, rs1, f3, op):
    return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | op


def b_type(off, rs2, rs1, f3):
    return ((((off >> 12) & 1) << 31) | (((off >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) |
            (f3 << 12) | (((off >> 1) & 0xF) << 8) | (((off >> 11) & 1) << 7) | 0x63)


# ---------------------------------------------------------------- matrix encoders
def cfg_imm(func4, v):             # msettile{k,m,n}i: func4 1=k 2=m 3=n
    return (func4 << 28) | ((v & 0x3FF) << 15) | OPC_MX


def cfg_rs(func4, rs1):            # msettile{k,m,n} rs1
    return (func4 << 28) | (1 << 25) | (rs1 << 15) | OPC_MX


def mls(func4, store, rs2, rs1, dsize, md):   # func4 0=A 1=B 2=C, dsize 0=8-bit 2=32-bit
    return (func4 << 28) | (1 << 26) | (store << 25) | (rs2 << 20) | (rs1 << 15) | (dsize << 10) | (md << 7) | OPC_MX


def mmac(variant, md, ms1, ms2):   # 0 mmaccu 1 mmaccus 2 mmaccsu 3 mmacc (.w.b)
    return (1 << 28) | (2 << 26) | (variant << 23) | (ms2 << 20) | (ms1 << 15) | (2 << 10) | (md << 7) | OPC_MX


def mfmacc(md, ms1, ms2):
    return (2 << 26) | (ms2 << 20) | (2 << 18) | (ms1 << 15) | (2 << 10) | (md << 7) | OPC_MX


def mzero(md):
    return (3 << 26) | (md << 7) | OPC_MX


def mmov_mm(md, ms1):
    return (1 << 28) | (3 << 26) | (ms1 << 15) | (md << 7) | OPC_MX


def mmovw_x_m(rd, ms2, rs1):       # rd = ms2[element rs1]
    return (2 << 28) | (3 << 26) | (0b10 << 23) | (ms2 << 20) | (rs1 << 15) | (rd << 7) | OPC_MX


def mmovw_m_x(md, rs2, rs1):       # md[element rs1] = rs2
    return (3 << 28) | (3 << 26) | (1 << 25) | (rs2 << 20) | (rs1 << 15) | (2 << 10) | (md << 7) | OPC_MX


def mdupw(md, rs2):
    return (3 << 28) | (3 << 26) | (rs2 << 20) | (2 << 10) | (md << 7) | OPC_MX


def mslide(func4, md, ms1, imm):   # 5 rslidedown 6 rslideup (8-bit), 7 cslidedown.w 8 cslideup.w
    w = func4 >= 7
    return ((func4 << 28) | (3 << 26) | (imm << 23) | ((2 if w else 0) << 18) | (ms1 << 15) |
            ((2 if w else 0) << 10) | (md << 7) | OPC_MX)


def mew(func4, md, ms1, ms2, imm3=7):   # integer .w element-wise; imm3 7 = .mm, 0-3 = .mv row
    return ((func4 << 28) | (1 << 26) | (imm3 << 23) | (ms2 << 20) | (2 << 18) | (ms1 << 15) |
            (1 << 12) | (2 << 10) | (md << 7) | OPC_MX)


def mfew(func4, md, ms1, ms2):     # FP32 element-wise .mm: 0 add 1 sub 2 mul 3 max 4 min
    return ((func4 << 28) | (2 << 26) | (7 << 23) | (ms2 << 20) | (2 << 18) | (ms1 << 15) |
            (1 << 12) | (2 << 10) | (md << 7) | OPC_MX)


EW_NAMES = ["madd", "msub", "mmul", "mmulh", "mmax", "mumax", "mmin", "mumin", "msrl", "msll", "msra"]
FEW_NAMES = ["mfadd", "mfsub", "mfmul", "mfmax", "mfmin"]
MAC_NAMES = ["mmaccu", "mmaccus", "mmaccsu", "mmacc"]
A, B, C = 0, 1, 2
TR = [0, 1, 2, 3]
ACC = [4, 5, 6, 7]


class Prog:
    def __init__(self):
        self.words, self.asm, self.data, self.expect = [], [], {}, []
        self.labels, self.fixups = {}, []

    def emit(self, w, text):
        self.words.append(w & 0xFFFFFFFF)
        self.asm.append(text)

    # scalar helpers
    def addi(self, rd, rs1, imm): self.emit(i_type(imm, rs1, 0, rd, 0x13), f"addi x{rd}, x{rs1}, {imm}")
    def add(self, rd, rs1, rs2): self.emit(r_type(0, rs2, rs1, 0, rd, 0x33), f"add x{rd}, x{rs1}, x{rs2}")
    def lw(self, rd, rs1, imm): self.emit(i_type(imm, rs1, 2, rd, 0x03), f"lw x{rd}, {imm}(x{rs1})")
    def sw(self, rs2, rs1, imm): self.emit(s_type(imm, rs2, rs1, 2, 0x23), f"sw x{rs2}, {imm}(x{rs1})")
    def fsw(self, rs2, rs1, imm): self.emit(s_type(imm, rs2, rs1, 2, 0x27), f"fsw f{rs2}, {imm}(x{rs1})")
    def fmv_w_x(self, rd, rs1): self.emit(r_type(0x78, 0, rs1, 0, rd, 0x53), f"fmv.w.x f{rd}, x{rs1}")
    def fadd(self, rd, rs1, rs2): self.emit(r_type(0x00, rs2, rs1, 0, rd, 0x53), f"fadd.s f{rd}, f{rs1}, f{rs2}, rne")

    def li(self, rd, v):
        v &= 0xFFFFFFFF
        sv = v - (1 << 32) if v & 0x80000000 else v
        if -2048 <= sv < 2048:
            self.addi(rd, 0, sv)
            return
        lo = v & 0xFFF
        lo = lo - 4096 if lo & 0x800 else lo
        hi = ((v - lo) >> 12) & 0xFFFFF
        self.emit((hi << 12) | (rd << 7) | 0x37, f"lui x{rd}, 0x{hi:x}")
        if lo:
            self.addi(rd, rd, lo)

    def label(self, name): self.labels[name] = len(self.words)

    def branch(self, f3, rs1, rs2, target, mnem):
        self.fixups.append((len(self.words), f3, rs1, rs2, target))
        self.emit(0, f"{mnem} x{rs1}, x{rs2}, {target}")

    def mx(self, w, text): self.emit(w, text)

    # data helpers
    def bytes_at(self, addr, bs):
        for i, b in enumerate(bs):
            self.data[addr + i] = b & 0xFF

    def words_at(self, addr, ws):
        for i, w in enumerate(ws):
            self.bytes_at(addr + 4 * i, (w & 0xFFFFFFFF).to_bytes(4, "little"))

    def expect_word(self, addr, value, note):
        self.expect.append((addr, value & 0xFFFFFFFF, note))

    def finish(self):
        self.li(31, 1)
        self.li(30, TOHOST)
        self.sw(31, 30, 0)
        self.label("_end")
        self.emit(0x0000006F, "jal x0, 0")
        for pos, f3, rs1, rs2, target in self.fixups:
            self.words[pos] = b_type((self.labels[target] - pos) * 4, rs2, rs1, f3)
        assert len(self.words) * 4 <= IN, "program overlaps the data area"

    def write(self, d: Path):
        d.mkdir(parents=True, exist_ok=True)
        mem = {}
        for i, w in enumerate(self.words):
            for k, b in enumerate(w.to_bytes(4, "little")):
                mem[4 * i + k] = b
        mem.update(self.data)
        top = max(mem) + 1
        (d / "mem.hex").write_text("".join(f"{mem.get(a, 0):02x}\n" for a in range(top)))
        (d / "asm.txt").write_text("".join(f"{4 * i:04x}: {w:08x}  {t}\n" for i, (w, t) in enumerate(zip(self.words, self.asm))))
        (d / "expect.txt").write_text("".join(f"{a:04x} {v:08x} {n}\n" for a, v, n in self.expect))


def tile(p, m, n, k):
    p.mx(cfg_imm(2, m), f"msettilemi {m}")
    p.mx(cfg_imm(3, n), f"msettileni {n}")
    p.mx(cfg_imm(1, k), f"msettileki {k}")


# ---------------------------------------------------------------- cases
def case_ls(rng):
    """Tile loads/stores of A, B (8-bit and 32-bit) and C, full and partial tiles, two strides."""
    p = Prog()
    a8 = [rng.randrange(256) for _ in range(4 * 32)]
    p.bytes_at(IN, a8)                                    # 4 rows x 32 bytes (stride 32)
    w32 = [rng.getrandbits(32) for _ in range(4 * 8)]
    p.words_at(IN + 0x100, w32)                           # 4 rows x 8 words (stride 32)
    p.li(1, IN); p.li(2, 32); p.li(3, IN + 0x100); p.li(4, OUT)
    tile(p, 4, 4, 16)
    p.mx(mls(A, 0, 2, 1, 0, 0), "mlae8 tr0, (x1), x2")
    p.mx(mls(B, 0, 2, 1, 0, 1), "mlbe8 tr1, (x1), x2")
    p.mx(mls(C, 0, 2, 3, 2, 4), "mlce32 acc0, (x3), x2")
    p.mx(mls(A, 1, 2, 4, 0, 0), "msae8 tr0, (x4), x2")
    p.addi(5, 4, 0x80)
    p.mx(mls(B, 1, 2, 5, 0, 1), "msbe8 tr1, (x5), x2")
    p.addi(5, 4, 0x100)
    p.mx(mls(C, 1, 2, 5, 2, 4), "msce32 acc0, (x5), x2")
    for r in range(4):                                    # stores copy the 16-byte rows back
        for w in range(4):
            v = int.from_bytes(bytes(a8[32 * r + 4 * w:32 * r + 4 * w + 4]), "little")
            p.expect_word(OUT + 32 * r + 4 * w, v, f"msae8 row {r} word {w}")
            p.expect_word(OUT + 0x80 + 32 * r + 4 * w, v, f"msbe8 row {r} word {w}")
            p.expect_word(OUT + 0x100 + 32 * r + 4 * w, w32[8 * r + w], f"msce32 row {r} col {w}")
    # 32-bit A/B (K = 4 words per row), then a partial tile M=3 N=2 K=5 with stride 16
    tile(p, 4, 4, 4)
    p.mx(mls(A, 0, 2, 3, 2, 2), "mlae32 tr2, (x3), x2")
    p.mx(mls(B, 0, 2, 3, 2, 3), "mlbe32 tr3, (x3), x2")
    p.addi(5, 4, 0x180)
    p.mx(mls(A, 1, 2, 5, 2, 2), "msae32 tr2, (x5), x2")
    p.addi(5, 4, 0x200)
    p.mx(mls(B, 1, 2, 5, 2, 3), "msbe32 tr3, (x5), x2")
    for r in range(4):
        for w in range(4):
            p.expect_word(OUT + 0x180 + 32 * r + 4 * w, w32[8 * r + w], f"msae32 row {r} col {w}")
            p.expect_word(OUT + 0x200 + 32 * r + 4 * w, w32[8 * r + w], f"msbe32 row {r} col {w}")
    p.li(6, 3); p.li(7, 2); p.li(8, 5); p.li(2, 16)
    p.mx(cfg_rs(2, 6), "msettilem x6")
    p.mx(cfg_rs(3, 7), "msettilen x7")
    p.mx(cfg_rs(1, 8), "msettilek x8")
    p.mx(mzero(0), "mzero tr0")
    p.mx(mls(A, 0, 2, 1, 0, 0), "mlae8 tr0, (x1), x2")
    p.mx(mls(C, 0, 2, 3, 2, 5), "mlce32 acc1, (x3), x2")
    p.addi(5, 4, 0x280)
    p.mx(mls(A, 1, 2, 5, 0, 0), "msae8 tr0, (x5), x2")
    p.addi(5, 4, 0x2C0)
    p.mx(mls(C, 1, 2, 5, 2, 5), "msce32 acc1, (x5), x2")
    p.mx(0x0000002B, "mrelease")
    return p


def case_mm_int(rng):
    """All four int8 matmul signedness variants, accumulation, and a partial M=3 N=4 K=7 tile."""
    p = Prog()
    M = N = 4
    K = 16
    a = [[rng.randrange(256) for _ in range(K)] for _ in range(M)]
    b = [[rng.randrange(256) for _ in range(K)] for _ in range(N)]   # stored transposed: row n = B[:, n]
    for i in range(M):
        p.bytes_at(IN + 16 * i, a[i])
    for j in range(N):
        p.bytes_at(IN + 0x40 + 16 * j, b[j])
    p.li(1, IN); p.li(2, 16); p.li(3, IN + 0x40); p.li(4, OUT)
    tile(p, M, N, K)
    p.mx(mls(A, 0, 2, 1, 0, 0), "mlae8 tr0, (x1), x2")
    p.mx(mls(B, 0, 2, 3, 0, 1), "mlbe8 tr1, (x3), x2")

    def s8(x):
        return x - 256 if x & 0x80 else x

    def ref(variant, mm, nn, kk):
        ua, ub = variant in (0, 1), variant in (0, 2)
        return [[sum((a[i][k] if ua else s8(a[i][k])) * (b[j][k] if ub else s8(b[j][k])) for k in range(kk))
                 for j in range(nn)] for i in range(mm)]

    for v in range(4):
        p.mx(mzero(ACC[v]), f"mzero acc{v}")
        p.mx(mmac(v, ACC[v], 0, 1), f"{MAC_NAMES[v]}.w.b acc{v}, tr0, tr1")
        p.addi(5, 4, 0x40 * v)
        p.mx(mls(C, 1, 2, 5, 2, ACC[v]), f"msce32 acc{v}, (x5), x2")
        c = ref(v, M, N, K)
        for i in range(M):
            for j in range(N):
                p.expect_word(OUT + 0x40 * v + 16 * i + 4 * j, c[i][j], f"{MAC_NAMES[v]} C[{i}][{j}]")
    p.mx(mmac(3, ACC[0], 0, 1), "mmacc.w.b acc0, tr0, tr1   (accumulate onto the mmaccu result)")
    p.addi(5, 4, 0x100)
    p.mx(mls(C, 1, 2, 5, 2, ACC[0]), "msce32 acc0, (x5), x2")
    c0, c3 = ref(0, M, N, K), ref(3, M, N, K)
    for i in range(M):
        for j in range(N):
            p.expect_word(OUT + 0x100 + 16 * i + 4 * j, c0[i][j] + c3[i][j], f"mmaccu+mmacc C[{i}][{j}]")
    # partial tile through msettile{m,n,k} rs1
    p.li(6, 3); p.li(7, 4); p.li(8, 7)
    p.mx(cfg_rs(2, 6), "msettilem x6")
    p.mx(cfg_rs(3, 7), "msettilen x7")
    p.mx(cfg_rs(1, 8), "msettilek x8")
    p.mx(mzero(ACC[2]), "mzero acc2")
    p.mx(mmac(3, ACC[2], 0, 1), "mmacc.w.b acc2, tr0, tr1 (M=3 N=4 K=7)")
    p.addi(5, 4, 0x140)
    p.mx(mls(C, 1, 2, 5, 2, ACC[2]), "msce32 acc2, (x5), x2")
    c = ref(3, 3, 4, 7)
    for i in range(3):
        for j in range(4):
            p.expect_word(OUT + 0x140 + 16 * i + 4 * j, c[i][j], f"mmacc partial C[{i}][{j}]")
    return p


def fp_values(rng, n, specials=False):
    vals = [f2u(rng.uniform(-8, 8)) for _ in range(n)]
    if specials:
        extra = [0x00000000, 0x80000000, 0x7F800000, 0xFF800000, 0x7FC00000, 0x7F800001,
                 0x00000001, 0x007FFFFF, 0x7F7FFFFF, 0x3F800000]
        for i, v in enumerate(extra):
            vals[(3 * i + 1) % n] = v
    return vals


def case_mm_fp(rng):
    """mfmacc.s on a full 4x4x4 tile and a partial 2x3x3 tile."""
    p = Prog()
    p.words_at(IN, fp_values(rng, 16))            # A 4x4
    p.words_at(IN + 0x40, fp_values(rng, 16))     # B (transposed) 4x4
    p.words_at(IN + 0x80, fp_values(rng, 16))     # C 4x4
    p.li(1, IN); p.li(2, 16); p.li(3, IN + 0x40); p.li(4, OUT); p.li(9, IN + 0x80)
    tile(p, 4, 4, 4)
    p.mx(mls(A, 0, 2, 1, 2, 2), "mlae32 tr2, (x1), x2")
    p.mx(mls(B, 0, 2, 3, 2, 3), "mlbe32 tr3, (x3), x2")
    p.mx(mls(C, 0, 2, 9, 2, 5), "mlce32 acc1, (x9), x2")
    p.mx(mfmacc(5, 2, 3), "mfmacc.s acc1, tr2, tr3")
    p.mx(mls(C, 1, 2, 4, 2, 5), "msce32 acc1, (x4), x2")
    tile(p, 2, 3, 3)
    p.mx(mzero(6), "mzero acc2")
    p.mx(mfmacc(6, 2, 3), "mfmacc.s acc2, tr2, tr3 (M=2 N=3 K=3)")
    p.addi(5, 4, 0x40)
    p.mx(mls(C, 1, 2, 5, 2, 6), "msce32 acc2, (x5), x2")
    return p


def case_ew_int(rng):
    """Every integer element-wise .w op in .mm form and in .mv form (row imm3 of ms1)."""
    p = Prog()
    x = [rng.getrandbits(32) for _ in range(16)]
    y = [rng.getrandbits(32) for _ in range(16)]
    p.words_at(IN, x)
    p.words_at(IN + 0x40, y)
    p.li(1, IN); p.li(2, 16); p.li(3, IN + 0x40); p.li(4, OUT)
    tile(p, 4, 4, 4)
    p.mx(mls(C, 0, 2, 1, 2, 4), "mlce32 acc0, (x1), x2")
    p.mx(mls(C, 0, 2, 3, 2, 5), "mlce32 acc1, (x3), x2")
    p.mx(mls(A, 0, 2, 3, 2, 0), "mlae32 tr0, (x3), x2")
    slot = 0
    for f, name in enumerate(EW_NAMES):
        for form, imm3 in (("mm", 7), ("mv", f % 4)):
            ms1, ms2 = (4, 5) if form == "mm" else (4, 0)
            p.mx(mew(f, 6, ms1, ms2, imm3), f"{name}.w.{form} acc2, m{ms1}, m{ms2}" + ("" if form == "mm" else f", row {imm3}"))
            p.addi(5, 4, 0x40 * slot)
            p.mx(mls(C, 1, 2, 5, 2, 6), f"msce32 acc2, (x5), x2   # slot {slot}")
            slot += 1
    return p


def case_ew_fp(rng):
    """FP32 element-wise .mm ops, including NaN, infinities, signed zeros and subnormals."""
    p = Prog()
    p.words_at(IN, fp_values(rng, 16, specials=True))
    p.words_at(IN + 0x40, fp_values(rng, 16, specials=True)[::-1])
    p.li(1, IN); p.li(2, 16); p.li(3, IN + 0x40); p.li(4, OUT)
    tile(p, 4, 4, 4)
    p.mx(mls(C, 0, 2, 1, 2, 4), "mlce32 acc0, (x1), x2")
    p.mx(mls(C, 0, 2, 3, 2, 5), "mlce32 acc1, (x3), x2")
    for f, name in enumerate(FEW_NAMES):
        p.mx(mfew(f, 6, 4, 5), f"{name}.s.mm acc2, acc0, acc1")
        p.addi(5, 4, 0x40 * f)
        p.mx(mls(C, 1, 2, 5, 2, 6), f"msce32 acc2, (x5), x2   # {name}")
    return p


def case_misc(rng):
    """mzero, mmov.mm, mmovw.x.m (GPR write-back), mmovw.m.x, mdupw.m.x and the four slides."""
    p = Prog()
    x = [rng.getrandbits(32) for _ in range(16)]
    t8 = [rng.randrange(256) for _ in range(64)]
    p.words_at(IN, x)
    p.bytes_at(IN + 0x40, t8)
    p.li(1, IN); p.li(2, 16); p.li(3, IN + 0x40); p.li(4, OUT)
    tile(p, 4, 4, 16)
    p.mx(mls(C, 0, 2, 1, 2, 4), "mlce32 acc0, (x1), x2")
    p.mx(mls(A, 0, 2, 3, 0, 0), "mlae8 tr0, (x3), x2")
    p.mx(mmov_mm(5, 4), "mmov.mm acc1, acc0")
    p.mx(mls(C, 1, 2, 4, 2, 5), "msce32 acc1, (x4), x2")
    for i in range(16):
        p.expect_word(OUT + 4 * i, x[i], f"mmov.mm acc1 element {i}")
    # mmovw.x.m: x10.. = acc0[idx]; the add right after uses the fresh values (hazard)
    for n, idx in enumerate([0, 5, 10, 15, 3, 12]):
        p.li(6, idx)
        p.mx(mmovw_x_m(10 + n, 4, 6), f"mmovw.x.m x{10 + n}, acc0, x6(={idx})")
        p.sw(10 + n, 4, 0x40 + 4 * n)
        p.expect_word(OUT + 0x40 + 4 * n, x[idx], f"mmovw.x.m acc0[{idx}] stored by sw")
    p.add(16, 10, 11)
    p.sw(16, 4, 0x60)
    p.expect_word(OUT + 0x60, x[0] + x[5], "add of two mmovw.x.m results")
    # mmovw.m.x into acc2 and mdupw into acc3
    p.mx(mzero(6), "mzero acc2")
    for n, (idx, val) in enumerate([(0, 0x11111111), (6, 0xDEADBEEF), (15, 0x80000001)]):
        p.li(6, idx); p.li(7, val)
        p.mx(mmovw_m_x(6, 7, 6), f"mmovw.m.x acc2, x7(={val:#x}), x6(={idx})")
    p.addi(5, 4, 0x80)
    p.mx(mls(C, 1, 2, 5, 2, 6), "msce32 acc2, (x5), x2")
    p.li(7, 0x5A5AA5A5)
    p.mx(mdupw(7, 7), "mdupw.m.x acc3, x7")
    p.addi(5, 4, 0xC0)
    p.mx(mls(C, 1, 2, 5, 2, 7), "msce32 acc3, (x5), x2")
    for i in range(16):
        p.expect_word(OUT + 0xC0 + 4 * i, 0x5A5AA5A5, f"mdupw acc3 element {i}")
    # slides: rows of tr0 (8-bit), columns of acc0 (32-bit)
    slot = 0
    for f4, name, src, dst, imm in [(5, "mrslidedown", 0, 1, 1), (6, "mrslideup", 0, 1, 2),
                                    (7, "mcslidedown.w", 4, 5, 1), (8, "mcslideup.w", 4, 5, 3)]:
        p.mx(mzero(dst), f"mzero m{dst}")
        p.mx(mslide(f4, dst, src, imm), f"{name} m{dst}, m{src}, {imm}")
        p.addi(5, 4, 0x100 + 0x40 * slot)
        if dst < 4:
            p.mx(mls(A, 1, 2, 5, 0, dst), f"msae8 m{dst}, (x5), x2")
        else:
            p.mx(mls(C, 1, 2, 5, 2, dst), f"msce32 m{dst}, (x5), x2")
        slot += 1
    p.mx(mzero(0), "mzero tr0")
    return p


def case_pipeline(rng):
    """Interaction with the scalar pipeline: hazards on rs1/rs2, a load/store next to a matrix
    load/store, FP instructions around a matrix op, back-to-back identical matrix instructions,
    a taken branch over a matrix instruction, a branch on a mmovw.x.m result, and encodings the
    matrix unit rejects (must behave as no-ops)."""
    p = Prog()
    x = [rng.getrandbits(32) for _ in range(16)]
    p.words_at(IN, x)
    p.words_at(IN + 0x40, [f2u(1.5), f2u(-2.25), f2u(3.0), f2u(0.5)])
    p.li(4, OUT)
    p.li(1, IN)                                           # rs1 written right before use
    p.li(2, 16)
    p.mx(cfg_imm(2, 4), "msettilemi 4")
    p.mx(cfg_imm(3, 4), "msettileni 4")
    p.mx(cfg_imm(1, 4), "msettileki 4")
    p.mx(mls(C, 0, 2, 1, 2, 4), "mlce32 acc0, (x1), x2   # x1, x2 just written")
    p.lw(20, 1, 4)                                        # load right after a matrix load
    p.sw(20, 4, 0x200)
    p.expect_word(OUT + 0x200, x[1], "lw after mlce32")
    p.sw(1, 4, 0x204)                                     # store right before a matrix store
    p.mx(mls(C, 1, 2, 4, 2, 4), "msce32 acc0, (x4), x2")
    for i in range(16):
        p.expect_word(OUT + 4 * i, x[i], f"msce32 after sw, element {i}")
    p.lw(21, 4, 0x204)                                    # load right after a matrix store
    p.sw(21, 4, 0x208)
    p.expect_word(OUT + 0x208, IN, "lw after msce32")
    # FP around a matrix op
    p.li(22, IN + 0x40)
    p.lw(23, 22, 0); p.fmv_w_x(1, 23)
    p.lw(23, 22, 4); p.fmv_w_x(2, 23)
    p.fadd(3, 1, 2)
    p.mx(mmov_mm(5, 4), "mmov.mm acc1, acc0   # right after fadd.s")
    p.fadd(4, 3, 1)
    p.fsw(3, 4, 0x20C)
    p.fsw(4, 4, 0x210)
    p.expect_word(OUT + 0x20C, f2u(1.5 + -2.25), "fadd.s before matrix op")
    p.expect_word(OUT + 0x210, f2u(1.5 + -2.25 + 1.5), "fadd.s after matrix op")
    # back-to-back identical matrix instructions (mdupw twice, mmovw.m.x twice)
    p.li(7, 3)
    p.mx(mdupw(6, 7), "mdupw.m.x acc2, x7")
    p.mx(mdupw(6, 7), "mdupw.m.x acc2, x7   # identical, back to back")
    p.li(8, 2); p.li(9, 0x77)
    p.mx(mmovw_m_x(6, 9, 8), "mmovw.m.x acc2, x9, x8")
    p.mx(mmovw_m_x(6, 9, 8), "mmovw.m.x acc2, x9, x8   # identical, back to back")
    p.addi(5, 4, 0x40)
    p.mx(mls(C, 1, 2, 5, 2, 6), "msce32 acc2, (x5), x2")
    for i in range(16):
        p.expect_word(OUT + 0x40 + 4 * i, 0x77 if i == 2 else 3, f"mdupw + mmovw.m.x element {i}")
    # taken branch skips a matrix instruction; not-taken branch falls into one
    p.mx(mzero(7), "mzero acc3")
    p.branch(0, 0, 0, "skip1", "beq")                      # taken
    p.mx(mdupw(7, 9), "mdupw.m.x acc3, x9   # must be skipped")
    p.label("skip1")
    p.branch(1, 0, 0, "skip2", "bne")                      # not taken
    p.mx(mmovw_m_x(7, 7, 8), "mmovw.m.x acc3, x7, x8   # executed")
    p.label("skip2")
    p.addi(5, 4, 0x80)
    p.mx(mls(C, 1, 2, 5, 2, 7), "msce32 acc3, (x5), x2")
    for i in range(16):
        p.expect_word(OUT + 0x80 + 4 * i, 3 if i == 2 else 0, f"branch case acc3 element {i}")
    # branch on a mmovw.x.m result (rd hazard into a branch)
    p.li(6, 2)
    p.mx(mmovw_x_m(24, 6, 6), "mmovw.x.m x24, acc2, x6   # = 0x77")
    p.li(25, 0x77)
    p.li(26, 0)
    p.branch(0, 24, 25, "eq", "beq")
    p.li(26, 0xBAD)
    p.label("eq")
    p.addi(26, 26, 1)
    p.sw(26, 4, 0x214)
    p.expect_word(OUT + 0x214, 1, "beq on mmovw.x.m result taken")
    p.mx(mmovw_x_m(27, 6, 6), "mmovw.x.m x27, acc2, x6")
    p.add(28, 27, 27)                                     # consumer right after
    p.sw(28, 4, 0x218)
    p.expect_word(OUT + 0x218, 0xEE, "add right after mmovw.x.m")
    # rejected encodings: no state change, x29 keeps its value
    p.li(29, 0x1234)
    p.mx(mfew(5, 6, 4, 5), "reserved: FP element-wise func4=5")
    p.mx(mew(11, 6, 4, 5), "reserved: integer element-wise func4=11")
    p.mx(mmac(4, 4, 0, 1), "reserved: matmul size_sup=4")
    p.mx((2 << 28) | (3 << 26) | (1 << 25) | (0b10 << 23) | (6 << 15) | (29 << 7) | OPC_MX,
         "reserved: mmovw.x.m with bit 25 set, rd=x29")
    p.mx((2 << 12) | OPC_MX, "reserved: matrix opcode, func3=010")
    p.sw(29, 4, 0x21C)
    p.expect_word(OUT + 0x21C, 0x1234, "x29 unchanged by rejected encodings")
    p.addi(5, 4, 0xC0)
    p.mx(mls(C, 1, 2, 5, 2, 6), "msce32 acc2, (x5), x2   # unchanged by rejected encodings")
    for i in range(16):
        p.expect_word(OUT + 0xC0 + 4 * i, 0x77 if i == 2 else 3, f"acc2 after rejected encodings, element {i}")
    return p


CASES = {
    "ls": case_ls,
    "mm_int": case_mm_int,
    "mm_fp": case_mm_fp,
    "ew_int": case_ew_int,
    "ew_fp": case_ew_fp,
    "misc": case_misc,
    "pipeline": case_pipeline,
}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("outdir", type=Path)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    for i, (name, fn) in enumerate(CASES.items()):
        p = fn(random.Random(a.seed * 1000 + i))
        p.finish()
        p.write(a.outdir / name)
        print(f"{name:9s} {len(p.words):4d} words, {len(p.expect):3d} expected words -> {a.outdir / name}")


if __name__ == "__main__":
    main()
