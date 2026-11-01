#!/usr/bin/env python3
"""Waveform of one lockstep run (tb_lockstep.v): the RTL copy and the netlist copy of `core` side by
side in the Vivado waveform viewer, as visual evidence next to the PASS line of run_lockstep.py.

The run is the same as run_lockstep.py (same netlist rename, same testbench), elaborated with
--debug typical and every testbench signal logged to a waveform database (.wdb). The viewer opens
with each port as a pair <name>_r (RTL) / <name>_n (netlist), and the mismatch counter, which
stays 0 when the two copies agree in every cycle.

Usage (WSL, from kltn/):
  python3 tb/lockstep/wave_lockstep.py F-fadd.s-00                       # PASS run, opens the viewer
  python3 tb/lockstep/wave_lockstep.py F-fadd.s-00 --inject-cycle 2000   # self-test: divergence
  python3 tb/lockstep/wave_lockstep.py F-fadd.s-00 --no-gui              # only write the .wdb
  python3 tb/lockstep/wave_lockstep.py F-fadd.s-00 --netlist build/vivado/kltn_gui/netlist/core_funcsim_synth.v \
      --tag gui_default_synth                                            # a netlist exported from the GUI
Output: sim/build/lockstep_wave/<test>_<tag>[_inject].wdb and view.tcl (tag: --tag, else the
synthesis configuration)
Open later: Vivado > Flow > Open Static Simulation > <the .wdb>, then in the Tcl Console:
  source C:/TPU/TPU/kltn/sim/build/lockstep_wave/view.tcl
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from run_lockstep import (DEFAULT_ACT, DEFAULT_TOOLCHAIN, DEFAULT_VIVADO_BIN, ROOT,  # noqa: E402
                          RTL, TB, elf_path, newest_netlist, rename_netlist, symbol_address, synth_tag,
                          win)

WORK = ROOT / "sim" / "build" / "lockstep_wave"
SNAPSHOT = "tb_lockstep_wave"
T = "/tb_lockstep"
# Viewer layout: (group name, [(signal, radix)]); each port shows the RTL copy above the netlist copy.
PAIRS = [
    ("pc_address", "pc", "hex"),
    ("instruction (from memory)", "instruction", "hex"),
    ("instruction_mem_request", "instruction_mem_request", "bin"),
    ("data_mem_request", "data_mem_request", "bin"),
    ("data_mem_we_re", "data_mem_we_re", "bin"),
    ("alu_out_address", "address", "hex"),
    ("store_data_out", "store_data", "hex"),
    ("mask_singal", "mask", "bin"),
    ("load_data_in", "load_data", "hex"),
]


def bat(vivado_bin, tool, args, log, timeout=None):
    """As run_lockstep.bat, from this script's work directory."""
    line = " ".join(f'"{x}"' if any(c in x for c in '= ;,') else x for x in [*args, "--log", log])
    script = WORK / f"_run_{tool}.bat"
    script.write_text(f'@cd /d "{win(WORK)}"\r\n@call "{win(vivado_bin / (tool + ".bat"))}" {line}\r\n'
                      f'@exit /b %errorlevel%\r\n')
    r = subprocess.run(["cmd.exe", "/c", win(script)], cwd=WORK, capture_output=True, text=True,
                       timeout=timeout)
    return r.returncode, (r.stdout + r.stderr).replace("\r", "")


