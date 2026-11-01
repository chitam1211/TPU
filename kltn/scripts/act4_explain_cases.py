#!/usr/bin/env python3
"""Representative ACT4 testcases of the RV32F instructions, explained.

For each instruction, the testcases are classified (normal, rounding, tie, overflow,
underflow, subnormal, zero sign, infinity, invalid, NaN, ...) by an exact IEEE 754 model
(fp32_ref.py); one representative per class is extracted from the disassembly and written
to <insn>_cases.asm with Vietnamese comments: why it is tested, inputs, expected output
and why the output is what it is. <insn>_cases.json lists the cases for act4_case_wave.py.

Expected values are Sail's (ACT4 .results files). Every extracted case is checked:
model == Sail, otherwise it is reported as MISMATCH (exit code 1).

Usage (from kltn/, Windows or WSL):
  python scripts/act4_explain_cases.py fadd.s            # one instruction
  python scripts/act4_explain_cases.py all               # all 26
  python scripts/act4_explain_cases.py all --validate    # model vs Sail on EVERY testcase
Options: --out-dir (default reports/act4_cases), --disasm-dir, --act-root
"""
import argparse
import glob
import json
import os
import re
import struct
import sys
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fp32_ref as fp                                   # noqa: E402
from act4_case_text import FADD_CASES                   # noqa: E402

KLTN = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ALL = ["flw", "fsw", "fadd.s", "fsub.s", "fmul.s", "fdiv.s", "fsqrt.s",
       "fmadd.s", "fmsub.s", "fnmsub.s", "fnmadd.s", "fsgnj.s", "fsgnjn.s", "fsgnjx.s",
       "fmin.s", "fmax.s", "feq.s", "flt.s", "fle.s", "fcvt.w.s", "fcvt.wu.s",
       "fcvt.s.w", "fcvt.s.wu", "fmv.x.w", "fmv.w.x", "fclass.s"]
FLAG_BITS = [(0x10, "NV"), (0x08, "DZ"), (0x04, "OF"), (0x02, "UF"), (0x01, "NX")]
INT_RESULT = {"feq.s", "flt.s", "fle.s", "fclass.s", "fcvt.w.s", "fcvt.wu.s", "fmv.x.w"}
INT_SOURCE = {"fcvt.s.w", "fcvt.s.wu", "fmv.w.x"}


# ------------------------------------------------------------------------------ paths
def default_act_root():
    for p in (os.environ.get("ACT_ROOT"), os.path.expanduser("~/tools/riscv-arch-test"),
              r"\\wsl.localhost\Ubuntu\home\chitam\tools\riscv-arch-test"):
        if p and os.path.isdir(p):
            return p
    return None


def default_disasm_dir():
    runs = sorted(glob.glob(os.path.join(KLTN, "reports", "act4_runs", "*")))
    runs = [r for r in runs if glob.glob(os.path.join(r, "F-*.disasm.txt"))]
    return runs[-1] if runs else None


# ------------------------------------------------------------------------------ loading
LABEL_RE = re.compile(r"^[0-9a-f]+ <(F_[^>]*_cg_[^>]*)>:$")
FAIL_RE = re.compile(r"\sjal\s+\w+,[0-9a-f]+ <failedtest")


def parse_source(path):
    """label -> testcase facts from the ACT4 .S source."""
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    heads = [i for i, l in enumerate(lines) if l.startswith("# Testcase")]
    out = {}
    for n, s in enumerate(heads):
        block = lines[s:heads[n + 1] if n + 1 < len(heads) else len(lines)]
        info = dict(heading=block[0][2:], loads=[], frm=None, preset=None, other_csr=False,
                    label=None, op=None, rm=None, load_value=None, setup=[])
        for i, l in enumerate(block):
            if info["label"] is None and l.strip() and not l.strip().startswith("#"):
                info["setup"].append(l.split("#")[0].strip())
            m = re.search(r"# load (\w+): (\w+) = (0x[0-9a-fA-F]+)", l)
            if m and info["label"] is None:
                info["loads"].append((m.group(1), m.group(2), int(m.group(3), 16)))
            if info["label"] is None:
                m = re.match(r"\s*fsrmi\s+(\w+)", l)
                if m: info["frm"] = int(m.group(1), 0)
                m = re.match(r"\s*csrsi\s+fcsr,\s*(\w+)", l)
                if m: info["preset"] = int(m.group(1), 0)
                if re.match(r"\s*(fscsr|csrw|csrrw|fsrm\b|csrs\b|csrc)", l): info["other_csr"] = True
            m = re.match(r"^(F_\w+):\s*$", l)
            if m and info["label"] is None:
                info["label"] = m.group(1)
                op = next((x.strip() for x in block[i + 1:] if x.strip() and not x.strip().startswith("#")), "")
                info["op"] = op
                body = op.split("#")[0].split()
                info["rm"] = body[-1].lower() if body and body[-1].lower() in fp.RM_NAMES + ["dyn"] else None
                m2 = re.search(r"perform load \((0x[0-9a-fA-F]+)\)", op)
                if m2: info["load_value"] = int(m2.group(1), 16)
        if info["label"]:
            out[info["label"]] = info
    return out


def load_file(insn, num, disasm_dir, act_root):
    name = f"F-{insn}-{num}"
    lines = open(os.path.join(disasm_dir, f"{name}.disasm.txt"), encoding="utf-8",
                 errors="replace").read().splitlines()
    results = src = None
    if act_root:
        rp = os.path.join(act_root, "work", "rv32if-core", "build", "rv32i", "F", f"{name}.results")
        if os.path.exists(rp):
            results = [int(m.group(1), 16) for m in
                       (re.search(r"0x([0-9a-fA-F]+)", l) for l in open(rp)) if m]
        sp = os.path.join(act_root, "tests", "rv32i", "F", f"{name}.S")
        if os.path.exists(sp):
            src = parse_source(sp)
    start = next(i for i, l in enumerate(lines) if "<rvtest_code_begin>:" in l)
    end = next((i for i, l in enumerate(lines) if "<rvtest_code_end>:" in l), len(lines))
    marks = [i for i in range(start, end) if LABEL_RE.match(lines[i])]
    tests, carry, word = [], lines[start + 1:marks[0]], 1      # word 0 of .results = canary
    for n, i in enumerate(marks):
        j = marks[n + 1] if n + 1 < len(marks) else end
        body = lines[i:j]
        hits = [k for k, l in enumerate(body) if FAIL_RE.search(l)]
        k = min(hits[-1] + 3, len(body) - 1) if hits else len(body) - 1
        label = LABEL_RE.match(lines[i]).group(1)
        skip = 1 if insn == "fsw" else 0                        # the stored word itself
        exp = exp_index = None
        if results and hits:
            exp_index = word + skip                             # 0-based word = line - 1 of .results
            exp = (results[exp_index], results[exp_index + 1] if len(hits) > 1 else None)
        word += skip + len(hits)
        t = dict(label=label, setup=carry, body=body[:k + 1], exp=exp, exp_index=exp_index,
                 num=num, tc=n + 1, total=len(marks), insn=insn, src=(src or {}).get(label))
        tests.append(t)
        carry = body[k + 1:]
    return tests


