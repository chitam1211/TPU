#!/usr/bin/env python3
"""
Dieu khien rv32if_matrix_axi tren KR260 tu Linux (PS) qua AXI4-Lite tai 0xA000_0000.

Hai cach nap bitstream:
  * Kria-PYNQ:    sudo python3 rvm_host.py --bit rv32if_matrix.bit           (can .hwh cung ten)
  * Kria Ubuntu:  sudo xmutil unloadapp; sudo fpgautil -b rv32if_matrix.bin -o rv32if_matrix.dtbo
                  sudo python3 rvm_host.py                                    (dung /dev/mem)

Che do:
  (mac dinh)      demo: mmacc.w.b 4x4x16 int8 + scalar, so ket qua voi Python
  --hex FILE      nap chuong trinh (1 word hex/dong), chay, in DMEM (--dump N word)
"""
import argparse
import mmap
import os
import random
import struct
import sys
import time

BASE, SPAN = 0xA0000000, 0x4000

CTRL, STATUS, CYCLES, PC = 0x00, 0x04, 0x08, 0x0C
MTILEM, MTILEN, MTILEK, MDONE = 0x10, 0x14, 0x18, 0x1C
MSEL, MDATA, ID = 0x20, 0x24, 0x28
IMEM, DMEM = 0x1000, 0x2000
MEM_WORDS = 256
HALT_CYCLES = 64          # CYCLES gom ca HALT_CYCLES chu ky phat hien dung

NOP, JAL_SELF = 0x00000013, 0x0000006F
TR0, TR1, TR2, TR3, ACC0, ACC1, ACC2, ACC3 = range(8)


