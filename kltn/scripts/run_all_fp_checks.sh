#!/usr/bin/env bash
# One command for all 26 RV32F instructions:
#   1. ACT4 official tests (all ELFs, self-checked against Sail expectations)
#   2. isolated waveform run of each instruction (result/flags checked, EX/MEM cycles measured)
#   3. one combined waveform with all 26 instructions in sequence
# Usage (WSL, from kltn/):
#   bash scripts/run_all_fp_checks.sh               # everything
#   bash scripts/run_all_fp_checks.sh --view        # ... then open the combined wave in GTKWave
#   bash scripts/run_all_fp_checks.sh --skip-act4   # waveform part only (fast, no RISC-V toolchain)
#   bash scripts/run_all_fp_checks.sh --no-flags    # ACT4 results only (CSR-free programs, fflags not checked)
set -uo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
view=0 act4=1 act4_opts=()
for arg in "$@"; do
    case "$arg" in
        --view) view=1 ;;
        --skip-act4) act4=0 ;;
        --no-flags) act4_opts+=(--no-flags) ;;
        *) echo "Unknown option $arg" >&2; exit 2 ;;
    esac
done
INSNS=(flw fsw fadd.s fsub.s fmul.s fdiv.s fsqrt.s fmadd.s fmsub.s fnmsub.s fnmadd.s
       fsgnj.s fsgnjn.s fsgnjx.s fmin.s fmax.s feq.s flt.s fle.s
       fcvt.w.s fcvt.wu.s fcvt.s.w fcvt.s.wu fmv.x.w fmv.w.x fclass.s)
failed=0

act4_status="SKIPPED"
if (( act4 )); then
    echo "=== [1/3] ACT4: all implemented RV32F tests ==="
    if python3 scripts/act4_cli.py all "${act4_opts[@]}"; then act4_status="PASS"; else act4_status="FAIL"; failed=1; fi
fi

echo "=== [2/3] Isolated waveform run of each instruction ==="
summary=()
for insn in "${INSNS[@]}"; do
    log="$(bash scripts/run_fp_wave.sh "$insn" 2>&1)"
    if grep -q WAVE_ONE_TEST_PASS <<<"$log"; then status=PASS; else status=FAIL; failed=1; fi
    cycles="$(grep -E "^${insn//./\\.}[ ,]" <<<"$log" | head -1 | awk '{print $(NF-2) " " $(NF-1)}')"
    summary+=("$(printf '%-11s %-5s EX/MEM=%s' "$insn" "$status" "${cycles:-?}")")
    printf '  %s\n' "${summary[-1]}"
    [[ $status == FAIL ]] && printf '%s\n' "$log" | tail -5 | sed 's/^/      /'
done

echo "=== [3/3] Combined waveform (all 26 in one program) ==="
log="$(bash scripts/run_fp_wave.sh 2>&1)"
if grep -q F10_E2E_TEST_PASS <<<"$log"; then combined=PASS; else combined=FAIL; failed=1; fi
echo "  combined program: $combined"

echo
echo "================ SUMMARY ================"
echo "ACT4 (26 instructions):        $act4_status${act4_opts:+ (results only, CSR-free programs)}"
echo "Isolated waves (26 runs):      $(printf '%s\n' "${summary[@]}" | grep -c ' PASS ')/26 PASS"
echo "Combined wave:                 $combined"
echo "Waves: sim/build/wave_<insn>/wave.gtkw  (open one: gtkwave sim/build/wave_fadd.s/wave.gtkw)"
echo "Combined: sim/build/wave_all26/wave.gtkw"
(( view )) && gtkwave sim/build/wave_all26/wave.gtkw &
exit $failed
