"""Build an RV32F program for waveform viewing: all 26 F instructions, or just one.

Writes, into --output:
  wave.txt            case file for tb_f10_e2e (expected values from the F10 model)
  labels.json         instruction word -> mnemonic, in program order
  insn_filter.txt     GTKWave translate filter: instruction word -> mnemonic
  state_<unit>.txt    GTKWave translate filters for each FPU FSM state register
  wave.gtkw           GTKWave save file preloading the useful signals
Operands are loaded first so each F instruction reads ready registers; the
remaining stalls in the waveform are the FPU latency itself.
With --only <mnemonic> (e.g. fadd.s, or fadd) the program runs just that F
instruction and the save file shows only the signals of the unit executing it.
"""
import argparse
import json
from pathlib import Path
from gen_f10_programs import (Program, execute, fp, r4, store, imm,
                              FMADD, FMSUB, FNMSUB, FNMADD)

RNE = 0
# Registers: f1=1.5 f2=2.25 f3=1.0 f4=0.99999994, x1=-7 x2=5.
OPS = [
    ('fadd.s f5,f1,f2',       fp(0x00, 5, 1, 2, RNE)),
    ('fsub.s f6,f3,f4',       fp(0x04, 6, 3, 4, RNE)),   # cancellation: NORMALIZE loops
    ('fmul.s f7,f1,f2',       fp(0x08, 7, 1, 2, RNE)),
    ('fdiv.s f8,f1,f2',       fp(0x0c, 8, 1, 2, RNE)),
    ('fsqrt.s f9,f2',         fp(0x2c, 9, 2, 0, RNE)),
    ('fmadd.s f10,f1,f2,f3',  r4(FMADD, 10, 1, 2, 3, RNE)),
    ('fmsub.s f11,f1,f2,f3',  r4(FMSUB, 11, 1, 2, 3, RNE)),
    ('fnmsub.s f12,f1,f2,f3', r4(FNMSUB, 12, 1, 2, 3, RNE)),
    ('fnmadd.s f13,f1,f2,f3', r4(FNMADD, 13, 1, 2, 3, RNE)),
    ('fsgnj.s f14,f1,f3',     fp(0x10, 14, 1, 3, 0)),
    ('fsgnjn.s f15,f1,f3',    fp(0x10, 15, 1, 3, 1)),
    ('fsgnjx.s f16,f1,f3',    fp(0x10, 16, 1, 3, 2)),
    ('fmin.s f17,f1,f2',      fp(0x14, 17, 1, 2, 0)),
    ('fmax.s f18,f1,f2',      fp(0x14, 18, 1, 2, 1)),
    ('fcvt.w.s x3,f1',        fp(0x60, 3, 1, 0, RNE)),
    ('fcvt.wu.s x4,f2',       fp(0x60, 4, 2, 1, RNE)),
    ('fmv.x.w x5,f1',         fp(0x70, 5, 1, 0, 0)),
    ('feq.s x6,f1,f2',        fp(0x50, 6, 1, 2, 2)),
    ('flt.s x7,f1,f2',        fp(0x50, 7, 1, 2, 1)),
    ('fle.s x8,f1,f2',        fp(0x50, 8, 1, 2, 0)),
    ('fclass.s x9,f1',        fp(0x70, 9, 1, 0, 1)),
    ('fcvt.s.w f19,x1',       fp(0x68, 19, 1, 0, RNE)),
    ('fcvt.s.wu f20,x2',      fp(0x68, 20, 2, 1, RNE)),
    ('fmv.w.x f21,x2',        fp(0x78, 21, 2, 0, 0)),
    ('fsw f1,512(x0)',        store(0x27, 1, 512)),
]

# flw is also the setup instruction; as a target it loads a fresh register.
EXTRA = {'flw': ('flw f5,4(x0)', imm(7, 5, 0, 4, 2))}
ONE_OPERAND = {'fsqrt.s', 'fclass.s', 'fmv.x.w', 'fmv.w.x', 'flw',
               'fcvt.w.s', 'fcvt.wu.s', 'fcvt.s.w', 'fcvt.s.wu'}


def mnemonic(name):
    return name.split()[0]


