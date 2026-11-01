#!/usr/bin/env python3
"""Random RV32IF programs for the differential test of `core` (scripts/run_core_diff.py).

No NOPs are inserted: operands come from a small register pool so most instructions read a
register written one to three instructions earlier (ALU, load, FP, CSR and link results, store
data, branch and jalr operands, load/store addresses). Control flow only goes forward (taken
branches and jumps skip 1-3 instructions), so every program ends with the store to TOHOST.

Memory map: code from 0x0000, data 0x8000-0x8fff (x2 points to it), TOHOST 0xfff0.
Registers: x2 data base, x3 data pointer (always inside the data area), x4 jalr target,
x30 CSR source value, x31 TOHOST; the pool is x0 and x5-x12, f0-f7. Load/store offsets stay
below 0x800 (positive 12-bit), so no store reaches the code.

Usage: gen_core_diff.py OUTDIR --seed S [--count N]   writes OUTDIR/mem.hex (bytes) and asm.txt
"""
import argparse
import random
import struct
from pathlib import Path

DATA, TOHOST, CODE_LIMIT = 0x8000, 0xFFF0, 0x8000
XPOOL = [0, 5, 6, 7, 8, 9, 10, 11, 12]
FPOOL = list(range(8))
FP_SPECIALS = [0x00000000, 0x80000000, 0x3F800000, 0xBF800000, 0x7F800000, 0xFF800000,
               0x7FC00000, 0x7F800001, 0x00000001, 0x807FFFFF, 0x7F7FFFFF, 0x4B000000,
               0x4F000000, 0xCF000000, 0x3EAAAAAB, 0x40490FDB]


def r(f7, rs2, rs1, f3, rd, op): return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
def i(imm, rs1, f3, rd, op): return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
def s(imm, rs2, rs1, f3, op=0x23):
    return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | op
