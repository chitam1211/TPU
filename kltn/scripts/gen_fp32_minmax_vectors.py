"""FP32 min/max oracle using numeric sorting, separate from RTL bit ordering."""
import argparse
import random
import struct
from pathlib import Path
from gen_fp32_compare_vectors import EDGES


def reference(a, b, maximum):
    nans = [v for v in (a, b) if (v & 0x7fffffff) > 0x7f800000]
    flags = 16 if any(not (v & 0x00400000) for v in nans) else 0
    numbers = [v for v in (a, b) if v not in nans]
    if not numbers:
        return 0x7fc00000, flags
    def key(bits):
        value = struct.unpack('>f', bits.to_bytes(4, 'big'))[0]
        # Secondary ordering distinguishes -0 from +0 (and leaves equal
        # nonzero values unchanged). Keep original operand bits in the result.
        return value, -1 if bits >> 31 else 1
    ordered = sorted(numbers, key=key)
    return ordered[-1 if maximum else 0], flags


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    # Fixed anchors independently check the oracle's special-case policy.
    assert reference(0, 0x80000000, False) == (0x80000000, 0)
    assert reference(0x80000000, 0, True) == (0, 0)
    assert reference(0x7f800001, 0xbf800000, True) == (0xbf800000, 16)
    assert reference(0x7fc12345, 0xffc12345, False) == (0x7fc00000, 0)
    assert reference(0xff800001, 0x7fc00000, False) == (0x7fc00000, 16)
    rng = random.Random(0xF15)
    pairs = [(a, b) for a in EDGES for b in EDGES]
    for i in range(10000):
        a, b = rng.getrandbits(32), rng.getrandbits(32)
        pairs.extend(((a, b), (b, a)))
        if i % 32 == 0:
            pairs.extend(((a, a), (a, (a+1) & 0xffffffff)))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('w', encoding='ascii', newline='\n') as out:
        for a, b in pairs:
            lo, flags = reference(a, b, False)
            hi, _ = reference(a, b, True)
            out.write(f'{a:08x} {b:08x} {lo:08x} {hi:08x} {flags:02x}\n')
    print(f'FP32_MINMAX_VECTORS_GENERATED pairs={len(pairs)} results={2*len(pairs)}')


if __name__ == '__main__':
    main()