def unit_of(op):
    if op in ('fadd.s', 'fsub.s'): return 'addsub'
    if op == 'fmul.s': return 'mul'
    if op in ('fdiv.s', 'fsqrt.s'): return 'divsqrt'
    if op in ('fmadd.s', 'fmsub.s', 'fnmsub.s', 'fnmadd.s'): return 'fma'
    if op.startswith('fcvt.'): return 'convert'
    return None   # combinational in EX, or load/store


# Operand registers loaded by the setup instructions (and preloaded in isolated mode).
SETUP_X = {1: 0xfffffff9, 2: 5}
SETUP_F = {1: 0x3fc00000, 2: 0x40100000, 3: 0x3f800000, 4: 0x3f7fffff}


def program(only=None, rm=None):
    p = Program('wave_' + (only or 'all26').replace('.', '_'))
    labels = []
    for rd, bits in SETUP_X.items():
        p.lw(rd, bits); labels.append((f'lw x{rd}', p.code[-1]))
    for rd, bits in SETUP_F.items():
        p.fl(rd, bits); labels.append((f'flw f{rd}', p.code[-1]))
    targets = [(n, w) for n, w in OPS if only is None or mnemonic(n) == only]
    if only in EXTRA: targets.append(EXTRA[only])
    for name, word in targets:
        if rm is not None:   # funct3 is the rounding-mode field for these instructions
            word = (word & ~(7 << 12)) | (rm << 12)
            name += f',rm={rm}'
        p.emit(word); labels.append((name, word))
    p.finish()
    labels += [('addi x31,x0,0x123', p.code[-2]), ('sw x31,1020(x0)', p.code[-1])]
    return p, labels


STATES = {
    'addsub':  ['IDLE', 'CLASSIFY', 'ALIGN', 'ADD', 'NORMALIZE', 'ROUND'],
    'mul':     ['IDLE', 'CLASSIFY', 'MULTIPLY', 'NORMALIZE', 'ROUND'],
    'divsqrt': ['IDLE', 'CLASSIFY', 'PREPARE', 'ITERATE', 'NORMALIZE', 'ROUND'],
    'fma':     ['IDLE', 'CLASSIFY', 'MULTIPLY', 'ALIGN', 'ADD', 'NORMALIZE', 'ROUND'],
    'convert': ['IDLE', 'ALIGN', 'ROUND'],
}
# Datapath registers worth watching inside each unit.
INTERNALS = {
    'addsub':  ['large_m[26:0]', 'small_m[26:0]', 'distance[7:0]', 'sum[27:0]', 'exponent[8:0]'],
    'mul':     ['sig_a[23:0]', 'sig_b[23:0]', 'product[47:0]', 'norm_sig[23:0]', 'norm_guard', 'norm_sticky'],
    'divsqrt': ['sig_a[23:0]', 'sig_b[23:0]', 'count[4:0]', 'q[26:0]', 'rem[31:0]', 'norm_sig[23:0]', 'norm_sticky'],
    'fma':     ['product[47:0]', 'frame_p[79:0]', 'frame_c[79:0]', 'mag[79:0]', 'norm_sig[23:0]', 'norm_guard', 'norm_sticky'],
    'convert': ['operand[31:0]', 'r_value[32:0]', 'r_guard', 'r_sticky', 'r_exponent[7:0]'],
}


def filter_lines(pairs, width):
    # GTKWave matches the displayed hex text; emit both cases to be safe.
    out = []
    for value, name in pairs:
        text = f'{value:0{width}x}'
        out += [f'{text} {name}', f'{text.upper()} {name}']
    return '\n'.join(dict.fromkeys(out)) + '\n'