def b(imm, rs2, rs1, f3):
    return ((((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12)
            | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63)
def u(imm20, rd, op): return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op
def j(imm, rd):
    return ((((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 1) << 20)
            | (((imm >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F)
def r4(op, rs3, rs2, rs1, rm, rd): return (rs3 << 27) | (rs2 << 20) | (rs1 << 15) | (rm << 12) | (rd << 7) | op


def li(rd, value):
    """lui + addi for any 32-bit value."""
    lo = value & 0xFFF
    lo = lo - 0x1000 if lo & 0x800 else lo
    hi = ((value - lo) >> 12) & 0xFFFFF
    return [(u(hi, rd, 0x37), f"lui x{rd},{hi:#x}"), (i(lo, rd, 0, rd, 0x13), f"addi x{rd},x{rd},{lo}")]


class Gen:
    def __init__(self, rng):
        self.rng = rng
        self.code = []                                  # (word, text)

    def emit(self, word, text):
        self.code.append((word, text))

    def xs(self): return self.rng.choice(XPOOL)
    def xd(self): return self.rng.choice(XPOOL[1:]) if self.rng.random() < 0.95 else 0
    def fr(self): return self.rng.choice(FPOOL)
    def rm(self): return self.rng.choice([0, 1, 2, 3, 4, 7, 7])

    def alu(self):
        g = self.rng
        if g.random() < 0.5:
            f3, f7, name = g.choice([(0, 0, "add"), (0, 0x20, "sub"), (1, 0, "sll"), (2, 0, "slt"), (3, 0, "sltu"),
                                     (4, 0, "xor"), (5, 0, "srl"), (5, 0x20, "sra"), (6, 0, "or"), (7, 0, "and")])
            rd, a, c = self.xd(), self.xs(), self.xs()
            self.emit(r(f7, c, a, f3, rd, 0x33), f"{name} x{rd},x{a},x{c}")
        elif g.random() < 0.75:
            f3, name = g.choice([(0, "addi"), (2, "slti"), (3, "sltiu"), (4, "xori"), (6, "ori"), (7, "andi"),
                                 (1, "slli"), (5, "srli"), (5, "srai")])
            rd, a = self.xd(), self.xs()
            imm = g.randrange(32) | (0x400 if name == "srai" else 0) if f3 in (1, 5) else g.randrange(-2048, 2048)
            self.emit(i(imm, a, f3, rd, 0x13), f"{name} x{rd},x{a},{imm}")
        else:
            rd, imm = self.xd(), g.randrange(1 << 20)       # rs1 field = random immediate bits
            op, name = g.choice([(0x37, "lui"), (0x17, "auipc")])
            self.emit(u(imm, rd, op), f"{name} x{rd},{imm:#x}")

    def address(self, align):
        """Base register and offset inside the data area; sometimes through a fresh x3.
        x3 is only ever written here (and starts equal to x2), so it points into the data area
        even when a taken branch skips its addi: stores never reach the code."""
        g = self.rng
        if g.random() < 0.4:
            base = g.randrange(0, 0x800, 4)
            self.emit(i(base, 2, 0, 3, 0x13), f"addi x3,x2,{base}")
            return 3, g.randrange(0, 0x400, align)
        if g.random() < 0.5:
            return 3, g.randrange(0, 0x400, align)
        return 2, g.randrange(0, 0x800, align)

    def load(self):
        g = self.rng
        f3, name, align = g.choice([(0, "lb", 1), (4, "lbu", 1), (1, "lh", 2), (5, "lhu", 2), (2, "lw", 4)])
        base, off = self.address(align)
        rd = self.xd()
        self.emit(i(off, base, f3, rd, 0x03), f"{name} x{rd},{off}(x{base})")

    def store(self):
        g = self.rng
        f3, name, align = g.choice([(0, "sb", 1), (1, "sh", 2), (2, "sw", 4)])
        base, off = self.address(align)
        src = self.xs()
        self.emit(s(off, src, base, f3), f"{name} x{src},{off}(x{base})")

    def fp_mem(self):
        base, off = self.address(4)
        if self.rng.random() < 0.5:
            rd = self.fr()
            self.emit(i(off, base, 2, rd, 0x07), f"flw f{rd},{off}(x{base})")
        else:
            src = self.fr()
            self.emit(s(off, src, base, 2, 0x27), f"fsw f{src},{off}(x{base})")

    def fp(self):
        g = self.rng
        k = g.randrange(12)
        rd, a, c, rm = self.fr(), self.fr(), self.fr(), self.rm()
        if k < 3:
            f7, name = g.choice([(0x00, "fadd.s"), (0x04, "fsub.s"), (0x08, "fmul.s"), (0x0C, "fdiv.s")]) \
                if g.random() < 0.15 else g.choice([(0x00, "fadd.s"), (0x04, "fsub.s"), (0x08, "fmul.s")])
            self.emit(r(f7, c, a, rm, rd, 0x53), f"{name} f{rd},f{a},f{c},rm{rm}")
        elif k == 3 and g.random() < 0.3:
            self.emit(r(0x2C, 0, a, rm, rd, 0x53), f"fsqrt.s f{rd},f{a},rm{rm}")
        elif k < 6:
            op, name = g.choice([(0x43, "fmadd.s"), (0x47, "fmsub.s"), (0x4B, "fnmsub.s"), (0x4F, "fnmadd.s")])
            e = self.fr()
            self.emit(r4(op, e, c, a, rm, rd), f"{name} f{rd},f{a},f{c},f{e},rm{rm}")
        elif k == 6:
            f3, name = g.choice([(0, "fsgnj.s"), (1, "fsgnjn.s"), (2, "fsgnjx.s")])
            self.emit(r(0x10, c, a, f3, rd, 0x53), f"{name} f{rd},f{a},f{c}")
        elif k == 7:
            f3, name = g.choice([(0, "fmin.s"), (1, "fmax.s")])
            self.emit(r(0x14, c, a, f3, rd, 0x53), f"{name} f{rd},f{a},f{c}")
        elif k == 8:                                     # FP -> x
            xd = self.xd()
            f3, name = g.choice([(2, "feq.s"), (1, "flt.s"), (0, "fle.s")])
            self.emit(r(0x50, c, a, f3, xd, 0x53), f"{name} x{xd},f{a},f{c}")
        elif k == 9:
            xd = self.xd()
            which = g.randrange(4)
            if which < 2:
                self.emit(r(0x60, which, a, rm, xd, 0x53), f"fcvt.w{'u' if which else ''}.s x{xd},f{a},rm{rm}")
            else:
                f3 = which - 2
                self.emit(r(0x70, 0, a, f3, xd, 0x53), f"{'fclass.s' if f3 else 'fmv.x.w'} x{xd},f{a}")
        else:                                            # x -> FP
            xs = self.xs()
            which = g.randrange(3)
            if which < 2:
                self.emit(r(0x68, which, xs, rm, rd, 0x53), f"fcvt.s.w{'u' if which else ''} f{rd},x{xs},rm{rm}")
            else:
                self.emit(r(0x78, 0, xs, 0, rd, 0x53), f"fmv.w.x f{rd},x{xs}")

    def csr(self):
        g = self.rng
        addr, name = g.choice([(1, "fflags"), (2, "frm"), (3, "fcsr")])
        rd = self.xd()
        names = ["", "rw", "rs", "rc", "", "rwi", "rsi", "rci"]
        # frm may still become 5-7 (csrrs); dynamic-rounding ops then take the illegal-rm path.
        if g.random() < 0.5:
            f3 = g.choice([5, 6, 7])
            imm = g.randrange(5) if addr == 2 else g.randrange(32)
            self.emit(i(addr, imm, f3, rd, 0x73), f"csr{names[f3]} x{rd},{name},{imm}")
        else:
            f3 = g.choice([1, 2, 3])
            if addr != 1 and g.random() < 0.8:           # mostly a legal frm, through x30
                val = g.randrange(5) if addr == 2 else (g.randrange(5) << 5) | g.randrange(32)
                self.emit(i(val, 0, 0, 30, 0x13), f"addi x30,x0,{val}")
                src = 30
            else:
                src = self.xs()
            self.emit(i(addr, src, f3, rd, 0x73), f"csr{names[f3]} x{rd},{name},x{src}")

    def control(self, body):
        """Forward branch / jal / jalr over 1-3 instructions of `body` (which may run or not)."""
        g = self.rng
        k = g.randrange(1, 4)
        kind = g.randrange(5)
        if kind < 3:
            f3, name = g.choice([(0, "beq"), (1, "bne"), (4, "blt"), (5, "bge"), (6, "bltu"), (7, "bgeu")])
            a, c = self.xs(), self.xs()
            self.emit(b((k + 1) * 4, c, a, f3), f"{name} x{a},x{c},+{(k + 1) * 4}")
        elif kind == 3:
            rd = self.xd()
            self.emit(j((k + 1) * 4, rd), f"jal x{rd},+{(k + 1) * 4}")
        else:
            rd = self.xd()
            self.emit(u(0, 4, 0x17), "auipc x4,0")
            self.emit(i(12 + k * 4, 4, 0, 4, 0x13), f"addi x4,x4,{12 + k * 4}")
            self.emit(i(0, 4, 0, rd, 0x67), f"jalr x{rd},0(x4)")
        for _ in range(k):
            body()

    def one(self):
        g = self.rng
        pick = g.random()
        if pick < 0.25: self.alu()
        elif pick < 0.37: self.load()
        elif pick < 0.47: self.store()
        elif pick < 0.55: self.fp_mem()
        elif pick < 0.82: self.fp()
        elif pick < 0.87: self.csr()
        else: self.control(self.one_plain)

    def one_plain(self):
        pick = self.rng.random()
        if pick < 0.35: self.alu()
        elif pick < 0.5: self.load()
        elif pick < 0.62: self.store()
        elif pick < 0.7: self.fp_mem()
        else: self.fp()


def generate(seed, count):
    rng = random.Random(seed)
    gen = Gen(rng)
    for w, t in li(2, DATA) + li(31, TOHOST):
        gen.emit(w, t)
    gen.emit(i(0, 2, 0, 3, 0x13), "addi x3,x2,0")
    for x in XPOOL[1:]:
        for w, t in li(x, rng.getrandbits(32) if rng.random() < 0.7 else rng.randrange(-8, 8) & 0xFFFFFFFF):
            gen.emit(w, t)
    for f in FPOOL:
        gen.emit(i(4 * f, 2, 2, f, 0x07), f"flw f{f},{4 * f}(x2)")
    gen.emit(i(rng.randrange(5), 0, 5, 0, 0x73), "csrrwi x0,frm,<0-4>")
    while len(gen.code) < count:
        gen.one()
    gen.emit(i(1, 0, 0, 30, 0x13), "addi x30,x0,1")
    gen.emit(s(0, 30, 31, 2), "sw x30,0(x31)")
    gen.emit(j(0, 0), "jal x0,0")
    assert len(gen.code) * 4 <= CODE_LIMIT

    mem = bytearray(0x10000)
    for n, (w, _) in enumerate(gen.code):
        struct.pack_into("<I", mem, 4 * n, w)
    for a in range(DATA, DATA + 0x1000, 4):
        v = rng.choice(FP_SPECIALS) if rng.random() < 0.5 else rng.getrandbits(32)
        struct.pack_into("<I", mem, a, v)
    return gen.code, mem


def write(outdir, seed, count):
    code, mem = generate(seed, count)
    out = Path(outdir)
    out.mkdir(parents=True, exist_ok=True)
    last = max(DATA + 0x1000, 4 * len(code))
    (out / "mem.hex").write_text("\n".join(f"{x:02x}" for x in mem[:last]) + "\n")
    (out / "asm.txt").write_text("".join(f"{4 * n:05x}: {w:08x}  {t}\n" for n, (w, t) in enumerate(code)))


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("outdir")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=400, help="instructions per program (approximate)")
    a = ap.parse_args()
    write(a.outdir, a.seed, a.count)