def load_insn(insn, disasm_dir, act_root):
    files = sorted(glob.glob(os.path.join(disasm_dir, f"F-{insn}-[0-9]*.disasm.txt")))
    tests = []
    for f in files:
        num = re.search(r"-(\d+)\.disasm\.txt$", f).group(1)
        tests += load_file(insn, num, disasm_dir, act_root)
    return tests


def operands_and_mode(t):
    """(operands, mode int, mode name, how) of a testcase, or None if not modelled."""
    s = t["src"]
    if not s or s["other_csr"]:
        return None
    insn = t["insn"]
    if insn == "flw":
        ops = [s["load_value"]] if s["load_value"] is not None else None
    elif insn == "fsw":
        ops = [v for n, _, v in s["loads"] if n == "fs2"]
    else:
        order = {"fs1": 0, "fs2": 1, "fs3": 2, "rs1": 0}
        # x0 reads as 0 whatever the framework tried to load into it
        ops = [0 if r == "x0" else v for n, r, v in sorted(s["loads"], key=lambda x: order.get(x[0], 9))]
    if not ops:
        return None
    if insn not in fp.ROUNDED:
        return ops, fp.RNE, None, "none"
    rm = s["rm"] or "dyn"
    if rm == "dyn":
        # no fsrmi in the testcase: frm still holds 0 (boot value, restored after each dyn test)
        frm = 0 if s["frm"] is None else s["frm"]
        if frm > 4:
            return None
        return ops, frm, fp.RM_NAMES[frm], "dyn"
    return ops, fp.RM_NAMES.index(rm), rm, "static"


def dest_is_x0(t):
    op = (t["src"] or {}).get("op") or ""
    parts = op.split("#")[0].replace(",", " ").split()
    return t["insn"] in INT_RESULT and len(parts) > 1 and parts[1] == "x0"


def model(t):
    om = operands_and_mode(t)
    if om is None:
        return None
    ops, mode, _, _ = om
    r = fp.execute(t["insn"], ops, mode)
    if dest_is_x0(t):
        r.bits, r.rule = 0, "rd_x0"
    if t["src"]["preset"]:
        r.flags |= t["src"]["preset"] & 0x1F
    return r


# ------------------------------------------------------------------------------ validate
def validate(insns, disasm_dir, act_root):
    bad_total = 0
    for insn in insns:
        tests = load_insn(insn, disasm_dir, act_root)
        n = ok = skipped = 0
        bad = []
        for t in tests:
            r = model(t)
            if r is None or t["exp"] is None:
                skipped += 1
                continue
            n += 1
            er, ef = t["exp"]
            if r.bits == er and (ef is None or r.flags == ef):
                ok += 1
            else:
                bad.append((t, r))
        bad_total += len(bad)
        print(f"{insn:<10} {len(tests):6d} testcases  model==Sail {ok:6d}/{n:<6d} skipped {skipped}")
        for t, r in bad[:5]:
            print(f"   MISMATCH F-{insn}-{t['num']} tc {t['tc']} {t['label']}: "
                  f"Sail {t['exp'][0]:08x}/{t['exp'][1]} model {r.bits:08x}/{r.flags:02x}")
    return 1 if bad_total else 0


# ------------------------------------------------------------------------------ classify
FAMILY = {"fadd.s": "arith", "fsub.s": "arith", "fmul.s": "arith", "fdiv.s": "arith",
          "fsqrt.s": "sqrt", "fmadd.s": "fma", "fmsub.s": "fma", "fnmsub.s": "fma", "fnmadd.s": "fma",
          "fmin.s": "minmax", "fmax.s": "minmax", "feq.s": "cmp", "flt.s": "cmp", "fle.s": "cmp",
          "fsgnj.s": "sgnj", "fsgnjn.s": "sgnj", "fsgnjx.s": "sgnj", "fclass.s": "class",
          "fcvt.w.s": "f2i", "fcvt.wu.s": "f2i", "fcvt.s.w": "i2f", "fcvt.s.wu": "i2f",
          "fmv.x.w": "move", "fmv.w.x": "move", "flw": "move", "fsw": "move"}
ORDER = {
    "arith": ["normal", "round", "tie", "modes", "cancel", "zero_sign", "zero_in", "sub_in", "sub_out",
              "underflow", "overflow", "inf", "div_by_inf", "invalid", "divzero", "qnan", "snan"],
    "fma": ["normal", "fused", "round", "tie", "modes", "zero_sign", "zero_in", "sub_in", "sub_out",
            "underflow", "overflow", "inf", "invalid", "qnan", "snan"],
    "sqrt": ["exact", "round", "modes", "sub_in", "zero", "inf", "invalid", "qnan", "snan"],
    "f2i": ["exact", "negative", "round", "tie", "modes", "small", "sub_in", "zero", "neg_wu", "range",
            "inf", "nan"],
    "i2f": ["exact", "negative", "zero", "round", "tie", "modes", "int_min"],
    "cmp": ["less", "equal", "greater", "zeros", "sub_in", "inf", "qnan", "snan"],
    "minmax": ["compare", "neg", "equal", "zeros", "sub_in", "inf", "one_qnan", "both_nan", "snan"],
    "sgnj": ["pp", "pn", "np", "nn", "zero", "inf", "nan"],
    "class": [f"class{i}" for i in range(10)],
    "move": ["normal", "negative", "zero", "neg_zero", "subnormal", "inf", "qnan", "snan"],
}
MEM_KEYS = ["imm_zero", "imm_pos", "imm_odd", "imm_neg", "imm_max", "imm_min", "base_reg"]
ORDER["flw"] = MEM_KEYS + ["normal", "negative"]
ORDER["fsw"] = MEM_KEYS + ORDER["move"]


def mem_access(t):
    """(imm, rs1, base register, adjustment) of an flw/fsw testcase: rs1 = base + adjustment,
    built by the source's mv/addi lines (e.g. addi x11,x2,2047 ; addi x11,x11,1)."""
    s = t["src"] or {}
    m = re.search(r"\s(-?\d+)\((x\d+)\)", s.get("op") or "")
    if not m:
        return None
    imm, rs1 = int(m.group(1)), m.group(2)
    base, adj = None, 0
    for l in s.get("setup", []):
        a = re.match(rf"addi\s+{rs1},\s*(x\d+),\s*(-?\d+)$", l)
        v = re.match(rf"mv\s+{rs1},\s*(x\d+)$", l)
        if a and a.group(1) == rs1 and base is not None:
            adj += int(a.group(2))
        elif a:
            base, adj = a.group(1), int(a.group(2))
        elif v:
            base, adj = v.group(1), 0
    return imm, rs1, base, adj


