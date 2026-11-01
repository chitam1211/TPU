#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner_win="$(wslpath -w "${script_dir}/run_vivado_kv260.ps1")"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${runner_win}" "$@"

