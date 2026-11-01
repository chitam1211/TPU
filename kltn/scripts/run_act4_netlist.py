#!/usr/bin/env python3
"""Post-synthesis simulation: ACT4 ELFs on the synthesized netlist of `core`, with xsim.

The netlist comes from Vivado (functional, UNISIM primitives, no delays):
  bash scripts/run_vivado_kv260.sh 10 netlist   -> build/vivado/runs/<time>_netlist_10ns/netlist/core_funcsim.v
(the newest netlist run is used by default; --netlist picks another one)
The testbench is tb_act4_unified.v compiled with -d NETLIST (only the ports of `core` are used;
the +trace/+explain logs need RTL-internal signals and are left out). Each ELF is self-checking,
so ACT4_RTL_PASS means every testcase in it matched Sail on the netlist too. The cycle count is
compared with the RTL run: synthesis must not change the cycle-by-cycle behaviour.

Usage (WSL, from kltn/):
  python3 scripts/run_act4_netlist.py                    # one ELF per instruction (the -00 file), 26 runs
  python3 scripts/run_act4_netlist.py F-fadd.s-01 F-flw-00
  python3 scripts/run_act4_netlist.py all                # all 119 ELFs: 80 F + 39 I (slow)
  python3 scripts/run_act4_netlist.py all --netlist build/vivado/kltn_gui/netlist/core_funcsim_routed.v \
      --tag gui_default_routed --work sim/build/act4_netlist_2
      a netlist exported by hand (Vivado GUI): name the results, and use a second work directory
      to run next to another job (two jobs in one work directory lock each other's snapshot)
Results: reports/act4_netlist/results_<tag>.csv; the tag defaults to the synthesis configuration
read from the netlist run's vivado.log (e.g. results_default.csv, results_poweroptimized_medium.csv)
and is "unknown" for a netlist from outside build/vivado/runs. xsim logs in sim/build/act4_netlist/
"""
import argparse
import csv
import glob
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_act4_rtl import DEFAULT_ACT, DEFAULT_TOOLCHAIN, IMPLEMENTED_TESTS, elf_path, symbol_address  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "sim" / "build" / "act4_netlist"
REPORT = ROOT / "reports" / "act4_netlist"
LEGACY_NETLIST = ROOT / "build" / "vivado" / "kv260_core_if" / "netlist" / "core_funcsim.v"


def newest_netlist():
    """Netlist of the newest `netlist` run (build/vivado/runs/<time>_netlist_<clock>ns/), else the old path."""
    runs = sorted(glob.glob(str(ROOT / "build" / "vivado" / "runs" / "*_netlist_*" / "netlist" / "core_funcsim.v")))
    return Path(runs[-1]) if runs else LEGACY_NETLIST


def synth_tag(netlist):
    """Synthesis configuration the netlist was made with, as a file-name tag ("default",
    "poweroptimized_medium", "default_retiming", ...), read from the "options:" line that
    implement_core_if.tcl prints in reports/vivado/runs/<run>/vivado.log; "unknown" if not found."""
    log = ROOT / "reports" / "vivado" / "runs" / netlist.parent.parent.name / "vivado.log"
    if not log.exists():
        return "unknown"
    m = re.search(r"^INFO: Synthesizing top=\S+ part=\S+ options:(.*)$", log.read_text(errors="replace"), re.M)
    if not m:
        return "unknown"
    opts = m.group(1).split()
    tag = opts[opts.index("-directive") + 1].lower() if "-directive" in opts else "default"
    return tag + ("_retiming" if "-retiming" in opts else "")


NETLIST = newest_netlist()
TB = ROOT / "tb" / "core_if" / "tb_act4_unified.v"
DEFAULT_VIVADO_BIN = Path("/mnt/d/Xilinx/Vivado/2022.2/bin")
SNAPSHOT = "tb_act4_netlist"


def win(path):
    """Windows path with forward slashes (accepted by xsim and by $readmemh)."""
    out = subprocess.run(["wslpath", "-m", str(path)], capture_output=True, text=True, check=True)
    return out.stdout.strip()


def bat(vivado_bin, tool, args, log, timeout=None):
    """Run a Vivado .bat tool from the work directory; return (exit code, output).
    The command goes through a small batch file: cmd.exe splits unquoted arguments at '=',
    and quotes passed from WSL arrive escaped, so "mem=C:/..." must be written in the file."""
    line = " ".join(f'"{x}"' if any(c in x for c in '= ;,') else x for x in [*args, "--log", log])
    script = WORK / f"_run_{tool}.bat"
    script.write_text(f'@cd /d "{win(WORK)}"\r\n@call "{win(vivado_bin / (tool + ".bat"))}" {line}\r\n'
                      f'@exit /b %errorlevel%\r\n')
    r = subprocess.run(["cmd.exe", "/c", win(script)], cwd=WORK, capture_output=True, text=True,
                       timeout=timeout)
    return r.returncode, (r.stdout + r.stderr).replace("\r", "")


def rtl_cycles():
    """Cycles of the newest full RTL run (reports/act4_runs/*/results.csv), by test name."""
    runs = sorted(p for p in glob.glob(str(ROOT / "reports" / "act4_runs" / "*" / "results.csv"))
                  if "noflags" not in p)
    if not runs:
        return {}, None
    with open(runs[-1], newline="") as f:
        return {r["test"]: r["cycles"] for r in csv.DictReader(f) if r["status"] == "PASS"}, runs[-1]