def mem_category(t):
    lab = t["label"]
    if "cp_imm_edges" in lab:
        acc = mem_access(t)
        if acc:
            imm = acc[0]
            return ("imm_zero" if imm == 0 else "imm_max" if imm == 2047 else "imm_min" if imm == -2048
                    else "imm_neg" if imm < 0 else "imm_odd" if imm % 4 else "imm_pos")
    if "cp_rs1_nx0" in lab:
        return "base_reg"
    return None
# second testcase (other rounding mode, different result) shown with these categories
COMPANION = {"zero_sign": ["rdn"], "overflow": ["rtz", "rdn", "rup"], "tie": ["rmm", "rup", "rtz"],
             "round": ["rup", "rdn", "rtz"], "small": ["rup", "rdn"], "sub_in": ["rup", "rdn"]}


def is_fp_sub(x): return fp.exp_of(x) == 0 and fp.man_of(x) != 0


def two_step(insn, ops, mode):
    """fmul then fadd (two roundings) for an FMA instruction: bits."""
    a, b, c = ops
    m = fp.fmul(a, b, mode).bits
    if insn in ("fnmsub.s", "fnmadd.s"): m ^= fp.SIGN
    c2 = c ^ fp.SIGN if insn in ("fmsub.s", "fnmadd.s") else c
    return fp.fadd(m, c2, mode).bits


def categorize(insn, ops, mode, r, t=None):
    fam = FAMILY[insn]
    if insn in ("flw", "fsw") and t is not None:
        k = mem_category(t)
        if k:
            return k
    if fam in ("arith", "fma", "sqrt"):
        kinds = [fp.kind(o) for o in ops]
        if "snan" in kinds: return "snan"
        if "qnan" in kinds: return "qnan"
        if r.flags & fp.NV: return "invalid"
        if r.flags & fp.DZ: return "divzero"
        if "inf" in kinds: return "div_by_inf" if r.rule == "div_by_inf" else "inf"
        if r.overflow: return "overflow"
        if r.flags & fp.UF: return "underflow"
        if r.rule == "zero_sum": return "zero_sign"
        if r.rule == "sqrt_zero": return "zero"
        if r.rule == "zero_operand": return "zero_in"
        if fam == "fma" and two_step(insn, ops, mode) != r.bits: return "fused"
        if is_fp_sub(r.bits): return "sub_out"
        if "subnormal" in kinds: return "sub_in"
        if r.tie: return "tie"
        if r.inexact: return "round"
        if "zero" in kinds: return "zero_in"
        if fam == "sqrt": return "exact"
        if insn in ("fadd.s", "fsub.s") and fp.exp_of(r.bits) + 8 <= max(fp.exp_of(o) for o in ops):
            return "cancel"
        return "normal"
    if fam == "f2i":
        a, uns = ops[0], insn == "fcvt.wu.s"
        k = fp.kind(a)
        if k in ("snan", "qnan"): return "nan"
        if k == "inf": return "inf"
        if r.rule == "cvt_range": return "neg_wu" if (uns and fp.sign_of(a)) else "range"
        if k == "zero": return "zero"
        if k == "subnormal": return "sub_in"
        if uns and fp.sign_of(a): return "neg_wu"
        if r.tie: return "tie"
        if r.inexact: return "small" if abs(fp.value(a)) < 1 else "round"
        return "negative" if fp.sign_of(a) else "exact"
    if fam == "i2f":
        v = fp.int_value(ops[0], insn == "fcvt.s.wu")
        if v == 0: return "zero"
        if insn == "fcvt.s.w" and ops[0] == 0x80000000: return "int_min"
        if r.tie: return "tie"
        if r.inexact: return "round"
        return "negative" if v < 0 else "exact"
    if fam == "cmp":
        a, b = ops
        kinds = [fp.kind(a), fp.kind(b)]
        if "snan" in kinds: return "snan"
        if "qnan" in kinds: return "qnan"
        if kinds == ["zero", "zero"]: return "zeros"
        if "inf" in kinds: return "inf"
        if "subnormal" in kinds: return "sub_in"
        va, vb = fp.value(a), fp.value(b)
        return "equal" if va == vb else "less" if va < vb else "greater"
    if fam == "minmax":
        a, b = ops
        kinds = [fp.kind(a), fp.kind(b)]
        if all(k in ("snan", "qnan") for k in kinds): return "both_nan"
        if "snan" in kinds: return "snan"
        if "qnan" in kinds: return "one_qnan"
        if kinds == ["zero", "zero"]: return "zeros"
        if "inf" in kinds: return "inf"
        if "subnormal" in kinds: return "sub_in"
        if fp.value(a) == fp.value(b): return "equal"
        return "neg" if fp.sign_of(a) and fp.sign_of(b) else "compare"
    if fam == "sgnj":
        a, b = ops
        k = fp.kind(a)
        if k in ("snan", "qnan"): return "nan"
        if k == "inf": return "inf"
        if k == "zero": return "zero"
        return "pnpn"[0] * 0 + {(0, 0): "pp", (0, 1): "pn", (1, 0): "np", (1, 1): "nn"}[(fp.sign_of(a), fp.sign_of(b))]
    if fam == "class":
        return f"class{r.bits.bit_length() - 1}"
    if fam == "move":
        a = ops[0]
        k = fp.kind(a)
        if k == "zero": return "neg_zero" if fp.sign_of(a) else "zero"
        if k == "normal": return "negative" if fp.sign_of(a) else "normal"
        return k
    return None


def complexity(insn, ops):
    if insn in INT_SOURCE:
        return bin(ops[0]).count("1")
    return sum(bin(fp.man_of(o)).count("1") + (3 if fp.is_nan(o) and fp.man_of(o) not in (0x400000, 1) else 0)
               for o in ops)


def score(t, key, ops, how, mode_name):
    lab = t["label"]
    pref = 0 if ("edges" in lab or "_cr_" in lab) else 1
    bonus = 0
    if key in ("zeros", "zero_sign") and len(ops) > 1 and fp.sign_of(ops[0]) == fp.sign_of(ops[1]):
        bonus = 1                                       # prefer +0 vs -0
    if key in ("less", "greater", "equal", "compare", "neg") and any(fp.is_zero(o) for o in ops):
        bonus = 1                                       # plain comparisons: two non-zero numbers
    return (pref, bonus, {"static": 0, "none": 0, "dyn": 2}[how], 0 if mode_name in (None, "rne") else 1,
            complexity(t["insn"], ops), t["num"], t["tc"])


def op_key(t):
    om = operands_and_mode(t)
    return tuple(om[0]) if om else None


