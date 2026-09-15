"""Exact bigint oracle: every finite binary32 is an integer times 2**-149.

No RTL alignment/GRS algorithm, floating-point library, or third-party FPU IP.
Deterministic seed; output is consumable by Icarus on Windows and WSL.
"""
import argparse
from pathlib import Path
import random
import struct


def reference(a, b, sub, rm):
    if rm > 4:
        return 0, 0, 1
    sa, sb = a >> 31, (b >> 31) ^ sub
    ea, eb = (a >> 23) & 255, (b >> 23) & 255
    fa, fb = a & 0x7fffff, b & 0x7fffff
    na, nb = ea == 255 and fa != 0, eb == 255 and fb != 0
    ia, ib = ea == 255 and fa == 0, eb == 255 and fb == 0
    invalid = (na and not (fa & 0x400000)) or (nb and not (fb & 0x400000))
    invalid |= ia and ib and sa != sb
    if na or nb or invalid:
        return 0x7fc00000, 16 if invalid else 0, 0
    if ia or ib:
        return ((sa if ia else sb) << 31) | 0x7f800000, 0, 0

    def units(e, f):
        return f if e == 0 else ((1 << 23) | f) << (e - 1)

    exact = (-1 if sa else 1) * units(ea, fa) + (-1 if sb else 1) * units(eb, fb)
    if exact == 0:
        sign = sa if sa == sb else int(rm == 2)
        return sign << 31, 0, 0
    sign = int(exact < 0)
    mag = abs(exact)
    shift = max(0, mag.bit_length() - 24)
    q, remainder = divmod(mag, 1 << shift)
    nx = int(remainder != 0)
    twice = remainder * 2
    denominator = 1 << shift
    up = ((rm == 0 and (twice > denominator or (twice == denominator and q & 1))) or
          (rm == 2 and sign and nx) or (rm == 3 and not sign and nx) or
          (rm == 4 and twice >= denominator))
    q += int(up)
    if q >= (1 << 24):
        q >>= 1
        shift += 1
    exponent = shift + 1 if q >= (1 << 23) else 0
    if exponent >= 255:
        infinity = rm in (0, 4) or (rm == 2 and sign) or (rm == 3 and not sign)
        return (sign << 31) | (0x7f800000 if infinity else 0x7f7fffff), 5, 0
    return (sign << 31) | (exponent << 23) | (q & 0x7fffff), nx, 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[1] / 'sim/build/fp32_addsub_vectors.txt')
    args = parser.parse_args()
    # Hand-derived anchors guard the oracle, including ties and canonical NaNs.
    anchors = [
        (0x3f800000, 0x40000000, 0, 0, 0x40400000, 0),
        (0x3f800000, 0x33800000, 0, 0, 0x3f800000, 1),
        (0x3f800000, 0x33800000, 0, 4, 0x3f800001, 1),
        (0x3f800000, 0x3f800000, 1, 2, 0x80000000, 0),
        (0x00800000, 0x007fffff, 1, 0, 1, 0),
        (0x7f7fffff, 0x7f7fffff, 0, 1, 0x7f7fffff, 5),
        (0x7f800000, 0xff800000, 0, 0, 0x7fc00000, 16),
        (0x7fc12345, 0, 0, 0, 0x7fc00000, 0),
    ]
    for a, b, sub, rm, result, flags in anchors:
        assert reference(a, b, sub, rm) == (result, flags, 0)
    edges = [0, 1, 2, 0x003fffff, 0x007fffff, 0x00800000, 0x00800001,
             0x33800000, 0x33000000, 0x3f000000, 0x3f7fffff, 0x3f800000,
             0x3f800001, 0x40000000, 0x4b800000, 0x7f000000, 0x7f7fffff,
             0x7f800000, 0x7fc00000, 0x7fa00001]
    edges += [x | 0x80000000 for x in edges]
    cases = [(a, b, s, r) for a in edges for b in edges for s in range(2) for r in range(5)]
    rng = random.Random(0x23521419)
    for _ in range(20000):
        a, b = rng.getrandbits(32), rng.getrandbits(32)
        cases.append((a, b, rng.randrange(2), rng.randrange(5)))
    # Near cancellation / exponent boundaries across the entire finite range.
    for e in range(1, 255):
        for r in range(5):
            a = (e << 23) | rng.randrange(1 << 23)
            cases.extend([(a, a - 1, 1, r), (a, a ^ 0x80000000, 0, r),
                          (e << 23, (e << 23) - 1, 1, r)])
    cases += [(0x3f800000, 0x40000000, 0, r) for r in (5, 6, 7)]
    # Additional independent host binary64 -> binary32 RNE sanity check.
    # Exclude nonfinite inputs; Python float is not the directed-rounding oracle.
    host_checks = 0
    for a, b, sub, rm in cases:
        if rm != 0 or ((a >> 23) & 255) == 255 or ((b >> 23) & 255) == 255:
            continue
        av = struct.unpack('>f', a.to_bytes(4, 'big'))[0]
        bv = struct.unpack('>f', b.to_bytes(4, 'big'))[0]
        value = av - bv if sub else av + bv
        try:
            bits = int.from_bytes(struct.pack('>f', value), 'big')
        except OverflowError:
            bits = 0xff800000 if value < 0 else 0x7f800000
        assert reference(a, b, sub, rm)[0] == bits, (hex(a), hex(b), sub)
        host_checks += 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('w', encoding='ascii', newline='\n') as f:
        for a, b, sub, rm in cases:
            result, flags, illegal = reference(a, b, sub, rm)
            f.write(f'{a:08x} {b:08x} {sub:x} {rm:x} {result:08x} {flags:02x} {illegal:x}\n')
    print(f'Generated {len(cases)} exact vectors; {host_checks} host RNE cross-checks: {args.output}')


if __name__ == '__main__':
    main()
