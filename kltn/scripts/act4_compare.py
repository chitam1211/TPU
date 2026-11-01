#!/usr/bin/env python3
"""Per-testcase evidence that the core's results match Sail's (.results), from an ACT4 run log.

A "PASS" from tb_act4_unified.v only says the self-checking program reached the end.
This script shows WHY: for every check of every testcase (result, then fflags) it puts
side by side
  core      : the value the core produced, read from the RTL log at the beq that does
              the check (register values tracked from the RETIRE lines, in program order)
  program   : the expected value the program loaded from memory (embedded in the ELF)
  .results  : the value on the matching line of Sail's .results file
and marks the check OK only if all three are equal.

Needs a run made with --explain (run.log + disasm.txt), e.g.:
  python3 scripts/act4_cli.py fadd.s          # or: all   -> reports/act4_runs/<time>_<target>/
Usage (from kltn/, Windows or WSL):
  python scripts/act4_compare.py fadd.s                    # summary + CSV per instruction
  python scripts/act4_compare.py all                       # every instruction found in the run
  python scripts/act4_compare.py fadd.s --show 00 940      # one testcase in detail
Options: --run-dir (default: newest reports/act4_runs/* with run logs), --act-root, --out-dir
"""
import argparse
import csv
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import act4_explain_cases as ex                         # noqa: E402

KLTN = ex.KLTN
RETIRE_RE = re.compile(r"^RETIRE cycle=(\d+) pc=([0-9a-f]+) insn=([0-9a-f]+)(?: rd=(\d+) bank=(\w))?")
FPEXEC_RE = re.compile(r"^FP_EXEC cycle=(\d+) pc=([0-9a-f]+) insn=([0-9a-f]+) a=(\w+) b=(\w+) c=(\w+) "
                       r"result=(\w+) flags=(\w+)")
INS_RE = re.compile(r"^\s*([0-9a-f]+):\s+([0-9a-f]+)\s+(\S+)\s*(.*)$")


def default_run_dir():
    runs = sorted(glob.glob(os.path.join(KLTN, "reports", "act4_runs", "*")))
    runs = [r for r in runs if glob.glob(os.path.join(r, "F-*.run.log"))]
    return runs[-1] if runs else None


def checks_of(t):
    """[(beq pc, check number 0/1)] of a testcase, from its disassembly."""
    out = []
    for l in t["body"]:
        m = INS_RE.match(l)
        if m and m.group(3) in ("beq", "beqz", "bne"):
            out.append(int(m.group(1), 16))
    return out


def compare_file(tests, log_path):
    """Fill t['checks'] = [(name, core, program, results, ok)] and t['fp'] for each testcase."""
    beq = {}
    for t in tests:
        t["checks"], t["fp"], t["log"] = [], None, []
        for i, pc in enumerate(checks_of(t)):
            beq[pc] = (t, i)
    first = {}
    for t in tests:
        for l in t["body"][1:2]:
            m = INS_RE.match(l)
            if m:
                first[int(m.group(1), 16)] = t                  # pc of the instruction under test
    xreg = [0] * 32
    with open(log_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = FPEXEC_RE.match(line)
            if m:
                pc = int(m.group(2), 16)
                if pc in first:
                    first[pc]["fp"] = m.groups()
                    first[pc]["log"].append(line.rstrip())
                continue
            m = RETIRE_RE.match(line)
            if not m:
                continue
            pc, insn = int(m.group(2), 16), int(m.group(3), 16)
            if m.group(4) is not None and m.group(5) == "x" and int(m.group(4)) != 0:
                xreg[int(m.group(4))] = int(line.split("value=")[1].split()[0], 16)
            if pc in first:
                first[pc]["log"].append(line.rstrip())
            if pc in beq:
                t, i = beq[pc]
                rs1, rs2 = (insn >> 15) & 31, (insn >> 20) & 31
                program = xreg[rs1] if rs1 else 0               # ACT4: beq <expected>, <actual>
                core = xreg[rs2] if rs2 else 0
                results = None
                if t["exp"] is not None:
                    results = t["exp"][i] if i < len(t["exp"]) else None
                ok = core == program and (results is None or results == program)
                t["checks"].append(("result" if i == 0 else "fflags", core, program, results, ok))
                t["log"].append(line.rstrip())
    return tests


def fmt(v, flags=False):
    return "-" if v is None else (f"{v:02x}" if flags else f"{v:08x}")


def run_insn(insn, run_dir, act_root, out_dir):
    tests = ex.load_insn(insn, run_dir, act_root)
    by_file = {}
    for t in tests:
        by_file.setdefault(t["num"], []).append(t)
    for num, ts in by_file.items():
        log = os.path.join(run_dir, f"F-{insn}-{num}.run.log")
        if not os.path.exists(log):
            sys.exit(f"Missing {log}: run the instruction with --explain (python3 scripts/act4_cli.py {insn})")
        compare_file(ts, log)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"{insn}_compare.csv")
    n_checks = n_ok = n_missing = 0
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["file", "testcase", "label", "operands", "check", "core", "program_expected",
                    "results_line", "results_value", "match"])
        for t in tests:
            om = ex.operands_and_mode(t)
            ops = " ".join(f"{v:08x}" for v in om[0]) if om else ""
            if not t["checks"]:
                n_missing += 1
            for i, (name, core, prog, res, ok) in enumerate(t["checks"]):
                n_checks += 1
                n_ok += ok
                line = t["exp_index"] + 1 + i if t["exp_index"] is not None else ""
                fl = name == "fflags"
                w.writerow([f"F-{insn}-{t['num']}", t["tc"], t["label"], ops, name, fmt(core, fl),
                            fmt(prog, fl), line, fmt(res, fl), "OK" if ok else "MISMATCH"])
    return tests, path, n_checks, n_ok, n_missing


