# KV260 synthesis and implementation

This non-project Vivado flow measures the RV32IF core (pipeline and FPU)
out-of-context. The top module is `core_timing_wrap`, which instantiates `core`
and registers every data port, so the memory-interface paths are timed instead
of left unconstrained. The wrapper adds one cycle to the memory handshake and
exists only for measurement; it must not replace `core` in simulation.
`microprocessor` cannot be measured because it has no outputs, so synthesis
removes the entire design.

The target device is the KV260 SOM part `xck26-sfvc784-2LV-c`. The clock period
defaults to 10 ns (100 MHz) and is the only clock constraint: the flow writes
`clock.xdc` from it into the run's build folder. Pass another period in
nanoseconds as the first argument. The flow (`implement_core_if.tcl`) runs synthesis, placement, and
routing; it does not generate a bitstream and needs no pin assignments.

Every run gets its own folders, named by start time, mode and clock, so runs never
overwrite each other:

| Folder | Contents |
|---|---|
| `reports/vivado/runs/<yyyyMMdd_HHmmss>_<mode>_<clock>ns/` | reports, Vivado log and journal, `run_info.txt` |
| `build/vivado/runs/<same name>/` | checkpoints (`.dcp`), netlist, `clock.xdc`, `.Xil`, crash dumps |

`run_info.txt` records the mode, clock, sweep configurations, start and end time,
status, and the RTL version: the git commit plus the uncommitted files under
`rtl/` and `fpga/`. The folders `*/vivado/kv260_core_if` and `*/vivado/kv260_synth_sweep`
hold older runs made before this layout.

From a WSL VS Code terminal:

```bash
cd /mnt/c/TPU/TPU/kltn
chmod +x scripts/run_vivado_kv260.sh
./scripts/run_vivado_kv260.sh          # 10 ns
./scripts/run_vivado_kv260.sh 8.0      # 8 ns (125 MHz)
```

From a PowerShell VS Code terminal:

```powershell
cd C:\TPU\TPU\kltn
.\scripts\run_vivado_kv260.ps1
.\scripts\run_vivado_kv260.ps1 -ClockNs 8.0
```

A second argument selects the mode (default `full`):

| Mode | What runs | Main output |
|---|---|---|
| `full` | synthesis, then opt/place/phys_opt/route | `run_summary.txt` (routed timing), post-synthesis and post-route reports |
| `synth` | synthesis only | `post_synth_summary.txt` (estimated timing, no wire delays), `post_synth_*.rpt` |
| `netlist` | synthesis of `core` itself (no wrapper), functional netlist | `build/vivado/runs/<run>/netlist/core_funcsim.v`, `post_synth_core_utilization.rpt` |

```bash
./scripts/run_vivado_kv260.sh 6.5 synth     # synthesis only, 6.5 ns target
./scripts/run_vivado_kv260.sh 10 netlist    # netlist for post-synthesis simulation
```

Use routed timing (`full`) for Fmax; post-synthesis timing is only an estimate.

### Synthesis sweep

`sweep` mode runs synthesis only, once per strategy, each in a new Vivado
session (`synth_sweep.tcl` handles one configuration; the runner loops). Several
`synth_design` runs in one session influenced each other (PerformanceOptimized
alone: -0.451 ns; the same after other runs in one session: -5.136 ns), so the
runs are kept apart. Each configuration is a `synth_design -directive` value,
optionally with `+retiming` (adds `-retiming`). Directive names are case-sensitive.
Logs: `vivado_<config>.log` in the run folder.

```bash
./scripts/run_vivado_kv260.sh 6.5 sweep        # default list: all 12 directives of 2022.2 + 2 with retiming
./scripts/run_vivado_kv260.sh 6.5 sweep -Configs default,PerformanceOptimized,PerformanceOptimized+retiming
```

Reports go to `<run folder>/<config>/` (utilization,
timing summary, `summary.txt`); `sweep_summary.txt` and `sweep_summary.csv`
compare all configurations (estimated WNS/TNS, failing endpoints, LUTs, FFs,
CARRY8, DSPs, logic levels of the worst path, synthesis time). The timing is the
post-synthesis estimate: confirm a promising strategy with a routed run.

