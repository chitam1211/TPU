#!/usr/bin/env python3
"""
Control rv32if_xif_soc (fpga/soc_xif) from Linux on the Kria board (PS, Cortex-A53).

  0xA000_0000   4 KB  registers (docs/soc_xif_ngat_halt.pdf, section 9)
  0xA001_0000  16 KB  IMEM, AXI BRAM Controller -> port A of the IMEM BRAM
  0xA002_0000  64 KB  DMEM, AXI BRAM Controller -> port A of the DMEM BRAM

Load the bitstream first (fpga/soc_xif/README.md):
  Kria Ubuntu:  sudo xmutil unloadapp; sudo xmutil loadapp rv32if_xif_soc
  Kria-PYNQ:    sudo -E python3 soc_host.py --bit rv32if_xif_soc.bit   (.hwh next to the .bit)

Modes:
  sudo python3 soc_host.py                    GEMM int8 4x4x16 demo (P1 of tb/soc_xif), --runs N data sets
  sudo python3 soc_host.py --image mem.hex    run a program image: objcopy -O verilog output or one
                                              32-bit word per line, loaded into IMEM and DMEM from 0
         [--golden sim.log]                   compare DMEM with the "STATE mem" lines of tb_matrix_regress
         [--dump 0x1000:0x1040]               print a DMEM range after the run
  sudo python3 soc_host.py --case DIR ...     each DIR holds mem.hex + sim.log, as written by
                                              scripts/run_matrix_sw.py (sim/build/matrix_sw/<tag>/<case>/)

The end of a run is seen by polling IRQ_STATUS (set when halted or the watchdog fires; it does
not depend on IRQ_EN), so no interrupt driver is needed. sw/baremetal/main.c uses the interrupt.
"""
import argparse
import mmap
import os
import random
import struct
import sys
import time
from pathlib import Path

REG_BASE, REG_SPAN = 0xA0000000, 0x1000
IMEM_BASE, IMEM_BYTES = 0xA0010000, 16 * 1024
DMEM_BASE, DMEM_BYTES = 0xA0020000, 64 * 1024

CTRL, STATUS, CYCLES, PC = 0x00, 0x04, 0x08, 0x0C
MTILEM, MTILEN, MTILEK, MDONE = 0x10, 0x14, 0x18, 0x1C
MSEL, MDATA, ID, IRQ_EN = 0x20, 0x24, 0x28, 0x2C
IRQ_STATUS, EXIT_CODE, MAX_CYCLES, CONFIG = 0x30, 0x34, 0x38, 0x3C
ID_VALUE = 0x4B4C544E          # "KLTN"
ST_RUNNING, ST_HALTED, ST_MBUSY, ST_MDONE, ST_TIMEOUT, ST_EXIT = (1 << i for i in range(6))

TR0, TR1, TR2, TR3, ACC0, ACC1, ACC2, ACC3 = range(8)
JAL_SELF = 0x0000006F