def show(insn, tests, num, tc, act_root):
    t = next((x for x in tests if x["num"] == num and x["tc"] == tc), None)
    if t is None:
        sys.exit(f"No testcase {tc} in F-{insn}-{num}")
    om = ex.operands_and_mode(t)
    print(f"F-{insn}-{num}  testcase {tc}/{t['total']}  {t['label']}")
    if om:
        print(f"  operands (ACT4 source) : {' '.join(f'0x{v:08x}' for v in om[0])}"
              + (f"   rounding mode {om[2].upper()}" if om[2] else ""))
    if t["fp"]:
        cyc, pc, insn_hex, a, b, c, res, fl = t["fp"]
        print(f"  core FP unit (FP_EXEC) : cycle {cyc}, pc {pc}, a={a} b={b} c={c} -> result={res} flags={fl}")
    print("  checks (beq in the program):")
    res_path = os.path.join(act_root, "work", "rv32if-core", "build", "rv32i", "F", f"F-{insn}-{num}.results")
    for i, (name, core, prog, res, ok) in enumerate(t["checks"]):
        fl = name == "fflags"
        line = t["exp_index"] + 1 + i if t["exp_index"] is not None else "?"
        print(f"    {name:<7} core = {fmt(core, fl):>8}   program expected = {fmt(prog, fl):>8}   "
              f".results line {line} = {fmt(res, fl):>8}   -> {'OK' if ok else 'MISMATCH'}")
    print("  RTL log lines of this testcase:")
    for l in t["log"]:
        print("    " + l)
    print(f"  check it yourself:  sed -n '{t['exp_index'] + 1},{t['exp_index'] + len(t['checks'])}p' {res_path}"
          if t["exp_index"] is not None else "")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("insns", nargs="+", help="instruction(s), or all")
    ap.add_argument("--show", nargs=2, metavar=("FILE", "TC"), help="detail of one testcase, e.g. --show 00 940")
    ap.add_argument("--run-dir", default=default_run_dir())
    ap.add_argument("--act-root", default=ex.default_act_root())
    ap.add_argument("--out-dir", default=os.path.join(KLTN, "reports", "act4_compare"))
    a = ap.parse_args()
    if not a.run_dir:
        sys.exit("No reports/act4_runs/* with run logs: run  python3 scripts/act4_cli.py <insn|all>  first")
    if not a.act_root:
        sys.exit("ACT4 folder not found; pass --act-root")
    if a.insns == ["all"]:
        found = {re.match(r"F-(.+)-\d+\.run\.log$", os.path.basename(p)).group(1)
                 for p in glob.glob(os.path.join(a.run_dir, "F-*.run.log"))}
        insns = [i for i in ex.ALL if i in found]
    else:
        insns = a.insns
    print(f"run: {os.path.relpath(a.run_dir, KLTN)}")
    total = ok_total = 0
    for insn in insns:
        tests, path, n, ok, missing = run_insn(insn, a.run_dir, a.act_root, a.out_dir)
        total += n
        ok_total += ok
        if a.show:
            show(insn, tests, a.show[0].zfill(2), int(a.show[1]), a.act_root)
            continue
        print(f"{insn:<10} {len(tests):5d} testcases  {n:6d} checks  core==program==.results {ok:6d}"
              + (f"  MISMATCH {n - ok}" if n - ok else "") + (f"  no check found {missing}" if missing else "")
              + f"   {os.path.relpath(path, KLTN)}")
    if not a.show:
        print(f"TOTAL {total} checks, {ok_total} OK" + ("" if ok_total == total else f", {total - ok_total} MISMATCH"))
    return 0 if ok_total == total else 1


if __name__ == "__main__":
    sys.exit(main())
