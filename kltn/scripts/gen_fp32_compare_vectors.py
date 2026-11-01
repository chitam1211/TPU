"""Independent comparison oracle: binary32 values compare exactly as Python doubles.

Classify NaNs from their original bits before conversion, preserving signaling
versus quiet status. No RTL sign/magnitude ordering algorithm is reproduced.
"""
import argparse
import random
import struct
from pathlib import Path

EDGES = [0, 0x80000000, 1, 0x80000001, 0x007fffff, 0x807fffff,
         0x00800000, 0x80800000, 0x3f800000, 0xbf800000, 0x3f800001,
         0xbf800001, 0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000,
         0x7fc00000, 0xffc12345, 0x7fffffff, 0x7f800001, 0xff800001,
         0x7fbfffff]


def reference(a, b, operation):
    if operation not in (0, 1, 2):
        return 0, 0
    nans = [v for v in (a, b) if (v & 0x7fffffff) > 0x7f800000]
    if nans:
        invalid = operation != 2 or any(not (v & 0x00400000) for v in nans)
        return 0, 16 if invalid else 0
    left, right = (struct.unpack('>f', v.to_bytes(4, 'big'))[0] for v in (a, b))
    return int((left <= right, left < right, left == right)[operation]), 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    rng = random.Random(0xF13)
    pairs = [(a, b) for a in EDGES for b in EDGES]
    for _ in range(10000):
        a, b = rng.getrandbits(32), rng.getrandbits(32)
        pairs.append((a, b))
        # Also exercise equal and adjacent encodings, rare in uniform randoms.
        if len(pairs) % 10 == 0:
            pairs.extend(((a, a), (a, (a + 1) & 0xffffffff)))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with args.output.open('w', encoding='ascii', newline='\n') as out:
        for a, b in pairs:
            for operation in range(3):
                result, flags = reference(a, b, operation)
                out.write(f'{a:08x} {b:08x} {operation:x} {result:08x} {flags:02x}\n')
                count += 1
        for operation in range(3, 8):
            out.write(f'7f800001 00000000 {operation:x} 00000000 00\n')
            count += 1
    print(f'FP32_COMPARE_VECTORS_GENERATED cases={count}')


if __name__ == '__main__':
    main()
