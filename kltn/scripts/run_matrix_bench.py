#!/usr/bin/env python3
"""Speed of C = A * B with the matrix unit versus scalar instructions only.

For each size, one program (sw/matrix: matmul.c, matmul_scalar.c, link_bench.ld) computes the
same product twice on the core + matrix unit (tb/matrix/tb_matrix_regress.sv, DUT core_matrix):
    MARK 1, matmul_<t>(...)  -> Cm, MARK 2, matmul_<t>_scalar(...) -> Cs, MARK 3
The cycles between marks are each version's time. Both results are checked bit for bit against
Python: Cm with the matrix-unit order (as scripts/run_matrix_sw.py), Cs with the scalar order
(fp32: one FMA per product, k = 0 .. K-1 from +0.0; int8: exact sum).
The scalar version alone is also timed on the current core without the matrix unit
(rtl/core_if, tb/core_if/tb_act4_unified.v), because core_matrix keeps its own older pipeline.

Usage (WSL, from kltn/):
  python3 scripts/run_matrix_bench.py                 # i8 and f32 at 4, 8, 16
  python3 scripts/run_matrix_bench.py --sizes 4 8 16 32 --types f32
Results: reports/matrix_bench/results.csv; programs and logs in sim/build/matrix_bench/.
"""
import argparse
import csv
import random
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from run_matrix_regress import sources  # noqa: E402
from run_matrix_sw import f2b, fma32, ref_f32, ref_i8  # noqa: E402

SW = ROOT / "sw" / "matrix"
WORK = ROOT / "sim" / "build" / "matrix_bench"
TOOL = "riscv64-unknown-elf-"
CFLAGS = ["-march=rv32if", "-mabi=ilp32f", "-O2", "-ffreestanding", "-nostdlib", "-nostartfiles",
          "-mno-relax", "-Wall", "-Wextra", "-Werror"]
MAX_CYCLES = 100_000_000


def ref_f32_scalar(A, B, M, N, K):
    C = [[0] * N for _ in range(M)]
    for i in range(M):
        for j in range(N):
            acc = 0
            for k in range(K):
                acc = fma32(A[i][k], B[k][j], acc)
            C[i][j] = acc
    return C


def run(cmd, **kw):
    res = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if res.returncode:
        sys.exit(f"command failed: {' '.join(map(str, cmd))}\n{res.stdout}{res.stderr}")
    return res.stdout


def program(kind, M, N, K, A, B, scalar_only):
    ld = (K + 3) & ~3 if kind == "i8" else K
    a_flat = [A[i][k] if k < K else 0 for i in range(M) for k in range(ld)]
    bt_flat = [B[k][j] if k < K else 0 for j in range(N) for k in range(ld)]
    if kind == "i8":
        et, ct, st, sct, cast = "int8_t", "int32_t", "int8_t", "int32_t", ""
        fmt = str
    else:   # fp32 data as bit patterns; the scalar routine reads the same words as float
        et, ct, st, sct, cast = "uint32_t", "uint32_t", "float", "float", "(const float *)"
        fmt = lambda v: f"0x{v:08x}u"  # noqa: E731
    out_cast = "(float *)" if kind == "f32" else ""
    return "".join([
        "#include <stdint.h>\n",
        "#define MARK(v) (*(volatile uint32_t *)0x3FE0 = (v))\n",
        f"void matmul_{kind}(const {et} *, const {et} *, {ct} *, int, int, int, int);\n",
        f"void matmul_{kind}_scalar(const {st} *, const {st} *, {sct} *, int, int, int, int);\n",
        f"const {et} A[{len(a_flat)}] __attribute__((aligned(4))) = {{{', '.join(map(fmt, a_flat))}}};\n",
        f"const {et} Bt[{len(bt_flat)}] __attribute__((aligned(4))) = {{{', '.join(map(fmt, bt_flat))}}};\n",
        f"{ct} Cm[{M * N}] __attribute__((aligned(4)));\n",
        f"{ct} Cs[{M * N}] __attribute__((aligned(4)));\n",
        "int main(void) {\n    MARK(1);\n",
        "" if scalar_only else f"    matmul_{kind}(A, Bt, Cm, {M}, {N}, {K}, {ld});\n",
        "    MARK(2);\n",
        f"    matmul_{kind}_scalar({cast}A, {cast}Bt, {out_cast}Cs, {M}, {N}, {K}, {ld});\n",
        "    MARK(3);\n    return 0;\n}\n"])


