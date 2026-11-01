"""Measure, from a core VCD, how many cycles each instruction spends in EX and MEM.

Signals are sampled just before every rising clock edge. An instruction leaves
EX on an edge where execute_valid=1 and execute_wait=0 (fp_wait|memory_wait),
and leaves MEM on an edge where memstage_valid=1 and memory_wait=0.
"""
import argparse
import json
from pathlib import Path

WANT = ['clk', 'execute_valid', 'fp_wait', 'memory_wait', 'memstage_valid',
        'instruction_execute', 'instruction_memstage']


def read_vcd(path):
    ids, scope = {}, []
    with open(path, encoding='ascii', errors='replace') as f:
        for line in f:
            tok = line.split()
            if not tok: continue
            if tok[0] == '$scope': scope.append(tok[2])
            elif tok[0] == '$upscope': scope.pop()
            elif tok[0] == '$var' and scope[-2:] == ['dut', 'u_core'] and tok[4] in WANT:
                ids.setdefault(tok[3], []).append(tok[4])
            elif tok[0] == '$enddefinitions': break
        missing = set(WANT) - {n for v in ids.values() for n in v}
        if missing: raise SystemExit(f'VCD lacks signals: {sorted(missing)}')
        cur = {n: 0 for n in WANT}
        before, rose = dict(cur), False
        for line in f:
            line = line.strip()
            if not line or line[0] == '$': continue
            if line[0] == '#':
                if rose: yield before
                before, rose = dict(cur), False
                continue
            if line[0] in 'bB':
                parts = line[1:].split()   # iverilog may emit 'b <id>' with no bits
                bits, code = (parts[0], parts[1]) if len(parts) == 2 else ('0', parts[0])
                value = int(bits.replace('x', '0').replace('z', '0') or '0', 2)
            else:
                code, value = line[1:], int(line[0]) if line[0] in '01' else 0
            for name in ids.get(code, ()):
                if name == 'clk' and cur['clk'] == 0 and value == 1: rose = True
                cur[name] = value
        if rose: yield before


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('vcd', type=Path)
    parser.add_argument('--labels', type=Path, required=True)
    args = parser.parse_args()
    names = {int(w, 16): n for n, w in json.loads(args.labels.read_text(encoding='utf-8'))}
    rows, ex, mem, cycle = [], 0, 0, 0
    pending_mem = {}
    for s in read_vcd(args.vcd):
        cycle += 1
        if s['memstage_valid']:
            mem += 1
            if not s['memory_wait']:
                pending_mem[s['instruction_memstage']] = mem; mem = 0
        if s['execute_valid']:
            ex += 1
            if not (s['fp_wait'] or s['memory_wait']):
                rows.append([s['instruction_execute'], ex, cycle]); ex = 0
    print(f'{"instruction":<24}{"EX":>4}{"MEM":>5}   (cycles; leaves EX at cycle)')
    for word, ex_cycles, at in rows:
        if word not in names: continue
        print(f'{names[word]:<24}{ex_cycles:>4}{pending_mem.get(word, "-"):>5}   @{at}')


if __name__ == '__main__': main()