def select(insn, tests):
    """[(category, [testcase, ...]), ...] in presentation order."""
    fam = FAMILY[insn]
    cands, by_ops = {}, {}
    for t in tests:
        s = t["src"]
        if not s or dest_is_x0(t) or any(r == "x0" for _, r, _ in s["loads"]) or t["exp"] is None:
            continue
        om = operands_and_mode(t)
        if om is None:
            continue
        ops, mode, mode_name, how = om
        r = model(t)
        if r.bits != t["exp"][0] or (t["exp"][1] is not None and r.flags != t["exp"][1]):
            continue                                    # never explain a case the model gets wrong
        t["model"], t["mode_name"], t["how"] = r, mode_name, how
        key = categorize(insn, ops, mode, r, t)
        if key:
            cands.setdefault(key, []).append((score(t, key, ops, how, mode_name), t))
        if how == "static":
            by_ops.setdefault(tuple(ops), {})[mode_name] = t
    picked = []
    for key in ORDER.get(insn) or ORDER[fam]:
        if key == "modes":
            best = None
            used = {op_key(t) for _, g in picked for t in g}
            for ops, modes in by_ops.items():
                if ops in used or len(modes) < 5 or any(fp.is_nan(o) or fp.is_inf(o) for o in ops if insn not in INT_SOURCE):
                    continue
                distinct = len({m["model"].bits for m in modes.values()})
                sc = (-distinct, complexity(insn, list(ops)))
                if distinct >= 2 and (best is None or sc < best[0]):
                    best = (sc, [modes[m] for m in fp.RM_NAMES])
            if best:
                picked.append(("modes", best[1]))
            continue
        if key not in cands:
            continue
        t = min(cands[key], key=lambda x: x[0])[1]
        group = [t]
        for m in COMPANION.get(key, []):
            o = by_ops.get(op_key(t), {}).get(m)
            if o is not None and o is not t and o["model"].bits != t["model"].bits:
                group.append(o)
                break
        picked.append((key, group))
    return picked


# ------------------------------------------------------------------------------ explain
MODE_RULE = {"rne": "RNE chọn số GẦN NHẤT (hòa -> số chẵn)",
             "rtz": "RTZ chọn số có độ lớn NHỎ HƠN (về phía 0)",
             "rdn": "RDN chọn số NHỎ HƠN (về phía -vô cực)",
             "rup": "RUP chọn số LỚN HƠN (về phía +vô cực)",
             "rmm": "RMM chọn số GẦN NHẤT (hòa -> số xa 0)"}


def flags_text(f):
    if f is None:
        return "(không kiểm tra)"
    names = [n for b, n in FLAG_BITS if f & b]
    return f"0x{f:02x} ({' + '.join(names)})" if names else "0x00 (không cờ nào)"


def describe(x):
    """Human description of a float32 bit pattern."""
    s, e, m = x >> 31, (x >> 23) & 0xFF, x & 0x7FFFFF
    sign = "-" if s else "+"
    if e == 0xFF:
        if m == 0:
            return f"{sign}vô cực"
        return f"{'qNaN' if m & 0x400000 else 'sNaN'} (payload 0x{m & 0x3FFFFF:06x})"
    if e == 0 and m == 0:
        return f"{sign}0"
    v = struct.unpack(">f", struct.pack(">I", x))[0]
    if e == 0:
        return f"{v:.9g} (subnormal = {sign}{m} x 2^-149)"
    tag = " (số hữu hạn lớn nhất)" if (e, m) == (0xFE, 0x7FFFFF) else \
        " (số thường nhỏ nhất)" if (e, m) == (1, 0) else ""
    return f"{v:.9g}{tag}"


def short(x):
    if fp.is_nan(x): return "NaN"
    if fp.is_inf(x): return "-vô cực" if fp.sign_of(x) else "+vô cực"
    if fp.is_zero(x): return "-0" if fp.sign_of(x) else "+0"
    return f"{struct.unpack('>f', struct.pack('>I', x))[0]:.9g}"


def fmt_frac(f):
    """Readable exact value."""
    if f == 0:
        return "0"
    a = abs(f)
    if a.numerator == 1 or a.denominator == 1:
        n = a.denominator if a.numerator == 1 else a.numerator
        if n & (n - 1) == 0 and n > 2 ** 8:
            k = n.bit_length() - 1
            return f"{'-' if f < 0 else ''}2^{-k if a.numerator == 1 else k}"
    if a.denominator == 1 and a < 10 ** 12:
        return str(f.numerator)
    try:
        bits = fp.encode(1 if f < 0 else 0, a)
        if fp.value(bits) == f:
            return short(bits)
    except AssertionError:
        pass
    from decimal import Decimal, getcontext
    getcontext().prec = 30
    d = Decimal(f.numerator) / Decimal(f.denominator)
    return f"≈ {d:.12g}"


def bits_breakdown(x):
    return (f"{x >> 31} {(x >> 23) & 0xFF:08b} {x & 0x7FFFFF:023b} "
            f"(dấu {x >> 31}, trường mũ {(x >> 23) & 0xFF}, mantissa 0x{x & 0x7FFFFF:06x})")


def expr(insn, ops):
    n = [short(o) for o in ops] if insn not in INT_SOURCE else [str(fp.int_value(ops[0], insn.endswith("wu")))]
    return {"fadd.s": "{0} + {1}", "fsub.s": "{0} - {1}", "fmul.s": "{0} x {1}", "fdiv.s": "{0} / {1}",
            "fsqrt.s": "căn({0})", "fmadd.s": "{0} x {1} + {2}", "fmsub.s": "{0} x {1} - {2}",
            "fnmsub.s": "-({0} x {1}) + {2}", "fnmadd.s": "-({0} x {1}) - {2}"}.get(insn, "{0}").format(*n)