class DevMem:
    def __init__(self, base=BASE, span=SPAN):
        fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.m = mmap.mmap(fd, span, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
        os.close(fd)

    def read(self, off):
        return struct.unpack_from("<I", self.m, off)[0]

    def write(self, off, val):
        struct.pack_into("<I", self.m, off, val & 0xFFFFFFFF)


class RVM:
    def __init__(self, bus):
        self.bus = bus
        ident = bus.read(ID)
        if ident != 0x4B4C544E:
            raise RuntimeError(f"ID = 0x{ident:08x}, khong phai rv32if_matrix_axi (bitstream chua nap?)")

    def stop(self):
        self.bus.write(CTRL, 0)

    def start(self):
        self.bus.write(CTRL, 1)

    def load_program(self, words):
        if len(words) > MEM_WORDS:
            raise ValueError("chuong trinh > 256 word")
        self.stop()
        for i in range(MEM_WORDS):
            self.bus.write(IMEM + 4 * i, words[i] if i < len(words) else NOP)
        for i, w in enumerate(words):
            if self.bus.read(IMEM + 4 * i) != w:
                raise RuntimeError(f"IMEM[{i}] doc lai sai")

    def write_dmem(self, byte_addr, words):
        for i, w in enumerate(words):
            self.bus.write(DMEM + byte_addr + 4 * i, w)

    def read_dmem(self, byte_addr, n):
        return [self.bus.read(DMEM + byte_addr + 4 * i) for i in range(n)]

    def run(self, timeout_s=1.0):
        self.stop()
        self.start()
        t0 = time.time()
        while not (self.bus.read(STATUS) & 0x2):
            if time.time() - t0 > timeout_s:
                raise TimeoutError(f"core khong dung, PC=0x{self.bus.read(PC):08x} STATUS=0x{self.bus.read(STATUS):x}")
        return self.bus.read(CYCLES) - HALT_CYCLES

    def mreg_sel(self, reg, row, beat):
        self.bus.write(MSEL, (beat << 16) | (row << 8) | reg)

    def mreg_read(self, reg, row, beat):
        self.mreg_sel(reg, row, beat)
        return self.bus.read(MDATA)

    def mreg_write(self, reg, row, beat, val):
        self.mreg_sel(reg, row, beat)
        self.bus.write(MDATA, val)


# ---------------- Ma hoa lenh (giong Verify/common/tb_matrix_pkg.sv) ----------------
OPC_MATRIX = 0b0101011


def e_addi(rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0b0010011


def e_add(rd, rs1, rs2):
    return (rs2 << 20) | (rs1 << 15) | (rd << 7) | 0b0110011


def e_sw(rs2, rs1, imm):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (0b010 << 12) | ((imm & 0x1F) << 7) | 0b0100011


def enc_cfg(func4, uimm10):
    return (func4 << 28) | (uimm10 << 15) | OPC_MATRIX


def enc_ls(func4, is_store, rs2, rs1, d_size, md):
    return (func4 << 28) | (0b01 << 26) | (is_store << 25) | (rs2 << 20) | (rs1 << 15) | (d_size << 10) | (md << 7) | OPC_MATRIX


def enc_mma(func4, size_sup, ms2, s_size, ms1, d_size, md):
    return ((func4 << 28) | (0b10 << 26) | (size_sup << 23) | (ms2 << 20) | (s_size << 18)
            | (ms1 << 15) | (d_size << 10) | (md << 7) | OPC_MATRIX)


def s8(b):
    return b - 256 if b >= 128 else b


def demo(rvm):
    prog = [
        e_addi(1, 0, 0x000), e_addi(2, 0, 16), e_addi(3, 0, 0x040), e_addi(4, 0, 0x080),
        e_addi(9, 0, 0x200), e_addi(20, 0, 100), e_addi(21, 0, 23), NOP, NOP, NOP,
        e_add(22, 20, 21), NOP, NOP, NOP,
        e_sw(22, 0, 0x300),                                   # mem[0x300] = 123
        enc_cfg(0b0010, 4), enc_cfg(0b0011, 4), enc_cfg(0b0001, 16),   # msettile{m,n,k}i
        enc_ls(0b0000, 0, 2, 1, 0b00, TR0),                   # mlae8  tr0, (x1), x2
        enc_ls(0b0001, 0, 2, 3, 0b00, TR1),                   # mlbe8  tr1, (x3), x2
        enc_ls(0b0010, 0, 2, 4, 0b10, ACC0),                  # mlce32 acc0, (x4), x2
        enc_mma(0b0001, 0b011, TR1, 0b00, TR0, 0b10, ACC0),   # mmacc.w.b acc0, tr1, tr0
        enc_ls(0b0010, 1, 2, 9, 0b10, ACC0),                  # msce32 acc0, (x9), x2
        NOP, NOP, JAL_SELF,
    ]
    A = [[random.randrange(256) for _ in range(16)] for _ in range(4)]
    B = [[random.randrange(256) for _ in range(16)] for _ in range(4)]
    C = [[random.randrange(1 << 32) for _ in range(4)] for _ in range(4)]

    def pack(row):
        return [row[4 * b] | row[4 * b + 1] << 8 | row[4 * b + 2] << 16 | row[4 * b + 3] << 24 for b in range(4)]

    rvm.load_program(prog)
    for r in range(4):
        rvm.write_dmem(0x000 + 16 * r, pack(A[r]))
        rvm.write_dmem(0x040 + 16 * r, pack(B[r]))
        rvm.write_dmem(0x080 + 16 * r, C[r])
    rvm.write_dmem(0x200, [0] * 64)

    cycles = rvm.run()
    print(f"halted: {cycles} chu ky, {rvm.bus.read(MDONE)} lenh ma tran, "
          f"mtile = {rvm.bus.read(MTILEM)}x{rvm.bus.read(MTILEN)}x{rvm.bus.read(MTILEK)}")

    exp = [[(C[i][j] + sum(s8(A[i][k]) * s8(B[j][k]) for k in range(16))) & 0xFFFFFFFF
            for j in range(4)] for i in range(4)]
    errors = 0
    for i in range(4):                                    # acc0 qua MREG (truoc khi stop)
        for j in range(4):
            v = rvm.mreg_read(ACC0, i, j)
            if v != exp[i][j]:
                errors += 1
                print(f"[FAIL] acc0[{i}][{j}] = 0x{v:08x}, expected 0x{exp[i][j]:08x}")
    rvm.stop()
    for i in range(4):
        got = rvm.read_dmem(0x200 + 16 * i, 4)
        for j in range(4):
            if got[j] != exp[i][j]:
                errors += 1
                print(f"[FAIL] C'[{i}][{j}] = 0x{got[j]:08x}, expected 0x{exp[i][j]:08x}")
    scalar = rvm.read_dmem(0x300, 1)[0]
    if scalar != 123:
        errors += 1
        print(f"[FAIL] mem[0x300] = {scalar}, expected 123")
    print("RESULT:", "PASS" if errors == 0 else f"FAIL ({errors} errors)")
    return errors == 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bit", help="nap bitstream bang PYNQ Overlay (.bit, can .hwh cung ten)")
    ap.add_argument("--hex", help="chuong trinh: moi dong 1 word hex")
    ap.add_argument("--dmem", help="du lieu DMEM ban dau: moi dong 1 word hex, tu dia chi 0")
    ap.add_argument("--dump", type=int, default=64, help="so word DMEM in ra sau khi chay (--hex)")
    args = ap.parse_args()

    if args.bit:
        from pynq import Overlay, MMIO
        Overlay(args.bit)
        bus = MMIO(BASE, SPAN)
    else:
        bus = DevMem()
    rvm = RVM(bus)

    if not args.hex:
        sys.exit(0 if demo(rvm) else 1)

    def read_hex(path):
        with open(path) as f:
            return [int(l.split("//")[0].strip(), 16) for l in f if l.split("//")[0].strip()]

    rvm.load_program(read_hex(args.hex))
    if args.dmem:
        rvm.write_dmem(0, read_hex(args.dmem))
    cycles = rvm.run()
    print(f"halted: {cycles} chu ky, PC=0x{bus.read(PC):08x}, {bus.read(MDONE)} lenh ma tran")
    rvm.stop()
    for i, w in enumerate(rvm.read_dmem(0, args.dump)):
        print(f"0x{4 * i:03x}: {w:08x}")


if __name__ == "__main__":
    main()
