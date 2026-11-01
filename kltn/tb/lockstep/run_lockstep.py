#!/usr/bin/env python3
"""Lockstep simulation: RTL `core` and its post-synthesis netlist run ACT4 ELFs side by side in
xsim (tb_lockstep.v), and every port is compared once per cycle.

ACT4 on the netlist (scripts/run_act4_netlist.py) checks each result against Sail; this run also
checks that the netlist behaves like the RTL in every cycle, so it points at the first cycle and
the port where the two copies differ.

The netlist modules have the same names as the RTL ones (core, decode, fp32_addsub, ...), so a
renamed copy is written first: every module becomes net_<name> (glbl and UNISIM cells are kept).
The newest netlist run is used by default (bash scripts/run_vivado_kv260.sh <ns> netlist ...).

Usage (WSL, from kltn/):
  python3 tb/lockstep/run_lockstep.py                       # one ELF per instruction, 26 runs
  python3 tb/lockstep/run_lockstep.py F-fadd.s-00 F-flw-00
  python3 tb/lockstep/run_lockstep.py all                   # all 119 ELFs: 80 F + 39 I (slow)
  python3 tb/lockstep/run_lockstep.py F-fadd.s-00 --inject-cycle 2000
      self-test: the netlist copy gets one wrong instruction, the run must report a mismatch
  python3 tb/lockstep/run_lockstep.py all --netlist build/vivado/kltn_gui/netlist/core_funcsim_synth.v \
      --tag gui_default_synth --work sim/build/lockstep_2
      a netlist exported by hand (Vivado GUI), with its own results name and work directory
Results: reports/lockstep/results_<tag>.csv (results_inject_<tag>.csv for --inject-cycle); the tag
defaults to the synthesis configuration read from the netlist run's vivado.log (e.g. results_default.csv,
results_poweroptimized_medium.csv) and is "unknown" for a netlist from outside build/vivado/runs.
xsim logs and the renamed netlist in sim/build/lockstep/
"""
import argparse
import csv
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from run_act4_rtl import DEFAULT_ACT, DEFAULT_TOOLCHAIN, IMPLEMENTED_TESTS, elf_path, symbol_address  # noqa: E402
from run_act4_netlist import (DEFAULT_VIVADO_BIN, default_tests, newest_netlist, rtl_cycles,  # noqa: E402
                              synth_tag, win)

HERE = Path(__file__).resolve().parent
TB = HERE / "tb_lockstep.v"
RTL = ROOT / "rtl" / "core_if"
WORK = ROOT / "sim" / "build" / "lockstep"
REPORT = ROOT / "reports" / "lockstep"
SNAPSHOT = "tb_lockstep"
PREFIX = "net_"


def bat(vivado_bin, tool, args, log, timeout=None):
    """Run a Vivado .bat tool from WORK through a batch file (cmd.exe splits unquoted
    arguments at '=', see run_act4_netlist.py); return (exit code, output)."""
    line = " ".join(f'"{x}"' if any(c in x for c in '= ;,') else x for x in [*args, "--log", log])
    script = WORK / f"_run_{tool}.bat"
    script.write_text(f'@cd /d "{win(WORK)}"\r\n@call "{win(vivado_bin / (tool + ".bat"))}" {line}\r\n'
                      f'@exit /b %errorlevel%\r\n')
    r = subprocess.run(["cmd.exe", "/c", win(script)], cwd=WORK, capture_output=True, text=True,
                       timeout=timeout)
    return r.returncode, (r.stdout + r.stderr).replace("\r", "")


