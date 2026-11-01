"""Build and run the implemented ACT4 RV32I and RV32F tests on the RTL core."""

import argparse
import csv
import hashlib
import json
import re
import shutil
import struct
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from act4_csrfree import make_csr_free


ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl" / "core_if"
TB = ROOT / "tb" / "core_if" / "tb_act4_unified.v"
BUILD = ROOT / "sim" / "build" / "act4"
DEFAULT_ACT = Path.home() / "tools" / "riscv-arch-test"
DEFAULT_TOOLCHAIN = Path.home() / "tools" / "riscv-gcc15" / "bin"

IMPLEMENTED_TESTS = (
    "F-fmv.w.x-00",
    "F-fmv.x.w-00",
    "F-fsgnj.s-00",
    "F-fsgnjn.s-00",
    "F-fsgnjx.s-00",
    "F-fclass.s-00",
    "F-flw-00",
    "F-fsw-00",
    "F-fadd.s-00",
    "F-fadd.s-01",
    "F-fadd.s-02",
    "F-fadd.s-03",
    "F-fadd.s-04",
    "F-fsub.s-00",
    "F-fsub.s-01",
    "F-fsub.s-02",
    "F-fsub.s-03",
    "F-fsub.s-04",
    "F-fmul.s-00",
    "F-fmul.s-01",
    "F-fmul.s-02",
    "F-fmul.s-03",
    "F-fmul.s-04",
    "F-fdiv.s-00",
    "F-fdiv.s-01",
    "F-fdiv.s-02",
    "F-fdiv.s-03",
    "F-fdiv.s-04",
    "F-fsqrt.s-00",
    "F-fmadd.s-00",
    "F-fmadd.s-01",
    "F-fmadd.s-02",
    "F-fmadd.s-03",
    "F-fmadd.s-04",
    "F-fmadd.s-05",
    "F-fmadd.s-06",
    "F-fmadd.s-07",
    "F-fmadd.s-08",
    "F-fmadd.s-09",
    "F-fmsub.s-00",
    "F-fmsub.s-01",
    "F-fmsub.s-02",
    "F-fmsub.s-03",
    "F-fmsub.s-04",
    "F-fmsub.s-05",
    "F-fmsub.s-06",
    "F-fmsub.s-07",
    "F-fmsub.s-08",
    "F-fmsub.s-09",
    "F-fnmsub.s-00",
    "F-fnmsub.s-01",
    "F-fnmsub.s-02",
    "F-fnmsub.s-03",
    "F-fnmsub.s-04",
    "F-fnmsub.s-05",
    "F-fnmsub.s-06",
    "F-fnmsub.s-07",
    "F-fnmsub.s-08",
    "F-fnmsub.s-09",
    "F-fnmadd.s-00",
    "F-fnmadd.s-01",
    "F-fnmadd.s-02",
    "F-fnmadd.s-03",
    "F-fnmadd.s-04",
    "F-fnmadd.s-05",
    "F-fnmadd.s-06",
    "F-fnmadd.s-07",
    "F-fnmadd.s-08",
    "F-fnmadd.s-09",
    "F-fcvt.s.w-00",
    "F-fcvt.s.wu-00",
    "F-fcvt.w.s-00",
    "F-fcvt.wu.s-00",
    "F-feq.s-00",
    "F-flt.s-00",
    "F-fle.s-00",
    "F-fmin.s-00",
    "F-fmin.s-01",
    "F-fmax.s-00",
    "F-fmax.s-01",
)

# ACT4 tests of the base ISA (39 ELFs, one per instruction; ecall/ebreak are privileged tests,
# not built since include_priv_tests is false in verification/act4/rv32if_core/test_config.yaml).
IMPLEMENTED_I_TESTS = tuple(f"I-{insn}-00" for insn in (
    "add", "addi", "and", "andi", "auipc", "beq", "bge", "bgeu", "blt", "bltu", "bne",
    "fence", "jal", "jalr", "lb", "lbu", "lh", "lhu", "lui", "lw", "nop", "or", "ori",
    "sb", "sh", "sll", "slli", "slt", "slti", "sltiu", "sltu", "sra", "srai", "srl", "srli",
    "sub", "sw", "xor", "xori"))
