#!/usr/bin/env bash
# SoC testbench (rtl/core_matrix_xif/rv32if_xif_soc.v) with Icarus Verilog 12, twice: BRAM ports
# in WRITE_FIRST mode (Block Memory Generator default) and in NO_CHANGE mode.
# Logs: tb/soc_xif/build/<mode>/soc_xif.log. Then the board software fpga/soc_xif/sw/soc_host.py on
# the RTL (host_sim.py: GEMM demo, and the sw/matrix C programs when scripts/run_matrix_sw.py has
# built them in sim/build/matrix_sw/). Expect "SOC_XIF_ALL_PASS" at the end.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
kltn="$(cd "$here/../.." && pwd)"
kr260_tb="$kltn/fpga/kr260/tb"            # tb_matrix_pkg.sv + rv32if_asm.svh (partner)

files="$kltn/rtl/core_if_xif/cvxif_pkg.sv"
for f in "$kltn"/rtl/core_if_xif/*.v; do
    case "$(basename "$f")" in Microprocessor.v) ;; *) files="$files $f";; esac
done
files="$files $kltn/rtl/matrix_if/fp32_fma_pkg.sv"
for f in "$kltn"/rtl/matrix_if/*.sv; do
    name="$(basename "$f")"
    [ "$name" = fp32_fma_pkg.sv ] && continue
    if [ -f "$kltn/rtl/matrix_if_xif/$name" ]; then files="$files $kltn/rtl/matrix_if_xif/$name"
    else files="$files $f"; fi
done
files="$files $kltn/rtl/core_if_xif/matrix_xif_adapter.sv $kltn/rtl/core_matrix_xif/matrix_xif_coproc.sv"
files="$files $kltn/rtl/core_matrix_xif/core_matrix_xif.sv $kltn/rtl/core_matrix_xif/halt_detect.v"
files="$files $kltn/rtl/core_matrix_xif/rv32if_xif_soc.v $here/bram_tdp_model.v"

rc=0
for mode in write_first no_change; do
    build="$here/build/$mode"
    mkdir -p "$build"
    defs=""
    [ "$mode" = no_change ] && defs="-DBRAM_NO_CHANGE"
    echo "== BRAM $mode =="
    iverilog -g2012 $defs -I "$kr260_tb" -o "$build/tb.vvp" "$kr260_tb/tb_matrix_pkg.sv" $files \
        "$here/tb_rv32if_xif_soc.sv" > "$build/compile.log" 2>&1 \
        || { echo "COMPILE ERROR (see $build/compile.log)"; cat "$build/compile.log" | head -20; rc=1; continue; }
    (cd "$build" && vvp -n tb.vvp > run.log 2>&1) || true
    grep -E "\->|TONG|RESULT|FAIL\]|FATAL" "$build/soc_xif.log" 2>/dev/null || grep -E "FATAL|error" "$build/run.log"
    grep -q "RESULT: PASS" "$build/soc_xif.log" 2>/dev/null || rc=1
done

py=python3; "$py" -c "" 2>/dev/null || py=python
echo "== soc_host.py on the RTL (host_sim.py) =="
"$py" "$here/host_sim.py" --runs 5 > "$here/build/host_sim_demo.log" 2>&1 || rc=1
grep -E "RESULT|SOC_HOST_SIM|FAIL\]" "$here/build/host_sim_demo.log"
cases=$(ls -d "$kltn"/sim/build/matrix_sw/*/*/ 2>/dev/null | head -10)
if [ -n "$cases" ]; then
    "$py" "$here/host_sim.py" --case $cases > "$here/build/host_sim_cases.log" 2>&1 || rc=1
    grep -E " PASS$| FAIL$|SOC_HOST_SIM" "$here/build/host_sim_cases.log"
else
    echo "(no sim/build/matrix_sw cases: run python3 scripts/run_matrix_sw.py to add them)"
fi
if [ $rc -eq 0 ]; then echo "SOC_XIF_ALL_PASS"; else echo "SOC_XIF_FAIL"; fi
exit $rc