def rename_netlist(src, dst):
    """Copy the funcsim netlist with every module renamed PREFIX<name>, declarations and
    instances. Return the number of modules. Fails if an instance of an old name is left, since
    it would silently bind to the RTL module of the same name."""
    text = src.read_text()
    names = [n for n in re.findall(r"^module\s+(\w+)", text, re.M) if n != "glbl"]
    if "core" not in names:
        sys.exit(f"{src}: no module `core` in the netlist")
    alt = "|".join(map(re.escape, names))
    text, n_mod = re.subn(rf"^module\s+({alt})\b", rf"module {PREFIX}\1", text, flags=re.M)
    # Vivado writes a submodule instance as "  <module> <instance>" on its own line.
    text, n_inst = re.subn(rf"^(\s+)({alt})(\s+(?:\\\S+|\w+)\s*$)", rf"\g<1>{PREFIX}\2\3", text, flags=re.M)
    left = re.findall(rf"^\s+({alt})\s", text, re.M)
    if n_mod != len(names) or left:
        sys.exit(f"Netlist rename incomplete: {n_mod}/{len(names)} modules, old names left: {sorted(set(left))}")
    dst.write_text(text)
    return n_mod, n_inst


def main():
    global WORK
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tests", nargs="*", help="ELF stems (default: one per instruction), or all")
    ap.add_argument("--netlist", type=Path, default=newest_netlist())
    ap.add_argument("--vivado-bin", type=Path, default=DEFAULT_VIVADO_BIN)
    ap.add_argument("--act-root", type=Path, default=DEFAULT_ACT)
    ap.add_argument("--toolchain-bin", type=Path, default=DEFAULT_TOOLCHAIN)
    ap.add_argument("--max-cycles", type=int, default=5_000_000)
    ap.add_argument("--max-mismatches", type=int, default=1, help="mismatching ports reported before stopping")
    ap.add_argument("--inject-cycle", type=int, default=None,
                    help="self-test: replace one netlist instruction from this cycle on; a mismatch is expected")
    ap.add_argument("--timeout", type=int, default=3600, help="seconds per ELF")
    ap.add_argument("--tag", help="results file name results_<tag>.csv (default: synthesis configuration)")
    ap.add_argument("--work", type=Path, help=f"simulation work directory (default {WORK.relative_to(ROOT)})")
    a = ap.parse_args()
    if a.work:
        WORK = a.work.resolve()
    a.netlist = a.netlist.resolve()

    tests = list(IMPLEMENTED_TESTS) if a.tests == ["all"] else (a.tests or default_tests())
    if not a.netlist.exists():
        sys.exit(f"Missing netlist {a.netlist}\nCreate it with:  bash scripts/run_vivado_kv260.sh 6.5 netlist")
    if not (a.vivado_bin / "xvlog.bat").exists():
        sys.exit(f"Missing {a.vivado_bin / 'xvlog.bat'}; pass --vivado-bin <Vivado>/bin")
    objcopy = a.toolchain_bin / "riscv32-unknown-elf-objcopy"
    nm = a.toolchain_bin / "riscv32-unknown-elf-nm"
    WORK.mkdir(parents=True, exist_ok=True)
    REPORT.mkdir(parents=True, exist_ok=True)

    renamed = WORK / "core_netlist_renamed.v"
    n_mod, n_inst = rename_netlist(a.netlist, renamed)
    tag = a.tag or synth_tag(a.netlist)
    print(f"netlist : {a.netlist.relative_to(ROOT) if a.netlist.is_relative_to(ROOT) else a.netlist}"
          f"  (written {time.strftime('%Y-%m-%d %H:%M', time.localtime(a.netlist.stat().st_mtime))},"
          f" synthesis {synth_tag(a.netlist)}, results tag {tag})")
    print(f"work    : {WORK}")
    print(f"rename  : {n_mod} modules, {n_inst} instances -> {PREFIX}*")
    # The netlist carries its own glbl (guarded by `ifndef GLBL), so glbl.v is not added.
    rtl_sources = sorted(RTL.glob("*.v"))
    print(f"compile : xvlog ({len(rtl_sources)} RTL files + netlist + tb) + xelab -L unisims_ver ...", flush=True)
    code, out = bat(a.vivado_bin, "xvlog", [*(win(p) for p in rtl_sources), win(renamed), win(TB)], "xvlog.log")
    if code:
        sys.exit(f"xvlog failed ({WORK / 'xvlog.log'}):\n" + out[-3000:])
    # The RTL has no `timescale while the netlist and tb do: give it the tb's one.
    code, out = bat(a.vivado_bin, "xelab", ["--timescale", "1ns/1ps", "-L", "unisims_ver", "-s", SNAPSHOT,
                                            "work.tb_lockstep", "work.glbl"], "xelab.log")
    if code:
        sys.exit(f"xelab failed ({WORK / 'xelab.log'}):\n" + out[-3000:])

    ref, ref_path = rtl_cycles()
    if ref_path:
        print(f"RTL ref : {Path(ref_path).relative_to(ROOT)} (iverilog cycles, for comparison)")
    inject = a.inject_cycle is not None
    rows, fails = [], 0
    for name in tests:
        elf = elf_path(a.act_root, name)
        if not elf.exists():
            sys.exit(f"ACT4 ELF not found: {elf}")
        hex_file = WORK / f"{name}.hex"
        subprocess.run([str(objcopy), "-O", "verilog", "--verilog-data-width=1", str(elf), str(hex_file)],
                       check=True)
        tohost = symbol_address(nm, elf, "tohost")
        plusargs = [f"mem={win(hex_file)}", f"tohost={tohost:08x}", f"max_cycles={a.max_cycles}",
                    f"max_mismatches={a.max_mismatches}"]
        if inject:
            plusargs.append(f"inject_cycle={a.inject_cycle}")
        t0 = time.monotonic()
        try:
            code, out = bat(a.vivado_bin, "xsim",
                            [SNAPSHOT, "-R", *(x for p in plusargs for x in ("--testplusarg", p))],
                            f"xsim_{name}{'_inject' if inject else ''}.log", timeout=a.timeout)
        except subprocess.TimeoutExpired:
            code, out = -1, "TIMEOUT"
        secs = time.monotonic() - t0

        m_pass = re.search(r"LOCKSTEP_PASS cycles=(\d+)", out)
        m_miss = re.search(r"LOCKSTEP_MISMATCH cycle=(\d+) signal=(\S+) rtl=(\S+) net=(\S+)", out)
        cycles = m_pass.group(1) if m_pass else ""
        rtl = ref.get(name, "")
        if inject:
            # Self-test: the expected outcome is a mismatch.
            ok = m_miss is not None
            status = "DETECTED" if ok else "UNDETECTED"
            detail = (f"cycle {m_miss.group(1)} {m_miss.group(2)} rtl={m_miss.group(3)} net={m_miss.group(4)}"
                      if m_miss else "no mismatch reported")
        else:
            ok = m_pass is not None and m_miss is None
            status = "PASS" if ok else "FAIL"
            if m_miss:
                detail = f"cycle {m_miss.group(1)} {m_miss.group(2)} rtl={m_miss.group(3)} net={m_miss.group(4)}"
            elif m_pass:
                detail = "" if not rtl else ("cycles same as iverilog RTL" if cycles == rtl
                                             else f"iverilog RTL cycles {rtl}")
            else:
                detail = next((l.strip() for l in out.splitlines()
                               if "FAIL" in l or "TIMEOUT" in l or "Fatal" in l or "ERROR" in l), "no PASS line")
        fails += not ok
        rows.append((name, status, cycles, rtl, detail, f"{secs:.0f}"))
        print(f"{name:<18} lockstep {status:<10} cycles {cycles:<8} {detail} ({secs:.0f} s)", flush=True)

    out_csv = REPORT / (f"results_inject_{tag}.csv" if inject else f"results_{tag}.csv")
    with open(out_csv, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(("test", "status", "cycles", "iverilog_rtl_cycles", "detail", "seconds"))
        w.writerows(rows)
    print(f"results : {out_csv.relative_to(ROOT)}")
    if inject:
        print("LOCKSTEP_SELFTEST_PASS" if not fails else f"LOCKSTEP_SELFTEST_FAIL ({fails} of {len(rows)} undetected)")
    else:
        print("LOCKSTEP_ALL_PASS" if not fails else f"LOCKSTEP_FAIL ({fails} of {len(rows)})")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
