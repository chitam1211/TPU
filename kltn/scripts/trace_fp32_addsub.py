#!/usr/bin/env python3
"""Print the actual cycle-by-cycle state of rtl/core_if/fp32_addsub.v.

Run in WSL: python3 scripts/trace_fp32_addsub.py
Or:         python3 scripts/trace_fp32_addsub.py --a 1.5 --b 2.25 --op add
"""

import argparse
import math
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl" / "core_if" / "fp32_addsub.v"
TB = ROOT / "tb" / "core_if" / "tb_fp32_addsub_trace.v"
MODES = {"rne": 0, "rtz": 1, "rdn": 2, "rup": 3, "rmm": 4}
FLAG_BITS = ((4, "NV"), (3, "DZ"), (2, "OF"), (1, "UF"), (0, "NX"))


def float_bits(value):
    try:
        return int.from_bytes(struct.pack(">f", float(value)), "big")
    except OverflowError as exc:
        raise ValueError(f"{value} không biểu diễn được dưới dạng FP32") from exc


def bits_float(bits):
    return struct.unpack(">f", bits.to_bytes(4, "big"))[0]


def show_float(bits):
    number = bits_float(bits)
    if math.isnan(number):
        return "NaN"
    if math.isinf(number):
        return "-vô cực" if number < 0 else "+vô cực"
    return format(number, ".9g")


def fields(line):
    return dict(re.findall(r"([a-z_]+)=([^\s]+)", line))


def number(event, key, base=10):
    return int(event[key], base)


def trace_event(event):
    cycle = number(event, "cycle")
    state = event["state"]
    if state == "CLASSIFY":
        a, b = number(event, "a", 16), number(event, "b", 16)
        print(f"  C{cycle:02d} PHÂN LOẠI: A={show_float(a)} (0x{a:08x}), B={show_float(b)} (0x{b:08x})")
        print(f"       Dấu A={a >> 31}, dấu B gốc={b >> 31}, "
              f"dấu B dùng để tính={event['sign_b']} "
              f"({'đảo dấu vì phép trừ' if (b >> 31) != number(event, 'sign_b') else 'giữ nguyên'}).")
        print(f"       Số mũ lưu trữ A/B = {event['exp_a']}/{event['exp_b']} (có độ lệch 127); "
              f"phần trị mở rộng = 0x{event['mant_a']}/0x{event['mant_b']}.")
        if number(event, "mode") > 4:
            print("       Chế độ làm tròn sai: kết thúc sớm, báo illegal_rm.")
        elif number(event, "nan_a") or number(event, "nan_b"):
            print("       Gặp NaN: tạo kết quả đặc biệt, bỏ qua các bước tính thường.")
        elif number(event, "inf_a") or number(event, "inf_b"):
            print("       Gặp vô cực: xử lý trường hợp đặc biệt ngay tại đây.")
        else:
            print("       Hai số hữu hạn: chọn phần trị lớn/nhỏ rồi căn số mũ.")
    elif state == "ALIGN":
        shift = number(event, "distance")
        print(f"  C{cycle:02d} CĂN SỐ MŨ: phần trị lớn=0x{event['large']}, "
              f"phần trị nhỏ=0x{event['small']}; "
              f"dấu kết quả dự kiến={'âm' if number(event, 'sign_big') else 'dương'}.")
        print(f"       Dịch phải phần trị nhỏ {shift} bit; các bit mất được gộp vào sticky.")
    elif state == "ADD":
        kind = "cộng" if number(event, "same_sign") else "lấy phần trị lớn trừ phần trị nhỏ"
        print(f"  C{cycle:02d} TÍNH PHẦN TRỊ: sau căn số mũ, lớn=0x{event['large']}, "
              f"nhỏ=0x{event['small']}; {kind}.")
    elif state == "NORMALIZE":
        value = number(event, "sum", 16)
        exp = number(event, "exponent")
        if value == 0:
            action = "Kết quả đúng bằng 0: phát done, không cần làm tròn."
        elif number(event, "carry"):
            action = "Có bit nhớ ra ngoài: dịch phải 1 bit, tăng số mũ, sang ROUND."
        elif not number(event, "leading") and exp > 1:
            action = "Chưa có bit đầu: dịch trái 1 bit, giảm số mũ, LẶP NORMALIZE."
        else:
            action = "Đã chuẩn hóa hoặc chạm giới hạn số mũ: sang ROUND."
        print(f"  C{cycle:02d} CHUẨN HÓA: sum=0x{value:07x} "
              f"(nhị phân {value:028b}), số mũ lưu trữ={exp}.")
        print(f"       {action}")
    elif state == "ROUND":
        print(f"  C{cycle:02d} LÀM TRÒN: G/R/S={event['guard']}/{event['round']}/{event['sticky']}; "
              f"tăng phần trị={event['increment']}; không chính xác={event['inexact']}.")
        print(f"       Phần trị sau làm tròn=0x{event['rounded_mant']}; "
              f"số mũ sau làm tròn={event['rounded_exp']}; ghép thành FP32.")
    elif state == "DONE":
        bits, flags = number(event, "result", 16), number(event, "flags", 16)
        active = ", ".join(name for bit, name in FLAG_BITS if flags & (1 << bit)) or "không có"
        if number(event, "illegal"):
            print(f"  C{cycle:02d} HOÀN TẤT: illegal_rm=1; không có kết quả FP hợp lệ.")
        else:
            print(f"  C{cycle:02d} HOÀN TẤT: result={show_float(bits)} (0x{bits:08x}); "
                  f"fflags=0x{flags:02x} ({active}).")
        print("       done=1 trong một chu kỳ; mạch trở về IDLE.")


