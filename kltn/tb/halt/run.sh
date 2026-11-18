#!/usr/bin/env bash
# Halt detector check (rtl/core_if_xif + rtl/core_matrix_xif/halt_detect.v). Expect HALT_DETECT_ALL_PASS.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
kltn="$here/../.."
cd "$here"
iverilog -g2012 -o halt.vvp "$kltn"/rtl/core_if_xif/cvxif_pkg.sv "$kltn"/rtl/core_if_xif/*.v \
    "$kltn/rtl/core_matrix_xif/halt_detect.v" tb_halt_detect.v
vvp -n halt.vvp
