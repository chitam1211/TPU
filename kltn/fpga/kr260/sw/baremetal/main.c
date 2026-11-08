/*
 * Bare-metal (Vitis, A53 standalone) cho rv32if_matrix_axi tren KR260.
 * Platform: build/out/rv32if_matrix.xsa. Ket qua in ra UART (USB-UART cua KR260, 115200).
 * Chuong trinh test giong tb/tb_rv32if_matrix_axi.sv va sw/rvm_host.py (mmacc.w.b 4x4x16).
 */
#include <stdio.h>
#include "xil_io.h"
#include "xil_types.h"
#include "sleep.h"

#define RVM_BASE    0xA0000000u
#define R_CTRL      0x00u
#define R_STATUS    0x04u
#define R_CYCLES    0x08u
#define R_PC        0x0Cu
#define R_MTILEM    0x10u
#define R_MTILEN    0x14u
#define R_MTILEK    0x18u
#define R_MDONE     0x1Cu
#define R_MSEL      0x20u
#define R_MDATA     0x24u
#define R_ID        0x28u
#define IMEM        0x1000u
#define DMEM        0x2000u
#define HALT_CYCLES 64u

#define NOP         0x00000013u
#define JAL_SELF    0x0000006Fu
#define OPC_MATRIX  0x2Bu
#define TR0 0u
#define TR1 1u
#define ACC0 4u

#define WR(off, v)  Xil_Out32(RVM_BASE + (off), (v))
#define RD(off)     Xil_In32(RVM_BASE + (off))

static u32 e_addi(u32 rd, u32 rs1, s32 imm) { return (((u32)imm & 0xFFFu) << 20) | (rs1 << 15) | (rd << 7) | 0x13u; }
static u32 e_add(u32 rd, u32 rs1, u32 rs2)  { return (rs2 << 20) | (rs1 << 15) | (rd << 7) | 0x33u; }
static u32 e_sw(u32 rs2, u32 rs1, u32 imm)
{
    imm &= 0xFFFu;
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (2u << 12) | ((imm & 0x1Fu) << 7) | 0x23u;
}
static u32 enc_cfg(u32 f4, u32 uimm10) { return (f4 << 28) | (uimm10 << 15) | OPC_MATRIX; }
static u32 enc_ls(u32 f4, u32 st, u32 rs2, u32 rs1, u32 dsz, u32 md)
{
    return (f4 << 28) | (1u << 26) | (st << 25) | (rs2 << 20) | (rs1 << 15) | (dsz << 10) | (md << 7) | OPC_MATRIX;
}
static u32 enc_mma(u32 f4, u32 sup, u32 ms2, u32 ssz, u32 ms1, u32 dsz, u32 md)
{
    return (f4 << 28) | (2u << 26) | (sup << 23) | (ms2 << 20) | (ssz << 18) | (ms1 << 15) | (dsz << 10) | (md << 7) | OPC_MATRIX;
}

static u32 lcg = 0x1234u;
static u32 rnd(void) { lcg = lcg * 1103515245u + 12345u; return lcg >> 8; }

