#!/usr/bin/env python3
"""Count the ACT4 RV32F tests per instruction, straight from the 80 ELF files.

Columns: files, testcases, result checks, fflags checks (removed by --no-flags),
cp_csr_* testcases (the ones written to test fcsr), and DYN instructions that --no-flags
rewrites to a static rounding mode.

  python3 scripts/act4_stats.py              # all 26 instructions
  python3 scripts/act4_stats.py fadd.s       # one instruction
"""
import argparse
import collections
import re
import subprocess
from pathlib import Path

from act4_csrfree import make_csr_free
from run_act4_rtl import DEFAULT_ACT, DEFAULT_TOOLCHAIN, IMPLEMENTED_TESTS


def run(argv):
    return subprocess.run([str(a) for a in argv], capture_output=True, text=True, check=True).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("insn", nargs="?", help="instruction, e.g. fadd.s (default: all 26)")
    parser.add_argument("--act-root", type=Path, default=DEFAULT_ACT)
    parser.add_argument("--toolchain-bin", type=Path, default=DEFAULT_TOOLCHAIN)
    args = parser.parse_args()
    objdump = args.toolchain_bin / "riscv32-unknown-elf-objdump"
    nm = args.toolchain_bin / "riscv32-unknown-elf-nm"
    elf_dir = args.act_root / "work" / "rv32if-core" / "elfs" / "rv32i" / "F"

    tests = [t for t in IMPLEMENTED_TESTS if args.insn in (None, t[2:].rsplit("-", 1)[0])]
    if not tests:
        parser.error(f"no ACT4 ELF for {args.insn!r}")
    stats = collections.OrderedDict()
    for test in tests:
        elf = elf_dir / f"{test}.elf"
        row = stats.setdefault(test[2:].rsplit("-", 1)[0], collections.Counter())
        symbols = {}
        for address, name in re.findall(r"(?m)^([0-9a-fA-F]+)\s+\w\s+(\S+)$", run([nm, "-n", elf])):
            symbols.setdefault(name, int(address, 16))
        lo, hi = symbols["rvtest_code_begin"], symbols["rvtest_code_end"]
        listing, words = [], {}
        for line in run([objdump, "-d", elf]).splitlines():
            m = re.match(r"^\s*([0-9a-f]+)[: ]", line)
            if m and lo <= int(m.group(1), 16) < hi:
                listing.append(line)
            w = re.match(r"^\s*([0-9a-f]+):\s+([0-9a-f]{8})\s", line)
            if w:
                words[int(w.group(1), 16)] = int(w.group(2), 16)
        body = "\n".join(listing)
        labels = re.findall(r"(?m)^[0-9a-f]+ <(F_\S+_cg_\S+)>:$", body)
        fail = {a for n, a in symbols.items() if n.startswith("failedtest_")}
        fflags = {a for n, a in symbols.items() if n.startswith("failedtest_fflags_")}
        _, patched = make_csr_free(words.get, [(min(words), max(words) + 4)], (lo, hi), fail, fflags)
        row["files"] += 1
        row["testcases"] += len(labels)
        row["result_checks"] += len(re.findall(r"\tjal\t\S+ <failedtest_(?!fflags)", body))
        row["fflags_checks"] += len(re.findall(r"\tjal\t\S+ <failedtest_fflags", body))
        row["cp_csr"] += sum("_cp_csr_" in label for label in labels)
        row["dyn"] += patched["dyn_to_static"]

    columns = ("files", "testcases", "result_checks", "fflags_checks", "cp_csr", "dyn")
    header = ("instruction", "files", "testcases", "result checks", "fflags checks", "cp_csr_*", "DYN->static")
    widths = (11, 5, 9, 13, 13, 8, 11)
    print("  ".join(f"{h:>{w}}" if i else f"{h:<{w}}" for i, (h, w) in enumerate(zip(header, widths))))
    total = collections.Counter()
    for insn, row in stats.items():
        total.update(row)
        print("  ".join([f"{insn:<11}"] + [f"{row[c]:>{w}}" for c, w in zip(columns, widths[1:])]))
    if len(stats) > 1:
        print("  ".join([f"{'TOTAL':<11}"] + [f"{total[c]:>{w}}" for c, w in zip(columns, widths[1:])]))
    print("fflags checks and the CSR part of cp_csr_* testcases are skipped by --no-flags; "
          "every testcase keeps its result check.")


if __name__ == "__main__":
    main()
