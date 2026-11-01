"""Exact reference model of the RV32F operations (IEEE 754 binary32 + RISC-V rules).

Values are computed exactly with fractions and rounded once, so every result also
carries the facts needed to explain it (exact value, neighbours, tie, tininess).
Used by act4_explain_cases.py to classify ACT4 testcases and to word the explanations;
its results are compared with Sail's expected values there.
"""
from dataclasses import dataclass, field
from fractions import Fraction
from math import isqrt

RNE, RTZ, RDN, RUP, RMM = range(5)
RM_NAMES = ["rne", "rtz", "rdn", "rup", "rmm"]
NV, DZ, OF, UF, NX = 0x10, 0x08, 0x04, 0x02, 0x01
CANON = 0x7FC00000
MAX_BITS = 0x7F7FFFFF
MAXF = Fraction((2 ** 24 - 1) * 2 ** 104)       # (2 - 2^-23) * 2^127
MIN_NORMAL = Fraction(1, 2 ** 126)
MIN_SUB = Fraction(1, 2 ** 149)
SIGN = 0x80000000


def sign_of(x): return x >> 31
def exp_of(x): return (x >> 23) & 0xFF
def man_of(x): return x & 0x7FFFFF
def is_nan(x): return exp_of(x) == 0xFF and man_of(x) != 0
def is_snan(x): return is_nan(x) and not (x & 0x400000)
def is_qnan(x): return is_nan(x) and bool(x & 0x400000)
def is_inf(x): return exp_of(x) == 0xFF and man_of(x) == 0
def is_zero(x): return (x & 0x7FFFFFFF) == 0
def is_sub(x): return exp_of(x) == 0 and man_of(x) != 0


def kind(x):
    """zero / subnormal / normal / inf / qnan / snan."""
    if is_snan(x): return "snan"
    if is_qnan(x): return "qnan"
    if is_inf(x): return "inf"
    if is_zero(x): return "zero"
    return "subnormal" if is_sub(x) else "normal"


def value(x):
    """Exact value of a finite float32 as a Fraction (signed)."""
    e, m = exp_of(x), man_of(x)
    v = m * MIN_SUB if e == 0 else (Fraction(2 ** 23 + m, 2 ** 23) * Fraction(2) ** (e - 127))
    return -v if sign_of(x) else v


def floor_log2(f):
    """Largest e with 2^e <= f (f > 0)."""
    e = f.numerator.bit_length() - f.denominator.bit_length()
    while Fraction(2) ** e > f: e -= 1
    while Fraction(2) ** (e + 1) <= f: e += 1
    return e


def encode(sign, mag):
    """Bits of an exactly representable magnitude."""
    if mag == 0:
        return sign << 31
    if mag < MIN_NORMAL:
        m = mag / MIN_SUB
        assert m.denominator == 1
        return (sign << 31) | int(m)
    e = floor_log2(mag)
    frac = (mag / Fraction(2) ** e - 1) * 2 ** 23
    assert frac.denominator == 1 and e + 127 < 255
    return (sign << 31) | ((e + 127) << 23) | int(frac)


def round_int(x, mode, sign):
    """Round a non-negative Fraction to an integer. Returns (n, inexact, tie)."""
    n = x.numerator // x.denominator
    r = x - n
    if r == 0:
        return n, False, False
    half = Fraction(1, 2)
    up = {RNE: r > half or (r == half and n % 2 == 1),
          RMM: r >= half,
          RTZ: False,
          RDN: sign == 1,
          RUP: sign == 0}[mode]
    return n + up, True, r == half


@dataclass
class Result:
    bits: int                  # result register value (float bits or integer)
    flags: int = 0
    rule: str = ""             # special-case rule applied ("" = computed and rounded)
    exact: Fraction = None     # exact mathematical value before rounding (signed)
    inexact: bool = False
    tie: bool = False
    tiny: bool = False
    lo: int = None             # neighbours of an inexact result (bits)
    hi: int = None
    frac_pos: Fraction = None  # position of the exact value between lo and hi (0..1)
    overflow: bool = False
    notes: list = field(default_factory=list)