# ------------------------------------------------------------------ bus access
class DevMem:
    """One /dev/mem window, 32-bit accesses (uncached: O_SYNC)."""

    def __init__(self, base, span):
        fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        try:
            self.m = mmap.mmap(fd, span, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
        finally:
            os.close(fd)
        self.w32 = memoryview(self.m).cast("I")

    def read(self, off):
        return self.w32[off >> 2]

    def write(self, off, val):
        self.w32[off >> 2] = val & 0xFFFFFFFF


class PynqMem:
    def __init__(self, base, span):
        from pynq import MMIO
        self.m = MMIO(base, span)

    def read(self, off):
        return self.m.read(off)

    def write(self, off, val):
        self.m.write(off, val & 0xFFFFFFFF)


class Soc:
    def __init__(self, bus_cls, mhz):
        self.reg = bus_cls(REG_BASE, REG_SPAN)
        self.imem = bus_cls(IMEM_BASE, IMEM_BYTES)
        self.dmem = bus_cls(DMEM_BASE, DMEM_BYTES)
        self.mhz = mhz
        self.check_ident()

    def check_ident(self):
        ident = self.r(ID)
        if ident != ID_VALUE:
            raise RuntimeError(f"ID = 0x{ident:08x}: not rv32if_xif_soc (bitstream not loaded?)")
        cfg = self.r(CONFIG)
        if cfg & 0xFF != 2 or not cfg >> 24 & 1:
            raise RuntimeError(f"CONFIG = 0x{cfg:08x}: expected version 2 with CV-X-IF")
        if 1 << (cfg >> 8 & 0xFF) != IMEM_BYTES or 1 << (cfg >> 16 & 0xFF) != DMEM_BYTES:
            raise RuntimeError(f"CONFIG = 0x{cfg:08x}: IMEM/DMEM size differs from this script "
                               f"({IMEM_BYTES} / {DMEM_BYTES} bytes)")

    def r(self, off):
        return self.reg.read(off)

    def w(self, off, val):
        self.reg.write(off, val)

    def stop(self):
        self.w(CTRL, 0)

    def load(self, words):
        """words: {word index: value}. IMEM gets the indexes below its size, DMEM all of them;
        every other word of both memories is set to 0, so each run starts from the same state."""
        top = max(words, default=-1)
        if 4 * top >= DMEM_BYTES:
            raise ValueError(f"image reaches 0x{4 * top:x}, beyond the {DMEM_BYTES // 1024} KB DMEM")
        self.stop()
        for i in range(IMEM_BYTES // 4):
            self.imem.write(4 * i, words.get(i, 0))
        for i in range(DMEM_BYTES // 4):
            self.dmem.write(4 * i, words.get(i, 0))
        for i, v in words.items():
            got = self.imem.read(4 * i) if 4 * i < IMEM_BYTES else v
            if got != v or self.dmem.read(4 * i) != v:
                raise RuntimeError(f"read-back mismatch at 0x{4 * i:x}: AXI BRAM path broken?")

    def run(self, max_cycles):
        """RUN 0 -> 1 with the watchdog at max_cycles; wait for IRQ_STATUS (done or timeout).
        Returns a dict of the result registers; the core stays out of reset (RUN = 1) so MREG
        can still be read. Call stop() afterwards."""
        self.stop()
        self.w(IRQ_EN, 0)                     # polling: the irq line stays low
        self.w(MAX_CYCLES, max_cycles)
        self.w(CTRL, 1)                       # clears CYCLES, MDONE_CNT, IRQ_STATUS, EXIT_CODE
        limit = time.time() + 1.0 + 2.0 * max_cycles / (self.mhz * 1e6)
        while True:
            st = self.r(IRQ_STATUS)
            if st:
                break
            if time.time() > limit:
                raise TimeoutError(f"no done/timeout after {max_cycles} cycles: PC=0x{self.r(PC):08x} "
                                   f"STATUS=0x{self.r(STATUS):x} CYCLES={self.r(CYCLES)}")
        self.w(IRQ_STATUS, st)                # W1C
        res = {"irq_status": st, "status": self.r(STATUS), "cycles": self.r(CYCLES), "pc": self.r(PC),
               "mdone": self.r(MDONE), "exit_code": self.r(EXIT_CODE)}
        res["done"] = bool(st & 1)
        res["timeout"] = bool(st & 2)
        return res

    def mreg_read(self, reg, row, beat):
        self.w(MSEL, (beat << 16) | (row << 8) | reg)
        return self.r(MDATA)


def show(res, mhz):
    s = res["status"]
    flags = [n for b, n in ((ST_RUNNING, "running"), (ST_HALTED, "halted"), (ST_MBUSY, "matrix_busy"),
                            (ST_MDONE, "matrix_done"), (ST_TIMEOUT, "timeout"), (ST_EXIT, "exit")) if s & b]
    us = res["cycles"] / mhz
    print(f"  {'done' if res['done'] else 'TIMEOUT'}: CYCLES {res['cycles']} (~{us:.2f} us at {mhz:g} MHz), "
          f"PC 0x{res['pc']:08x}, MDONE_CNT {res['mdone']}, EXIT_CODE 0x{res['exit_code']:08x}, "
          f"STATUS {'|'.join(flags)}")


# ------------------------------------------------------------------ encoders (fpga/kr260/tb/rv32if_asm.svh)
OPC_MATRIX = 0b0101011


def e_addi(rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13


def e_lui(rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37


def e_lw(rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x03


def e_sw(rs2, rs1, imm):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (2 << 12) | ((imm & 0x1F) << 7) | 0x23


def li(rd, v):
    hi = (v + 0x800) >> 12
    lo = v & 0xFFF
    return [e_lui(rd, hi), e_addi(rd, rd, lo - 0x1000 if lo & 0x800 else lo)]


def enc_cfg(func4, uimm10):
    return (func4 << 28) | ((uimm10 & 0x3FF) << 15) | OPC_MATRIX


def enc_ls(func4, is_store, rs2, rs1, d_size, md):
    return ((func4 << 28) | (0b01 << 26) | (is_store << 25) | (rs2 << 20) | (rs1 << 15)
            | (d_size << 10) | (md << 7) | OPC_MATRIX)


def enc_mma(func4, size_sup, ms2, s_size, ms1, d_size, md):
    return ((func4 << 28) | (0b10 << 26) | (size_sup << 23) | (ms2 << 20) | (s_size << 18)
            | (ms1 << 15) | (d_size << 10) | (md << 7) | OPC_MATRIX)


# ------------------------------------------------------------------ demo: GEMM int8 4x4x16
A_AD, B_AD, C_AD, D_AD, FLAG_AD, TOHOST = 0x000, 0x040, 0x080, 0x0C0, 0x3F0, 0x3FF0


def demo_program():
    p = li(10, A_AD) + li(11, B_AD) + li(12, C_AD) + li(13, D_AD)
    p += [e_addi(14, 0, 16),
          enc_cfg(0b0010, 4), enc_cfg(0b0011, 4), enc_cfg(0b0001, 16),       # msettile m, n, k
          enc_ls(0b0000, 0, 14, 10, 0b00, TR0),                              # mlae8  tr0, (x10), x14
          enc_ls(0b0001, 0, 14, 11, 0b00, TR1),                              # mlbe8  tr1, (x11), x14
          enc_ls(0b0010, 0, 14, 12, 0b10, ACC0),                             # mlce32 acc0, (x12), x14
          enc_mma(0b0001, 0b011, TR1, 0b00, TR0, 0b10, ACC0),                # mmacc.w.b acc0, tr1, tr0
          enc_ls(0b0010, 1, 14, 13, 0b10, ACC0),                             # msce32 acc0, (x13), x14
          e_lw(20, 13, 0),                                                   # lw right after the matrix store
          e_addi(20, 20, 1),
          e_sw(20, 0, FLAG_AD),                                              # DMEM[0x3F0] = D[0][0] + 1
          e_addi(21, 0, 1)]
    p += li(22, TOHOST) + [e_sw(21, 22, 0),                                  # TOHOST = 1 -> EXIT_CODE
                           JAL_SELF]
    return p, 8                                                              # 8 matrix instructions


def s8(b):
    return b - 256 if b & 0x80 else b


def demo(soc, runs, seed, max_cycles):
    rng = random.Random(seed)
    prog, n_mx = demo_program()
    errors = 0
    for run in range(runs):
        A = [[rng.randrange(256) for _ in range(16)] for _ in range(4)]
        B = [[rng.randrange(256) for _ in range(16)] for _ in range(4)]
        A[0][0] = B[0][0] = 0x80                                             # -128 * -128
        C = [[rng.randrange(1 << 24) for _ in range(4)] for _ in range(4)]
        exp = [[(C[i][j] + sum(s8(A[i][k]) * s8(B[j][k]) for k in range(16))) & 0xFFFFFFFF
                for j in range(4)] for i in range(4)]
        words = {i: w for i, w in enumerate(prog)}
        dwords = {}
        for r in range(4):
            for b in range(4):
                dwords[(A_AD + 16 * r + 4 * b) >> 2] = int.from_bytes(bytes(A[r][4 * b:4 * b + 4]), "little")
                dwords[(B_AD + 16 * r + 4 * b) >> 2] = int.from_bytes(bytes(B[r][4 * b:4 * b + 4]), "little")
                dwords[(C_AD + 16 * r + 4 * b) >> 2] = C[r][b]
        # program and data share word indexes 0.. in this demo: IMEM gets the program, DMEM the data
        soc.load({})
        for i, w in words.items():
            soc.imem.write(4 * i, w)
        for i, w in dwords.items():
            soc.dmem.write(4 * i, w)

        res = soc.run(max_cycles)
        print(f"run {run + 1}/{runs}:")
        show(res, soc.mhz)
        bad = []

        def check(what, got, want):
            if got != want:
                bad.append(f"{what}: 0x{got:08x}, expected 0x{want:08x}")

        check("IRQ_STATUS (done)", res["irq_status"], 1)
        check("STATUS running|halted|matrix_done|exit", res["status"] & 0x3F,
              ST_RUNNING | ST_HALTED | ST_MDONE | ST_EXIT)
        check("MDONE_CNT", res["mdone"], n_mx)
        check("EXIT_CODE", res["exit_code"], 1)
        jal = 4 * (len(prog) - 1)
        if not 0 <= res["pc"] - jal <= 12:     # continuous fetch runs up to 3 words past the jal
            bad.append(f"PC 0x{res['pc']:08x}, expected jal x0,0 at 0x{jal:x} + 0..12")
        check("MTILEM", soc.r(MTILEM), 4)
        check("MTILEN", soc.r(MTILEN), 4)
        check("MTILEK", soc.r(MTILEK), 16)
        check("IRQ_STATUS after W1C", soc.r(IRQ_STATUS), 0)
        for i in range(4):
            for j in range(4):
                check(f"acc0[{i}][{j}] (MREG, RUN = 1)", soc.mreg_read(ACC0, i, j), exp[i][j])
                check(f"D[{i}][{j}] (DMEM)", soc.dmem.read(D_AD + 16 * i + 4 * j), exp[i][j])
        check("DMEM[0x3F0] = D[0][0] + 1", soc.dmem.read(FLAG_AD), (exp[0][0] + 1) & 0xFFFFFFFF)
        cyc = res["cycles"]
        soc.stop()
        check("CYCLES kept after RUN = 0", soc.r(CYCLES), cyc)
        for b in bad:
            print("  [FAIL]", b)
        errors += len(bad)
    print("RESULT:", "PASS" if errors == 0 else f"FAIL ({errors} errors)")
    return errors == 0


# ------------------------------------------------------------------ program images
def read_image(path):
    """objcopy -O verilog (--verilog-data-width=1, @ = byte address) or one 32-bit word per line
    (@ = word address, as $readmemh). Returns {word index: value}."""
    data, addr, unit = {}, 0, None
    for line in Path(path).read_text().splitlines():
        for tok in line.split("//")[0].split():
            if tok.startswith("@"):
                addr = int(tok[1:], 16)
                continue
            if unit is None:
                unit = 1 if len(tok) <= 2 else 4
            v = int(tok, 16)
            for b in range(unit):
                data[addr * unit + b] = v >> (8 * b) & 0xFF
            addr += 1
    words = {}
    for a, v in data.items():
        words[a >> 2] = words.get(a >> 2, 0) | v << (8 * (a & 3))
    return words


def read_golden(path):
    """STATE mem<addr> <value> and MATRIX_REGRESS_DONE cycles=<n> from tb_matrix_regress."""
    mem, cycles = {}, None
    for line in Path(path).read_text(errors="replace").splitlines():
        if line.startswith("STATE mem"):
            a, v = line[9:].split()
            mem[int(a, 16)] = int(v, 16)
        elif line.startswith("MATRIX_REGRESS_DONE"):
            kv = dict(x.split("=") for x in line.split()[1:])
            cycles = int(kv.get("cycles", 0))
    return mem, cycles


def run_image(soc, image, golden, dump, max_cycles, name=None):
    words = read_image(image)
    print(f"{name or image}: {len(words)} words, up to 0x{4 * max(words):x}")
    soc.load(words)
    res = soc.run(max_cycles)
    show(res, soc.mhz)
    ok = res["done"]
    if not res["done"]:
        print("  [FAIL] watchdog: program did not reach jal x0,0")
    if golden:
        mem, sim_cycles = read_golden(golden)
        board = {a: soc.dmem.read(a) for a in mem}
        bad = [(a, board[a], v) for a, v in sorted(mem.items()) if board[a] != v]
        print(f"  DMEM vs simulation: {len(mem) - len(bad)}/{len(mem)} words equal"
              + (f" (simulation: {sim_cycles} cycles up to the TOHOST store)" if sim_cycles is not None else ""))
        for a, got, want in bad[:8]:
            print(f"  [FAIL] 0x{a:04x}: board 0x{got:08x}, simulation 0x{want:08x}")
        ok = ok and not bad and bool(mem)
        if not mem:
            print("  [FAIL] no STATE mem lines in", golden)
    if dump:
        lo, hi = (int(x, 0) for x in dump.split(":"))
        for a in range(lo & ~3, hi, 4):
            print(f"  0x{a:04x}: {soc.dmem.read(a):08x}")
    soc.stop()
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bit", help="load this bitstream with PYNQ (Overlay) and use PYNQ MMIO")
    ap.add_argument("--image", help="program image (see above)")
    ap.add_argument("--golden", help="tb_matrix_regress log (sim.log) to compare DMEM with")
    ap.add_argument("--dump", help="DMEM byte range lo:hi to print after --image")
    ap.add_argument("--case", nargs="+", help="directories with mem.hex + sim.log")
    ap.add_argument("--runs", type=int, default=5, help="demo: number of data sets (default 5)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--max-cycles", type=lambda s: int(s, 0), default=200_000_000,
                    help="watchdog MAX_CYCLES (default 200000000 = 2 s at 100 MHz)")
    ap.add_argument("--mhz", type=float, default=100.0, help="pl_clk0 (for the host-side time limit)")
    a = ap.parse_args()

    bus = DevMem
    if a.bit:
        from pynq import Overlay
        Overlay(a.bit)
        bus = PynqMem
    soc = Soc(bus, a.mhz)

    if a.case:
        results = []
        for d in a.case:
            d = Path(d)
            results.append((d.name, run_image(soc, d / "mem.hex", d / "sim.log", None, a.max_cycles, d.name)))
        print()
        for n, ok in results:
            print(f"{n:16s} {'PASS' if ok else 'FAIL'}")
        fails = sum(not ok for _, ok in results)
        print("RESULT:", "PASS" if not fails else f"FAIL ({fails} of {len(results)})")
        sys.exit(1 if fails else 0)
    if a.image:
        sys.exit(0 if run_image(soc, a.image, a.golden, a.dump, a.max_cycles) else 1)
    sys.exit(0 if demo(soc, a.runs, a.seed, a.max_cycles) else 1)


if __name__ == "__main__":
    main()
