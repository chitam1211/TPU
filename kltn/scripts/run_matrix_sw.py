#!/usr/bin/env python3
"""Matrix software test: C programs using sw/matrix (matrix.h + tiled matmul_i8 / matmul_f32),
compiled with the stock riscv64-unknown-elf GCC, run on tb/matrix/tb_matrix_regress.sv.

Each case builds A (M x K) and B (K x N) at random, compiles a small main() calling the tiled
routine, runs it, and compares C in the dumped RAM with Python:
  int8 -> int32  exact integer product (mmacc.w.b, both signed);
  fp32           bit-exact model of the hardware: per 4-wide K chunk, column j adds the
                 products in order k = j, j+1, j+2, j+3 (mod 4) with one FMA rounding each
                 (round to nearest even), starting from the accumulator value.

Usage (WSL, from kltn/):
  python3 scripts/run_matrix_sw.py              # all cases
  python3 scripts/run_matrix_sw.py i8_8x8x8 f32_10x10x10
  python3 scripts/run_matrix_sw.py --dut core_matrix_xif --core uut.u_core --extra 'rtl/xif/*'
Results: reports/matrix_sw/results_<tag>.csv; programs and logs in sim/build/matrix_sw/<tag>/.
"""
import argparse
import csv
import glob
import random
import shutil
import struct
import subprocess
import sys
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from run_matrix_regress import sources  # noqa: E402

SW = ROOT / "sw" / "matrix"
TOOL = "riscv64-unknown-elf-"
CFLAGS = ["-march=rv32i", "-mabi=ilp32", "-O2", "-ffreestanding", "-nostdlib", "-nostartfiles",
          "-mno-relax", "-Wall", "-Wextra", "-Werror"]

# name: (type, M, N, K)
CASES = {
    "i8_user4x4":   ("i8", 4, 4, 4),     # the 4x4 example from the discussion
    "i8_8x8x8":     ("i8", 8, 8, 8),
    "i8_10x10x10":  ("i8", 10, 10, 10),
    "i8_6x9x7":     ("i8", 6, 9, 7),
    "i8_5x3x20":    ("i8", 5, 3, 20),    # K > 16: two K chunks
    "i8_8x8x33":    ("i8", 8, 8, 33),    # three K chunks, short tail
    "f32_4x4x4":    ("f32", 4, 4, 4),
    "f32_8x8x8":    ("f32", 8, 8, 8),
    "f32_10x10x10": ("f32", 10, 10, 10),
    "f32_5x7x9":    ("f32", 5, 7, 9),
}
USER_A = [[2, 3, 4, 5], [2, 3, 2, 3], [1, 2, 3, 4], [2, 3, 4, 5]]
USER_B = [[2, 3, 2, 5], [2, 3, 2, 3], [2, 2, 3, 5], [2, 3, 4, 5]]


# ---------- fp32 helpers ----------
def f2b(x):
    return struct.unpack("<I", struct.pack("<f", x))[0]


def b2frac(b):
    return Fraction(struct.unpack("<f", struct.pack("<I", b))[0])


def frac_to_f32(x, neg_zero=False):
    """Round an exact rational to fp32 bits, round to nearest even (finite inputs only)."""
    if x == 0:
        return 0x80000000 if neg_zero else 0
    sign = 0x80000000 if x < 0 else 0
    x = abs(x)
    e = x.numerator.bit_length() - x.denominator.bit_length()
    if Fraction(2) ** e > x:
        e -= 1
    e = max(e, -126)                                  # subnormal range keeps e = -126
    q = x / Fraction(2) ** (e - 23)
    m = q.numerator // q.denominator
    rem = q - m
    if rem > Fraction(1, 2) or (rem == Fraction(1, 2) and m & 1):
        m += 1
    if m == 1 << 24:
        m, e = 1 << 23, e + 1
    if e > 127:
        return sign | 0x7F800000
    if m < 1 << 23:
        return sign | m                               # subnormal
    return sign | ((e + 127) << 23) | (m - (1 << 23))


def fma32(a, b, c):
    """fp32 a*b + c with one rounding (a, b, c bit patterns, finite)."""
    exact = b2frac(a) * b2frac(b) + b2frac(c)
    if exact == 0:
        psign = ((a ^ b) >> 31) & 1
        csign = (c >> 31) & 1
        return frac_to_f32(exact, neg_zero=bool(psign and csign))
    return frac_to_f32(exact)


def ref_f32(A, B, M, N, K):
    C = [[0] * N for _ in range(M)]
    for i in range(M):
        for j in range(N):
            acc = 0                                   # mzero: +0.0
            for kb in range(0, K, 4):
                kt = min(4, K - kb)
                for r in range(4):                    # PE rows of column j % 4
                    kl = ((j % 4) + r) % 4
                    if kl < kt:
                        acc = fma32(A[i][kb + kl], B[kb + kl][j], acc)
            C[i][j] = acc
    return C


def ref_i8(A, B, M, N, K):
    return [[sum(A[i][k] * B[k][j] for k in range(K)) & 0xFFFFFFFF for j in range(N)] for i in range(M)]


# ---------- program generation ----------
def c_array(ctype, name, values, align=4):
    body = ", ".join(str(v) if ctype == "int8_t" else f"0x{v:08x}u" for v in values)
    return f"const {ctype} {name}[{len(values)}] __attribute__((aligned({align}))) = {{{body}}};\n"


