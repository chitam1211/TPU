#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner_win="$(wslpath -w "${script_dir}/run_vivado_kv260.ps1")"

# --core_if_xif (as in the Python scripts) is the PowerShell switch -core_if_xif;
# --ooc <design> is -Ooc <design> (core, coproc, core_matrix); --from-run <run> is -FromRun <run>.
args=()
for a in "$@"; do
    case "$a" in
        --core_if_xif) args+=("-core_if_xif") ;;
        --ooc)         args+=("-Ooc") ;;
        --from-run)    args+=("-FromRun") ;;
        *)             args+=("$a") ;;
    esac
done

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${runner_win}" "${args[@]}"
