#!/usr/bin/env python3
"""Matrix regression: run the programs of gen_matrix_regress.py on tb/matrix/tb_matrix_regress.sv.

Each case is checked two ways:
  expect  words in expect.txt (values that follow from simple integer rules) must be in RAM;
  golden  the final state (GPR, FPR, matrix registers, tile CSRs, RAM 0x1000-0x3FEF) and the
          retired instruction sequence must equal tb/matrix/golden/<case>/, recorded from the
          design before the CV-X-IF change. Cycle counts are reported, not required to match.

Usage (WSL, from kltn/):
  python3 scripts/run_matrix_regress.py --record          # current design -> golden (baseline)
  python3 scripts/run_matrix_regress.py                   # compare with the golden
  python3 scripts/run_matrix_regress.py --dut core_matrix_xif --core uut.u_core --extra 'rtl/xif/*' --tag xif
Results: reports/matrix_regress/results_<tag>.csv, logs in sim/build/matrix_regress/<tag>/.
"""
import argparse
import csv
import glob
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GOLDEN = ROOT / "tb" / "matrix" / "golden"


def sources(extra):
    core = [p for p in sorted(glob.glob(str(ROOT / "rtl/core_if/*.v"))) if not p.endswith("Microprocessor.v")]
    mx = [str(ROOT / "rtl/matrix_if/fp32_fma_pkg.sv")]
    mx += [p for p in sorted(glob.glob(str(ROOT / "rtl/matrix_if/*.sv"))) if not p.endswith("fp32_fma_pkg.sv")]
    return core + mx + [str(ROOT / "rtl/matrix_if/core_matrix.v")] + extra + [str(ROOT / "tb/matrix/tb_matrix_regress.sv")]


def parse(log):
    state, retire, done = [], [], None
    for line in log.splitlines():
        if line.startswith("STATE "):
            state.append(line[6:])
        elif line.startswith("RETIRE "):
            _, cyc, pc, insn = line.split()
            retire.append((int(cyc), pc, insn))
        elif line.startswith("MATRIX_REGRESS_DONE"):
            done = dict(kv.split("=") for kv in line.split()[1:])
    return state, retire, done


