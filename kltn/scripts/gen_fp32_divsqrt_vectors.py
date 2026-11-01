"""Exact-rational binary32 divide/square-root oracle for all five RISC-V rounding modes.

Division is evaluated as an exact Fraction. Square root is evaluated through its
exact square, so every rounding decision is an exact rational comparison.
Tininess is detected after rounding (RISC-V), i.e. with unbounded exponent range.
"""
import argparse
import math
import random
import struct
from fractions import Fraction
from pathlib import Path

QNAN = 0x7fc00000


def fields(x):
    e, f = (x >> 23) & 255, x & 0x7fffff
    return x >> 31, e, f


def value(x):
    _, e, f = fields(x)
    return Fraction(f if e == 0 else (1 << 23) | f) * Fraction(2) ** (max(e, 1) - 150)


def floor_log2(v):
    e = v.numerator.bit_length() - v.denominator.bit_length()
    while Fraction(2) ** e > v:
        e -= 1
    while Fraction(2) ** (e + 1) <= v:
        e += 1
    return e


class Exact:
    """A positive real V, given either as V (division) or as V*V (square root)."""

    def __init__(self, v, squared):
        self.v, self.squared = v, squared

    def floor_log2(self):
        return floor_log2(self.v) >> 1 if self.squared else floor_log2(self.v)

    def scaled(self, k):
        # Returns floor(V*2^k) and the rounding class of the discarded part.
        s = self.v * Fraction(4 if self.squared else 2) ** k
        q = math.isqrt(s.numerator // s.denominator) if self.squared else s.numerator // s.denominator
        exact = s == (q * q if self.squared else q)
        twice_frac = 4 * s - (2 * q + 1) ** 2 if self.squared else 2 * s - (2 * q + 1)
        half = 0 if exact else (1 if twice_frac > 0 else (0.5 if twice_frac == 0 else -1))
        return q, exact, half


def increment(rm, sign, q, exact, half):
    if exact:
        return 0
    return int((rm == 0 and (half == 1 or (half == 0.5 and q & 1))) or
               (rm == 2 and sign) or (rm == 3 and not sign) or
               (rm == 4 and half >= 0.5))


def round_pack(sign, exact_value, rm):
    e = exact_value.floor_log2()
    target = max(e, -126)
    q, exact, half = exact_value.scaled(23 - target)
    q += increment(rm, sign, q, exact, half)
    if q == 1 << 24:
        q, target = 1 << 23, target + 1
    if target > 127:
        to_inf = rm in (0, 4) or (rm == 2 and sign) or (rm == 3 and not sign)
        return (sign << 31) | (0x7f800000 if to_inf else 0x7f7fffff), 5
    tiny = False
    if e < -126:
        qu, exact_u, half_u = exact_value.scaled(23 - e)
        tiny = qu + increment(rm, sign, qu, exact_u, half_u) < 1 << 24 or e < -127
    exp_field = target + 127 if q >= 1 << 23 else 0
    nx = int(not exact)
    return (sign << 31) | (exp_field << 23) | (q & 0x7fffff), nx | (int(tiny and nx) << 1)


def reference(a, b, is_sqrt, rm):
    if rm > 4:
        return 0, 0, 1
    sa, ea, fa = fields(a)
    sb, eb, fb = fields(b)
    na, nb = ea == 255 and fa != 0, eb == 255 and fb != 0
    ia, ib = ea == 255 and fa == 0, eb == 255 and fb == 0
    za, zb = ea == 0 and fa == 0, eb == 0 and fb == 0
    snan_a, snan_b = na and not fa & 0x400000, nb and not fb & 0x400000
    if is_sqrt:
        if na:
            return QNAN, 16 if snan_a else 0, 0
        if za:
            return a, 0, 0
        if sa:
            return QNAN, 16, 0
        if ia:
            return 0x7f800000, 0, 0
        bits, flags = round_pack(0, Exact(value(a), True), rm)
        return bits, flags, 0
    sign = sa ^ sb
    if na or nb:
        return QNAN, 16 if snan_a or snan_b else 0, 0
    if (ia and ib) or (za and zb):
        return QNAN, 16, 0
    if ia:
        return (sign << 31) | 0x7f800000, 0, 0
    if zb:
        return (sign << 31) | 0x7f800000, 8, 0
    if ib or za:
        return sign << 31, 0, 0
    bits, flags = round_pack(sign, Exact(value(a) / value(b), False), rm)
    return bits, flags, 0


def host_bits(av, is_sqrt, bv):
    # Binary64 has >= 2*24+2 bits, so double rounding is innocuous for / and sqrt.
    try:
        return int.from_bytes(struct.pack('>f', math.sqrt(av) if is_sqrt else av / bv), 'big')
    except OverflowError:
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=Path('sim/build/f22/divsqrt.txt'))
    args = parser.parse_args()
    anchors = [
        # a, b, sqrt, rm, expected bits, expected flags
        (0x40400000, 0x40000000, 0, 0, 0x3fc00000, 0),   # 3/2
        (0x3f800000, 0x40400000, 0, 0, 0x3eaaaaab, 1),   # 1/3 RNE
        (0x3f800000, 0x40400000, 0, 1, 0x3eaaaaaa, 1),   # 1/3 RTZ
        (0x3f800000, 0x00000000, 0, 0, 0x7f800000, 8),   # DZ
        (0x00000000, 0x00000000, 0, 0, QNAN, 16),
        (0x7f800000, 0x7f800000, 0, 0, QNAN, 16),
        (0x7f7fffff, 0x3f000000, 0, 0, 0x7f800000, 5),   # overflow
        (0x7f7fffff, 0x3f000000, 0, 1, 0x7f7fffff, 5),
        (0x00800000, 0x40000000, 0, 0, 0x00400000, 0),   # exact subnormal
        (0x00000001, 0x40000000, 0, 0, 0x00000000, 3),   # tie to even zero
        (0x00000001, 0x40000000, 0, 4, 0x00000001, 3),
        # (1-2^-24)*2^-126 is representable at 24 bits: tiny, rounds up to normal.
        (0x3f7fffff, 0x7e800000, 0, 0, 0x00800000, 3),
        (0x40800000, 0, 1, 0, 0x40000000, 0),            # sqrt(4)
        (0x40000000, 0, 1, 0, 0x3fb504f3, 1),            # sqrt(2)
        (0x40000000, 0, 1, 3, 0x3fb504f4, 1),
        (0x80000000, 0, 1, 0, 0x80000000, 0),            # sqrt(-0)
        (0xbf800000, 0, 1, 0, QNAN, 16),
        (0x00000001, 0, 1, 0, 0x1a3504f3, 1),            # sqrt(min subnormal)
        (0x7f800000, 0, 1, 0, 0x7f800000, 0),
        (0xff800000, 0, 1, 0, QNAN, 16),
        (0x7fa00000, 0, 1, 0, QNAN, 16),
    ]
    for a, b, is_sqrt, rm, bits, flags in anchors:
        assert reference(a, b, is_sqrt, rm) == (bits, flags, 0), (hex(a), hex(b), is_sqrt, rm,
                                                                  reference(a, b, is_sqrt, rm))
    edges = [0, 1, 2, 3, 0x003fffff, 0x00400000, 0x007fffff, 0x00800000, 0x00800001,
             0x3f000000, 0x3f7fffff, 0x3f800000, 0x3f800001, 0x3fc00000, 0x40000000,
             0x40400000, 0x7e800000, 0x7f000000, 0x7f7fffff, 0x7f800000, 0x7fc00000,
             0x7fa00001]
    edges += [v | 0x80000000 for v in edges]
    cases = [(a, b, 0, rm) for a in edges for b in edges for rm in range(5)]
    cases += [(a, 0, 1, rm) for a in edges for rm in range(5)]
    rng = random.Random(0x23521422)
    for _ in range(12000):
        cases.append((rng.getrandbits(32), rng.getrandbits(32), 0, rng.randrange(5)))
    for _ in range(4000):
        cases.append((rng.getrandbits(31), 0, 1, rng.randrange(5)))
    for _ in range(2000):
        # Quotients near the subnormal boundary and exact-square roots.
        a = rng.randrange(1, 0x01000000)
        b = rng.randrange(0x3f000000, 0x42000000)
        cases.append((a, b, 0, rng.randrange(5)))
        root = rng.randrange(1 << 11, 1 << 12)
        cases.append((int.from_bytes(struct.pack('>f', float(root * root)), 'big'), 0, 1, rng.randrange(5)))
    cases.extend((a, b, s, rm) for a, b, s, rm, _, _ in anchors)
    cases.extend((0x3f800000, 0x40000000, s, rm) for s in (0, 1) for rm in (5, 6, 7))
    host_checks = 0
    for a, b, is_sqrt, rm in cases:
        if rm or (a >> 23) & 255 == 255 or (not is_sqrt and (b >> 23) & 255 == 255):
            continue
        av = struct.unpack('>f', a.to_bytes(4, 'big'))[0]
        bv = struct.unpack('>f', b.to_bytes(4, 'big'))[0]
        if (is_sqrt and av < 0) or (not is_sqrt and bv == 0):
            continue
        expected = host_bits(av, is_sqrt, bv)
        got = reference(a, b, is_sqrt, rm)[0]
        assert expected == got or (expected is None and got & 0x7fffffff == 0x7f800000), \
            (hex(a), hex(b), is_sqrt, hex(got), expected)
        host_checks += 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('w', encoding='ascii', newline='\n') as f:
        for a, b, is_sqrt, rm in cases:
            bits, flags, illegal = reference(a, b, is_sqrt, rm)
            f.write(f'{a:08x} {b:08x} {is_sqrt:x} {rm:x} {bits:08x} {flags:02x} {illegal:x}\n')
    print(f'Generated {len(cases)} vectors; {host_checks} host RNE cross-checks: {args.output}')


if __name__ == '__main__':
    main()
