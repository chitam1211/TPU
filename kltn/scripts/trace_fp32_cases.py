#!/usr/bin/env python3
"""Explore rounding modes and IEEE-754 special cases in the existing FP32 RTL.

WSL examples:
  python3 scripts/trace_fp32_cases.py rounding
  python3 scripts/trace_fp32_cases.py special
  python3 scripts/trace_fp32_cases.py special --case signaling_nan --verbose
  python3 scripts/trace_fp32_cases.py rounding --a -1 --b=-5.9604644775390625e-8

This is an explanatory RTL trace, not an independent reference model.
"""

import argparse
from decimal import Decimal, localcontext
from fractions import Fraction
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from trace_fp32_addsub import FLAG_BITS, MODES, RTL, TB, bits_float, fields, float_bits, show_float, trace_event


ROUNDING_NAMES = {
    "rne": "gần nhất, hòa chọn số chẵn",
    "rtz": "về 0",
    "rdn": "về -vô cực",
    "rup": "về +vô cực",
    "rmm": "gần nhất, hòa xa 0",
}

SPECIAL_CASES = {
    "quiet_nan": ("NaN yên lặng + 1", 0x7FC00001, 0x3F800000, "add", "rne"),
    "signaling_nan": ("NaN báo hiệu + 1", 0x7F800001, 0x3F800000, "add", "rne"),
    "opposite_infinities": ("+vô cực + -vô cực", 0x7F800000, 0xFF800000, "add", "rne"),
    "one_infinity": ("+vô cực + 2", 0x7F800000, 0x40000000, "add", "rne"),
    "cancel_to_positive_zero": ("1 - 1, làm tròn gần nhất", 0x3F800000, 0x3F800000, "sub", "rne"),
    "cancel_to_negative_zero": ("1 - 1, làm tròn về -vô cực", 0x3F800000, 0x3F800000, "sub", "rdn"),
    "exact_subnormal": ("số dưới chuẩn nhỏ nhất + chính nó", 0x00000001, 0x00000001, "add", "rne"),
    "overflow_rne": ("số hữu hạn lớn nhất + chính nó, RNE", 0x7F7FFFFF, 0x7F7FFFFF, "add", "rne"),
    "overflow_rtz": ("số hữu hạn lớn nhất + chính nó, RTZ", 0x7F7FFFFF, 0x7F7FFFFF, "add", "rtz"),
    "invalid_rm": ("mã chế độ làm tròn không hợp lệ (101)", 0x3F800000, 0x3F800000, "add", "invalid"),
}


def flag_names(flags):
    return ",".join(name for bit, name in FLAG_BITS if flags & (1 << bit)) or "—"


def run_rtl(executable, a, b, operation, mode):
    rm_bits = 5 if mode == "invalid" else MODES[mode]
    command = ["vvp", str(executable), f"+a={a:08x}", f"+b={b:08x}",
               f"+sub={int(operation == 'sub')}", f"+rm={rm_bits}"]
    process = subprocess.run(command, capture_output=True, text=True, check=False)
    if process.returncode:
        raise RuntimeError(process.stdout + process.stderr)
    events = [fields(line) for line in process.stdout.splitlines() if line.startswith("TRACE ")]
    if not events or events[-1].get("state") != "DONE":
        raise RuntimeError("RTL không phát done trong lần chạy này")
    return events


def result_of(events):
    done = events[-1]
    return int(done["result"], 16), int(done["flags"], 16), int(done["illegal"])


def exact_expression(a, b, operation):
    try:
        left = Fraction(bits_float(a))
        right = Fraction(bits_float(b))
    except (ValueError, OverflowError):
        return "không hữu hạn (NaN hoặc vô cực)"
    value = left + right if operation == "add" else left - right
    with localcontext() as context:
        context.prec = 40
        return format(Decimal(value.numerator) / Decimal(value.denominator), ".18g")


def print_verbose(events):
    for event in events:
        trace_event(event)


def rounding_suite(executable, a, b, operation, verbose):
    symbol = "+" if operation == "add" else "-"
    print(f"\nCÙNG MỘT PHÉP TÍNH: {show_float(a)} {symbol} {show_float(b)}")
    print(f"A=0x{a:08x}, B=0x{b:08x}; giá trị toán học trước làm tròn ≈ {exact_expression(a, b, operation)}")
    print("Mọi dòng dưới đây dùng đúng cùng hai mẫu bit đầu vào; chỉ thay rounding mode.\n")
    print(f"{'Mode':<5} {'Quy tắc':<28} {'Kết quả FP32':<17} {'Bit kết quả':<12} {'G/R/S':<7} {'Tăng?':<6} Cờ")
    for mode, description in ROUNDING_NAMES.items():
        events = run_rtl(executable, a, b, operation, mode)
        result, flags, illegal = result_of(events)
        if illegal:
            raise RuntimeError(f"RTL báo illegal_rm với mode {mode}")
        round_event = next((event for event in events if event["state"] == "ROUND"), None)
        grs = (round_event["guard"] + "/" + round_event["round"] + "/" +
               round_event["sticky"]) if round_event else "—"
        increment = round_event["increment"] if round_event else "—"
        print(f"{mode.upper():<5} {description:<28} {show_float(result):<17} "
              f"0x{result:08x}   {grs:<7} {increment:<6} {flag_names(flags)}")
        if verbose:
            print_verbose(events)
            print()
    print("G/R/S là ba bit dùng để quyết định làm tròn; 'Tăng?' cho biết RTL có cộng 1 vào phần trị được giữ lại hay không.")
    print("NX = kết quả không biểu diễn chính xác; OF = tràn; UF = hụt; NV = phép toán không hợp lệ.")