### Synthesis + implementation sweep

`fullsweep` mode (`full_sweep.tcl`) uses project mode, so the preconfigured strategies of
Vivado 2022.2 are applied by Vivado itself (UG901 *Vivado Preconfigured Strategies*, UG904
*Implementation Categories, Strategy Descriptions, and Directive Mapping*). Every run is a separate
Vivado process, `-Jobs` of them at a time (about 4.5 GB of memory each).

- Stage 1: each synthesis configuration (the 8 synthesis strategies, the directives that no
  strategy uses, and three `+retiming` variants), each routed with the default implementation.
- Stage 2: the stage-1 synthesis with the best routed WNS (`-Base auto`), routed with each
  implementation strategy (the 33 of 2022.2 minus the 6 for multi-die devices).

```powershell
.\scripts\run_vivado_kv260.ps1 6.5 fullsweep                       # defaults: 16 + 26 routed runs
.\scripts\run_vivado_kv260.ps1 6.5 fullsweep -Jobs 3 -Base top2    # stage 2 on the best two syntheses
.\scripts\run_vivado_kv260.ps1 6.5 fullsweep -Configs default,default+retiming -Impl default,Performance_Explore
```

Results: `full_sweep_summary.txt` (routed WNS, TNS, Fmax per stage), `rows.csv` (also failing
endpoints, hold, LUT/FF/CARRY8/DSP, worst path), and `<synthesis>__<implementation>/` with the
routed timing and utilization reports. A failed run is listed as `ERROR` and the sweep goes on;
its log is `build/vivado/runs/<run>/proj/sweep.runs/<run name>/runme.log`.

### Post-synthesis simulation

`netlist` mode synthesizes `core` (the wrapper would add a cycle to the memory
handshake) and writes a functional netlist made of UNISIM primitives. It is run
with xsim, using `tb_act4_unified.v` compiled with `-d NETLIST`: that define
leaves out the `+trace`/`+explain` logging, which reads RTL-internal signals that
do not exist after synthesis. The RTL simulation is unchanged.

```bash
python3 scripts/run_act4_netlist.py                  # one ACT4 ELF per instruction (26 F + 39 I)
python3 scripts/run_act4_netlist.py F-fadd.s-01      # chosen ELFs
python3 scripts/run_act4_netlist.py all              # all 119 ELFs (80 F + 39 I)
```

Each ELF is self-checking, so `PASS` means every testcase in it matched Sail on
the netlist. The script also compares the cycle count with the newest RTL run:
synthesis must not change the cycle-by-cycle behaviour. Results go to
`reports/act4_netlist/results_<synthesis configuration>.csv` (for example
`results_default.csv`, `results_poweroptimized_medium.csv`; the configuration is read
from the netlist run's `vivado.log`), xsim logs to `sim/build/act4_netlist/`. A netlist exported by
hand (Vivado GUI: `open_run synth_1` or `open_run impl_1`, then `write_verilog -mode funcsim`) has no
such log: name its results with `--tag`, and use `--work <dir>` to run it next to another job.

```bash
python3 scripts/run_act4_netlist.py all --netlist build/vivado/kltn_gui/netlist/core_funcsim_routed.v --tag gui_default_routed
```

The runner prints the run folder at the start and the end. The most useful files of
a `full` run are `run_summary.txt`, `post_route_utilization.rpt`, and
`post_route_timing_summary.rpt`. The newest runs come last in
`ls reports/vivado/runs/`.

If Vivado exits before printing its banner, first verify the installation from
PowerShell:

```powershell
& 'D:\Xilinx\Vivado\2022.2\bin\vivado.bat' -version
```

An installation moved between drive letters should be repaired with the Xilinx
installer or mounted using the original drive letter. Editing only
`settings64.bat` may be insufficient because other installed components can
retain the original path.

This flow does not yet represent the final RV32IF-plus-Matrix system. The active
RV32IF top and the inherited RV32I Matrix top are currently separate RTL designs.