def make_case(name, rng):
    kind, M, N, K = CASES[name]
    if kind == "i8":
        if name == "i8_user4x4":
            A, B = USER_A, USER_B
        else:
            A = [[rng.randint(-128, 127) for _ in range(K)] for _ in range(M)]
            B = [[rng.randint(-128, 127) for _ in range(N)] for _ in range(K)]
        ld = (K + 3) & ~3                              # word-aligned rows
        expect = ref_i8(A, B, M, N, K)
        ctype, func, ctype_c = "int8_t", "matmul_i8", "int32_t"
    else:
        A = [[f2b(rng.uniform(-4, 4)) for _ in range(K)] for _ in range(M)]
        B = [[f2b(rng.uniform(-4, 4)) for _ in range(N)] for _ in range(K)]
        ld = K
        expect = ref_f32(A, B, M, N, K)
        ctype, func, ctype_c = "uint32_t", "matmul_f32", "uint32_t"
    pad = 0
    a_flat = [A[i][k] if k < K else pad for i in range(M) for k in range(ld)]
    bt_flat = [B[k][j] if k < K else pad for j in range(N) for k in range(ld)]
    src = ["#include <stdint.h>\n",
           f"void {func}(const {ctype} *, const {ctype} *, {ctype_c} *, int, int, int, int);\n",
           c_array(ctype, "A", a_flat), c_array(ctype, "Bt", bt_flat),
           f"{ctype_c} C[{M * N}] __attribute__((aligned(4)));\n",
           f"int main(void) {{ {func}(A, Bt, C, {M}, {N}, {K}, {ld}); return 0; }}\n"]
    return "".join(src), expect, (M, N, K)


def run(cmd, **kw):
    res = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if res.returncode:
        sys.exit(f"command failed: {' '.join(map(str, cmd))}\n{res.stdout}{res.stderr}")
    return res.stdout


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cases", nargs="*", help="case names (default: all)")
    ap.add_argument("--dut", default="core_matrix")
    ap.add_argument("--core", default=None)
    ap.add_argument("--extra", nargs="*", default=[])
    ap.add_argument("--tag", default=None)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    tag = a.tag or a.dut
    work = ROOT / "sim" / "build" / "matrix_sw" / tag
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)

    extra = [str(Path(p).resolve()) for e in a.extra for p in sorted(glob.glob(str(ROOT / e)))]
    sim = work / "tb.out"
    comp = subprocess.run(["iverilog", "-g2012", "-Wno-timescale", f"-DDUT={a.dut}"] +
                          ([f"-DCORE={a.core}"] if a.core else []) + ["-s", "tb_matrix_regress", "-o", str(sim)] +
                          sources(extra), capture_output=True, text=True)
    if comp.returncode:
        sys.exit("testbench compile failed:\n" + comp.stdout + comp.stderr)

    rng = random.Random(a.seed)
    names = a.cases or list(CASES)
    rows, fails = [], 0
    for name in names:
        d = work / name
        d.mkdir()
        src, expect, (M, N, K) = make_case(name, rng)
        (d / "case.c").write_text(src)
        elf = d / "prog.elf"
        run([TOOL + "gcc", *CFLAGS, f"-I{SW}", "-T", str(SW / "link.ld"), str(SW / "start.S"),
             str(SW / "matmul.c"), str(d / "case.c"), "-o", str(elf)])
        run([TOOL + "objcopy", "-O", "verilog", "--verilog-data-width=1", str(elf), str(d / "mem.hex")])
        (d / "prog.dis").write_text(run([TOOL + "objdump", "-d", str(elf)]))
        c_addr = next(int(l.split()[0], 16) for l in run([TOOL + "nm", str(elf)]).splitlines() if l.endswith(" C"))

        res = subprocess.run(["vvp", "-n", str(sim), f"+mem={d / 'mem.hex'}", "+max_cycles=2000000"],
                             capture_output=True, text=True, cwd=d)
        (d / "sim.log").write_text(res.stdout + res.stderr)
        mem, done = {}, None
        for line in res.stdout.splitlines():
            if line.startswith("STATE mem"):
                k, v = line[9:].split()
                mem[int(k, 16)] = int(v, 16)
            elif line.startswith("MATRIX_REGRESS_DONE"):
                done = dict(kv.split("=") for kv in line.split()[1:])
        bad = []
        if done is None:
            bad.append("no MATRIX_REGRESS_DONE: " + ((res.stdout + res.stderr).strip().splitlines() or ["?"])[-1])
        else:
            for i in range(M):
                for j in range(N):
                    got = mem.get(c_addr + 4 * (i * N + j))
                    if got != expect[i][j]:
                        bad.append(f"C[{i}][{j}] got {got if got is None else f'{got:08x}'} expected {expect[i][j]:08x}")
        status = "PASS" if not bad else "FAIL"
        fails += status != "PASS"
        cyc = done["cycles"] if done else ""
        mx = done["matrix_insns"] if done else ""
        print(f"{name:13s} {status}  M,N,K={M},{N},{K}  C words {M * N - len([b for b in bad if b.startswith('C[')])}/{M * N}"
              f"  cycles {cyc}  matrix insns {mx}")
        for b in bad[:6]:
            print("   ", b)
        if name == "i8_user4x4" and done:
            print("    C =", [[mem.get(c_addr + 4 * (i * N + j)) for j in range(N)] for i in range(M)])
        rows.append([name, status, M, N, K, cyc, mx, len(bad)])

    rep = ROOT / "reports" / "matrix_sw"
    rep.mkdir(parents=True, exist_ok=True)
    with open(rep / f"results_{tag}.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["case", "status", "M", "N", "K", "cycles", "matrix_insns", "errors"])
        w.writerows(rows)
    print(f"results : reports/matrix_sw/results_{tag}.csv")
    print("MATRIX_SW_PASS" if not fails else f"MATRIX_SW_FAIL ({fails} of {len(names)})")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