def view_tcl():
    """Tcl for the waveform viewer: clock and counters, then one group per port pair."""
    lines = ["# Lockstep waveform layout (wave_lockstep.py): <port>_r = RTL core, <port>_n = netlist core",
             f"add_wave {T}/clk {T}/rst",
             f"add_wave -radix unsigned {T}/cycle_count",
             f"add_wave -radix unsigned -color yellow {T}/mismatches",
             f"add_wave {T}/injected"]
    for title, sig, radix in PAIRS:
        n = "instruction_n" if sig == "instruction" else f"{sig}_n"
        lines += [f'set g [add_wave_group "{title}"]',
                  f"add_wave -into $g -radix {radix} -color cyan   {T}/{sig}_r",
                  f"add_wave -into $g -radix {radix} -color orange {T}/{n}"]
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("test", help="ELF stem, e.g. F-fadd.s-00")
    ap.add_argument("--netlist", type=Path, default=newest_netlist())
    ap.add_argument("--vivado-bin", type=Path, default=DEFAULT_VIVADO_BIN)
    ap.add_argument("--act-root", type=Path, default=DEFAULT_ACT)
    ap.add_argument("--toolchain-bin", type=Path, default=DEFAULT_TOOLCHAIN)
    ap.add_argument("--max-cycles", type=int, default=5_000_000)
    ap.add_argument("--inject-cycle", type=int, default=None, help="self-test: the netlist copy diverges here")
    ap.add_argument("--no-gui", action="store_true", help="write the .wdb only")
    ap.add_argument("--tag", help="name in the .wdb file (default: synthesis configuration)")
    a = ap.parse_args()
    a.netlist = a.netlist.resolve()

    if not a.netlist.exists():
        sys.exit(f"Missing netlist {a.netlist}")
    elf = elf_path(a.act_root, a.test)
    if not elf.exists():
        sys.exit(f"ACT4 ELF not found: {elf}")
    WORK.mkdir(parents=True, exist_ok=True)
    tag = a.tag or synth_tag(a.netlist)
    print(f"netlist : {a.netlist.relative_to(ROOT)}  (synthesis {synth_tag(a.netlist)}, tag {tag})")

    renamed = WORK / "core_netlist_renamed.v"
    rename_netlist(a.netlist, renamed)
    print("compile : xvlog + xelab --debug typical ...", flush=True)
    code, out = bat(a.vivado_bin, "xvlog", [*(win(p) for p in sorted(RTL.glob("*.v"))), win(renamed), win(TB)],
                    "xvlog.log")
    if code:
        sys.exit("xvlog failed (sim/build/lockstep_wave/xvlog.log):\n" + out[-3000:])
    code, out = bat(a.vivado_bin, "xelab", ["--debug", "typical", "--timescale", "1ns/1ps", "-L", "unisims_ver",
                                            "-s", SNAPSHOT, "work.tb_lockstep", "work.glbl"], "xelab.log")
    if code:
        sys.exit("xelab failed (sim/build/lockstep_wave/xelab.log):\n" + out[-3000:])

    hex_file = WORK / f"{a.test}.hex"
    subprocess.run([str(a.toolchain_bin / "riscv32-unknown-elf-objcopy"), "-O", "verilog",
                    "--verilog-data-width=1", str(elf), str(hex_file)], check=True)
    tohost = symbol_address(a.toolchain_bin / "riscv32-unknown-elf-nm", elf, "tohost")
    plusargs = [f"mem={win(hex_file)}", f"tohost={tohost:08x}", f"max_cycles={a.max_cycles}"]
    if a.inject_cycle is not None:
        # Keep running after the first mismatches so the divergence is visible in the waveform.
        plusargs += [f"inject_cycle={a.inject_cycle}", "max_mismatches=50"]
    name = f"{a.test}_{tag}{'_inject' if a.inject_cycle is not None else ''}"
    wdb = WORK / f"{name}.wdb"
    (WORK / "log_all.tcl").write_text(f"log_wave [get_objects {T}/*]\nrun all\nquit\n")
    (WORK / "view.tcl").write_text(view_tcl())

    print(f"simulate: {a.test} -> {wdb.relative_to(ROOT)}", flush=True)
    code, out = bat(a.vivado_bin, "xsim",
                    [SNAPSHOT, "-tclbatch", "log_all.tcl", "-wdb", win(wdb),
                     *(x for p in plusargs for x in ("--testplusarg", p))], f"xsim_{name}.log")
    result = next((l.strip() for l in out.splitlines()
                   if re.search(r"LOCKSTEP_(PASS|FAIL|INJECT_UNDETECTED)|Fatal", l)),
                  "no LOCKSTEP line (see the xsim log)")
    misses = [l.strip() for l in out.splitlines() if "LOCKSTEP_MISMATCH" in l]
    print(f"result  : {result}")
    if misses:
        print(f"first   : {misses[0]}\nmismatch: {len(misses)} reported")
    if not wdb.exists():
        sys.exit(f"No waveform written; see sim/build/lockstep_wave/xsim_{name}.log")
    print(f"viewer  : Vivado > Flow > Open Static Simulation > {win(wdb)}\n"
          f"          then Tcl Console: source {win(WORK / 'view.tcl')}")
    if not a.no_gui:
        print("opening the waveform viewer ...", flush=True)
        bat(a.vivado_bin, "xsim", [win(wdb), "-gui", "-tclbatch", "view.tcl"], "xsim_gui.log")
    return 0


if __name__ == "__main__":
    sys.exit(main())
