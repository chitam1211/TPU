"""Exact-rational binary32 fused multiply-add oracle for all five RISC-V rounding modes.

Computes (-1)^np * a*b + (-1)^nc * c exactly as a Fraction and rounds once.
np/nc select FMADD (0,0), FMSUB (0,1), FNMSUB (1,0) and FNMADD (1,1).
"""
import argparse
import random
from pathlib import Path
from gen_fp32_divsqrt_vectors import Exact, QNAN, fields, round_pack, value
from gen_fp32_mul_vectors import reference as mul_reference
from gen_fp32_addsub_vectors import reference as addsub_reference


def reference(a, b, c, negate_product, negate_addend, rm):
    if rm > 4:
        return 0, 0, 1
    sa, ea, fa = fields(a)
    sb, eb, fb = fields(b)
    sc, ec, fc = fields(c)
    nan = [e == 255 and f != 0 for e, f in ((ea, fa), (eb, fb), (ec, fc))]
    snan = any(n and not f & 0x400000 for n, f in zip(nan, (fa, fb, fc)))
    inf_a, inf_b, inf_c = ea == 255 and not fa, eb == 255 and not fb, ec == 255 and not fc
    zero_a, zero_b, zero_c = not a & 0x7fffffff, not b & 0x7fffffff, not c & 0x7fffffff
    sign_p, sign_c = sa ^ sb ^ negate_product, sc ^ negate_addend
    # RISC-V requires NV for inf*0 even when the addend is a quiet NaN.
    inf_times_zero = (inf_a and zero_b) or (inf_b and zero_a)
    if any(nan) or inf_times_zero:
        return QNAN, 16 if snan or inf_times_zero else 0, 0
    if inf_a or inf_b:
        if inf_c and sign_c != sign_p:
            return QNAN, 16, 0
        return (sign_p << 31) | 0x7f800000, 0, 0
    if inf_c:
        return (sign_c << 31) | 0x7f800000, 0, 0
    total = (-1) ** sign_p * value(a) * value(b) + (-1) ** sign_c * value(c)
    if total == 0:
        if (zero_a or zero_b) and zero_c:
            sign = sign_p if sign_p == sign_c else int(rm == 2)
        else:
            sign = int(rm == 2)
        return sign << 31, 0, 0
    sign = int(total < 0)
    bits, flags = round_pack(sign, Exact(abs(total), False), rm)
    return bits, flags, 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=Path('sim/build/f26/fma.txt'))
    args = parser.parse_args()
    one, two, three, third = 0x3f800000, 0x40000000, 0x40400000, 0x3eaaaaab
    anchors = [
        # a, b, c, np, nc, rm, expected bits, expected flags
        (two, three, one, 0, 0, 0, 0x40e00000, 0),                # 2*3+1
        (two, three, one, 0, 1, 0, 0x40a00000, 0),                # 2*3-1
        (two, three, one, 1, 0, 0, 0xc0a00000, 0),                # -(2*3)+1
        (two, three, one, 1, 1, 0, 0xc0e00000, 0),                # -(2*3)-1
        (two, three, 0x40c00000, 0, 1, 0, 0x00000000, 0),         # exact cancellation
        (two, three, 0x40c00000, 0, 1, 2, 0x80000000, 0),         # ... is -0 in RDN
        (0x00000000, one, 0x80000000, 0, 0, 0, 0x00000000, 0),    # +0 + -0
        (0x80000000, one, 0x80000000, 0, 0, 0, 0x80000000, 0),    # -0 + -0
        (0x7f800000, 0x00000000, 0x7fc00000, 0, 0, 0, QNAN, 16),  # inf*0 + qNaN
        (0x7f800000, one, 0xff800000, 0, 0, 0, QNAN, 16),         # inf - inf
        (0x7f800000, one, 0xff800000, 0, 1, 0, 0x7f800000, 0),
        (one, one, 0x7fa00000, 0, 0, 0, QNAN, 16),                # sNaN addend
        (0x7f7fffff, two, 0x00000000, 0, 0, 0, 0x7f800000, 5),    # overflow
        (0x7f7fffff, two, 0x00000000, 0, 0, 1, 0x7f7fffff, 5),
        # Single rounding: 1/3*3 - 1 keeps the product's tail (not 0 as with two roundings).
        (third, three, one, 0, 1, 0, 0x33000000, 0),
        (0x00800000, 0x3f000000, 0x00000000, 0, 0, 0, 0x00400000, 0),
        (0x00800000, 0x3f7fffff, 0x00000000, 0, 0, 0, 0x00800000, 3),
    ]
    for a, b, c, np_, nc, rm, bits, flags in anchors:
        got = reference(a, b, c, np_, nc, rm)
        assert got == (bits, flags, 0), (hex(a), hex(b), hex(c), np_, nc, rm, got)
    edges = [0, 1, 0x007fffff, 0x00800000, 0x3f000000, 0x3f800000, 0x3f800001,
             0x40400000, 0x7f7fffff, 0x7f800000, 0x7fc00000, 0x7fa00001]
    edges += [v | 0x80000000 for v in edges]
    cases = [(a, b, c, rng_ops >> 1, rng_ops & 1, rm)
             for a in edges for b in edges for c in edges[::3]
             for rng_ops, rm in ((0, 0), (1, 2), (2, 3), (3, 1))]
    rng = random.Random(0x23521426)
    for _ in range(16000):
        cases.append((rng.getrandbits(32), rng.getrandbits(32), rng.getrandbits(32),
                      rng.getrandbits(1), rng.getrandbits(1), rng.randrange(5)))
    for _ in range(8000):
        # Near-cancellation: c is close to -(a*b), exercising massive normalization.
        a = rng.randrange(0x3e000000, 0x41000000)
        b = rng.randrange(0x3e000000, 0x41000000)
        p = mul_reference(a, b, 1)[0]
        c = (p ^ 0x80000000) + rng.randrange(-3, 4)
        cases.append((a, b, c & 0xffffffff, 0, 0, rng.randrange(5)))
    for _ in range(4000):
        # Wide exponent gaps and subnormal results.
        a = rng.randrange(1, 0x02000000) | (rng.getrandbits(1) << 31)
        b = rng.randrange(0x30000000, 0x50000000)
        c = rng.randrange(1, 0x7f000000) | (rng.getrandbits(1) << 31)
        cases.append((a, b, c, rng.getrandbits(1), rng.getrandbits(1), rng.randrange(5)))
    cases.extend((a, b, c, np_, nc, rm) for a, b, c, np_, nc, rm, _, _ in anchors)
    cases.extend((one, two, three, 0, 0, rm) for rm in (5, 6, 7))
    # Independent check: when a*b is exact in binary32, FMA equals add(mul(a,b), c).
    cross_checks = 0
    for a, b, c, np_, nc, rm in cases:
        if rm > 4 or any((x >> 23) & 255 == 255 for x in (a, b, c)):
            continue
        product, mul_flags, _ = mul_reference(a, b, rm)
        if mul_flags or not product & 0x7fffffff:
            continue
        expected = addsub_reference(product ^ (np_ << 31), c ^ (nc << 31), 0, rm)
        assert reference(a, b, c, np_, nc, rm) == expected, (hex(a), hex(b), hex(c), np_, nc, rm)
        cross_checks += 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('w', encoding='ascii', newline='\n') as f:
        for a, b, c, np_, nc, rm in cases:
            bits, flags, illegal = reference(a, b, c, np_, nc, rm)
            f.write(f'{a:08x} {b:08x} {c:08x} {np_:x} {nc:x} {rm:x} {bits:08x} {flags:02x} {illegal:x}\n')
    print(f'Generated {len(cases)} vectors; {cross_checks} exact-product add cross-checks: {args.output}')


if __name__ == '__main__':
    main()