def gtkw(out, vcd, only, top, dest=None, title=None):
    """dest: ('f'|'x', register number) written by the target, for isolated runs.
    title: comment line shown at the top of the signal list."""
    core = f'{top}.dut.u_core'
    lines = [f'[dumpfile] "{vcd}"', '[timestart] 0', '[size] 1600 900', '[signals_width] 300']
    if title:
        lines.extend(['@200', f'-{title}'])
    BIN, HEX = 0x28, 0x22
    def sig(flags, name, translate=None):
        if translate:
            lines.extend([f'@{0x2000 | flags:x}', f'^1 {translate}'])
        else:
            lines.append(f'@{flags:x}')
        lines.append(name)
    def group(title):
        lines.extend(['@200', f'-{title}'])
    def state(unit):
        sig(HEX, f'{core}.u_fp_{unit}.state[{1 if unit == "convert" else 2}:0]', out / f'state_{unit}.txt')
    insn = out / 'insn_filter.txt'
    unit = unit_of(only) if only else None

    group('Pipeline')
    sig(BIN, f'{core}.clk')
    if only is None:
        sig(HEX, f'{core}.instruction_decode[31:0]', insn)
    sig(BIN, f'{core}.execute_valid')
    sig(HEX, f'{core}.instruction_execute[31:0]', insn)
    if only is None or unit is None:
        sig(HEX, f'{core}.instruction_memstage[31:0]', insn)
    sig(HEX, f'{core}.instruction_wb[31:0]', insn)
    if only is None or unit:
        group('FPU handshake')
        for name in ('fp_start', 'fp_busy', 'fp_done', 'fp_wait'):
            sig(BIN, f'{core}.{name}')
    if only is None:
        sig(BIN, f'{core}.memory_wait')
        group('FPU FSM states')
        for u in STATES: state(u)
    elif unit:
        state(unit)
    if only in ('flw', 'fsw'):
        dut = f'{top}.dut'
        group('Data memory (MEM stage)')
        sig(BIN, f'{core}.memstage_valid')
        sig(BIN, f'{core}.memory_wait')
        sig(BIN, f'{dut}.data_mem_request')
        sig(BIN, f'{dut}.data_mem_we_re')
        sig(HEX, f'{dut}.alu_out_address[31:0]')
        sig(HEX, f'{dut}.store_data[31:0]')
        sig(HEX, f'{dut}.load_data_out[31:0]')
        sig(BIN, f'{dut}.data_mem_valid')
        if only == 'fsw' and top == 'tb_wave_one':
            sig(HEX, f'{top}.mem_word[31:0]')   # memory word the store writes to
    if dest or only == 'fsw':
        group('Writeback')
        sig(BIN, f'{core}.wb_valid')
    if dest:
        sig(HEX, f'{core}.rd_wb_data[31:0]')
        sig(HEX, f'{top}.dest_{"fpr" if dest[0] == "f" else "gpr"}[31:0]')
    group('Operands / result')
    sig(HEX, f'{core}.opa_mux_out_execute[31:0]')
    if only not in ONE_OPERAND:
        sig(HEX, f'{core}.opb_mux_out_execute[31:0]')
    if only is None or unit == 'fma':
        sig(HEX, f'{core}.opc_mux_out_execute[31:0]')
    sig(HEX, f'{core}.execute_result[31:0]')
    sig(HEX, f'{core}.fp_flags[4:0]' if (only is None or unit) else f'{core}.fp_flags_memstage[4:0]')
    sig(HEX, f'{core}.fflags[4:0]')
    for u in (STATES if only is None else ([unit] if unit else [])):
        group(f'{u} internals')
        for name in INTERNALS[u]:
            sig(BIN if '[' not in name else HEX, f'{core}.u_fp_{u}.{name}')
    return '\n'.join(lines) + '\n'