def state_path(events):
    path = []
    for event in events:
        state = event["state"]
        if path and state == "NORMALIZE" and path[-1].startswith("NORMALIZE"):
            count = int(path[-1].split("×")[1]) + 1 if "×" in path[-1] else 2
            path[-1] = f"NORMALIZE×{count}"
        else:
            path.append(state)
    return " → ".join(path)


def special_suite(executable, selected_case, verbose):
    cases = ([selected_case] if selected_case else SPECIAL_CASES.keys())
    print("\nCÁC TRƯỜNG HỢP ĐẶC BIỆT — kết quả quan sát từ RTL")
    for name in cases:
        title, a, b, operation, mode = SPECIAL_CASES[name]
        events = run_rtl(executable, a, b, operation, mode)
        result, flags, illegal = result_of(events)
        symbol = "+" if operation == "add" else "-"
        print(f"\n{name}: {title}")
        print(f"  {show_float(a)} {symbol} {show_float(b)} "
              f"[A=0x{a:08x}, B=0x{b:08x}, rm={mode}]")
        print(f"  Đường đi: {state_path(events)}")
        if illegal:
            print(f"  RTL báo illegal_rm=1; dữ liệu 0x{result:08x} không phải kết quả FP hợp lệ.")
        else:
            print(f"  Kết quả: {show_float(result)} (0x{result:08x}); "
                  f"cờ: {flag_names(flags)} (0x{flags:02x}); illegal_rm=0")
        if verbose:
            print_verbose(events)
    print("\nNV = phép toán không hợp lệ; OF = tràn; UF = hụt; NX = kết quả không biểu diễn chính xác.")


def operand(parser, decimal_value, bit_value, label):
    if decimal_value is not None and bit_value is not None:
        parser.error(f"Chỉ chọn một trong --{label} và --{label}-bits")
    if bit_value is not None:
        if not 0 <= bit_value <= 0xFFFFFFFF:
            parser.error(f"--{label}-bits phải là một giá trị 32 bit")
        return bit_value
    return float_bits(decimal_value) if decimal_value is not None else None


def main():
    parser = argparse.ArgumentParser(description="Xem các trường hợp đặc biệt và so 5 cách làm tròn trên RTL FP32")
    parser.add_argument("suite", choices=("rounding", "special", "all"), nargs="?", default="all")
    parser.add_argument("--a", type=float, help="Toán hạng A dạng thập phân cho rounding")
    parser.add_argument("--b", type=float, help="Toán hạng B dạng thập phân cho rounding")
    parser.add_argument("--a-bits", type=lambda x: int(x, 16), help="Mẫu bit FP32 của A dạng hex")
    parser.add_argument("--b-bits", type=lambda x: int(x, 16), help="Mẫu bit FP32 của B dạng hex")
    parser.add_argument("--op", choices=("add", "sub"), default="add", help="Phép tính cho rounding")
    parser.add_argument("--case", choices=tuple(SPECIAL_CASES), help="Chỉ chạy một trường hợp special")
    parser.add_argument("--verbose", action="store_true", help="In từng trạng thái và thanh ghi bên trong RTL")
    args = parser.parse_args()
    a = operand(parser, args.a, args.a_bits, "a")
    b = operand(parser, args.b, args.b_bits, "b")
    if (a is None) != (b is None):
        parser.error("Cần cung cấp cả A và B cho rounding")
    if args.suite == "special" and a is not None:
        parser.error("--a/--b chỉ dùng với rounding hoặc all")
    if args.suite == "rounding" and args.case:
        parser.error("--case chỉ dùng với special hoặc all")
    if not shutil.which("iverilog") or not shutil.which("vvp"):
        parser.error("Chưa tìm thấy iverilog/vvp trong PATH")

    with tempfile.TemporaryDirectory(prefix="fp32_cases_") as temp_dir:
        executable = Path(temp_dir) / "trace.vvp"
        subprocess.run(["iverilog", "-g2012", "-s", "tb_fp32_addsub_trace",
                        "-o", str(executable), str(RTL), str(TB)], check=True)
        if args.suite in ("rounding", "all"):
            rounding_suite(executable, a if a is not None else 0x3F800000,
                           b if b is not None else 0x33800000, args.op, args.verbose)
        if args.suite in ("special", "all"):
            special_suite(executable, args.case, args.verbose)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Lỗi: {error}", file=sys.stderr)
        sys.exit(1)