int main(void)
{
    static s8  A[4][16], B[4][16];
    static u32 C[4][4];
    u32 prog[32];
    int n = 0, errors = 0;

    printf("\r\n== rv32if_matrix_axi @ 0x%08x ==\r\n", RVM_BASE);
    if (RD(R_ID) != 0x4B4C544Eu) {
        printf("ID = 0x%08x: sai, bitstream chua nap?\r\n", (unsigned)RD(R_ID));
        return 1;
    }

    prog[n++] = e_addi(1, 0, 0x000); prog[n++] = e_addi(2, 0, 16);
    prog[n++] = e_addi(3, 0, 0x040); prog[n++] = e_addi(4, 0, 0x080);
    prog[n++] = e_addi(9, 0, 0x200); prog[n++] = e_addi(20, 0, 100);
    prog[n++] = e_addi(21, 0, 23);
    prog[n++] = NOP; prog[n++] = NOP; prog[n++] = NOP;
    prog[n++] = e_add(22, 20, 21);
    prog[n++] = NOP; prog[n++] = NOP; prog[n++] = NOP;
    prog[n++] = e_sw(22, 0, 0x300);
    prog[n++] = enc_cfg(2, 4); prog[n++] = enc_cfg(3, 4); prog[n++] = enc_cfg(1, 16);
    prog[n++] = enc_ls(0, 0, 2, 1, 0, TR0);
    prog[n++] = enc_ls(1, 0, 2, 3, 0, TR1);
    prog[n++] = enc_ls(2, 0, 2, 4, 2, ACC0);
    prog[n++] = enc_mma(1, 3, TR1, 0, TR0, 2, ACC0);
    prog[n++] = enc_ls(2, 1, 2, 9, 2, ACC0);
    prog[n++] = NOP; prog[n++] = NOP; prog[n++] = JAL_SELF;

    WR(R_CTRL, 0);
    for (u32 i = 0; i < 256; i++) WR(IMEM + 4 * i, i < (u32)n ? prog[i] : NOP);

    for (int r = 0; r < 4; r++) {
        for (int k = 0; k < 16; k++) { A[r][k] = (s8)rnd(); B[r][k] = (s8)rnd(); }
        for (int c = 0; c < 4; c++) C[r][c] = rnd() ^ (rnd() << 16);
        for (int b = 0; b < 4; b++) {
            u32 wa = 0, wb = 0;
            for (int x = 3; x >= 0; x--) {
                wa = (wa << 8) | (u8)A[r][4 * b + x];
                wb = (wb << 8) | (u8)B[r][4 * b + x];
            }
            WR(DMEM + 0x000 + 16 * r + 4 * b, wa);
            WR(DMEM + 0x040 + 16 * r + 4 * b, wb);
            WR(DMEM + 0x080 + 16 * r + 4 * b, C[r][b]);
        }
    }
    for (u32 a = 0x200; a < 0x400; a += 4) WR(DMEM + a, 0);

    WR(R_CTRL, 1);
    for (int t = 0; !(RD(R_STATUS) & 2u); t++) {
        if (t > 100000) {
            printf("TIMEOUT: PC=0x%08x STATUS=0x%x\r\n", (unsigned)RD(R_PC), (unsigned)RD(R_STATUS));
            return 1;
        }
        usleep(1);
    }
    printf("halted: %u chu ky, %u lenh ma tran, mtile %ux%ux%u\r\n",
           (unsigned)(RD(R_CYCLES) - HALT_CYCLES), (unsigned)RD(R_MDONE),
           (unsigned)RD(R_MTILEM), (unsigned)RD(R_MTILEN), (unsigned)RD(R_MTILEK));

    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            u32 exp = C[i][j];
            for (int k = 0; k < 16; k++) exp += (u32)((s32)A[i][k] * (s32)B[j][k]);
            WR(R_MSEL, ((u32)j << 16) | ((u32)i << 8) | ACC0);
            u32 m = RD(R_MDATA);
            if (m != exp) { errors++; printf("[FAIL] acc0[%d][%d]=0x%08x exp 0x%08x\r\n", i, j, (unsigned)m, (unsigned)exp); }
        }
    }
    WR(R_CTRL, 0);
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            u32 exp = C[i][j];
            for (int k = 0; k < 16; k++) exp += (u32)((s32)A[i][k] * (s32)B[j][k]);
            u32 d = RD(DMEM + 0x200 + 16 * i + 4 * j);
            if (d != exp) { errors++; printf("[FAIL] C'[%d][%d]=0x%08x exp 0x%08x\r\n", i, j, (unsigned)d, (unsigned)exp); }
        }
    }
    if (RD(DMEM + 0x300) != 123u) { errors++; printf("[FAIL] mem[0x300]=%u\r\n", (unsigned)RD(DMEM + 0x300)); }

    printf("RESULT: %s (%d errors)\r\n", errors ? "FAIL" : "PASS", errors);
    return errors != 0;
}
