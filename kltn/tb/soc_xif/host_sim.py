#!/usr/bin/env python3
"""Run the board software fpga/soc_xif/sw/soc_host.py against the RTL instead of the board.

The demo() and run_image() functions of soc_host.py run unchanged on a Soc whose accesses are
served by tb/soc_xif/tb_soc_image.sv: the words written to IMEM / DMEM become the BRAM contents,
CTRL = 1 starts one simulation (CTRL = 0, IRQ_EN = 0, MAX_CYCLES, CTRL = 1, poll IRQ_STATUS,
W1C, as Soc.run), and the registers, matrix registers (MREG) and DMEM read afterwards come from
the snapshot the testbench writes (before and after RUN = 0).

  python3 tb/soc_xif/host_sim.py                                  # demo, 5 data sets
  python3 tb/soc_xif/host_sim.py --case sim/build/matrix_sw/core_matrix/*/
Output: SOC_HOST_SIM_PASS / SOC_HOST_SIM_FAIL. Work files in tb/soc_xif/build/host_sim/.
"""
import argparse
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
KLTN = HERE.parents[1]
sys.path.insert(0, str(KLTN / "fpga" / "soc_xif" / "sw"))
import soc_host as H  # noqa: E402


def sources():
    rtl = KLTN / "rtl"
    f = [rtl / "core_if_xif" / "cvxif_pkg.sv"]
    f += [p for p in sorted((rtl / "core_if_xif").glob("*.v")) if p.name != "Microprocessor.v"]
    f.append(rtl / "matrix_if" / "fp32_fma_pkg.sv")
    for p in sorted((rtl / "matrix_if").glob("*.sv")):
        if p.name == "fp32_fma_pkg.sv":
            continue
        x = rtl / "matrix_if_xif" / p.name
        f.append(x if x.exists() else p)
    f += [rtl / "core_if_xif" / "matrix_xif_adapter.sv", rtl / "core_matrix_xif" / "matrix_xif_coproc.sv",
          rtl / "core_matrix_xif" / "core_matrix_xif.sv", rtl / "core_matrix_xif" / "halt_detect.v",
          rtl / "core_matrix_xif" / "rv32if_xif_soc.v", HERE / "bram_tdp_model.v", HERE / "tb_soc_image.sv"]
    return [str(p) for p in f]


class SimMem:
    def __init__(self):
        self.cur = {}

    def read(self, off):
        return self.cur.get(off >> 2, 0)

    def write(self, off, val):
        val &= 0xFFFFFFFF
        if val:
            self.cur[off >> 2] = val
        else:
            self.cur.pop(off >> 2, None)


class SimSoc(H.Soc):
    def __init__(self, vvp, work, mhz=100.0):     # no H.Soc.__init__: ID / CONFIG come with the first run
        self.vvp, self.work, self.mhz = vvp, work, mhz
        self.imem, self.dmem = SimMem(), SimMem()
        self.phase, self.snap, self.w1c, self.msel, self.max_cycles, self.nrun = "idle", None, False, 0, 0, 0

    def _simulate(self):
        self.nrun += 1
        d = self.work / f"run{self.nrun:03d}"
        d.mkdir(parents=True, exist_ok=True)
        for name, mem, words in (("imem.hex", self.imem, H.IMEM_BYTES // 4), ("dmem.hex", self.dmem, H.DMEM_BYTES // 4)):
            (d / name).write_text("".join(f"{mem.cur.get(i, 0):08x}\n" for i in range(words)))
        res = subprocess.run(["vvp", "-n", str(self.vvp), f"+imem={d / 'imem.hex'}", f"+dmem={d / 'dmem.hex'}",
                              f"+max_cycles={self.max_cycles}", f"+out={d / 'snap.txt'}"],
                             capture_output=True, text=True)
        (d / "vvp.log").write_text(res.stdout + res.stderr)
        snap = {"irq": 0, "pre": {}, "post": {}, "mreg": {}, "dmem": {}, "end": None}
        for line in (d / "snap.txt").read_text().splitlines():
            t = line.split()
            if t[0] == "IRQ":
                snap["irq"] = int(t[1])
            elif t[0] == "REG":
                snap[t[1]][int(t[2])] = int(t[3])
            elif t[0] == "MREG":
                snap["mreg"][tuple(map(int, t[1:4]))] = int(t[4])
            elif t[0] == "DMEM":
                snap["dmem"][int(t[1])] = int(t[2])
            elif t[0] == "END":
                snap["end"] = t[1]
        if snap["end"] is None:
            raise RuntimeError(f"simulation did not finish: {d / 'vvp.log'}")
        self.snap, self.w1c = snap, False
        if snap["end"] == "ok":
            self.dmem.cur = dict(snap["dmem"])
            self.phase = "run"
            if self.nrun == 1:
                self.check_ident()                  # ID / CONFIG constants of soc_host.py vs the RTL

    def w(self, off, val):
        if off == H.CTRL:
            if val & 1 and self.phase != "run":
                self._simulate()
            elif not val & 1 and self.phase == "run":
                self.phase = "stopped"
        elif off == H.MAX_CYCLES:
            self.max_cycles = val
        elif off == H.IRQ_STATUS and self.phase == "run":
            self.w1c = True
        elif off == H.MSEL:
            self.msel = val

    def r(self, off):
        s = self.snap
        if s is None or s["end"] != "ok":
            return 0
        if self.phase == "run":
            if off == H.IRQ_STATUS and not self.w1c:
                return s["irq"]
            if off == H.MDATA:
                m = self.msel
                return s["mreg"].get((m & 7, m >> 8 & 7, m >> 16 & 7), 0)
            return s["pre"][off]
        return s["post"][off]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--case", nargs="+", help="matrix_sw case directories (mem.hex + sim.log)")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--max-cycles", type=int, default=1_000_000)
    a = ap.parse_args()

    work = HERE / "build" / "host_sim"
    work.mkdir(parents=True, exist_ok=True)
    vvp = work / "tb.vvp"
    comp = subprocess.run(["iverilog", "-g2012", "-s", "tb_soc_image", "-o", str(vvp)] + sources(),
                          capture_output=True, text=True)
    if comp.returncode:
        sys.exit("compile failed:\n" + comp.stdout + comp.stderr)

    soc = SimSoc(vvp, work)
    if a.case:
        oks = []
        for d in a.case:
            d = Path(d)
            oks.append((d.name, H.run_image(soc, d / "mem.hex", d / "sim.log", None, a.max_cycles, d.name)))
        print()
        for n, ok in oks:
            print(f"{n:16s} {'PASS' if ok else 'FAIL'}")
        ok = all(o for _, o in oks)
    else:
        ok = H.demo(soc, a.runs, 1, a.max_cycles)
    print("SOC_HOST_SIM_PASS" if ok else "SOC_HOST_SIM_FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
