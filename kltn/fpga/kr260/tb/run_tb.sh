#!/usr/bin/env bash
# Chay 2 testbench cua wrapper KR260 bang Icarus Verilog 12. Ket qua: tb/build/*.log
#   tb_rv32if_matrix_axi : kiem tra co ban (ban do thanh ghi, 1 chuong trinh GEMM)
#   tb_kr260_programs    : 12 kich ban P1-P8 chi qua AXI4-Lite (xem dau file)
set -e
here="$(cd "$(dirname "$0")" && pwd)"
kltn="$here/../../.."                     # thu muc kltn/ cua repo
cpu="$kltn/rtl/core_if"                   # CPU RV32IF (bo Core.v / Microprocessor.v)
rtl="$kltn/rtl/matrix_if"                 # core_matrix.v + matrix_core_v2
common="$here"                            # tb_matrix_pkg.sv (ban sao tu Verify/common)
asm="$here"                               # rv32if_asm.svh (ban sao tu Verify/top_test)
build="$here/build"
mkdir -p "$build"

matrix="matrix_cfg_pkg.sv fp32_fma_pkg.sv matrix_dispatch.sv matrix_ew.sv matrix_ew_fp.sv
        matrix_mac_int.sv matrix_mac_fp.sv matrix_misc.sv matrix_regfile.sv
        matrix_tile_ls.sv matrix_core_v2.sv"
files=""
for f in $matrix; do files="$files $rtl/$f"; done
for f in "$cpu"/*.v; do case "$(basename "$f")" in Core.v|Microprocessor.v) ;; *) files="$files $f";; esac; done
files="$files $rtl/core_matrix.v $here/../rtl/rv32if_matrix_soc.v $here/../rtl/rv32if_matrix_axi.v"

rc=0
for tb in tb_rv32if_matrix_axi tb_kr260_programs; do
    echo "== $tb =="
    iverilog -g2012 -I "$asm" -o "$build/$tb.vvp" "$common/tb_matrix_pkg.sv" $files "$here/$tb.sv" \
        > "$build/$tb.compile.log" 2>&1 || { echo "COMPILE ERROR (xem build/$tb.compile.log)"; rc=1; continue; }
    (cd "$build" && vvp -n "$tb.vvp" > "$tb.log" 2>&1) || true
    grep -E "RESULT|TONG|FAIL\]|->" "$build/$tb.log" | tail -40
    grep -q "RESULT: PASS" "$build/$tb.log" || rc=1
done
exit $rc
