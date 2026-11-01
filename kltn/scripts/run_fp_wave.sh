#!/usr/bin/env bash
# Simulate RV32F instructions on the core, dump a VCD, print EX/MEM cycles per
# instruction, and (with --view) open it in GTKWave.
# Usage (WSL, from kltn/):
#   bash scripts/run_fp_wave.sh                  # all 26 F instructions
#   bash scripts/run_fp_wave.sh fadd --view      # ONLY FADD.S: no setup loads in the wave
#   bash scripts/run_fp_wave.sh fdiv --set f2=00000000 --view   # special case: x/0
#   bash scripts/run_fp_wave.sh fadd --rm 5 --view              # reserved rounding mode
#   bash scripts/run_fp_wave.sh flw --mem 1=12345678 --view     # flw f5,4(x0) loads 0x12345678
# Default operands: f1=1.5 f2=2.25 f3=1.0 f4=0.99999994 x1=-7 x2=5.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
only="" view=0 extra=()
while (( $# )); do
    case "$1" in
        --view) view=1 ;;
        --set|--rm|--mem) extra+=("$1" "${2:?$1 needs a value}"); shift ;;
        -*) echo "Unknown option $1" >&2; exit 2 ;;
        *) only="$1" ;;
    esac
    shift
done
if (( ${#extra[@]} )) && [[ -z "$only" ]]; then
    echo "--set/--rm/--mem need one instruction, e.g. fdiv --set f2=00000000" >&2; exit 2
fi
tag="${only:-all26}$(printf '_%s' "${extra[@]+"${extra[@]}"}" | tr -c 'A-Za-z0-9=._\n' '_')"
[[ ${#extra[@]} -eq 0 ]] && tag="${only:-all26}"
out="$root/sim/build/wave_$tag"
cd "$root"
python3 scripts/gen_fp_wave_demo.py --output "$out" ${only:+--only "$only"} "${extra[@]+"${extra[@]}"}"
if [[ -n "$only" ]]; then
    # Isolated: target instruction only, registers preloaded, dump stops at retire.
    iverilog -g2012 -Wall -Wno-timescale -s tb_wave_one -o "$out/tb_wave" \
        rtl/core_if/*.v tb/core_if/tb_wave_one.v
    vvp "$out/tb_wave" +case="$out/iso.txt" +vcd="$out/wave.vcd" | grep -v '^VCD info'
else
    iverilog -g2012 -Wall -Wno-timescale -s tb_f10_e2e -o "$out/tb_wave" \
        rtl/core_if/*.v tb/core_if/tb_fp_mem_e2e.v tb/core_if/tb_f10_e2e.v
    vvp "$out/tb_wave" +case="$out/wave.txt" +vcd="$out/wave.vcd" \
        +trace_csv="$out/retire.csv" | grep -v '^VCD info'
fi
python3 scripts/measure_fp_ex_cycles.py "$out/wave.vcd" --labels "$out/labels.json" \
    | tee "$out/ex_cycles.txt"
echo "VCD:  $out/wave.vcd"
echo "GTKW: $out/wave.gtkw"
if (( view )); then gtkwave "$out/wave.gtkw" & fi