def default_tests():
    seen, out = set(), []
    for name in IMPLEMENTED_TESTS:
        insn = name[2:].rsplit("-", 1)[0]
        if insn not in seen:
            seen.add(insn)
            out.append(name)
    return out


def main():
    global WORK
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tests", nargs="*", help="ELF stems (default: one per instruction), or all")
    ap.add_argument("--netlist", type=Path, default=NETLIST)
    ap.add_argument("--vivado-bin", type=Path, default=DEFAULT_VIVADO_BIN)
    ap.add_argument("--act-root", type=Path, default=DEFAULT_ACT)
    ap.add_argument("--toolchain-bin", type=Path, default=DEFAULT_TOOLCHAIN)
    ap.add_argument("--max-cycles", type=int, default=5_000_000)
    ap.add_argument("--timeout", type=int, default=3600, help="seconds per ELF")
    ap.add_argument("--tag", help="results file name results_<tag>.csv (default: synthesis configuration)")
    ap.add_argument("--work", type=Path, help=f"simulation work directory (default {WORK.relative_to(ROOT)})")
    a = ap.parse_args()
    if a.work:
        WORK = a.work.resolve()
    a.netlist = a.netlist.resolve()
    tag = a.tag or synth_tag(a.netlist)

    tests = list(IMPLEMENTED_TESTS) if a.tests == ["all"] else (a.tests or default_tests())
    if not a.netlist.exists():
        sys.exit(f"Missing netlist {a.netlist}\nCreate it with:  bash scripts/run_vivado_kv260.sh 10 netlist")
    glbl = a.vivado_bin.parent / "data" / "verilog" / "src" / "glbl.v"
    for p in (a.vivado_bin / "xvlog.bat", glbl):
        if not p.exists():
            sys.exit(f"Missing {p}; pass --vivado-bin <Vivado>/bin")
    objcopy = a.toolchain_bin / "riscv32-unknown-elf-objcopy"
    nm = a.toolchain_bin / "riscv32-unknown-elf-nm"
    WORK.mkdir(parents=True, exist_ok=True)
    REPORT.mkdir(parents=True, exist_ok=True)

    print(f"netlist : {a.netlist.relative_to(ROOT) if a.netlist.is_relative_to(ROOT) else a.netlist}"
          f"  (written {time.strftime('%Y-%m-%d %H:%M', time.localtime(a.netlist.stat().st_mtime))},"
          f" synthesis {synth_tag(a.netlist)}, results tag {tag})")
    print(f"work    : {WORK}")
    print("compile : xvlog -d NETLIST + xelab -L unisims_ver ...", flush=True)
    code, out = bat(a.vivado_bin, "xvlog", ["--sv", "-d", "NETLIST", win(a.netlist), win(TB), win(glbl)],
                    "xvlog.log")
    if code:
        sys.exit(f"xvlog failed ({WORK / 'xvlog.log'}):\n" + out[-3000:])
    code, out = bat(a.vivado_bin, "xelab", ["-L", "unisims_ver", "-s", SNAPSHOT,
                                            "work.tb_act4_unified", "work.glbl"], "xelab.log")
    if code:
        sys.exit(f"xelab failed ({WORK / 'xelab.log'}):\n" + out[-3000:])

    ref, ref_path = rtl_cycles()
    if ref_path:
        print(f"RTL ref : {Path(ref_path).relative_to(ROOT)}")
    rows, fails = [], 0
    for name in tests:
        elf = elf_path(a.act_root, name)
        if not elf.exists():
            sys.exit(f"ACT4 ELF not found: {elf}")
        hex_file = WORK / f"{name}.hex"
        subprocess.run([str(objcopy), "-O", "verilog", "--verilog-data-width=1", str(elf), str(hex_file)],
                       check=True)
        tohost = symbol_address(nm, elf, "tohost")
        t0 = time.monotonic()
        try:
            code, out = bat(a.vivado_bin, "xsim",
                            [SNAPSHOT, "-R", "--testplusarg", f"mem={win(hex_file)}",
                             "--testplusarg", f"tohost={tohost:08x}",
                             "--testplusarg", f"max_cycles={a.max_cycles}"],
                            f"xsim_{name}.log", timeout=a.timeout)
        except subprocess.TimeoutExpired:
            code, out = -1, "TIMEOUT"
        secs = time.monotonic() - t0
        m = re.search(r"ACT4_RTL_PASS cycles=(\d+)", out)
        status = "PASS" if m else "FAIL"
        cycles = m.group(1) if m else ""
        rtl = ref.get(name, "")
        same = "" if not (cycles and rtl) else ("same" if cycles == rtl else "DIFFERENT")
        if not m:
            fails += 1
            why = next((l.strip() for l in out.splitlines()
                        if "ACT4_RTL_FAIL" in l or "TIMEOUT" in l or "Fatal" in l or "ERROR" in l), "no PASS line")
            cycles = why
        elif same == "DIFFERENT":
            fails += 1
        rows.append((name, status, cycles, rtl, same, f"{secs:.0f}"))
        print(f"{name:<18} netlist {status}  cycles {cycles:<8} RTL {rtl:<8} {same:<9} ({secs:.0f} s)", flush=True)

    out_csv = REPORT / f"results_{tag}.csv"
    with open(out_csv, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(("test", "netlist_status", "netlist_cycles", "rtl_cycles", "cycles_match", "seconds"))
        w.writerows(rows)
    print(f"results : {out_csv.relative_to(ROOT)}")
    print("ACT4_NETLIST_PASS" if not fails else f"ACT4_NETLIST_FAIL ({fails} of {len(rows)})")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
