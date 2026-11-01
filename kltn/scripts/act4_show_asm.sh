#!/usr/bin/env bash
# Show assembled ACT4 tests (objdump -d, ABI register names) of an RV32F instruction.
# By default a testcase is printed in a short annotated form (no padding NOPs, failure
# branches hidden, one comment per line); use --raw for the plain objdump text.
# Usage (WSL, from kltn/):
#   bash scripts/act4_show_asm.sh fadd.s                      # list the ELF files of the instruction
#   bash scripts/act4_show_asm.sh fadd.s 00                   # list every testcase of file 00: number and label
#   bash scripts/act4_show_asm.sh fadd.s 00 5                 # print testcase 5 (annotated)
#   bash scripts/act4_show_asm.sh fadd.s 00 F_fadd_s_cg_cp_fs1_b1   # ... or by label
#   bash scripts/act4_show_asm.sh fadd.s 00 5-20              # print testcases 5 to 20
#   bash scripts/act4_show_asm.sh fadd.s 00 every             # print EVERY testcase of file 00
#   bash scripts/act4_show_asm.sh fadd.s all every            # print every testcase of EVERY file (00..04)
#   bash scripts/act4_show_asm.sh fadd.s all                  # list testcases of every file
#   bash scripts/act4_show_asm.sh fadd.s 00 5 --raw           # plain objdump, NOPs and failure paths included
#   bash scripts/act4_show_asm.sh fadd.s 00 whole             # the whole program (plain objdump)
#   bash scripts/act4_show_asm.sh fadd.s 00 5 --no-flags      # the CSR-free program that `act4_cli.py --no-flags`
#                                                             # runs: no CSR instruction, no fflags check, DYN
#                                                             # rounding shown as the static mode; combines with --raw
# Large outputs: redirect to a file, e.g.  ... fadd.s all every > fadd_all_tests.txt
# Paths can be overridden with ACT_ROOT and OBJDUMP.
set -euo pipefail
args=(); raw=0; noflags=0
for a in "$@"; do
    case "$a" in
        --raw) raw=1 ;;
        --no-flags) noflags=1 ;;
        *) args+=("$a") ;;
    esac
done
set -- "${args[@]}"
insn="${1:?usage: act4_show_asm.sh <instruction> [file-number|all] [testcase|A-B|label|every|whole] [--raw]}"
num="${2:-}"
sel="${3:-}"
act="${ACT_ROOT:-$HOME/tools/riscv-arch-test}"
objdump="${OBJDUMP:-$HOME/tools/riscv-gcc15/bin/riscv32-unknown-elf-objdump}"
elfdir="$act/work/rv32if-core/elfs/rv32i/F"
insn="${insn#F-}"; insn="${insn%.elf}"

list_files() {
    ls "$elfdir" | grep -E "^F-${insn//./\\.}-[0-9]+\.elf$" | sed -E 's/^F-.*-([0-9]+)\.elf$/\1/'
}