IMPLEMENTED_TESTS = IMPLEMENTED_TESTS + IMPLEMENTED_I_TESTS


def elf_path(act_root, name):
    """ACT4 keeps each extension's ELFs in its own folder: F-fadd.s-00 -> elfs/rv32i/F/."""
    return act_root / "work" / "rv32if-core" / "elfs" / "rv32i" / name.split("-", 1)[0] / f"{name}.elf"


def run(argv, *, timeout=180):
    result = subprocess.run(
        [str(x) for x in argv], cwd=ROOT, capture_output=True, text=True, timeout=timeout
    )
    output = result.stdout + result.stderr
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {' '.join(map(str, argv))}\n{output}")
    return output


def symbol_address(nm, elf, symbol):
    output = run([nm, "-n", elf])
    match = re.search(rf"^([0-9a-fA-F]+)\s+\w\s+{re.escape(symbol)}$", output, re.MULTILINE)
    if not match:
        raise RuntimeError(f"ELF has no {symbol} symbol: {elf}")
    return int(match.group(1), 16)


def load_verilog_hex(path):
    """Read objcopy's byte-wide Verilog hex into {address: byte}."""
    memory, address = {}, 0
    for token in path.read_text(encoding="utf-8").split():
        if token.startswith("@"):
            address = int(token[1:], 16)
        else:
            memory[address] = int(token, 16)
            address += 1
    return memory


def save_verilog_hex(path, memory):
    lines, previous = [], None
    for address in sorted(memory):
        if address != previous:
            lines.append(f"@{address:08X}")
            row = []
            lines.append(row)
        elif len(row) == 16:
            row = []
            lines.append(row)
        row.append(f"{memory[address]:02X}")
        previous = address + 1
    path.write_text("\n".join(line if isinstance(line, str) else " ".join(line)
                              for line in lines) + "\n", encoding="utf-8")


def make_program_csr_free(hex_file, elf, nm, objdump):
    """--no-flags: rewrite the loaded image so the program has no CSR instruction and no
    fflags comparison, while every computed result is still checked (see act4_csrfree.py)."""
    symbols = {}
    for address, name in re.findall(r"(?m)^([0-9a-fA-F]+)\s+\w\s+(\S+)$", run([nm, "-n", elf])):
        symbols.setdefault(name, int(address, 16))
    fail = {a for n, a in symbols.items() if n.startswith("failedtest_")}
    fflags = {a for n, a in symbols.items() if n.startswith("failedtest_fflags_")}
    ranges = [(int(vma, 16), int(vma, 16) + int(size, 16)) for size, vma in re.findall(
        r"(?m)^\s*\d+\s+\.text\S*\s+([0-9a-f]+)\s+([0-9a-f]+)\s", run([objdump, "-h", elf]))]
    memory = load_verilog_hex(hex_file)

    def read_word(address):
        if all(address + i in memory for i in range(4)):
            return int.from_bytes(bytes(memory[address + i] for i in range(4)), "little")
        return None

    patches, stats = make_csr_free(read_word, ranges,
                                   (symbols["rvtest_code_begin"], symbols["rvtest_code_end"]),
                                   fail, fflags)
    for address, word in patches.items():
        for i, byte in enumerate(word.to_bytes(4, "little")):
            memory[address + i] = byte
    save_verilog_hex(hex_file, memory)
    return stats


def fp32_description(hex_bits):
    """Decode raw binary32 bits for display, without changing the test oracle."""
    bits = int(hex_bits, 16)
    sign, exponent, fraction = bits >> 31, (bits >> 23) & 255, bits & 0x7fffff
    if exponent == 255 and fraction:
        category = "quiet NaN" if fraction & 0x400000 else "signaling NaN"
        number = category
    else:
        number = format(struct.unpack(">f", bits.to_bytes(4, "big"))[0], ".9g")
        category = "infinity" if exponent == 255 else (
            "zero" if exponent == 0 and fraction == 0 else
            "subnormal" if exponent == 0 else "normal")
    return f"0x{bits:08x} = {number} ({category}; sign={sign}, exp={exponent}, frac=0x{fraction:06x})"


