"""F13 integration cases for the shared retirement/memory/FCSR scoreboard."""
import random
from gen_f10_programs import Program, fp, csr, imm, store, branch
from gen_fp32_compare_vectors import EDGES


def comparison_programs():
    # Includes reserved frm values: comparisons never consult rounding mode.
    for mode in range(8):
        for op in range(3):
            p = Program(f'compare_specials_frm{mode}_op{op}')
            for i, value in enumerate(EDGES):
                p.fl(i, value, i)
            p.emit(csr(2, 5, 0, mode))
            for i in range(len(EDGES)):
                # Existing NX must survive a comparison that accumulates NV.
                p.emit(csr(1, 5, 0, 1), fp(80, 24, i, (i+1) % len(EDGES), op),
                       store(0x23, 24, 512), csr(3, 2, 25, 0))
            p.finish()
            yield p

    p = Program('compare_hazards_flags_flush')
    p.fl(0, 0x7f800001); p.fl(1, 0x3f800000); p.fl(2, 0x40000000)
    p.fl(3, 0x7fc00000); p.fl(4, 0xff800000); p.fl(5, 0x7f800000)
    p.fl(6, 0x33800000)
    for op in range(3):
        # rd=x0 still raises NV, and never changes x0 or f0.
        p.emit(csr(1,5,0,0), fp(80,0,0,1,op), csr(1,2,10,0),
               store(0x23,0,512), store(0x27,0,516))
        # Quiet NaN differs between FEQ and ordered comparisons, both sides.
        p.emit(csr(1,5,0,0), fp(80,11,3,1,op), csr(1,2,12,0),
               csr(1,5,0,0), fp(80,11,1,3,op), csr(1,2,12,0))
        # Compare output immediately feeds integer ALU, FPR move and store.
        p.emit(fp(80,1,1,2,op), imm(0x13,2,1,1), fp(120,7,2),
               store(0x23,2,520), store(0x27,7,524))
        # Producing both operands with arithmetic forces FPR dependency stalls.
        p.emit(fp(0,8,1,2), fp(4,9,8,2), fp(80,13,9,8,op))
        # Sticky NX + NV from different execution units, in both orders.
        p.emit(csr(1,5,0,0), fp(0,10,1,6), fp(80,0,0,1,op), csr(1,2,14,0),
               csr(1,5,0,0), fp(80,0,0,1,op), fp(0,10,1,6), csr(1,2,14,0))
        # Compare-to-branch dependency, and cancel a would-be NV update.
        p.emit(csr(1,5,0,0), fp(80,15,1,1,2), imm(0x13,16,0,1),
               branch(15,16,8), fp(80,0,0,1,op), csr(1,2,17,0))
        # Compare before CSR overwrite; CSR before compare (both directions).
        p.emit(fp(80,0,0,1,op), csr(1,5,18,0), fp(80,19,1,2,op), csr(1,2,20,0))
    # Invalid funct3 and FP64 encoding must not write registers or flags.
    p.emit(csr(1,5,0,0))
    for op in range(3,8):
        p.emit(fp(80,21,0,1,op))
    p.emit(fp(81,21,0,1,2), csr(1,2,22,0), store(0x23,21,528))
    p.finish()
    yield p

    rng = random.Random(0xF1323521419)
    for batch in range(8):
        p = Program(f'compare_random_{batch:02d}')
        for i in range(32):
            p.fl(i, rng.choice(EDGES) if i < 22 else rng.getrandbits(32), i)
        for _ in range(60):
            d,a,b = (rng.randrange(32) for _ in range(3))
            p.emit(fp(80,d,a,b,rng.randrange(3)))
            kind = rng.randrange(5)
            if kind == 0: p.emit(csr(1,rng.choice([1,2,3,5,6,7]),d,a))
            elif kind == 1: p.emit(fp(0,d,a,b))
            elif kind == 2: p.emit(fp(120,a,d))
            elif kind == 3: p.emit(store(0x23,d,512+4*rng.randrange(100)))
            else: p.emit(fp(4,d,a,b))
        p.finish()
        yield p