def explain_rounded(insn, ops, mode_name, r):
    """Why-lines for an operation that computes then rounds to float32."""
    L = []
    e = expr(insn, ops)
    if r.exact is not None:
        v = fmt_frac(r.exact)
        L.append(f"Giá trị đúng (toán học) = {e}" + ("" if v == e else f" {v}" if v.startswith("≈") else f" = {v}") + ".")
    else:
        L.append(f"Giá trị đúng (toán học) = {e} là số vô tỉ (khai triển nhị phân vô hạn).")
    if r.overflow:
        L.append("Giá trị này vượt số hữu hạn lớn nhất (0x7F7FFFFF ≈ 3.40282347e38) -> TRÀN TRÊN.")
        L.append("Khi tràn, kết quả phụ thuộc rm: RNE/RMM -> vô cực; RTZ -> số lớn nhất; RDN -> +max nếu")
        L.append("dương, -vô cực nếu âm; RUP -> +vô cực nếu dương, -max nếu âm.")
        L.append(f"Ở đây {mode_name.upper()} -> 0x{r.bits:08X} = {describe(r.bits)}; cờ OF + NX.")
        return L
    if not r.inexact:
        L.append("Giá trị này biểu diễn CHÍNH XÁC được bằng float32 -> không làm tròn, không bật NX.")
        L.append(f"Mã hóa kết quả: {bits_breakdown(r.bits)} = 0x{r.bits:08X}.")
        if is_fp_sub(r.bits):
            L.append("Kết quả là subnormal nhưng chính xác -> không bật UF (UF cần cả tiny lẫn không chính xác).")
        return L
    lo = f"0x{r.lo:08X} ({short(r.lo)})" if r.lo is not None else "?"
    hi = f"0x{r.hi:08X} ({short(r.hi)})" if r.hi is not None else "?"
    L.append("Không biểu diễn chính xác được (cần hơn 24 bit có nghĩa). Hai số float32 kề nhau bao quanh nó:")
    L.append(f"  số có độ lớn nhỏ hơn: {lo}")
    L.append(f"  số có độ lớn lớn hơn: {hi}")
    p = r.frac_pos
    if r.tie:
        L.append("Giá trị đúng nằm CHÍNH GIỮA hai số này (hòa).")
    elif p < Fraction(1, 1000):
        L.append("Giá trị đúng nằm RẤT SÁT số nhỏ hơn (cách chưa tới 0.001 khoảng).")
    elif p > Fraction(999, 1000):
        L.append("Giá trị đúng nằm RẤT SÁT số lớn hơn.")
    elif abs(p - Fraction(1, 2)) < Fraction(1, 1000):
        side = "lớn" if p > Fraction(1, 2) else "nhỏ"
        L.append(f"Giá trị đúng nằm SÁT điểm giữa nhưng KHÔNG hòa: lệch về phía số {side} hơn "
                 f"{abs(float(p - Fraction(1, 2))):.2e} khoảng.")
    else:
        L.append(f"Giá trị đúng nằm ở vị trí {float(p):.3f} của khoảng (0 = số nhỏ hơn, 1 = số lớn hơn), "
                 f"gần số {'nhỏ' if p < Fraction(1, 2) else 'lớn'} hơn.")
    L.append(f"{MODE_RULE[mode_name]} -> 0x{r.bits:08X} = {describe(r.bits)}.")
    if r.tie and mode_name == "rne":
        L.append(f"(Số được chọn có bit cuối mantissa = {r.bits & 1}: số chẵn.)")
    fl = "NX"
    if r.flags & fp.UF:
        fl = "UF + NX"
        L.append("Giá trị đúng nhỏ hơn 2^-126 (tiny) VÀ đã bị làm tròn -> tràn dưới. RISC-V xét tiny sau khi")
        L.append("làm tròn với số mũ không giới hạn.")
    L.append(f"Kết quả khác giá trị đúng -> cờ {fl}.")
    return L


RULE_TEXT = {
    "nan": "Có toán hạng là NaN -> kết quả là NaN. RISC-V luôn trả canonical NaN 0x7FC00000 (không giữ payload).",
    "inf_minus_inf": "(+vô cực) + (-vô cực) không xác định -> phép toán không hợp lệ: canonical NaN, bật NV.",
    "inf_times_zero": "0 x vô cực không xác định -> phép toán không hợp lệ: canonical NaN, bật NV. (Với FMA, RISC-V "
                      "bật NV kể cả khi rs3 là qNaN.)",
    "inf_div_inf": "vô cực / vô cực không xác định -> canonical NaN, bật NV.",
    "zero_div_zero": "0 / 0 không xác định -> canonical NaN, bật NV.",
    "sqrt_negative": "Căn của số âm không xác định -> canonical NaN, bật NV.",
    "div_by_zero": "Số hữu hạn khác 0 chia cho 0 -> +-vô cực (dấu = XOR hai dấu), bật DZ.",
    "inf": "Phép toán với vô cực cho kết quả vô cực CHÍNH XÁC (vô cực là giá trị hợp lệ) -> không bật cờ.",
    "zero_operand": "Có toán hạng bằng 0 -> kết quả là 0 chính xác, dấu = XOR dấu hai toán hạng; không cờ.",
    "div_by_inf": "Số hữu hạn / vô cực = 0 chính xác, dấu = XOR dấu hai toán hạng; không cờ.",
    "sqrt_zero": "IEEE 754: căn(+-0) = +-0 (giữ nguyên dấu); không phải phép toán không hợp lệ -> không cờ.",
}


def explain_address(insn, t):
    acc = mem_access(t)
    if not acc:
        return []
    imm, rs1, base, adj = acc
    op = t["src"]["op"].split("#")[0].strip()
    L = [f"Lệnh trong mã nguồn ACT4: {op}"]
    if base:
        what = "con trỏ tới ô dữ liệu" if insn == "flw" else "con trỏ signature (ô sẽ ghi)"
        L.append(f"Trước đó ACT4 đặt {rs1} = {base} + ({adj}), với {base} là {what}.")
        L.append(f"Địa chỉ hiệu dụng = {rs1} + offset = {base} + ({adj}) + ({imm}) = {base} + {adj + imm}"
                 + (" -> đúng ô cần truy cập." if adj + imm == 0 else "."))
        L.append("ACT4 bù trừ rs1 theo offset để địa chỉ cuối cùng luôn đúng ô và chia hết cho 4, nhờ đó")
        L.append("kiểm tra được mọi giá trị offset mà không truy cập lệch (misaligned).")
    if imm < 0:
        L.append(f"Offset {imm} mã hóa 12 bit = 0x{imm & 0xFFF:03X}; phần cứng phải MỞ RỘNG DẤU thành "
                 f"0x{imm & 0xFFFFFFFF:08X} trước khi cộng.")
    elif imm == 2047:
        L.append("Offset 2047 = 0x7FF: số dương lớn nhất của immediate 12 bit có dấu (bit 11 = 0).")
    if insn == "fsw":
        L.append(f"fsw tách immediate thành imm[11:5] (bit 31:25 của lệnh) và imm[4:0] (bit 11:7): "
                 f"0x{(imm >> 5) & 0x7F:02X} và 0x{imm & 0x1F:02X}.")
    return L


