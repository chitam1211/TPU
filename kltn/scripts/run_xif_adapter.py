#!/usr/bin/env python3
"""CV-X-IF adapter test: rtl/core_if_xif/matrix_xif_adapter.sv + matrix_core_v2 (rtl/matrix_if_xif
copy with mem_ready / mem_last), driven by a behavioural CPU, checked by tb/xif/xif_checker.sv.
See tb/xif/tb_xif_adapter.sv for the program and what is randomised.

Usage (WSL, from kltn/):
  python3 scripts/run_xif_adapter.py                       # seeds 1-5, 40 rounds each
  python3 scripts/run_xif_adapter.py --seeds 1 2 --rounds 100
"""
import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "sim" / "build" / "xif"
# Files of rtl/matrix_if_xif replace the ones of the same name in rtl/matrix_if.
XIF_MATRIX = sorted((ROOT / "rtl" / "matrix_if_xif").glob("*.sv"))


def sources():
    replaced = {p.name for p in XIF_MATRIX}
    matrix = [p for p in sorted((ROOT / "rtl" / "matrix_if").glob("*.sv")) if p.name not in replaced]
    pkg = ROOT / "rtl" / "core_if_xif" / "cvxif_pkg.sv"
    return [str(p) for p in [pkg, *matrix, *XIF_MATRIX, ROOT / "rtl" / "core_if_xif" / "matrix_xif_adapter.sv",
                             ROOT / "tb" / "xif" / "xif_checker.sv", ROOT / "tb" / "xif" / "tb_xif_adapter.sv"]]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seeds", type=int, nargs="*", default=[1, 2, 3, 4, 5])
    ap.add_argument("--rounds", type=int, default=40)
    a = ap.parse_args()
    WORK.mkdir(parents=True, exist_ok=True)
    sim = WORK / "tb_xif_adapter.out"
    res = subprocess.run(["iverilog", "-g2012", "-Wno-timescale", "-s", "tb_xif_adapter", "-o", str(sim)] + sources(),
                         capture_output=True, text=True)
    if res.returncode:
        sys.exit("compile failed:\n" + res.stdout + res.stderr)
    fails = 0
    for s in a.seeds:
        out = subprocess.run(["vvp", "-n", str(sim), f"+rounds={a.rounds}", f"+seed={s}"],
                             capture_output=True, text=True).stdout
        (WORK / f"seed{s}.log").write_text(out)
        lines = out.splitlines()
        ok = any(l.startswith("XIF_ADAPTER_PASS") for l in lines)
        fails += not ok
        summary = next((l for l in lines if l.startswith("XIF_CHECK summary")), "")
        first_err = next((l for l in lines if l.startswith(("FAIL", "XIF_CHECK ")) and "summary" not in l), "")
        print(f"seed {s:3d}: {'PASS' if ok else 'FAIL'}  {summary.replace('XIF_CHECK summary: ', '')}"
              + ("" if ok else f"\n          {first_err}"))
    print(f"logs    : {WORK.relative_to(ROOT)}/seed*.log")
    print("XIF_ADAPTER_ALL_PASS" if not fails else f"XIF_ADAPTER_FAIL ({fails} seeds)")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
