#!/usr/bin/env python3
"""Waveforms of the representative ACT4 cases (see act4_explain_cases.py) on the RTL core.

Each testcase of a case is replayed alone on the core with the same operands and rounding
mode (tb_wave_one: registers preloaded, dump stops when the instruction retires). The result
and fflags are checked against Sail's expected values, and a VCD plus a GTKWave save file
(signals of the unit that executes the instruction, case title on top) are written.

Usage (WSL, from kltn/; needs reports/act4_cases/<insn>_cases.json):
  python3 scripts/act4_case_wave.py fadd.s              # list the cases of fadd.s
  python3 scripts/act4_case_wave.py fadd.s 7            # build case 7 (each of its testcases)
  python3 scripts/act4_case_wave.py fadd.s 7 --view     # ... and open GTKWave
  python3 scripts/act4_case_wave.py fadd.s all          # every case of fadd.s
  python3 scripts/act4_case_wave.py all                 # every case of the 26 instructions
Output: sim/build/act4_case_waves/<insn>/case<N>_<mode>/{wave.vcd,wave.gtkw}
"""
import argparse
import json
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from gen_fp_wave_demo import EXTRA, OPS, mnemonic   # noqa: E402

CASES_DIR = ROOT / "reports" / "act4_cases"
OUT = ROOT / "sim" / "build" / "act4_case_waves"
ROUNDED = {"fadd.s", "fsub.s", "fmul.s", "fdiv.s", "fsqrt.s", "fmadd.s", "fmsub.s", "fnmsub.s",
           "fnmadd.s", "fcvt.w.s", "fcvt.wu.s", "fcvt.s.w", "fcvt.s.wu"}
RM = ["rne", "rtz", "rdn", "rup", "rmm"]


def source_regs(insn):
    """Operand registers of the instruction in the wave program, e.g. fsqrt.s -> ['f2']."""
    name = next((n for n, _ in OPS if mnemonic(n) == insn), None)
    if name is None:
        return []                                       # flw: data comes from memory word 1
    regs = re.findall(r"\b[fx]\d+\b", name.split(None, 1)[1])
    regs = [r for r in regs if r != "x0"]
    return regs if insn == "fsw" else regs[1:]


def ascii_text(s):
    s = s.replace("đ", "d").replace("Đ", "D")
    return unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()


def run(cmd, **kw):
    return subprocess.run([str(c) for c in cmd], cwd=ROOT, capture_output=True, text=True, **kw)


def compile_tb():
    OUT.mkdir(parents=True, exist_ok=True)
    sim = OUT / "tb_wave_one.out"
    srcs = sorted((ROOT / "rtl" / "core_if").glob("*.v")) + [ROOT / "tb" / "core_if" / "tb_wave_one.v"]
    if not sim.exists() or max(s.stat().st_mtime for s in srcs) > sim.stat().st_mtime:
        r = run(["iverilog", "-g2012", "-Wall", "-Wno-timescale", "-s", "tb_wave_one", "-o", sim, *srcs])
        if r.returncode:
            sys.exit("iverilog failed:\n" + r.stdout + r.stderr)
    return sim


def build(insn, case, tc, sim):
    regs = source_regs(insn)
    mode = tc["rm"] or ""
    out = OUT / insn / f"case{case['id']}_{mode or 'x'}"
    cmd = [sys.executable, ROOT / "scripts" / "gen_fp_wave_demo.py", "--output", out, "--only", insn]
    if insn == "flw":
        cmd += ["--mem", f"1={tc['operands'][0]}"]
    for reg, val in zip(regs, tc["operands"]):
        cmd += ["--set", f"{reg}={val}"]
    if insn in ROUNDED and mode:
        cmd += ["--rm", str(RM.index(mode))]       # rm=DYN in ACT4 is replayed as the static mode it read
    cmd += ["--expect", f"{tc['result']}:{tc['fflags'] or '00'}"]
    title = (f"{insn} case {case['id']}: {ascii_text(case['title'])} | ops {' '.join(tc['operands'])}"
             f"{' ' + mode.upper() if mode else ''} -> {tc['result']} fflags {tc['fflags'] or '-'}"
             f" | {tc['file']} tc {tc['tc']}")
    if insn in ("flw", "fsw"):
        title += f" | wave: same data, fixed address {'4(x0)' if insn == 'flw' else '512(x0)'}"
    cmd += ["--title", title]
    r = run(cmd)
    if r.returncode:
        return out, False, (r.stdout + r.stderr).strip().splitlines()[-1:]
    r = run(["vvp", sim, f"+case={out / 'iso.txt'}", f"+vcd={out / 'wave.vcd'}"], timeout=120)
    text = r.stdout + r.stderr
    ok = "WAVE_ONE_TEST_PASS" in text
    m = re.search(r"cycles=(\d+)", text)
    detail = [f"cycles={m.group(1)}"] if ok and m else [l for l in text.splitlines() if "got=" in l or "FATAL" in l.upper()][:2]
    return out, ok, detail


def load(insn):
    path = CASES_DIR / f"{insn}_cases.json"
    if not path.exists():
        sys.exit(f"Missing {path.relative_to(ROOT)}: run  python3 scripts/act4_explain_cases.py {insn}")
    return json.loads(path.read_text(encoding="utf-8"))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("insn", help="instruction (e.g. fadd.s) or all")
    ap.add_argument("case", nargs="?", help="case number, or all (omit to list the cases)")
    ap.add_argument("--view", action="store_true", help="open the GTKWave file(s) of the case")
    a = ap.parse_args()
    if a.insn == "all":
        insns = sorted(p.name[:-len("_cases.json")] for p in CASES_DIR.glob("*_cases.json"))
        a.case = "all"
    else:
        insns = [a.insn]
    if a.case is None:
        data = load(a.insn)
        for c in data["cases"]:
            modes = ", ".join(f"{t['rm'].upper() if t['rm'] else ''} tc{t['tc']}".strip() for t in c["testcases"])
            print(f"{c['id']:>3}  {c['title']}   [{modes}]")
        print(f"build one: python3 scripts/act4_case_wave.py {a.insn} <number> [--view]", file=sys.stderr)
        return 0
    if a.view and (a.case == "all" or len(insns) > 1):
        sys.exit("--view opens one case at a time: give a case number")
    sim = compile_tb()
    fails = 0
    for insn in insns:
        data = load(insn)
        cases = data["cases"] if a.case == "all" else [c for c in data["cases"] if c["id"] == a.case]
        if not cases:
            sys.exit(f"No case {a.case!r} for {insn}; list them with: python3 scripts/act4_case_wave.py {insn}")
        for c in cases:
            for tc in c["testcases"]:
                out, ok, detail = build(insn, c, tc, sim)
                fails += not ok
                mode = (tc["rm"] or "").upper()
                print(f"{insn:<10} case {c['id']:>2} {mode:<4} {tc['file']} tc {tc['tc']:<5} "
                      f"RTL==Sail {'PASS' if ok else 'FAIL'}  {' '.join(detail)}  "
                      f"{(out / 'wave.gtkw').relative_to(ROOT)}")
                if a.view and ok:
                    subprocess.Popen(["gtkwave", str(out / "wave.gtkw")], cwd=ROOT,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("all cases: RTL result and fflags == Sail" if not fails else f"{fails} FAIL")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