def write_isolated(out, p, labels, trace, final, only, expect=None):
    """Case file for tb_wave_one: one target instruction, registers preloaded.
    expect: (value, fflags) that replace the model's expectation (e.g. Sail's)."""
    target = [(n, w) for n, w in labels if mnemonic(n) == only][-1]
    name, word = target
    row = next(r for r in trace if r[1] == word)
    gpr = [SETUP_X.get(i, 0) for i in range(32)]
    fpr = [SETUP_F.get(i, 0) for i in range(32)]
    is_store = only == 'fsw'
    value, csr = row[5], row[6]
    if expect:
        value = expect[0] if (row[2] or row[3]) else value
        csr = (csr & ~0x1f) | expect[1]
    head = [word, row[2], row[3], row[4], value, csr, int(is_store), 128, final[128]]
    with (out / 'iso.txt').open('w', encoding='ascii', newline='\n') as f:
        f.write(' '.join(f'{v:08x}' for v in head) + '\n')
        for v in gpr + fpr + p.data: f.write(f'{v:08x}\n')
    (out / 'labels.json').write_text(json.dumps([[name, f'{word:08x}']], indent=1) + '\n', encoding='utf-8')
    names = [(word, name.replace(' ', '_')), (0x13, 'nop')]
    (out / 'insn_filter.txt').write_text(filter_lines(names, 8), encoding='ascii')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--only', help='one F mnemonic, e.g. fadd.s (".s" may be omitted)')
    parser.add_argument('--with-setup', action='store_true',
                        help='with --only: keep the register-setup loads in the program instead of isolating')
    parser.add_argument('--set', action='append', default=[], metavar='REG=HEX',
                        help='override an operand register, e.g. --set f2=00000000 (f1-f4, x1, x2); repeatable')
    parser.add_argument('--mem', action='append', default=[], metavar='WORD=HEX',
                        help='preset a data-RAM word (byte address = 4*WORD), e.g. --mem 1=12345678 for flw f5,4(x0)')
    parser.add_argument('--rm', type=int, choices=range(8),
                        help='rounding-mode field of the target (0..4 valid, 5/6 reserved, 7=DYN from frm)')
    parser.add_argument('--expect', metavar='VALUE:FLAGS',
                        help='isolated mode: expected result and fflags (hex) instead of the model\'s, e.g. Sail\'s')
    parser.add_argument('--title', help='comment shown at the top of the GTKWave signal list')
    args = parser.parse_args()
    for item in args.set:
        reg, _, value = item.partition('=')
        table = {'f': SETUP_F, 'x': SETUP_X}.get(reg[:1])
        if table is None or not reg[1:].isdigit() or int(reg[1:]) not in table or not value:
            raise SystemExit(f'--set {item!r}: use f1..f4 or x1..x2, e.g. f2=00000000')
        table[int(reg[1:])] = int(value, 16) & 0xffffffff
    choices = sorted({mnemonic(n) for n, _ in OPS} | set(EXTRA))
    only = args.only
    if only:
        only = only.lower()
        if only not in choices and only + '.s' in choices: only += '.s'
        if only not in choices:
            raise SystemExit(f'Unknown instruction {args.only!r}. Choose one of: ' + ' '.join(choices))
    if args.rm is not None and (not only or (unit_of(only) is None)):
        raise SystemExit('--rm needs --only with an instruction that has a rounding mode '
                         '(fadd/fsub/fmul/fdiv/fsqrt, the 4 FMA, the 4 fcvt)')
    isolated = bool(only) and not args.with_setup
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    p, labels = program(only, args.rm)
    for item in args.mem:
        word, _, value = item.partition('=')
        if not word.isdigit() or int(word) > 127 or not value:
            raise SystemExit(f'--mem {item!r}: use WORD=HEX with WORD 0..127, e.g. 1=12345678')
        p.data[int(word)] = int(value, 16) & 0xffffffff
    trace, mem, final, _ = execute(p)
    image = p.code + [0x0000006f] + [0x13] * (255 - len(p.code))
    with (out / 'wave.txt').open('w', encoding='ascii', newline='\n') as f:
        f.write(f'{len(trace)} {len(mem)}\n')
        for value in image + p.data: f.write(f'{value:08x}\n')
        for row in trace + mem: f.write(' '.join(f'{v:08x}' for v in row) + '\n')
        for value in final: f.write(f'{value:08x}\n')
    (out / 'labels.json').write_text(json.dumps([[n, f'{w:08x}'] for n, w in labels], indent=1) + '\n', encoding='utf-8')
    (out / 'insn_filter.txt').write_text(filter_lines([(w, n.replace(' ', '_')) for n, w in labels], 8), encoding='ascii')
    expect = None
    if args.expect:
        v, _, f = args.expect.partition(':')
        expect = (int(v, 16) & 0xffffffff, int(f or '0', 16) & 0x1f)
    if isolated: write_isolated(out, p, labels, trace, final, only, expect)
    for unit, names in STATES.items():
        (out / f'state_{unit}.txt').write_text(filter_lines(enumerate(names), 1), encoding='ascii')
    top = 'tb_wave_one' if isolated else 'tb_f10_e2e'
    dest = None
    if isolated:
        row = next(r for r in trace if r[1] == [w for n, w in labels if mnemonic(n) == only][-1])
        dest = ('x' if row[2] else 'f', row[4]) if (row[2] or row[3]) else None
    (out / 'wave.gtkw').write_text(gtkw(out, out / 'wave.vcd', only, top, dest, args.title), encoding='utf-8')
    print(f'WAVE_PROGRAM_GENERATED name={p.name} mode={"isolated" if isolated else "full"} retired={len(trace)}')


if __name__ == '__main__': main()
