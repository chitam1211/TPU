"""F15 programs checked at retirement with normal and delayed memory."""
import random
from gen_f10_programs import Program, fp, csr, store, branch
from gen_fp32_compare_vectors import EDGES


def minmax_programs():
    for mode in range(8):
        for op in range(2):
            p = Program(f'minmax_specials_frm{mode}_op{op}')
            for i, value in enumerate(EDGES):
                p.fl(i, value, i)
            p.emit(csr(2,5,0,mode))
            for i in range(len(EDGES)):
                for a,b in ((i,(i+1)%len(EDGES)), ((i+1)%len(EDGES),i)):
                    p.emit(csr(1,5,0,15), fp(20,24,a,b,op),
                           store(0x27,24,512), csr(3,2,25,0))
            p.finish()
            yield p

    p = Program('minmax_hazards_flags_flush')
    for rd,value in enumerate([0,0x80000000,0x7f800001,0xff800001,
                               0x7fc12345,0xffc12345,0x3f800000,0x33800000]):
        p.fl(rd,value,rd)
    for op in range(2):
        # All quiet/signaling NaN pairs, both operands' positions, both signs.
        for a,b in ((2,3),(2,4),(4,2),(4,5),(4,6),(6,4),(2,6),(6,2),
                    (0,1),(1,0),(0,0),(1,1)):
            p.emit(csr(1,5,0,0),fp(20,8,a,b,op),fp(112,8,8),csr(1,2,9,0))
        # FPR write-to-read chain, f0 writable, x0 still hardwired to zero.
        p.emit(fp(20,0,2,6,op),fp(20,10,0,6,op),fp(80,11,10,0,2),
               store(0x27,0,516),store(0x23,0,520))
        # ADD -> min/max -> SUB, then min/max -> compare, with sticky NX+NV.
        p.emit(csr(1,5,0,0),fp(0,12,6,7),fp(20,13,12,2,op),
               fp(4,14,13,6),fp(80,15,14,1,2),csr(1,2,16,0))
        # Min/max before a CSR overwrite and after it; preserve flag ordering.
        p.emit(fp(20,17,2,6,op),csr(1,5,18,0),fp(20,19,6,6,op),csr(1,2,20,0))
        # Wrong-path min/max must not write an FPR or raise NV.
        p.emit(csr(1,5,0,0),branch(0,0,8),fp(20,21,2,6,op),
               store(0x27,21,524),csr(1,2,22,0))
    p.emit(csr(1,5,0,0))
    for op in range(2,8):
        p.emit(fp(20,23,2,6,op))
    p.emit(fp(21,23,2,6,0),fp(21,23,2,6,1),store(0x27,23,528),csr(1,2,24,0))
    p.finish()
    yield p

    rng = random.Random(0xF1523521419)
    for batch in range(8):
        p = Program(f'minmax_random_{batch:02d}')
        for i in range(32):
            p.fl(i, rng.choice(EDGES) if i < 22 else rng.getrandbits(32), i)
        for _ in range(70):
            d,a,b = (rng.randrange(32) for _ in range(3))
            p.emit(fp(20,d,a,b,rng.randrange(2)))
            kind=rng.randrange(6)
            if kind==0: p.emit(csr(1,rng.choice([1,2,3,5,6,7]),d,a))
            elif kind==1: p.emit(fp(0,d,a,b))
            elif kind==2: p.emit(fp(80,d,a,b,rng.randrange(3)))
            elif kind==3: p.emit(store(0x27,d,512+4*rng.randrange(100)))
            elif kind==4: p.emit(fp(4,d,a,b))
            else: p.emit(fp(112,d,a),fp(120,a,d))
        p.finish()
        yield p