def explain(insn, ops, mode_name, r, t=None):
    fam = FAMILY[insn]
    if insn in ("flw", "fsw") and t is not None and mem_category(t):
        L = explain_address(insn, t)
        L.append(f"Dữ liệu 0x{ops[0]:08X} được chép nguyên 32 bit "
                 + ("từ bộ nhớ vào thanh ghi float" if insn == "flw" else "từ thanh ghi float ra bộ nhớ")
                 + "; không phải phép toán -> không bật cờ.")
        return L
    if fam in ("arith", "fma", "sqrt", "i2f"):
        if r.rule in RULE_TEXT:
            L = [RULE_TEXT[r.rule]]
            if r.rule == "nan":
                L.append("Có sNaN -> bật NV." if any(fp.is_snan(o) for o in ops) else "Chỉ có qNaN -> KHÔNG bật NV.")
            return L
        if r.rule == "zero_sum":
            L = [f"Giá trị đúng = {expr(insn, ops)} = 0 chính xác."]
            zs = [o for o in ops if fp.is_zero(o)]
            L.append("IEEE 754: hai số 0 cùng dấu thì giữ dấu đó; các trường hợp còn lại (khác dấu, hoặc x + (-x))")
            L.append(f"cho +0, riêng RDN cho -0. Ở đây {mode_name.upper()} -> {short(r.bits)} = 0x{r.bits:08X}; không cờ.")
            return L
        if r.rule == "cvt_zero":
            return ["Số nguyên 0 -> +0 (0x00000000), không cờ."]
        L = explain_rounded(insn, ops, mode_name, r)
        if fam == "fma" and not r.overflow:
            ts = two_step(insn, ops, fp.RM_NAMES.index(mode_name))
            if ts != r.bits:
                L.append(f"So sánh: tính rời fmul rồi fadd (làm tròn 2 lần) sẽ ra 0x{ts:08X} = {short(ts)} -> SAI;")
                L.append("FMA chỉ làm tròn một lần trên giá trị chính xác nên ra kết quả trên.")
        return L
    if fam == "f2i":
        a, uns = ops[0], insn == "fcvt.wu.s"
        rng = "[0, 2^32 - 1]" if uns else "[-2^31, 2^31 - 1]"
        if r.rule == "cvt_nan":
            return [f"rs1 là NaN -> không có giá trị nguyên. RISC-V trả 0x{r.bits:08X} và bật NV."]
        if r.rule == "cvt_inf":
            return [f"rs1 = {short(a)} vượt mọi phạm vi {rng} -> bão hòa 0x{r.bits:08X}, bật NV."]
        v = fp.value(a)
        L = [f"rs1 = {fmt_frac(v)}."]
        if r.inexact or r.rule == "cvt_range":
            n = v.numerator // v.denominator
            if r.inexact:
                L.append(f"Không phải số nguyên: nằm giữa {n} và {n + 1}" + (" (chính giữa: hòa)." if r.tie else "."))
                L.append(f"{MODE_RULE[mode_name]}.")
        if r.rule == "cvt_range":
            L.append(f"Kết quả làm tròn nằm ngoài phạm vi {rng} -> bật NV (không bật NX), trả giá trị bão hòa "
                     f"0x{r.bits:08X}.")
            return L
        iv = fp.int_value(r.bits, uns)
        L.append(f"-> số nguyên {iv} = 0x{r.bits:08X}" + (" (bù hai)." if iv < 0 else "."))
        L.append("Có làm tròn -> cờ NX." if r.inexact else "Đổi chính xác -> không cờ.")
        return L
    if fam == "cmp":
        a, b = ops
        if r.rule == "cmp_nan":
            nv = "bật NV" if r.flags & fp.NV else "KHÔNG bật NV"
            why = ("có sNaN" if any(fp.is_snan(o) for o in ops)
                   else "flt/fle là so sánh có thứ tự" if insn != "feq.s" else "feq chỉ bật NV với sNaN")
            return [f"Có toán hạng NaN -> NaN không có thứ tự, mọi so sánh đều sai -> rd = 0.",
                    f"Cờ: {nv} ({why})."]
        rel = {"feq.s": "==", "flt.s": "<", "fle.s": "<="}[insn]
        L = [f"rs1 = {short(a)}, rs2 = {short(b)}."]
        if r.rule == "cmp_zero":
            L.append("+0 và -0 bằng nhau về giá trị (chỉ khác bit dấu).")
        L.append(f"rs1 {rel} rs2 là {'ĐÚNG' if r.bits else 'SAI'} -> rd = {r.bits}; không cờ.")
        return L
    if fam == "minmax":
        a, b = ops
        word = "nhỏ hơn" if insn == "fmin.s" else "lớn hơn"
        L = []
        if r.rule == "both_nan":
            L.append("Cả hai toán hạng là NaN -> canonical NaN 0x7FC00000.")
        elif r.rule == "one_nan":
            L.append(f"Một toán hạng là NaN -> kết quả là toán hạng còn lại: 0x{r.bits:08X} = {short(r.bits)}.")
        elif r.rule == "zeros":
            L.append(f"+0 và -0: RISC-V coi -0 < +0 -> số {word} là {short(r.bits)} = 0x{r.bits:08X}.")
        else:
            L.append(f"So sánh {short(a)} và {short(b)} -> số {word} là {short(r.bits)} = 0x{r.bits:08X}.")
        L.append("Có sNaN -> bật NV." if r.flags & fp.NV else "Không bật cờ.")
        return L
    if fam == "sgnj":
        a, b = ops
        rule = {"fsgnj.s": "dấu của rs2", "fsgnjn.s": "NGƯỢC dấu của rs2", "fsgnjx.s": "dấu rs1 XOR dấu rs2"}[insn]
        return [f"Độ lớn (31 bit thấp) lấy từ rs1 = 0x{a & 0x7FFFFFFF:08X}; dấu rs1 = {a >> 31}, dấu rs2 = {b >> 31}.",
                f"Bit dấu kết quả = {rule} = {r.bits >> 31} -> 0x{r.bits:08X} = {describe(r.bits)}.",
                "Chỉ thao tác bit: không làm tròn, không canonical hóa NaN, không bật cờ."]
    if fam == "class":
        i = r.bits.bit_length() - 1
        return [f"rs1 = 0x{ops[0]:08X} = {describe(ops[0])} -> thuộc loại {i} ({fp.CLASS_BITS[i]}).",
                f"rd = 1 << {i} = 0x{r.bits:08X}. fclass không bao giờ bật cờ, kể cả với sNaN."]
    if fam == "move":
        what = {"flw": "từ bộ nhớ vào thanh ghi float", "fsw": "từ thanh ghi float ra bộ nhớ",
                "fmv.x.w": "từ thanh ghi float sang thanh ghi nguyên",
                "fmv.w.x": "từ thanh ghi nguyên sang thanh ghi float"}[insn]
        L = [f"Chép nguyên 32 bit 0x{ops[0]:08X} {what}: kết quả 0x{r.bits:08X}."]
        if fp.is_nan(ops[0]):
            L.append("Dù là NaN, payload được giữ nguyên (không canonical hóa)"
                     + (" và sNaN KHÔNG bật NV." if fp.is_snan(ops[0]) else "."))
        L.append("Đây là chuyển dữ liệu, không phải phép toán -> không bật cờ.")
        return L
    return []


# ------------------------------------------------------------------------------ asm
INS_RE = re.compile(r"^\s*([0-9a-f]+):\s+([0-9a-f]+)\s+(\S+)\s*(.*)$")
OPERAND_NAMES = {"fsw": ["rs2"], "flw": ["bộ nhớ"]}