# count: number of ACT4 files per instruction and testcases per file
#   bash scripts/act4_show_asm.sh count            # all 26 instructions
#   bash scripts/act4_show_asm.sh fadd.s count     # one instruction
if [[ "$insn" == count || "$num" == count ]]; then
    if [[ "$insn" == count ]]; then
        insns=(flw fsw fadd.s fsub.s fmul.s fdiv.s fsqrt.s fmadd.s fmsub.s fnmsub.s fnmadd.s
               fsgnj.s fsgnjn.s fsgnjx.s fmin.s fmax.s feq.s flt.s fle.s
               fcvt.w.s fcvt.wu.s fcvt.s.w fcvt.s.wu fmv.x.w fmv.w.x fclass.s)
    else
        insns=("$insn")
    fi
    printf '%-11s %5s %10s   %s\n' instruction files testcases "testcases per file"
    all_files=0 all_cases=0
    for insn in "${insns[@]}"; do
        files=0 cases=0 per=()
        for n in $(list_files); do
            c=$("$objdump" -d "$elfdir/F-$insn-$n.elf" | grep -cE '^[0-9a-f]+ <F_[^>]*_cg_[^>]*>:$')
            per+=("$n:$c"); files=$((files + 1)); cases=$((cases + c))
        done
        printf '%-11s %5d %10d   %s\n' "$insn" "$files" "$cases" "${per[*]}"
        all_files=$((all_files + files)); all_cases=$((all_cases + cases))
    done
    (( ${#insns[@]} > 1 )) && printf '%-11s %5d %10d\n' TOTAL "$all_files" "$all_cases"
    exit 0
fi

if [[ -z "$num" ]]; then
    files="$(list_files)" || true
    [[ -n "$files" ]] || { echo "No ACT4 ELF for '$insn' in $elfdir" >&2; exit 1; }
    while read -r n; do echo "F-$insn-$n"; done <<<"$files"
    exit 0
fi

if [[ "$num" == all ]]; then
    files="$(list_files)" || true
    [[ -n "$files" ]] || { echo "No ACT4 ELF for '$insn' in $elfdir" >&2; exit 1; }
    while read -r n; do
        echo "================================================================ F-$insn-$n"
        bash "${BASH_SOURCE[0]}" "$insn" "$n" ${sel:+"$sel"} $([[ $raw == 1 ]] && echo --raw) \
            $([[ $noflags == 1 ]] && echo --no-flags)
    done <<<"$files"
    exit 0
fi

elf="$elfdir/F-$insn-$num.elf"
[[ -f "$elf" ]] || { echo "Missing $elf" >&2; exit 1; }
src="$act/tests/rv32i/F/F-$insn-$num.S"
asm="$(mktemp)"; trap 'rm -f "$asm"' EXIT
"$objdump" -d "$elf" > "$asm"

# One testcase = its operand loads (objdump places them at the end of the previous
# symbol), then the labelled instruction under test, then the result/flag checks.
python3 - "$asm" "$insn" "$num" "${sel:-}" "$raw" "$src" "$noflags" "$(dirname -- "${BASH_SOURCE[0]}")" <<'PY'
import re
import sys

asm, insn, num, sel, raw, src, noflags, script_dir = sys.argv[1:9]
noflags = noflags == "1"
sys.path.insert(0, script_dir)
from act4_csrfree import NOP, RM_NAMES, is_csr, make_csr_free
lines = open(asm, encoding="utf-8", errors="replace").read().splitlines()
label_re = re.compile(r"^[0-9a-f]+ <(F_[^>]*_cg_[^>]*)>:$")
line_re = re.compile(r"^\s*([0-9a-f]+):\s+[0-9a-f]+\s+(.*)$")
start = next((i for i, l in enumerate(lines) if "<rvtest_code_begin>:" in l), 0)
end = next((i for i, l in enumerate(lines) if "<rvtest_code_end>:" in l), len(lines))


# --no-flags shows the same CSR-free program the runner executes (act4_csrfree.py).
patches = {}
if noflags:
    words, labels = {}, {}
    for l in lines:
        m = re.match(r"^\s*([0-9a-f]+):\s+([0-9a-f]{8})\s", l)
        if m:
            words[int(m.group(1), 16)] = int(m.group(2), 16)
        lab = re.match(r"^([0-9a-f]+) <(.+)>:$", l)
        if lab:
            labels[lab.group(2)] = int(lab.group(1), 16)
    fail = {a for n, a in labels.items() if n.startswith("failedtest_")}
    fflags = {a for n, a in labels.items() if n.startswith("failedtest_fflags_")}
    if words:
        patches, _ = make_csr_free(words.get, [(min(words), max(words) + 4)],
                                   (labels.get("rvtest_code_begin", 0),
                                    labels.get("rvtest_code_end", max(words) + 4)), fail, fflags)


def apply_patches(out):
    """Drop CSR instructions turned into nop; show DYN instructions with their static rm."""
    kept = []
    for l in out:
        m = re.match(r"^(\s*([0-9a-f]+):\s+)([0-9a-f]{8})(\s+)(\S+)(\t?)(.*)$", l)
        if m and int(m.group(2), 16) in patches:
            old, new = int(m.group(3), 16), patches[int(m.group(2), 16)]
            if new == NOP and is_csr(old):
                continue
            if (new >> 12) & 7 != (old >> 12) & 7:
                ops = re.split(r"\s+(?:#|<)", m.group(7))[0].rstrip()
                rm = RM_NAMES[(new >> 12) & 7]
                l = f"{m.group(1)}{new:08x}{m.group(4)}{m.group(5)}{m.group(6)}{ops},{rm}"
        kept.append(l)
    return kept


def strip_flags(out):
    """--no-flags: drop instructions that only clear/set fflags, and each fflags check
    (frflags; lw expected; beq; jal failedtest_fflags; .word; .word; addi ptr,ptr,4).
    csrsi/csrci on fcsr carry a 5-bit immediate, so they touch the flag bits only and are
    dropped too. Writes that can change frm (fsrmi, fscsr) are kept: they belong to the
    operation under test."""
    kept, skipping, tail = [], False, 0
    for l in out:
        m = line_re.match(l)
        if not m:
            kept.append(l)
            continue
        text = m.group(2)
        mnem, _, ops = text.partition("\t")
        if skipping:
            if tail:
                tail -= 1
                skipping = tail > 0
            elif "failedtest_fflags" in text:
                tail = 3
            continue
        if mnem == "frflags":
            skipping = True
            continue
        if mnem in ("fsflags", "fsflagsi") or (
                mnem.startswith("csr") and re.search(r"\bfflags\b", ops)) or (
                mnem in ("csrsi", "csrci", "csrrsi", "csrrci") and re.search(r"\bfcsr\b", ops)):
            continue
        kept.append(l)
    return kept


if sel in ("whole", "all"):
    whole = lines[start:end]
    print("\n".join(apply_patches(strip_flags(whole)) if noflags else whole))
    sys.exit()

marks = [i for i, l in enumerate(lines) if label_re.match(l) and start <= i < end]
blocks = []   # (label, lines of the symbol)
for n, i in enumerate(marks):
    j = marks[n + 1] if n + 1 < len(marks) else end
    blocks.append((label_re.match(lines[i]).group(1), lines[i:j]))

fail_re = re.compile(r"\sjal\s+\w+,[0-9a-f]+ <failedtest")


def check_end(body):
    """Index of the last line of a testcase's checks. Each testcase has two checks (result,
    fflags), each ending "jal failedtest_*; .word; .word; addi ptr,ptr,4", whichever
    registers the framework picked (they change when the test's rd is sp, tp, gp...).
    So the testcase ends 3 lines after its second failedtest jump; the code after it
    (operand loads of the next testcase, or the epilogue of the last one) is not part of it."""
    hits = [x for x, l in enumerate(body) if fail_re.search(l)]
    if len(hits) >= 2:
        return min(hits[1] + 3, len(body) - 1)
    return hits[0] + 3 if hits else len(body) - 1


# The part after the checks of a symbol is the operand-load code of the next testcase;
# for the first testcase it is everything before the first label.
carry = lines[start + 1:marks[0]] if marks else []
setups, bodies = [], []
for label, body in blocks:
    k = check_end(body)
    setups.append(carry)
    bodies.append(body[:k + 1])
    carry = body[k + 1:]

if not sel:
    for n, (label, _) in enumerate(blocks, 1):
        print(f"{n:5d}  {label}")
    print(f"({len(blocks)} testcases; show one with: "
          f"bash scripts/act4_show_asm.sh {insn} {num} <number|A-B|label|every>)", file=sys.stderr)
    sys.exit()

if sel == "every":
    wanted = list(range(len(blocks)))
elif re.fullmatch(r"\d+-\d+", sel):
    a, b = (int(x) for x in sel.split("-"))
    wanted = [n for n in range(a - 1, b) if 0 <= n < len(blocks)]
    if not wanted or a > b:
        sys.exit(f"Range {sel!r} is outside 1..{len(blocks)}")
elif sel.isdigit():
    wanted = [int(sel) - 1]
else:
    wanted = [next((n for n, (label, _) in enumerate(blocks) if label == sel), -1)]
if any(not 0 <= n < len(blocks) for n in wanted):
    sys.exit(f"No testcase {sel!r} in this ELF ({len(blocks)} testcases)")

# Operand values come from the test source: "# load fs1: f1 = 0x..." in the n-th testcase.
src_cases = []   # per testcase: (heading, [(fs, reg, value)])
try:
    text = open(src, encoding="utf-8", errors="replace").read().splitlines()
    starts = [i for i, l in enumerate(text) if l.startswith("# Testcase")]
    for n, s0 in enumerate(starts):
        stop = starts[n + 1] if n + 1 < len(starts) else len(text)
        found = [m.groups() for m in (re.search(r"# load (\w+): (\w+) = (0x[0-9a-fA-F]+)", l)
                                       for l in text[s0:stop]) if m]
        src_cases.append((text[s0], found))
except OSError:
    pass

mem_test = insn in ("flw", "fsw")   # different check sequence: no load/check split


def abi_name(reg):
    """f0 -> ft0, x3 -> gp: the register name objdump prints."""
    m = re.fullmatch(r"([fx])(\d+)", reg)
    if not m:
        return reg
    n = int(m.group(2))
    if m.group(1) == "f":
        return (f"ft{n}" if n < 8 else f"fs{n - 8}" if n < 10 else f"fa{n - 10}" if n < 18
                else f"fs{n - 16}" if n < 28 else f"ft{n - 20}")
    return (("zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1")[n] if n < 10
            else f"a{n - 10}" if n < 18 else f"s{n - 16}" if n < 28 else f"t{n - 25}")


def render(idx):
    # flw/fsw: print the symbol itself
    out = blocks[idx][1] if mem_test else setups[idx] + bodies[idx]
    if mem_test:   # the last symbol runs on into the framework's failedtest_* handlers
        out = out[:next((k for k, l in enumerate(out) if re.match(r"^[0-9a-f]+ <failedtest", l)),
                        len(out))]
    if noflags:
        out = apply_patches(strip_flags(out))
    while out and not out[-1].strip():
        out.pop()
    if raw == "1":
        return "\n".join(out)
    heading, loads = src_cases[idx] if idx < len(src_cases) else ("", [])
    heading = heading.replace("# Testcase ", f"# Testcase #{idx + 1}/{len(blocks)} ", 1) if heading \
        else f"# Testcase #{idx + 1}/{len(blocks)} {blocks[idx][0]}"
    if noflags:
        heading += "   [CSR-free program, fflags not checked]"

    rows = []        # (addr, text, comment); text None = label line
    for l in out:
        m = line_re.match(l)
        if not m:
            lab = re.match(r"^([0-9a-f]+) <(.+)>:$", l)
            if lab:
                rows.append((lab.group(1), None, lab.group(2)))
            continue
        addr, rest = m.groups()
        mnem, _, ops = rest.partition("\t")
        ops = re.split(r"\s+(?:#|<)", ops)[0].strip()   # drop objdump trailing "# addr <sym>" notes
        if mnem in ("nop", ".word") or (mnem == "jal" and "failedtest" in rest):
            continue
        rows.append((addr, f"{mnem:<8} {ops}".rstrip(), ""))

    merged, i = [], 0     # "auipc t0,X ; addi t0,t0,Y" -> one line
    while i < len(rows):
        addr, txt, com = rows[i]
        if txt and txt.startswith("auipc") and i + 1 < len(rows) and rows[i + 1][1] \
                and rows[i + 1][1].startswith("addi"):
            reg = txt.split()[1].split(",")[0]
            merged.append((addr, f"auipc {reg} / addi {reg},...", "point to scratch word fp_sigupd_temp"))
            i += 2
            continue
        merged.append((addr, txt, com))
        i += 1

    load_no, check_no, seen_label, tested = 0, 0, False, False
    annotated = []
    for addr, txt, com in merged:
        if txt is None:
            seen_label = True
            annotated.append((addr, None, com))
            continue
        mnem = txt.split()[0]
        ops = txt[len(mnem):].strip()
        if not seen_label:
            if re.match(r"f?lw$", mnem) and re.search(r",0\(\w+\)$", ops):
                if load_no < len(loads):
                    fs, reg, val = loads[load_no]
                    # ACT4 names the source fields fs1/fs2/fs3 (FP) or rs1 (integer); use the
                    # spec field names rs1/rs2/rs3 and add the ABI name objdump prints.
                    field = {"fs1": "rs1", "fs2": "rs2", "fs3": "rs3"}.get(fs, fs)
                    com = f"load {field} operand: {reg} ({abi_name(reg)}) = {val}"
                else:
                    com = f"load operand {load_no + 1}"
                if ops.startswith("zero,"):
                    com += " (destination is zero, so the operand is actually 0)"
                load_no += 1
            elif mnem == "fsflagsi":
                com = "clear fflags"
            elif mnem == "fsrmi" and ops.split(",")[-1].isdigit():
                rm = int(ops.split(",")[-1])
                name = ("RNE", "RTZ", "RDN", "RUP", "RMM")[rm] if rm < 5 else "reserved"
                com = f"set frm = {rm} ({name}) for instructions with rm = DYN"
            elif mnem == "fscsr":
                com = "write fcsr = 0: clear fflags and set frm = RNE"
            elif mnem in ("csrsi", "csrrsi") and "fcsr" in ops:
                com = "preset fflags (tests that flags accumulate)"
            elif mnem == "mv" and ops in ("a1,sp", "a0,gp"):
                com = ("use a1 as expected-value pointer because rd = sp" if ops == "a1,sp"
                       else "use a0 as data pointer because rd = gp")
            elif mnem == "mv":
                com = "move to another register: rd is a register the ACT4 framework uses"
        else:
            if not tested:
                tested = True
                com = "← instruction under test"
                if int(addr, 16) in patches and not is_csr(patches[int(addr, 16)]):
                    rm = RM_NAMES[(patches[int(addr, 16)] >> 12) & 7]
                    com += f" (ACT4: rm=DYN, reads frm={rm.upper()}; here: rm={rm} written in the instruction)"
            elif mnem in ("fsw", "sw") and "(t0)" in ops:
                com = "store result to memory"
            elif mnem == "lw" and ops.endswith("(t0)"):
                com = "read it back as an integer"
            elif mnem == "lw" and re.fullmatch(r"\w+,0\(\w+\)", ops):
                check_no += 1
                com = "load expected result" if check_no == 1 else "load expected fflags"
            elif mnem == "beq":
                com = ("match: next testcase; mismatch: jump to failedtest_*" if noflags
                       else "match: go to the fflags check; mismatch: jump to failedtest_*" if check_no <= 1
                       else "match: next testcase; mismatch: jump to failedtest_fflags")
            elif mnem == "beqz":
                com = "rd = zero, so the result is always 0: only the expected value must be 0"
            elif mnem == "frflags":
                com = "read actual fflags"
            elif mnem == "addi" and re.fullmatch(r"(\w+),\1,4", ops):
                com = "advance to next expected value"
        annotated.append((addr, txt, com))

    if mem_test:
        annotated = [(a, t, c if t is None or c.startswith("←") else "") for a, t, c in annotated]
        heading += "\n# (flw/fsw use a different check sequence, so only the instruction under test is marked; use --raw for everything)"
    result = [heading] if heading else []
    for addr, txt, com in annotated:
        if txt is None:
            result.append(f"\n{addr} <{com}>:")
        else:
            result.append((f"{addr:>8}:  {txt:<34}" + (f" # {com}" if com else "")).rstrip())
    return "\n".join(result)


many = len(wanted) > 1
for n, idx in enumerate(wanted):
    if many:
        print(f"\n---------------- F-{insn}-{num}  testcase {idx + 1}/{len(blocks)}: {blocks[idx][0]}")
    print(render(idx))
PY