def round_float(v, mode):
    """Round an exact non-zero value (signed Fraction) to binary32."""
    sign = 1 if v < 0 else 0
    mag = -v if sign else v

    def rnd(bounded):
        e = floor_log2(mag)
        qe = -149 if bounded and e < -126 else e - 23
        q = Fraction(2) ** qe
        n, inex, tie = round_int(mag / q, mode, sign)
        lo = (mag / q).numerator // (mag / q).denominator
        return n * q, inex, tie, q, lo

    r, inex, tie, q, lo_n = rnd(True)
    r_unb = rnd(False)[0]
    res = Result(0, exact=v, inexact=inex, tie=tie)
    if inex:
        lo, hi = lo_n * q, (lo_n + 1) * q
        res.frac_pos = (mag - lo) / q
        res.lo = encode(sign, lo) if lo <= MAXF else None
        res.hi = encode(sign, hi) if hi <= MAXF else None
    if r_unb > MAXF:
        res.overflow = True
        res.flags = OF | NX
        to_inf = mode in (RNE, RMM) or (mode == RUP and sign == 0) or (mode == RDN and sign == 1)
        res.bits = (sign << 31) | (0x7F800000 if to_inf else MAX_BITS)
        res.inexact = True
        return res
    res.tiny = r_unb < MIN_NORMAL
    res.flags = (NX if inex else 0) | (UF if res.tiny and inex else 0)
    res.bits = encode(sign, r)
    return res


def nan_result(*ops, invalid=False, rule="nan"):
    nv = invalid or any(is_snan(o) for o in ops)
    return Result(CANON, NV if nv else 0, rule=rule)


def zero_sum(mode, a_zero_sign=None, b_zero_sign=None):
    """Sign of an exact zero sum: same-signed zeros keep it, otherwise +0 (-0 in RDN)."""
    if a_zero_sign is not None and a_zero_sign == b_zero_sign:
        return a_zero_sign << 31
    return SIGN if mode == RDN else 0


def fadd(a, b, mode, sub=False):
    if is_nan(a) or is_nan(b):
        return nan_result(a, b, rule="nan")
    b2 = b ^ SIGN if sub else b
    if is_inf(a) and is_inf(b2):
        if sign_of(a) != sign_of(b2):
            return Result(CANON, NV, rule="inf_minus_inf")
        return Result(a, rule="inf")
    if is_inf(a): return Result(a, rule="inf")
    if is_inf(b2): return Result(b2, rule="inf")
    s = value(a) + value(b2)
    if s == 0:
        same = sign_of(a) if is_zero(a) and is_zero(b2) else None
        other = sign_of(b2) if is_zero(a) and is_zero(b2) else None
        return Result(zero_sum(mode, same, other), rule="zero_sum", exact=Fraction(0))
    return round_float(s, mode)


def fmul(a, b, mode):
    if is_nan(a) or is_nan(b):
        return nan_result(a, b)
    s = sign_of(a) ^ sign_of(b)
    if (is_inf(a) and is_zero(b)) or (is_zero(a) and is_inf(b)):
        return Result(CANON, NV, rule="inf_times_zero")
    if is_inf(a) or is_inf(b):
        return Result((s << 31) | 0x7F800000, rule="inf")
    if is_zero(a) or is_zero(b):
        return Result(s << 31, rule="zero_operand", exact=Fraction(0))
    return round_float(value(a) * value(b), mode)


def fdiv(a, b, mode):
    if is_nan(a) or is_nan(b):
        return nan_result(a, b)
    s = sign_of(a) ^ sign_of(b)
    if is_inf(a) and is_inf(b):
        return Result(CANON, NV, rule="inf_div_inf")
    if is_zero(a) and is_zero(b):
        return Result(CANON, NV, rule="zero_div_zero")
    if is_inf(a):
        return Result((s << 31) | 0x7F800000, rule="inf")
    if is_inf(b):
        return Result(s << 31, rule="div_by_inf", exact=Fraction(0))
    if is_zero(b):
        return Result((s << 31) | 0x7F800000, DZ, rule="div_by_zero")
    if is_zero(a):
        return Result(s << 31, rule="zero_operand", exact=Fraction(0))
    return round_float(value(a) / value(b), mode)