def annotate(t, exp):
    s = t["src"] or {}
    loads = list(s.get("loads", []))
    out, nload, checks, temp, last_base, after_op = [], 0, 0, None, None, False
    for l in t["setup"] + t["body"]:
        if not l.strip():
            continue
        lab = re.match(r"^([0-9a-f]+) <(.+)>:$", l)
        if lab:
            out.append(f"\n{lab.group(2)}:" + f"{'':<4}# địa chỉ 0x{lab.group(1)}")
            continue
        m = INS_RE.match(l)
        if not m:
            continue
        addr, code, mnem, ops = m.groups()
        ops = re.split(r"\s+#", ops)[0].strip()
        ops = re.sub(r",([0-9a-f]+) <([^>+]+)\+0x[0-9a-f]+>$", r",0x\1", ops)
        ops = re.sub(r",[0-9a-f]+ <([^>+]+)>$", r",\1", ops)
        args = ops.split(",")
        c = ""
        if not after_op:
            if mnem in ("flw", "lw") and re.fullmatch(r"\w+,0\(\w+\)", ops) and nload < len(loads):
                name, reg, val = loads[nload]
                nload += 1
                last_base = re.search(r"\((\w+)\)", ops).group(1)
                name = {"fs1": "rs1", "fs2": "rs2", "fs3": "rs3"}.get(name, name)
                c = f"nạp toán hạng {name} = 0x{val:08X}" + (f" = {describe(val)}" if mnem == "flw" else
                                                              f" = {fp.int_value(val, False)}")
            elif mnem == "addi" and len(args) == 3 and args[0] == args[1] == last_base and args[2] == "4":
                c = f"{last_base} (con trỏ dữ liệu) sang toán hạng kế tiếp"
            elif mnem == "fsflagsi":
                c = "xóa fflags = 0 để chỉ thấy cờ do lệnh cần test bật"
            elif mnem == "fsrmi":
                v = int(args[-1], 0)
                c = f"frm = {v} ({fp.RM_NAMES[v].upper() if v < 5 else 'dành riêng'}): lệnh có rm = DYN đọc giá trị này"
            elif mnem in ("csrsi", "csrrsi"):
                c = "đặt sẵn fflags (kiểm tra cờ được cộng dồn)"
            elif mnem == "addi" and len(args) == 3 and args[0] == args[1] and args[2] == "4":
                c = f"(cuối testcase trước) {args[0]} sang ô kế tiếp"
            elif mnem in ("addi", "mv") and t["insn"] in ("flw", "fsw"):
                c = "tính thanh ghi cơ sở (rs1) cho lệnh nạp/ghi, bù trừ offset"
        if t["label"] and mnem not in (".word",) and not after_op and out and out[-1].startswith("\n"):
            pass
        if after_op is False and out and out[-1].startswith(f"\n{t['label']}:"):
            after_op = "op"
        if after_op == "op":
            c = "<== LỆNH CẦN TEST"
            after_op = True
        elif after_op is True:
            if mnem == "nop":
                c = "đệm của macro ACT4, không ảnh hưởng kết quả"
            elif mnem == "auipc":
                temp = args[0]
                c = f"{temp} = địa chỉ ô nhớ tạm fp_sigupd_temp (cùng lệnh addi kế tiếp)"
            elif mnem == "addi" and temp and args[0] == args[1] == temp and checks == 0:
                c = f"(tiếp) {temp} = &fp_sigupd_temp"
            elif mnem == "fsw" and temp and f"({temp})" in ops:
                c = "ghi 32 bit kết quả float ra ô nhớ tạm"
            elif mnem == "lw" and temp and ops == f"{temp},0({temp})":
                c = "đọc lại 32 bit đó vào thanh ghi nguyên (để so bằng beq)"
            elif mnem == "lw" and re.fullmatch(r"\w+,-4\(\w+\)", ops):
                c = "đọc lại word vừa ghi ra bộ nhớ"
            elif mnem == "lw" and re.fullmatch(r"\w+,0\(\w+\)", ops):
                checks += 1
                if checks == 1:
                    c = "KẾT QUẢ MONG ĐỢI (Sail)" + (f" = 0x{exp[0]:08X}" if exp else "")
                else:
                    c = "FFLAGS MONG ĐỢI (Sail)" + (f" = {flags_text(exp[1])}" if exp and exp[1] is not None else "")
            elif mnem == "beq":
                c = ("bằng -> sang kiểm tra cờ; khác -> rơi xuống lệnh báo lỗi" if checks == 1
                     else "bằng -> PASS, sang testcase kế; khác -> rơi xuống lệnh báo lỗi")
            elif mnem == "jal" and "failedtest" in ops:
                c = "báo lỗi FAIL (chỉ chạy khi kết quả/cờ sai)"
            elif mnem == ".word":
                c = "dữ liệu cho hàm báo lỗi, không phải lệnh"
            elif mnem == "addi" and len(args) == 3 and args[0] == args[1] and args[2] == "4":
                c = "con trỏ signature/đáp án sang ô kế tiếp"
            elif mnem == "addi" and len(args) == 3 and args[0] == args[1] and t["insn"] == "fsw":
                c = "trả thanh ghi cơ sở về giá trị trước offset"
            elif mnem == "frflags":
                c = "fflags THỰC TẾ sau lệnh cần test"
        text = f"    {mnem:<9}{ops}"
        out.append(f"{text:<44}# {addr}: {code}" + (f"  | {c}" if c else ""))
    return out


def comment_block(text, indent="#   "):
    return [indent + l if l.strip() else "#" for l in text.strip().splitlines()]


def category_text(insn, key):
    fam = FAMILY[insn]
    return CATEGORY_LOOKUP(fam, key)


def CATEGORY_LOOKUP(fam, key):
    from act4_case_text import CATEGORY
    return CATEGORY.get(f"{fam}:{key}") or CATEGORY.get(key) or (key, "")


def case_blocks_auto(insn, tests):
    """[(id, title, purpose, [(t, why_lines)]), ...]"""
    blocks = []
    for n, (key, group) in enumerate(select(insn, tests), 1):
        title, purpose = CATEGORY_LOOKUP(FAMILY[insn], key)
        items = []
        for t in group:
            ops, _, mode_name, _ = operands_and_mode(t)
            items.append((t, explain(insn, ops, mode_name or "rne", t["model"], t)))
        blocks.append((str(n), title, purpose, items))
    return blocks


def case_blocks_fadd(tests):
    index = {t["label"]: t for t in tests}
    blocks = []
    for case in FADD_CASES:
        items = []
        for mode in case["modes"]:
            label = (f"F_fadd_s_cg_cr_fs1_fs2_edges_frm_fs1val_0x{case['fs1']:x}"
                     f"_fs2val_0x{case['fs2']:x}_frm_{mode}")
            t = index[label]
            t["model"], t["mode_name"], t["how"] = model(t), mode, "static"
            items.append((t, None))
        blocks.append((case["id"], case["title"], case["purpose"], items, case["why"]))
    return blocks