def run_case(executable, title, a, b, operation, mode):
    print(f"\n{title}: {show_float(a)} {'+' if operation == 'add' else '-'} {show_float(b)} "
          f"[A=0x{a:08x}, B=0x{b:08x}, rm={mode}]")
    print("  Cxx là chu kỳ clock của riêng module cộng/trừ sau khi nhận start; số thập phân đã mã hóa thành FP32.")
    args = ["vvp", str(executable), f"+a={a:08x}", f"+b={b:08x}",
            f"+sub={int(operation == 'sub')}", f"+rm={MODES[mode]}"]
    result = subprocess.run(args, capture_output=True, text=True, check=False)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    for line in result.stdout.splitlines():
        if line.startswith("TRACE "):
            trace_event(fields(line))


def main():
    parser = argparse.ArgumentParser(description="In từng bước cộng/trừ FP32 từ chính RTL hiện tại")
    parser.add_argument("--a", type=float, help="Toán hạng A ở dạng thập phân")
    parser.add_argument("--b", type=float, help="Toán hạng B ở dạng thập phân")
    parser.add_argument("--a-bits", type=lambda x: int(x, 16), help="Bit FP32 của A ở dạng hex, ví dụ 3f800000")
    parser.add_argument("--b-bits", type=lambda x: int(x, 16), help="Bit FP32 của B ở dạng hex")
    parser.add_argument("--op", choices=("add", "sub"), default="add")
    parser.add_argument("--rm", choices=tuple(MODES), default="rne", help="Chế độ làm tròn; mặc định rne")
    args = parser.parse_args()
    for label in ("a", "b"):
        if getattr(args, label) is not None and getattr(args, f"{label}_bits") is not None:
            parser.error(f"Chỉ chọn một trong --{label} và --{label}-bits")
    selected = any(getattr(args, name) is not None for name in ("a", "b", "a_bits", "b_bits"))
    if selected and (args.a is None and args.a_bits is None or args.b is None and args.b_bits is None):
        parser.error("Cần cung cấp cả A và B")
    if not shutil.which("iverilog") or not shutil.which("vvp"):
        parser.error("Chưa tìm thấy iverilog/vvp trong PATH")

    with tempfile.TemporaryDirectory(prefix="fp32_addsub_trace_") as temp_dir:
        executable = Path(temp_dir) / "trace.vvp"
        subprocess.run(["iverilog", "-g2012", "-s", "tb_fp32_addsub_trace",
                        "-o", str(executable), str(RTL), str(TB)], check=True)
        if selected:
            a = args.a_bits if args.a_bits is not None else float_bits(args.a)
            b = args.b_bits if args.b_bits is not None else float_bits(args.b)
            if not 0 <= a <= 0xffffffff or not 0 <= b <= 0xffffffff:
                parser.error("Bit FP32 phải nằm trong 0x00000000..0xffffffff")
            run_case(executable, "Ví dụ theo tham số", a, b, args.op, args.rm)
        else:
            run_case(executable, "Ví dụ 1 — cộng", float_bits(1.5), float_bits(2.25), "add", "rne")
            run_case(executable, "Ví dụ 2 — trừ hai số gần nhau", 0x3f800000, 0x3f7fffff, "sub", "rne")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, ValueError) as exc:
        print(f"Lỗi: {exc}", file=sys.stderr)
        sys.exit(1)