def fsqrt(a, mode):
    if is_nan(a):
        return nan_result(a)
    if is_zero(a):
        return Result(a, rule="sqrt_zero", exact=Fraction(0))
    if sign_of(a):
        return Result(CANON, NV, rule="sqrt_negative")
    if is_inf(a):
        return Result(a, rule="inf")
    v = value(a)
    k = 200                                       # 2^-200 precision: far below any ulp
    scaled = v * Fraction(2) ** (2 * k)
    assert scaled.denominator == 1
    s = isqrt(int(scaled))
    exact = s * s == scaled
    approx = Fraction(s, 2 ** k) + (0 if exact else Fraction(1, 2 ** (k + 1)))
    res = round_float(approx, mode)
    res.exact = approx if exact else None         # irrational: no exact Fraction
    res.notes.append("sqrt_exact" if exact else "sqrt_irrational")
    return res


def fma(a, b, c, mode, neg_prod=False, neg_c=False):
    if (is_inf(a) and is_zero(b)) or (is_zero(a) and is_inf(b)):
        return Result(CANON, NV, rule="inf_times_zero")
    if is_nan(a) or is_nan(b) or is_nan(c):
        return nan_result(a, b, c)
    ps = sign_of(a) ^ sign_of(b) ^ int(neg_prod)
    cs = sign_of(c) ^ int(neg_c)
    c2 = (c & 0x7FFFFFFF) | (cs << 31)
    if is_inf(a) or is_inf(b):
        if is_inf(c) and cs != ps:
            return Result(CANON, NV, rule="inf_minus_inf")
        return Result((ps << 31) | 0x7F800000, rule="inf")
    if is_inf(c):
        return Result(c2, rule="inf")
    p = value(a) * value(b) * (-1 if neg_prod else 1)
    s = p + value(c2)
    if s == 0:
        prod_zero = is_zero(a) or is_zero(b)
        if prod_zero and is_zero(c):
            return Result(zero_sum(mode, ps, cs), rule="zero_sum", exact=Fraction(0))
        return Result(zero_sum(mode), rule="zero_sum", exact=Fraction(0))
    return round_float(s, mode)


def fminmax(a, b, is_max):
    flags = NV if (is_snan(a) or is_snan(b)) else 0
    if is_nan(a) and is_nan(b):
        return Result(CANON, flags, rule="both_nan")
    if is_nan(a): return Result(b, flags, rule="one_nan")
    if is_nan(b): return Result(a, flags, rule="one_nan")
    if is_zero(a) and is_zero(b):
        pick = (a if sign_of(a) == 0 else b) if is_max else (a if sign_of(a) else b)
        return Result(pick, rule="zeros")
    va = float("inf") if is_inf(a) and not sign_of(a) else float("-inf") if is_inf(a) else value(a)
    vb = float("inf") if is_inf(b) and not sign_of(b) else float("-inf") if is_inf(b) else value(b)
    if va == vb: return Result(a, rule="equal")
    return Result(a if (va > vb) == is_max else b, rule="compare")


def fcmp(a, b, op):
    if is_nan(a) or is_nan(b):
        nv = (is_snan(a) or is_snan(b)) if op == "feq" else True
        return Result(0, NV if nv else 0, rule="cmp_nan")
    def key(x):
        if is_inf(x): return float("-inf") if sign_of(x) else float("inf")
        return value(x)
    ka, kb = key(a), key(b)
    r = {"feq": ka == kb, "flt": ka < kb, "fle": ka <= kb}[op]
    return Result(int(r), rule="cmp_zero" if is_zero(a) and is_zero(b) else "cmp")


CLASS_BITS = ["-vô cực", "số âm thường", "subnormal âm", "-0", "+0",
              "subnormal dương", "số dương thường", "+vô cực", "sNaN", "qNaN"]


def fclass(a):
    k, s = kind(a), sign_of(a)
    idx = {"snan": 8, "qnan": 9}.get(k)
    if idx is None:
        idx = {("inf", 1): 0, ("normal", 1): 1, ("subnormal", 1): 2, ("zero", 1): 3,
               ("zero", 0): 4, ("subnormal", 0): 5, ("normal", 0): 6, ("inf", 0): 7}[(k, s)]
    return Result(1 << idx, rule="class")