def write_insn(insn, tests, out_dir, disasm_dir, act_root, curated):
    from act4_case_text import INSN_DOC
    blocks = case_blocks_fadd(tests) if curated else [b + (None,) for b in case_blocks_auto(insn, tests)]
    head = f"""\
# =====================================================================================
#  ACT4 - {insn} - các testcase đại diện cho từng trường hợp
#  Sinh bởi scripts/act4_explain_cases.py từ:
#    disassembly : {os.path.relpath(disasm_dir, KLTN)}
#    đáp án Sail : {act_root or '(không có - chưa đối chiếu)'}
#  Tổng số testcase ACT4 của lệnh: {len(tests)} ; số trường hợp đại diện: {len(blocks)}
# =====================================================================================
#
#  Lệnh: {INSN_DOC[insn]}
#
#  Cấu trúc chung của MỘT testcase ACT4:
#   (1) Chuẩn bị : nạp toán hạng từ vùng dữ liệu, fsflagsi xóa fflags (fsrmi nếu dùng rm = DYN)
#   (2) Thực thi : lệnh cần test (dòng đánh dấu <== LỆNH CẦN TEST)
#   (3) Kiểm tra : so kết quả rồi so fflags với đáp án nhúng sẵn trong chương trình
#   Đáp án do Sail (mô hình tham chiếu của đặc tả RISC-V) tính ở lần build 1 và được nhúng vào
#   chương trình ở lần build 2 (-DRVTEST_SELFCHECK). Mọi beq đều nhảy -> testcase PASS.
#
#  fflags = NV(0x10) DZ(0x08) OF(0x04) UF(0x02) NX(0x01)
#    NV: không hợp lệ  DZ: chia cho 0  OF: tràn trên  UF: tràn dưới  NX: không chính xác
#  Chế độ làm tròn: RNE = gần nhất (hòa -> chẵn), RTZ = về 0, RDN = về -vô cực,
#                   RUP = về +vô cực, RMM = gần nhất (hòa -> xa 0)
#
#  Mỗi dòng lệnh:  <lệnh>   # <địa chỉ>: <mã máy> | <giải thích>
#  Xem dạng sóng một trường hợp (WSL):  python3 scripts/act4_case_wave.py {insn} <số trường hợp> --view
# =====================================================================================
"""
    out, summary, cases_json, bad = [head], [], [], 0
    names = OPERAND_NAMES.get(insn) or (["rs1", "rs2", "rs3"])
    for cid, title, purpose, items, curated_why in blocks:
        out.append("\n# " + "#" * 85)
        out.append(f"# TRƯỜNG HỢP {cid}: {title}")
        out.append("# " + "#" * 85)
        out.append("#")
        out.append("# Vị trí : " + " ; ".join(
            f"F-{insn}-{t['num']} testcase {t['tc']}/{t['total']}"
            + (f" ({t['mode_name'].upper()}{', rm=DYN qua frm' if t['how'] == 'dyn' else ''})" if t["mode_name"] else "")
            for t, _ in items))
        out.append("#")
        out.append("# LÝ DO TEST:")
        out += comment_block(purpose)
        first = items[0][0]
        ops = operands_and_mode(first)[0]
        out.append("#")
        out.append("# ĐẦU VÀO:")
        for i, v in enumerate(ops):
            nm = names[i] if i < len(names) else f"op{i + 1}"
            if insn in INT_SOURCE:
                out.append(f"#   {nm} = 0x{v:08X} = {fp.int_value(v, insn.endswith('wu'))}"
                           + (" (int32)" if insn == "fcvt.s.w" else " (uint32)" if insn == "fcvt.s.wu" else ""))
            else:
                out.append(f"#   {nm} = 0x{v:08X} = {describe(v)}")
        out.append("#")
        out.append("# KẾT QUẢ RA (đáp án Sail):")
        tj = []
        for t, _ in items:
            er, ef = t["exp"]
            r = t["model"]
            ok = r.bits == er and (ef is None or r.flags == ef)
            bad += not ok
            mode = (t["mode_name"] or "").upper()
            if insn in INT_RESULT:
                val = f"rd = 0x{er:08X} = {fp.int_value(er, insn == 'fcvt.wu.s')}"
            else:
                val = f"rd = 0x{er:08X} = {describe(er)}"
            out.append(f"#   {mode + ': ' if mode else ''}{val} ; fflags = {flags_text(ef)}"
                       + ("" if ok else "   !! MÔ HÌNH KHÁC SAIL"))
            summary.append((cid, t, er, ef, ok))
            om = operands_and_mode(t)
            tj.append(dict(file=f"F-{insn}-{t['num']}", tc=t["tc"], label=t["label"],
                           operands=[f"{v:08x}" for v in om[0]], rm=t["mode_name"], rm_how=t["how"],
                           result=f"{er:08x}", fflags=None if ef is None else f"{ef:02x}"))
        cases_json.append(dict(id=cid, title=title, testcases=tj))
        out.append("#")
        out.append("# VÌ SAO CÓ KẾT QUẢ NHƯ VẬY:")
        if curated_why:
            out += comment_block(curated_why)
        else:
            first_why = items[0][1]
            for k, (t, why) in enumerate(items):
                if len(items) > 1:
                    out.append(f"#   [{(t['mode_name'] or '').upper()}]")
                # same operands: after the first mode, keep only what differs (the choice, flags)
                lines = why if k == 0 else [l for l in why if l not in first_why]
                out += ["#   " + l for l in lines] or ["#   (như trên)"]
        for t, _ in items:
            out.append("")
            out.append(f"# ---- F-{insn}-{t['num']}  testcase {t['tc']}/{t['total']}"
                       + (f"  ({t['mode_name'].upper()})" if t["mode_name"] else "") + " " + "-" * 40)
            out += annotate(t, t["exp"])
    os.makedirs(out_dir, exist_ok=True)
    base = os.path.join(out_dir, f"{insn}_cases")
    with open(base + ".asm", "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    with open(base + ".json", "w", encoding="utf-8", newline="\n") as f:
        json.dump(dict(insn=insn, cases=cases_json), f, indent=1, ensure_ascii=False)
        f.write("\n")
    return base + ".asm", summary, bad


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("insns", nargs="*", default=["fadd.s"])
    ap.add_argument("--validate", action="store_true", help="compare the model with Sail on every testcase")
    ap.add_argument("--auto", action="store_true", help="fadd.s: automatic selection instead of the hand-picked cases")
    ap.add_argument("--disasm-dir", default=default_disasm_dir())
    ap.add_argument("--act-root", default=default_act_root())
    ap.add_argument("--out-dir", default=os.path.join(KLTN, "reports", "act4_cases"))
    a = ap.parse_args()
    insns = ALL if a.insns in (["all"], []) else a.insns
    for i in insns:
        if i not in ALL:
            sys.exit(f"Unknown instruction {i!r}; choose from: {' '.join(ALL)} or all")
    if not a.disasm_dir:
        sys.exit("No reports/act4_runs/* with *.disasm.txt; run ACT4 with --explain or pass --disasm-dir")
    if a.validate:
        return validate(insns, a.disasm_dir, a.act_root)
    if not a.act_root:
        sys.exit("ACT4 folder not found (needed for the .S sources and Sail .results); pass --act-root")
    bad_total = 0
    print(f"{'instruction':<11} {'cases':>5} {'testcases':>9}  file")
    for insn in insns:
        tests = load_insn(insn, a.disasm_dir, a.act_root)
        path, summary, bad = write_insn(insn, tests, a.out_dir, a.disasm_dir, a.act_root,
                                        curated=(insn == "fadd.s" and not a.auto))
        bad_total += bad
        n_cases = len({s[0] for s in summary})
        print(f"{insn:<11} {n_cases:>5} {len(summary):>9}  {os.path.relpath(path, KLTN)}"
              + (f"   {bad} MISMATCH" if bad else ""))
    print("model == Sail on every extracted testcase" if not bad_total else f"{bad_total} MISMATCH")
    return 1 if bad_total else 0


if __name__ == "__main__":
    sys.exit(main())
