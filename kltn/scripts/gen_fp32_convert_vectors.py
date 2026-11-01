"""Exact-rational oracle for RV32F FCVT.S.W[U] and FCVT.W[U].S."""
import argparse
import random
import struct
from fractions import Fraction
from pathlib import Path


def round_fraction(value, mode):
    sign = value < 0
    quotient, remainder = divmod(abs(value.numerator), value.denominator)
    up = ((mode == 0 and (2 * remainder > value.denominator or
                           (2 * remainder == value.denominator and quotient & 1))) or
          (mode == 2 and sign and remainder != 0) or
          (mode == 3 and not sign and remainder != 0) or
          (mode == 4 and 2 * remainder >= value.denominator))
    rounded = quotient + int(up)
    return -rounded if sign else rounded, bool(remainder)


def reference(bits, to_float, unsigned, rm):
    if rm > 4:
        return 0, 0, 1
    if to_float:
        value = bits if unsigned or bits < 0x80000000 else bits - (1 << 32)
        if value == 0:
            return 0, 0, 0
        sign = int(value < 0)
        magnitude = abs(value)
        exponent = magnitude.bit_length() - 1
        if exponent <= 23:
            rounded, inexact = magnitude << (23 - exponent), False
        else:
            step = 1 << (exponent - 23)
            rounded, inexact = round_fraction(Fraction(magnitude, step), rm if not sign else
                                               {0: 0, 1: 1, 2: 3, 3: 2, 4: 4}[rm])
        # For negative inputs, directed modes swap when rounding the magnitude.
        if rounded == 1 << 24:
            rounded >>= 1
            exponent += 1
        result = (sign << 31) | ((exponent + 127) << 23) | (rounded & 0x7fffff)
        return result, int(inexact), 0

    sign, exp, frac = bits >> 31, (bits >> 23) & 255, bits & 0x7fffff
    positive_limit = 0xffffffff if unsigned else 0x7fffffff
    negative_limit = 0 if unsigned else 0x80000000
    if exp == 255:
        if frac:
            return positive_limit, 16, 0
        return (negative_limit if sign else positive_limit), 16, 0
    significand = frac if exp == 0 else (1 << 23) | frac
    power = (1 if exp == 0 else exp) - 150
    exact = Fraction(significand << power, 1) if power >= 0 else Fraction(significand, 1 << -power)
    if sign:
        exact = -exact
    rounded, inexact = round_fraction(exact, rm)
    low = 0 if unsigned else -(1 << 31)
    high = (1 << 32) - 1 if unsigned else (1 << 31) - 1
    if rounded < low:
        return negative_limit, 16, 0
    if rounded > high:
        return positive_limit, 16, 0
    return rounded & 0xffffffff, int(inexact), 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=Path('sim/build/f20/convert.txt'))
    args = parser.parse_args()
    anchors = [
        (0x00000000, 1, 0, 0, 0x00000000, 0),
        (0x80000000, 1, 0, 0, 0xcf000000, 0),
        (0x80000000, 1, 1, 0, 0x4f000000, 0),
        (0xffffffff, 1, 1, 0, 0x4f800000, 1),
        (0x3fc00000, 0, 0, 0, 2, 1),
        (0x3fc00000, 0, 0, 1, 1, 1),
        (0xbfc00000, 0, 0, 0, 0xfffffffe, 1),
        (0x7fc00000, 0, 0, 0, 0x7fffffff, 16),
        (0xffc00000, 0, 1, 0, 0xffffffff, 16),
        (0xbf000000, 0, 1, 0, 0, 1),
        (0xbf800000, 0, 1, 0, 0, 16),
    ]
    for bits, direction, unsigned, rm, want, flags in anchors:
        assert reference(bits, direction, unsigned, rm) == (want, flags, 0), (hex(bits), direction, unsigned, rm)
    edges = [0, 1, 2, 0x3effffff, 0x3f000000, 0x3f7fffff, 0x3f800000,
             0x3fc00000, 0x4effffff, 0x4f000000, 0x4f7fffff, 0x4f800000,
             0x7f800000, 0x7fc00000, 0x7fa00001, 0x7f7fffff,
             0x7fffffff, 0x80000000, 0x80000001, 0x80800000,
             0xbf000000, 0xbfc00000, 0xcf000000, 0xff800000, 0xffffffff]
    rng = random.Random(0x23521387)
    cases = [(x, direction, unsigned, rm) for x in edges
             for direction in (0, 1) for unsigned in (0, 1) for rm in range(5)]
    cases += [(rng.getrandbits(32), rng.randrange(2), rng.randrange(2), rng.randrange(5))
              for _ in range(30000)]
    cases += [(bits, d, u, rm) for bits, d, u, rm, _, _ in anchors]
    cases += [(0x3f800000, d, u, rm) for d in (0, 1) for u in (0, 1) for rm in (5, 6, 7)]
    host_checks = 0
    for bits, direction, unsigned, rm in cases:
        if direction != 1 or rm != 0:
            continue
        integer = bits if unsigned or bits < 0x80000000 else bits - (1 << 32)
        host_bits = int.from_bytes(struct.pack('>f', integer), 'big')
        assert reference(bits, direction, unsigned, rm)[0] == host_bits
        host_checks += 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('w', encoding='ascii', newline='\n') as out:
        for bits, direction, unsigned, rm in cases:
            result, flags, illegal = reference(bits, direction, unsigned, rm)
            out.write(f'{bits:08x} {direction:x} {unsigned:x} {rm:x} {result:08x} {flags:02x} {illegal:x}\n')
    print(f'Generated {len(cases)} FCVT vectors; {host_checks} host int-to-float RNE checks')


if __name__ == '__main__':
    main()