def check_expect(case_dir, state):
    mem = {}
    for s in state:
        key, val = s.split()
        if key.startswith("mem"):
            mem[int(key[3:], 16)] = int(val, 16)
    bad, total = [], 0
    for line in (case_dir / "expect.txt").read_text().splitlines():
        addr, val, note = line.split(" ", 2)
        total += 1
        got = mem.get(int(addr, 16))
        if got != int(val, 16):
            bad.append(f"  {addr}: got {got if got is None else f'{got:08x}'}, expected {val} ({note})")
    return total, bad


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cases", nargs="*", help="case names (default: all)")
    ap.add_argument("--dut", default="core_matrix")
    ap.add_argument("--core", default=None, help="hierarchy of the pipeline inside the DUT (default: the DUT)")
    ap.add_argument("--extra", nargs="*", default=[], help="extra RTL files (e.g. the XIF modules)")
    ap.add_argument("--tag", default=None, help="result name (default: the DUT name)")
    ap.add_argument("--record", action="store_true", help="write the golden from this run")
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    tag = a.tag or a.dut
    work = ROOT / "sim" / "build" / "matrix_regress" / tag
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)

    subprocess.run([sys.executable, str(ROOT / "scripts/gen_matrix_regress.py"), str(work / "cases"),
                    "--seed", str(a.seed)], check=True, stdout=subprocess.DEVNULL)
    sim = work / "tb.out"
    extra = [str(Path(p).resolve()) for e in a.extra for p in sorted(glob.glob(str(ROOT / e) if not Path(e).is_absolute() else e))]
    comp = subprocess.run(["iverilog", "-g2012", "-Wno-timescale", f"-DDUT={a.dut}"] + ([f"-DCORE={a.core}"] if a.core else []) + ["-s", "tb_matrix_regress",
                           "-o", str(sim)] + sources(extra), capture_output=True, text=True)
    noise = ("constant selects", "unique/unique0", "Padding", "expects", "sorry: ")
    msgs = [l for l in (comp.stdout + comp.stderr).splitlines() if not any(n in l for n in noise)]
    if comp.returncode:
        print("\n".join(msgs))
        sys.exit("compile failed")

    names = a.cases or sorted(p.name for p in (work / "cases").iterdir())
    rows, fails = [], 0
    for name in names:
        case = work / "cases" / name
        run = subprocess.run(["vvp", "-n", str(sim), f"+mem={case / 'mem.hex'}"], capture_output=True, text=True,
                             cwd=case)
        (case / "sim.log").write_text(run.stdout + run.stderr)
        state, retire, done = parse(run.stdout)
        status, notes = "PASS", []
        if done is None:
            status = "FAIL"
            notes.append("no MATRIX_REGRESS_DONE: " + ((run.stdout + run.stderr).strip().splitlines() or ["?"])[-1])
            total, bad = 0, []
        else:
            total, bad = check_expect(case, state)
            if bad:
                status = "FAIL"
                notes.append(f"{len(bad)}/{total} expected words differ")
        (case / "state.txt").write_text("\n".join(state) + "\n")
        (case / "retire.txt").write_text("".join(f"{c} {pc} {i}\n" for c, pc, i in retire))
        expect_ok = total - len(bad)
        g = GOLDEN / name
        golden_cycles, state_match, order_match = "", "", ""
        if a.record and done is not None and not bad:
            g.mkdir(parents=True, exist_ok=True)
            shutil.copy(case / "state.txt", g / "state.txt")
            shutil.copy(case / "retire.txt", g / "retire.txt")
            (g / "summary.txt").write_text(f"cycles={done['cycles']} matrix_insns={done['matrix_insns']} "
                                           f"matrix_busy={done['matrix_busy']} dut={a.dut}\n")
        if done is not None and (g / "state.txt").exists():
            gstate = (g / "state.txt").read_text().splitlines()
            gret = [l.split()[1:] for l in (g / "retire.txt").read_text().splitlines()]
            golden_cycles = (g / "summary.txt").read_text().split()[0].split("=")[1]
            diff = [f"  {x} != golden {y}" for x, y in zip(state, gstate) if x != y]
            state_match = "yes" if not diff and len(state) == len(gstate) else "NO"
            order_match = "yes" if [[pc, i] for _, pc, i in retire] == gret else "NO"
            if state_match == "NO" or order_match == "NO":
                status = "FAIL"
                notes.append(f"golden: state {state_match}, retire order {order_match}")
                bad += diff[:20]
        if status == "FAIL":
            fails += 1
        cyc = done["cycles"] if done else ""
        print(f"{name:9s} {status}  expect {expect_ok}/{total}  golden state {state_match or '-'}"
              f"  order {order_match or '-'}  cycles {cyc}" + (f" (golden {golden_cycles})" if golden_cycles else "")
              + ("  " + "; ".join(notes) if notes else ""))
        for b in bad[:10]:
            print(b)
        rows.append([name, status, total, expect_ok, state_match, order_match, cyc,
                     golden_cycles, done["matrix_insns"] if done else "", done["matrix_busy"] if done else ""])

    rep = ROOT / "reports" / "matrix_regress"
    rep.mkdir(parents=True, exist_ok=True)
    out = rep / f"results_{tag}.csv"
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["case", "status", "expect_total", "expect_ok", "golden_state", "golden_order", "cycles",
                    "golden_cycles", "matrix_insns", "matrix_busy_cycles"])
        w.writerows(rows)
    print(f"results : {out.relative_to(ROOT)}")
    if a.record:
        print(f"golden  : {GOLDEN.relative_to(ROOT)}/ (recorded for the cases that passed their expect checks)")
    print("MATRIX_REGRESS_PASS" if fails == 0 else f"MATRIX_REGRESS_FAIL ({fails} of {len(names)})")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