def fsgnj(a, b, variant):
    s = {"fsgnj": sign_of(b), "fsgnjn": sign_of(b) ^ 1, "fsgnjx": sign_of(a) ^ sign_of(b)}[variant]
    return Result((a & 0x7FFFFFFF) | (s << 31), rule="sign_inject")


def fcvt_w(a, mode, unsigned):
    hi, lo = (0xFFFFFFFF, 0) if unsigned else (2 ** 31 - 1, -2 ** 31)
    if is_nan(a):
        return Result(hi & 0xFFFFFFFF, NV, rule="cvt_nan")
    if is_inf(a):
        return Result((lo if sign_of(a) else hi) & 0xFFFFFFFF, NV, rule="cvt_inf")
    v = value(a)
    s = 1 if v < 0 else 0
    n, inex, tie = round_int(-v if s else v, mode, s)
    n = -n if s else n
    res = Result(0, exact=v, inexact=inex, tie=tie)
    if n < lo or n > hi:
        res.bits, res.flags, res.rule = (lo if v < 0 else hi) & 0xFFFFFFFF, NV, "cvt_range"
        res.inexact = False
        return res
    res.bits, res.flags = n & 0xFFFFFFFF, NX if inex else 0
    res.notes.append(f"int={n}")
    return res


def fcvt_s_w(x, mode, unsigned):
    v = x if unsigned else (x - 2 ** 32 if x & SIGN else x)
    if v == 0:
        return Result(0, rule="cvt_zero", exact=Fraction(0))
    return round_float(Fraction(v), mode)


def int_value(x, unsigned):
    return x if unsigned else (x - 2 ** 32 if x & SIGN else x)


OPS = {
    "fadd.s": lambda o, m: fadd(o[0], o[1], m),
    "fsub.s": lambda o, m: fadd(o[0], o[1], m, sub=True),
    "fmul.s": lambda o, m: fmul(o[0], o[1], m),
    "fdiv.s": lambda o, m: fdiv(o[0], o[1], m),
    "fsqrt.s": lambda o, m: fsqrt(o[0], m),
    "fmadd.s": lambda o, m: fma(o[0], o[1], o[2], m),
    "fmsub.s": lambda o, m: fma(o[0], o[1], o[2], m, neg_c=True),
    "fnmsub.s": lambda o, m: fma(o[0], o[1], o[2], m, neg_prod=True),
    "fnmadd.s": lambda o, m: fma(o[0], o[1], o[2], m, neg_prod=True, neg_c=True),
    "fmin.s": lambda o, m: fminmax(o[0], o[1], False),
    "fmax.s": lambda o, m: fminmax(o[0], o[1], True),
    "feq.s": lambda o, m: fcmp(o[0], o[1], "feq"),
    "flt.s": lambda o, m: fcmp(o[0], o[1], "flt"),
    "fle.s": lambda o, m: fcmp(o[0], o[1], "fle"),
    "fsgnj.s": lambda o, m: fsgnj(o[0], o[1], "fsgnj"),
    "fsgnjn.s": lambda o, m: fsgnj(o[0], o[1], "fsgnjn"),
    "fsgnjx.s": lambda o, m: fsgnj(o[0], o[1], "fsgnjx"),
    "fclass.s": lambda o, m: fclass(o[0]),
    "fcvt.w.s": lambda o, m: fcvt_w(o[0], m, False),
    "fcvt.wu.s": lambda o, m: fcvt_w(o[0], m, True),
    "fcvt.s.w": lambda o, m: fcvt_s_w(o[0], m, False),
    "fcvt.s.wu": lambda o, m: fcvt_s_w(o[0], m, True),
    "fmv.x.w": lambda o, m: Result(o[0], rule="move"),
    "fmv.w.x": lambda o, m: Result(o[0], rule="move"),
    "flw": lambda o, m: Result(o[0], rule="move"),
    "fsw": lambda o, m: Result(o[0], rule="move"),
}
ROUNDED = {"fadd.s", "fsub.s", "fmul.s", "fdiv.s", "fsqrt.s", "fmadd.s", "fmsub.s",
           "fnmsub.s", "fnmadd.s", "fcvt.w.s", "fcvt.wu.s", "fcvt.s.w", "fcvt.s.wu"}


def execute(insn, operands, mode=RNE):
    return OPS[insn](operands, mode)
