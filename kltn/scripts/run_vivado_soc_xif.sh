#!/usr/bin/env bash
# WSL front end of scripts/run_vivado_soc_xif.ps1 (Windows Vivado 2022.2).
#   ./scripts/run_vivado_soc_xif.sh                     # 100 MHz, full (bitstream + .bin/.hwh/.xsa)
#   ./scripts/run_vivado_soc_xif.sh 100 impl            # timing / utilization only
#   ./scripts/run_vivado_soc_xif.sh 100 bd              # project + block design for the GUI
#   ./scripts/run_vivado_soc_xif.sh 100 full --board kv260 --strategy Performance_Explore
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner_win="$(wslpath -w "${script_dir}/run_vivado_soc_xif.ps1")"
args=()
for a in "$@"; do
    case "$a" in
        --board)    args+=("-Board") ;;
        --strategy) args+=("-Strategy") ;;
        --vivado)   args+=("-VivadoBat") ;;
        *)          args+=("$a") ;;
    esac
done
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${runner_win}" "${args[@]}"
