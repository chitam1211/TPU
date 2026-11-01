"""Exact-integer binary32 multiply oracle for all five RISC-V rounding modes.

Tininess is detected after rounding: the exact product is rounded to 24 bits
with unbounded exponent range and compared with 2^-126.
"""
import argparse
import random
import struct
from pathlib import Path


def round_increment(rm, sign, q, rem, divisor):
    nx = bool(rem)
    return int((rm == 0 and (rem * 2 > divisor or (rem * 2 == divisor and q & 1))) or
               (rm == 2 and sign and nx) or (rm == 3 and not sign and nx) or
               (rm == 4 and rem * 2 >= divisor))


def reference(a, b, rm):
    if rm > 4:
        return 0, 0, 1
    sign = (a ^ b) >> 31
    ea, eb = (a >> 23) & 255, (b >> 23) & 255
    fa, fb = a & 0x7fffff, b & 0x7fffff
    na, nb = ea == 255 and fa != 0, eb == 255 and fb != 0
    ia, ib = ea == 255 and fa == 0, eb == 255 and fb == 0
    za, zb = ea == 0 and fa == 0, eb == 0 and fb == 0
    invalid = (na and not fa & 0x400000) or (nb and not fb & 0x400000)
    invalid |= (ia and zb) or (ib and za)
    if na or nb or invalid:
        return 0x7fc00000, 16 if invalid else 0, 0
    if ia or ib:
        return (sign << 31) | 0x7f800000, 0, 0
    if za or zb:
        return sign << 31, 0, 0

    sa = fa if ea == 0 else (1 << 23) | fa
    sb = fb if eb == 0 else (1 << 23) | fb
    product = sa * sb
    base_exponent = max(ea, 1) + max(eb, 1) - 300
    exact_exponent = product.bit_length() - 1 + base_exponent
    target_exponent = max(-126, exact_exponent)
    shift = target_exponent - 23 - base_exponent
    q, rem = divmod(product, 1 << shift) if shift > 0 else (product << -shift, 0)
    nx = bool(rem)
    divisor = 1 << shift if shift > 0 else 1
    tiny = exact_exponent < -126
    if exact_exponent == -127:
        shift_u = exact_exponent - 23 - base_exponent
        q_u, rem_u = divmod(product, 1 << shift_u) if shift_u > 0 else (product << -shift_u, 0)
        divisor_u = 1 << shift_u if shift_u > 0 else 1
        tiny = q_u + round_increment(rm, sign, q_u, rem_u, divisor_u) < 1 << 24
    q += round_increment(rm, sign, q, rem, divisor)
    if q >= 1 << 24:
        q >>= 1
        target_exponent += 1
    if target_exponent > 127:
        to_inf = rm in (0, 4) or (rm == 2 and sign) or (rm == 3 and not sign)
        return (sign << 31) | (0x7f800000 if to_inf else 0x7f7fffff), 5, 0
    exp_field = target_exponent + 127 if q >= 1 << 23 else 0
    bits = (sign << 31) | (exp_field << 23) | (q & 0x7fffff)
    return bits, int(nx) | (int(nx and tiny) << 1), 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=Path('sim/build/f16/mul.txt'))
    args = parser.parse_args()
    anchors = [
        (0x3fc00000, 0x40000000, 0, 0x40400000, 0),
        (0x80000000, 0x3f800000, 0, 0x80000000, 0),
        (0x7f800000, 0x00000000, 0, 0x7fc00000, 16),
        (0x7f7fffff, 0x40000000, 0, 0x7f800000, 5),
        (0x00800000, 0x3f000000, 0, 0x00400000, 0),
        # (1-2^-24)*2^-126 is exact at 24 bits, so it is tiny even though the
        # subnormal-precision tie rounds up to the smallest normal number.
        (0x00800000, 0x3f7fffff, 0, 0x00800000, 3),
        # (1-2^-46)*2^-126: RNE at 24 bits reaches 2^-126 (not tiny); RTZ does not.
        (0x00800001, 0x3f7ffffe, 0, 0x00800000, 1),
        (0x00800001, 0x3f7ffffe, 1, 0x007fffff, 3),
        (0x00800000, 0x3f7fffff, 1, 0x007fffff, 3),
        (0x00000001, 0x3f000000, 0, 0x00000000, 3),
        (0x00000001, 0x3f000000, 4, 0x00000001, 3),
    ]
    for a, b, rm, bits, flags in anchors:
        assert reference(a, b, rm) == (bits, flags, 0), (hex(a), hex(b), rm)
    edges = [0, 1, 2, 0x003fffff, 0x007fffff, 0x00800000, 0x00800001,
             0x3f000000, 0x3f7fffff, 0x3f800000, 0x3f800001, 0x40000000,
             0x7f000000, 0x7f7fffff, 0x7f800000, 0x7fc00000, 0x7fa00001]
    edges += [v | 0x80000000 for v in edges]
    cases = [(a, b, rm) for a in edges for b in edges for rm in range(5)]
    rng = random.Random(0x23521419)
    cases.extend((rng.getrandbits(32), rng.getrandbits(32), rng.randrange(5))
                 for _ in range(20000))
    cases.extend((a, b, rm) for a, b, rm, _, _ in anchors)
    cases.extend((0x3f800000, 0x3f800000, rm) for rm in (5, 6, 7))
    host_checks = 0
    for a, b, rm in cases:
        if rm or ((a >> 23) & 255) == 255 or ((b >> 23) & 255) == 255:
            continue
        av = struct.unpack('>f', a.to_bytes(4, 'big'))[0]
        bv = struct.unpack('>f', b.to_bytes(4, 'big'))[0]
        try:
            host_bits = int.from_bytes(struct.pack('>f', av * bv), 'big')
        except OverflowError:
            host_bits = ((a ^ b) & 0x80000000) | 0x7f800000
        assert reference(a, b, rm)[0] == host_bits, (hex(a), hex(b))
        host_checks += 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('w', encoding='ascii', newline='\n') as f:
        for a, b, rm in cases:
            bits, flags, illegal = reference(a, b, rm)
            f.write(f'{a:08x} {b:08x} {rm:x} {bits:08x} {flags:02x} {illegal:x}\n')
    print(f'Generated {len(cases)} vectors; {host_checks} host RNE cross-checks: {args.output}')


if __name__ == '__main__':
    main()