def integer_description(hex_bits, unsigned):
    bits = int(hex_bits, 16)
    value = bits if unsigned or bits < 0x80000000 else bits - (1 << 32)
    return f"0x{bits:08x} = {value} ({'unsigned' if unsigned else 'signed'} 32-bit integer)"


def check_kind(disassembly, pc):
    """Recognize ACT4's result/fflags checks from nearby ELF instructions."""
    rows = disassembly.splitlines()
    match = next((i for i, row in enumerate(rows) if
                  re.match(rf"^\s*{pc:x}:\s+[0-9a-f]+\s+beq\s", row)), None)
    if match is None:
        return "branch"
    preceding = "\n".join(rows[max(0, match-5):match]).lower()
    if "frflags" in preceding or "fflags" in preceding:
        return "flags"
    if "fsw" in preceding and preceding.count("\tlw\t") >= 2:
        return "result"
    if "check_regular_sig_offset_done" in rows[match]:
        return "signature bookkeeping"
    return "branch"


def print_explanation(name, output, report_dir, tohost, disassembly, source_cases=(), case_limit=3):
    """Show the arithmetic and decisive checks; retain all events in the run log."""
    lines = output.splitlines()
    fp_events = [line for line in lines if line.startswith("FP_EXEC ")]
    target_encoding = {
        "fmv.w.x": (0x78, 0), "fmv.x.w": (0x70, 0),
        "fsgnj.s": (0x10, 0), "fsgnjn.s": (0x10, 1), "fsgnjx.s": (0x10, 2),
        "fclass.s": (0x70, 1),
        "fadd.s": (0x00, None), "fsub.s": (0x04, None), "fmul.s": (0x08, None),
        "fdiv.s": (0x0c, None), "fsqrt.s": (0x2c, None),
        "fcvt.s.w": (0x68, None), "fcvt.s.wu": (0x68, None),
        "fcvt.w.s": (0x60, None), "fcvt.wu.s": (0x60, None),
        "feq.s": (0x50, 2), "flt.s": (0x50, 1), "fle.s": (0x50, 0),
        "fmin.s": (0x14, 0), "fmax.s": (0x14, 1),
    }
    operation = name.removeprefix("F-").rsplit("-", 1)[0]
    encoding = target_encoding.get(operation)
    r4_opcode = {"fmadd.s": 0x43, "fmsub.s": 0x47, "fnmsub.s": 0x4b, "fnmadd.s": 0x4f}.get(operation)
    if r4_opcode is not None:
        fp_events = [line for line in fp_events if
                     int(re.search(r"insn=([0-9a-fA-F]+)", line).group(1), 16) & 0x7f == r4_opcode]
    label_prefix = "F_" + operation.replace(".", "_") + "_cg_"
    testcase_pcs = {int(pc, 16) for pc in re.findall(
        rf"(?m)^\s*([0-9a-fA-F]+) <{re.escape(label_prefix)}[^>]*>:$", disassembly)}
    if operation in ("flw", "fsw"):
        fp_events = []  # Their payload is in memory transactions, not FP_EXEC.
    if encoding is not None:
        filtered_events = []
        for line in fp_events:
            insn = int(re.search(r"insn=([0-9a-fA-F]+)", line).group(1), 16)
            if ((insn >> 25) == encoding[0] and
                (encoding[1] is None or ((insn >> 12) & 7) == encoding[1]) and
                (not operation.startswith("fcvt.") or
                 ((insn >> 20) & 31) == int("wu" in operation))):
                filtered_events.append(line)
        fp_events = filtered_events
    if testcase_pcs:
        fp_events = [line for line in fp_events if
                     int(re.search(r"pc=([0-9a-fA-F]+)", line).group(1), 16) in testcase_pcs]
    if not fp_events:
        fp_events = [line for line in lines if line.startswith("RETIRE ")][:1]
    branch_events = [line for line in lines if line.startswith("BRANCH ")]
    last_fp_cycle = int(re.search(r"cycle=(\d+)", fp_events[-1]).group(1))
    following_branches = [line for line in branch_events if
                          int(re.search(r"cycle=(\d+)", line).group(1)) > last_fp_cycle]
    tohost_event = next((line for line in lines if line.startswith("MEM_WRITE ")
                         and f"address={tohost:08x}" in line), None)
    print(f"EXPLAIN {name}:", flush=True)
    if source_cases:
        print(f"  ACT4 source testcases: {len(source_cases)}", flush=True)
        for case_index, description in enumerate(source_cases[:case_limit], start=1):
            print(f"    Testcase {case_index}: {description}", flush=True)
        if len(source_cases) > case_limit:
            print(f"    ... {len(source_cases)-case_limit} more testcase labels", flush=True)
    if operation in ("flw", "fsw"):
        memory_kind = "MEM_READ " if operation == "flw" else "MEM_WRITE "
        transactions = [line for line in lines if line.startswith(memory_kind) and
                        f"address={tohost:08x}" not in line]
        print(f"  {operation.upper()} uses the RAM transactions below; these are raw 32-bit payloads:", flush=True)
        for line in transactions[:3]:
            print(f"    {line}", flush=True)
    for case_index, line in enumerate(fp_events[:case_limit], start=1):
        event = dict(re.findall(r"(cycle|pc|insn|a|b|c|result|flags)=([0-9a-fA-F]+)", line))
        if not all(field in event for field in ("a", "b", "result", "flags")):
            if operation not in ("flw", "fsw"):
                print("  See the RAM and retirement log for the target instruction.", flush=True)
            continue
        print(f"  Observed {operation.upper()} execution {case_index}/{len(fp_events)}: "
              f"cycle {event['cycle']}, PC 0x{event['pc']}", flush=True)
        if operation.startswith("fcvt.s."):
            print(f"    A: {integer_description(event['a'], 'wu' in operation)}", flush=True)
            print(f"    RESULT: {fp32_description(event['result'])}", flush=True)
        elif operation.startswith("fcvt.w"):
            print(f"    A: {fp32_description(event['a'])}", flush=True)
            print(f"    RESULT: {integer_description(event['result'], 'wu' in operation)}", flush=True)
        else:
            for label in ("a", "b", "c", "result") if r4_opcode is not None else ("a", "b", "result"):
                print(f"    {label.upper()}: {fp32_description(event[label])}", flush=True)
        flags = int(event["flags"], 16)
        active_flags = ",".join(label for bit, label in
                                ((4, "NV"), (3, "DZ"), (2, "OF"), (1, "UF"), (0, "NX"))
                                if flags & (1 << bit)) or "none"
        print(f"    New exception flags: 0x{flags:02x} ({active_flags})", flush=True)
    if len(fp_events) > case_limit:
        print(f"  ... {len(fp_events)-case_limit} further target operations; use --cases all to print them", flush=True)
    for line in following_branches[:3]:
        event = dict(re.findall(r"(cycle|pc|value|taken)=([0-9a-fA-F]+)", line))
        values = re.findall(r"rs[12]=x(\d+) value=([0-9a-fA-F]+)", line)
        kind = check_kind(disassembly, int(event["pc"], 16))
        if len(values) == 2:
            left, right = values
            label = {"result": "Result check", "flags": "fflags check",
                     "signature bookkeeping": "Signature offset check"}.get(kind, "Branch")
            print(f"  {label}: cycle {event['cycle']}, x{left[0]}=0x{left[1]} "
                  f"vs x{right[0]}=0x{right[1]}, taken={event['taken']}", flush=True)
    if tohost_event:
        print(f"  PASS signal: {tohost_event}  [tohost: 1=PASS, 3=FAIL]", flush=True)
    retired = sum(line.startswith("RETIRE ") for line in lines)
    nops = sum(line.startswith("RETIRE ") and "insn=00000013" in line for line in lines)
    print(f"  Program executed {retired} instructions ({nops} NOPs) before PASS; "
          "cycle numbers count the whole program.", flush=True)
    print(f"  Program: {report_dir / (name + '.disasm.txt')}", flush=True)
    print(f"  Full execution log: {report_dir / (name + '.run.log')}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("tests", nargs="*", help="ACT4 test stem or .elf path")
    parser.add_argument("--all", action="store_true",
                        help="run implemented test ELFs (80 for 26 F instructions, 39 for RV32I)")
    parser.add_argument("--trace", action="store_true", help="print retired instruction trace")
    parser.add_argument("--explain", action="store_true", help="save disassembly and detailed RTL execution log")
    parser.add_argument("--cases", default="3", help="target operations to explain per ELF: N or all (default: 3)")
    parser.add_argument("--max-cycles", type=int, default=5_000_000)
    parser.add_argument("--act-root", type=Path, default=DEFAULT_ACT)
    parser.add_argument("--toolchain-bin", type=Path, default=DEFAULT_TOOLCHAIN)
    parser.add_argument("--report-dir", type=Path, default=BUILD, help="directory for results and per-test logs")
    parser.add_argument("--no-flags", action="store_true",
                        help="results only: run a CSR-free version of each program (no CSR instruction, "
                             "no fflags check, DYN rounding replaced by the static mode in effect)")
    args = parser.parse_args()

    if args.cases != "all" and (not args.cases.isdecimal() or int(args.cases) < 1):
        parser.error("--cases must be a positive integer or all")

    if args.all and args.tests:
        parser.error("use either --all or explicit tests")
    selected = list(IMPLEMENTED_TESTS if args.all else args.tests)
    if not selected:
        selected = [IMPLEMENTED_TESTS[0]]

    iverilog = shutil.which("iverilog")
    vvp = shutil.which("vvp")
    objcopy = args.toolchain_bin / "riscv32-unknown-elf-objcopy"
    nm = args.toolchain_bin / "riscv32-unknown-elf-nm"
    objdump = args.toolchain_bin / "riscv32-unknown-elf-objdump"
    required_tools = ((iverilog, vvp, objcopy, nm, objdump) if args.explain or args.no_flags
                      else (iverilog, vvp, objcopy, nm))
    for tool in required_tools:
        if not tool or not Path(tool).exists():
            raise RuntimeError(f"Required tool not found: {tool}")

    BUILD.mkdir(parents=True, exist_ok=True)
    report_dir = args.report_dir.resolve()
    report_dir.mkdir(parents=True, exist_ok=True)
    simulator = BUILD / "tb_act4_unified.out"
    rtl_sources = sorted(RTL.glob("*.v"))
    compile_output = run(
        [iverilog, "-g2012", "-Wall", "-Wno-timescale", "-s", "tb_act4_unified",
         "-o", simulator, *rtl_sources, TB]
    )
    if compile_output.strip():
        print(compile_output, end="")
    (report_dir / "compile.log").write_text(compile_output, encoding="utf-8")

    rows = []
    elf_hashes = {}
    for requested in selected:
        candidate = Path(requested)
        if candidate.suffix == ".elf" and candidate.exists():
            elf = candidate.resolve()
            name = elf.stem
        else:
            name = candidate.name.removesuffix(".elf")
            elf = elf_path(args.act_root, name)
        if not elf.exists():
            raise RuntimeError(f"ACT4 ELF not found: {elf}")
        elf_hashes[name] = hashlib.sha256(elf.read_bytes()).hexdigest()
        disassembly = ""
        if args.explain:
            disassembly = run([objdump, "-d", elf])
            (report_dir / f"{name}.disasm.txt").write_text(disassembly, encoding="utf-8")

        hex_file = BUILD / f"{name}.hex"
        run([objcopy, "-O", "verilog", "--verilog-data-width=1", elf, hex_file])
        tohost = symbol_address(nm, elf, "tohost")
        patch_stats = {}
        if args.no_flags:
            patch_stats = make_program_csr_free(hex_file, elf, nm, objdump)
        argv = [vvp, simulator, f"+mem={hex_file}", f"+tohost={tohost:x}",
                f"+max_cycles={args.max_cycles}"]
        if args.trace:
            argv.append("+trace")
        if args.explain:
            argv.append("+explain")

        try:
            output = run(argv, timeout=300)
            (report_dir / f"{name}.run.log").write_text(output, encoding="utf-8")
            match = re.search(r"ACT4_RTL_PASS cycles=(\d+)", output)
            if not match:
                raise RuntimeError(f"Missing PASS marker for {name}\n{output}")
            cycles = int(match.group(1))
            patched = (f"nop={patch_stats['csr_to_nop']} dyn={patch_stats['dyn_to_static']} "
                       f"fflags={patch_stats['fflags_checks_skipped']}" if args.no_flags else "")
            rows.append((name, "PASS", cycles, patched))
            note = (f"; CSR-free: {patch_stats['csr_to_nop']} CSR instr -> nop, "
                    f"{patch_stats['dyn_to_static']} DYN -> static rm, "
                    f"{patch_stats['fflags_checks_skipped']} fflags checks removed" if args.no_flags else "")
            print(f"{name}: PASS ({cycles} cycles{note})", flush=True)
            if args.explain:
                case_limit = len(output.splitlines()) if args.cases == "all" else int(args.cases)
                source = args.act_root / "tests" / "rv32i" / name.split("-", 1)[0] / f"{name}.S"
                source_cases = re.findall(r"(?m)^\s*# Testcase\s+(.+)$",
                                          source.read_text(encoding="utf-8")) if source.exists() else []
                print_explanation(name, output, report_dir, tohost, disassembly,
                                  source_cases, case_limit)
        except Exception as exc:
            (report_dir / f"{name}.run.log").write_text(str(exc), encoding="utf-8")
            rows.append((name, "FAIL", "", ""))
            print(f"{name}: FAIL\n{exc}", file=sys.stderr, flush=True)
            break

    report = report_dir / "results.csv"
    with report.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream, lineterminator="\n")
        writer.writerow(("test", "status", "cycles", "csr_free_patches"))
        writer.writerows(rows)
    passed = len(rows) == len(selected) and all(row[1] == "PASS" for row in rows)
    provenance = subprocess.run(["git", "-C", str(args.act_root), "rev-parse", "HEAD"],
                                capture_output=True, text=True)
    summary = {
        "status": "PASS" if passed else "FAIL", "utc": datetime.now(timezone.utc).isoformat(),
        "selected_tests": selected, "completed_tests": len(rows),
        "explain": args.explain, "no_flags": args.no_flags,
        "act_root": str(args.act_root), "act_commit": provenance.stdout.strip(),
        "elf_sha256": elf_hashes,
        "rtl_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in rtl_sources},
        "scope": "Selected ACT4 ELFs on RTL; not full RV32IF certification." +
                 (" Results only (--no-flags): CSR-free programs, fflags not checked, "
                  "DYN rounding replaced by the static mode in effect." if args.no_flags else ""),
    }
    if args.no_flags:
        summary["csr_free_patches"] = {row[0]: row[3] for row in rows if row[1] == "PASS"}
    (report_dir / "summary.json").write_text(json.dumps(summary, indent=2)+"\n", encoding="utf-8")
    if any(row[1] != "PASS" for row in rows) or len(rows) != len(selected):
        raise SystemExit(1)
    if args.no_flags:
        print(f"ACT4_RTL_TESTS_PASS ({len(rows)}/{len(rows)}) [results only: CSR-free programs, "
              "fflags NOT checked]")
    else:
        print(f"ACT4_RTL_TESTS_PASS ({len(rows)}/{len(rows)})")
    print(f"Report: {report}")


if __name__ == "__main__":
    main()
