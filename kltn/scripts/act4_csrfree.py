"""Turn an ACT4 RV32F program into a CSR-free one that still checks every computed result.

Used by `--no-flags` (run_act4_rtl.py, act4_cli.py, act4_show_asm.sh). The test program then
exercises only the 26 F instructions and their results; it no longer depends on fcsr:

1. Every CSR instruction (fsflagsi, frflags, fsrmi, csrsi fcsr, fscsr, csrs mstatus, ...) in
   code becomes `nop`.
2. Each fflags comparison is skipped: its `jal failedtest_fflags_*` becomes `jal x0, +12`,
   which lands on the next check (the two data words after the jal are jumped over).
3. Each rounding instruction with rm = DYN (111) gets the static rm equal to the value frm
   holds at that point. frm is followed through fsrmi/fscsr in program order (the test
   body is straight-line code), starting from the reset value 0. The operation computed is
   therefore exactly the one ACT4 intended, and the Sail expected results stay valid.

Instruction count and code layout do not change.
"""

NOP = 0x00000013
JUMP_OVER_DATA = 0x00c0006f            # jal x0, +12
ROUNDING_FUNCT7 = {0x00, 0x04, 0x08, 0x0c, 0x2c, 0x60, 0x68}   # add sub mul div sqrt cvt.w cvt.s
FMA_OPCODES = {0x43, 0x47, 0x4b, 0x4f}
RM_NAMES = ("rne", "rtz", "rdn", "rup", "rmm")


def has_rm(word):
    opcode = word & 0x7f
    return opcode in FMA_OPCODES or (opcode == 0x53 and (word >> 25) in ROUNDING_FUNCT7)


def is_csr(word):
    return word & 0x7f == 0x73 and (word >> 12) & 3 != 0


def _sext(value, bits):
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def jal_target(address, word):
    if word & 0x7f != 0x6f:
        return None
    return address + _sext(((word >> 31) & 1) << 20 | ((word >> 12) & 0xff) << 12 |
                           ((word >> 20) & 1) << 11 | ((word >> 21) & 0x3ff) << 1, 21)


def _frm_after(word, frm):
    """frm after a CSR instruction, or raise if it cannot be known statically."""
    csr, funct3, field = word >> 20, (word >> 12) & 7, (word >> 15) & 31
    if csr not in (0x002, 0x003):
        return frm
    op, immediate = funct3 & 3, bool(funct3 & 4)
    if not immediate and field != 0:
        raise RuntimeError(f"frm changed from register x{field}: cannot be resolved statically")
    value = field if immediate else 0
    bits = value & 7 if csr == 0x002 else (value >> 5) & 7    # a 5-bit uimm never reaches fcsr[7:5]
    if op == 1:
        return bits
    if op == 2:
        return frm | bits
    return frm & ~bits


def make_csr_free(read_word, code_ranges, body_range, fail_handlers, fflags_handlers):
    """Return {address: new_word, ...} and statistics. read_word(address) -> int or None.

    code_ranges: [(start, end)] of code sections; body_range: (rvtest_code_begin,
    rvtest_code_end), where frm is tracked; fail_handlers/fflags_handlers: sets of addresses
    of every failedtest_* / failedtest_fflags_* label."""
    patches, stats = {}, {"csr_to_nop": 0, "fflags_checks_skipped": 0, "dyn_to_static": 0}
    frm, skip = 0, 0
    for start, end in code_ranges:
        for address in range(start, end, 4):
            word = read_word(address)
            if word is None:
                continue
            if skip:                      # the two .word data after a failedtest jump
                skip -= 1
                continue
            target = jal_target(address, word)
            if target in fail_handlers:
                if target in fflags_handlers:
                    patches[address] = JUMP_OVER_DATA
                    stats["fflags_checks_skipped"] += 1
                skip = 2
                continue
            in_body = body_range[0] <= address < body_range[1]
            if is_csr(word):
                if in_body:
                    frm = _frm_after(word, frm)
                patches[address] = NOP
                stats["csr_to_nop"] += 1
            elif in_body and has_rm(word) and (word >> 12) & 7 == 7:
                if frm > 4:
                    raise RuntimeError(f"reserved frm={frm} for DYN instruction at 0x{address:08x}")
                patches[address] = word & ~0x7000 | frm << 12
                stats["dyn_to_static"] += 1
    return patches, stats