def build(d, name, src):
    (d / f"{name}.c").write_text(src)
    elf = d / f"{name}.elf"
    run([TOOL + "gcc", *CFLAGS, f"-I{SW}", "-T", str(SW / "link_bench.ld"), str(SW / "start.S"),
         str(SW / "matmul.c"), str(SW / "matmul_scalar.c"), str(d / f"{name}.c"), "-lgcc", "-o", str(elf)])
    run([TOOL + "objcopy", "-O", "verilog", "--verilog-data-width=1", str(elf), str(d / f"{name}.hex")])
    (d / f"{name}.dis").write_text(run([TOOL + "objdump", "-d", str(elf)]))
    syms = {l.split()[2]: int(l.split()[0], 16) for l in run([TOOL + "nm", str(elf)]).splitlines() if len(l.split()) == 3}
    return d / f"{name}.hex", syms


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sizes", type=int, nargs="*", default=[4, 8, 16], help="square sizes M = N = K")
    ap.add_argument("--types", nargs="*", default=["i8", "f32"], choices=["i8", "f32"])
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    shutil.rmtree(WORK, ignore_errors=True)
    WORK.mkdir(parents=True)

    sim_mx = WORK / "tb_matrix.out"
    res = subprocess.run(["iverilog", "-g2012", "-Wno-timescale", "-DDUT=core_matrix", "-s", "tb_matrix_regress",
                          "-o", str(sim_mx)] + sources([]), capture_output=True, text=True)
    if res.returncode:
        sys.exit("tb_matrix_regress compile failed:\n" + res.stdout + res.stderr)
    sim_core = WORK / "tb_core.out"
    core_src = sorted(str(p) for p in (ROOT / "rtl" / "core_if").glob("*.v"))
    run(["iverilog", "-g2012", "-Wno-timescale", "-s", "tb_act4_unified", "-o", str(sim_core),
         *core_src, str(ROOT / "tb" / "core_if" / "tb_act4_unified.v")])

    rng = random.Random(a.seed)
    rows, fails = [], 0
    print(f"{'case':10s} {'matrix':>10s} {'scalar':>10s} {'speedup':>8s} | {'scalar new core':>15s} {'speedup':>8s} | check")
    for kind in a.types:
        for n in a.sizes:
            M = N = K = n
            name = f"{kind}_{n}"
            d = WORK / name
            d.mkdir()
            if kind == "i8":
                A = [[rng.randint(-128, 127) for _ in range(K)] for _ in range(M)]
                B = [[rng.randint(-128, 127) for _ in range(N)] for _ in range(K)]
                exp_m = exp_s = ref_i8(A, B, M, N, K)
            else:
                A = [[f2b(rng.uniform(-4, 4)) for _ in range(K)] for _ in range(M)]
                B = [[f2b(rng.uniform(-4, 4)) for _ in range(N)] for _ in range(K)]
                exp_m = ref_f32(A, B, M, N, K)
                exp_s = ref_f32_scalar(A, B, M, N, K)

            # Matrix + scalar on core_matrix, results checked.
            hexf, syms = build(d, "bench", program(kind, M, N, K, A, B, False))
            lo, hi = min(syms["Cm"], syms["Cs"]), max(syms["Cm"], syms["Cs"]) + 4 * M * N
            out = subprocess.run(["vvp", "-n", str(sim_mx), f"+mem={hexf}", f"+max_cycles={MAX_CYCLES}",
                                  f"+dump_lo={lo:x}", f"+dump_hi={hi:x}"], capture_output=True, text=True, cwd=d)
            (d / "bench.log").write_text(out.stdout + out.stderr)
            marks = {int(l.split()[1]): int(l.split()[2]) for l in out.stdout.splitlines() if l.startswith("MARK ")}
            mem = {int(l[9:].split()[0], 16): int(l[9:].split()[1], 16)
                   for l in out.stdout.splitlines() if l.startswith("STATE mem")}
            done = next((l for l in out.stdout.splitlines() if l.startswith("MATRIX_REGRESS_DONE")), None)
            bad = []
            if done is None or len(marks) != 3:
                bad.append("did not finish: " + ((out.stdout + out.stderr).strip().splitlines() or ["?"])[-1])
            else:
                for arr, exp in (("Cm", exp_m), ("Cs", exp_s)):
                    for i in range(M):
                        for j in range(N):
                            got = mem.get(syms[arr] + 4 * (i * N + j))
                            if got != exp[i][j]:
                                bad.append(f"{arr}[{i}][{j}] got {got} expected {exp[i][j]:08x}")
            cyc_m = marks.get(2, 0) - marks.get(1, 0)
            cyc_s = marks.get(3, 0) - marks.get(2, 0)

            # Scalar alone on the current core (no matrix unit).
            hexs, syms_s = build(d, "scalar", program(kind, M, N, K, A, B, True))
            out = subprocess.run(["vvp", "-n", str(sim_core), f"+mem={hexs}", "+tohost=3ff0",
                                  f"+max_cycles={MAX_CYCLES}"], capture_output=True, text=True, cwd=d)
            (d / "scalar.log").write_text(out.stdout + out.stderr)
            # Whole program (start-up + scalar call): the start-up is a few cycles of thousands.
            cyc_new = next((int(l.split("cycles=")[1]) for l in out.stdout.splitlines() if "ACT4_RTL_PASS" in l), None)

            status = "PASS" if not bad else "FAIL"
            fails += status != "PASS"
            sp = cyc_s / cyc_m if cyc_m else 0
            sp_new = cyc_new / cyc_m if cyc_m and cyc_new else 0
            print(f"{name:10s} {cyc_m:10d} {cyc_s:10d} {sp:7.1f}x | {cyc_new or 0:15d} {sp_new:7.1f}x | {status}"
                  + ("" if not bad else "  " + bad[0]))
            rows.append([kind, n, n, n, cyc_m, cyc_s, f"{sp:.2f}", cyc_new, f"{sp_new:.2f}", n ** 3, status])

    rep = ROOT / "reports" / "matrix_bench"
    rep.mkdir(parents=True, exist_ok=True)
    with open(rep / "results.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["type", "M", "N", "K", "matrix_cycles", "scalar_cycles_core_matrix", "speedup",
                    "scalar_cycles_core_if", "speedup_vs_core_if", "macs", "check"])
        w.writerows(rows)
    print("results : reports/matrix_bench/results.csv")
    print("MATRIX_BENCH_PASS" if not fails else f"MATRIX_BENCH_FAIL ({fails})")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
