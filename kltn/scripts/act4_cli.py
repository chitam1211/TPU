#!/usr/bin/env python3
"""Short command for the ACT4 tests supported by this RTL checkpoint."""

import argparse
import csv
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from run_act4_rtl import IMPLEMENTED_TESTS


ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts" / "run_act4_rtl.py"
SPEC_MNEMONICS = (
    "flw", "fsw", "fadd.s", "fsub.s", "fmul.s", "fdiv.s", "fsqrt.s",
    "fmadd.s", "fmsub.s", "fnmsub.s", "fnmadd.s", "fmin.s", "fmax.s",
    "fsgnj.s", "fsgnjn.s", "fsgnjx.s", "feq.s", "flt.s", "fle.s",
    "fcvt.w.s", "fcvt.wu.s", "fcvt.s.w", "fcvt.s.wu", "fmv.x.w",
    "fmv.w.x", "fclass.s",
)


def mnemonic(name):
    return name[2:].rsplit("-", 1)[0]


def select_tests(target):
    if target.lower() == "all":
        return list(IMPLEMENTED_TESTS)
    target = target.lower()
    exact = [name for name in IMPLEMENTED_TESTS if name.lower() == target]
    if exact:
        return exact
    if target.startswith("f-"):
        target = target[2:]
    return [name for name in IMPLEMENTED_TESTS if mnemonic(name).lower() == target]


def main():
    parser = argparse.ArgumentParser(
        description="Run ACT4 RTL tests by instruction name and explain each result."
    )
    parser.add_argument("target", nargs="?", help="instruction (e.g. fsub.s), ELF stem, or all")
    parser.add_argument("--list", action="store_true", help="list implemented instructions")
    parser.add_argument("--dry-run", action="store_true", help="show selected ELFs without running")
    parser.add_argument("--cases", default="3", help="show N operations per ELF, or all (default: 3)")
    parser.add_argument("--brief", action="store_true",
                        help="short output: run without explanations, print one PASS/FAIL line per instruction")
    parser.add_argument("--no-flags", action="store_true",
                        help="results only: CSR-free programs (no CSR instruction, no fflags check, "
                             "DYN rounding -> static mode in effect). Default: full test")
    args = parser.parse_args()
    if args.cases != "all" and (not args.cases.isdecimal() or int(args.cases) < 1):
        parser.error("--cases must be a positive integer or all")

    mnemonics = list(dict.fromkeys(mnemonic(name) for name in IMPLEMENTED_TESTS))
    # IMPLEMENTED_TESTS also has the RV32I ELFs; only RV32F counts against SPEC_MNEMONICS.
    f_done = sum(name in mnemonics for name in SPEC_MNEMONICS)
    if args.list or args.target is None:
        print(f"RV32F: {f_done}/{len(SPEC_MNEMONICS)} instructions implemented "
              f"(+{len(mnemonics) - f_done} RV32I instructions tested)")
        for name in SPEC_MNEMONICS:
            status = "TESTABLE" if name in mnemonics else "NOT IMPLEMENTED"
            print(f"  {name:<12} {status}")
        print("Usage: test <instruction>|all  (for example: test fsub.s)")
        return 0 if args.list else 2

    selected = select_tests(args.target)
    if not selected:
        parser.error(f"no ACT4 ELF for {args.target!r}; use --list to see available instructions")

    groups = list(dict.fromkeys(mnemonic(name) for name in selected))
    f_groups = sum(name in SPEC_MNEMONICS for name in groups)
    if args.target.lower() == "all":
        print(f"RV32F: {f_groups}/{len(SPEC_MNEMONICS)} instructions implemented "
              f"(+{len(groups) - f_groups} RV32I); testing {len(groups)} instructions, "
              f"{len(selected)} programs.", flush=True)
    for index, name in enumerate(groups, start=1):
        if args.brief:
            break
        count = sum(mnemonic(item) == name for item in selected)
        print(f"  Instruction {index}/{len(groups)}: {name.upper()} "
              f"({count} ACT4 program{'s' if count != 1 else ''})", flush=True)
    if args.no_flags:
        print("Mode: RESULTS ONLY (--no-flags). Programs are made CSR-free: every CSR instruction "
              "-> nop, fflags checks removed, DYN rounding -> the static mode in effect. "
              "Not an RV32F compliance result.", flush=True)
    if args.dry_run:
        return 0

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    label = re.sub(r"[^a-z0-9._-]", "_", args.target.lower()) + ("_noflags" if args.no_flags else "")
    report_dir = ROOT / "reports" / "act4_runs" / f"{timestamp}_{label}"
    print(f"{'Logs' if args.brief else 'Explanation and full logs'}: {report_dir}", flush=True)
    command = [sys.executable, str(RUNNER), *selected, "--report-dir", str(report_dir)]
    if args.no_flags:
        command.append("--no-flags")
    if args.brief:
        # No --explain: skips disassembly and detailed logs; runner output is kept in a file.
        report_dir.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        (report_dir / "runner.log").write_text(result.stdout + result.stderr, encoding="utf-8")
        status = result.returncode
        if status:
            print((result.stdout + result.stderr).strip().splitlines()[-1] if (result.stdout + result.stderr).strip()
                  else "runner failed", file=sys.stderr)
    else:
        command += ["--explain", "--cases", args.cases]
        status = subprocess.call(command, cwd=ROOT)
    results = report_dir / "results.csv"
    if results.exists():
        with results.open(newline="", encoding="utf-8") as stream:
            records = list(csv.DictReader(stream))
        rows = {row["test"]: row["status"] for row in records}
        print("Instruction summary" + (" (results only, CSR-free programs):" if args.no_flags else ":"))
        ok_groups = 0
        for name in groups:
            tests = [item for item in selected if mnemonic(item) == name]
            passed = sum(rows.get(item) == "PASS" for item in tests)
            ok_groups += passed == len(tests)
            mark = "PASS" if passed == len(tests) else "FAIL"
            print(f"  {name.upper():<12} {mark}  ({passed}/{len(tests)} programs)")
        if args.brief:
            print(f"ACT4{' [results only]' if args.no_flags else ''}: {ok_groups}/{len(groups)} "
                  f"instructions PASS ({sum(v == 'PASS' for v in rows.values())}/{len(selected)} programs)")
        if args.no_flags:
            print("fflags and fcsr: NOT tested in this mode (run without --no-flags for the full test)")
        if args.target.lower() == "all":
            for name in SPEC_MNEMONICS:
                if name not in groups:
                    print(f"  {name.upper():<12} NOT IMPLEMENTED (not run)")
            pending = len(SPEC_MNEMONICS) - f_groups
            print(f"Checkpoint: {f_groups}/{len(SPEC_MNEMONICS)} RV32F instructions implemented"
                  + (f"; {pending} pending, not run." if pending else "."))
    return status


if __name__ == "__main__":
    sys.exit(main())
