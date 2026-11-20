/*
 * Bare-metal (Vitis 2022.2, Cortex-A53 standalone) for rv32if_xif_soc (fpga/soc_xif).
 * Platform: the .xsa of a "full" build (build/vivado/runs/<run>/out/rv32if_xif_soc.xsa).
 * Output: the board's USB-UART, 115200 8N1.
 *
 *  1. GEMM int8 4x4x16 (P1 of tb/soc_xif, same program as sw/soc_host.py), 5 data sets. The end
 *     of each run comes by interrupt: IRQ_EN = done | timeout, RUN 0 -> 1, the ISR reads
 *     IRQ_STATUS, clears it (W1C) and reads it back before returning (the GIC is level
 *     sensitive, so irq must be low before the end of interrupt).
 *  2. Watchdog: a loop that never reaches jal x0,0, MAX_CYCLES = 10000. One timeout interrupt,
 *     no interrupt storm while the core keeps running; main stops the core with RUN = 0.
 *
 * Register map: docs/soc_xif_ngat_halt.pdf, section 9 (and rtl/core_matrix_xif/rv32if_xif_soc.v).
 */
#include <stdio.h>
#include "xparameters.h"
#include "xil_io.h"
#include "xil_types.h"
#include "xil_exception.h"
#include "xscugic.h"
#include "sleep.h"

#define SOC_BASE    0xA0000000u           /* rv32if_xif_soc registers  */
#define IMEM_BASE   0xA0010000u           /* AXI BRAM Controller, IMEM */
#define DMEM_BASE   0xA0020000u           /* AXI BRAM Controller, DMEM */
#define IMEM_WORDS  (16u * 1024u / 4u)
#define DMEM_WORDS  (64u * 1024u / 4u)
#ifdef XPAR_FABRIC_RVM_IRQ_INTR
#define SOC_IRQ_ID  XPAR_FABRIC_RVM_IRQ_INTR
#else
#define SOC_IRQ_ID  121u                  /* pl_ps_irq0[0] = SPI 89 = interrupt ID 121 */
#endif

enum {
    R_CTRL = 0x00, R_STATUS = 0x04, R_CYCLES = 0x08, R_PC = 0x0C,
    R_MTILEM = 0x10, R_MTILEN = 0x14, R_MTILEK = 0x18, R_MDONE = 0x1C,
    R_MSEL = 0x20, R_MDATA = 0x24, R_ID = 0x28, R_IRQ_EN = 0x2C,
    R_IRQ_STATUS = 0x30, R_EXIT = 0x34, R_MAXC = 0x38, R_CONFIG = 0x3C
};
enum { ST_RUNNING = 1, ST_HALTED = 2, ST_MBUSY = 4, ST_MDONE = 8, ST_TIMEOUT = 16, ST_EXIT = 32 };
enum { IRQ_DONE = 1, IRQ_TIMEOUT = 2 };

#define WR(off, v)     Xil_Out32(SOC_BASE + (off), (v))
#define RD(off)        Xil_In32(SOC_BASE + (off))
#define IMEM_WR(i, v)  Xil_Out32(IMEM_BASE + 4u * (u32)(i), (v))
#define DMEM_WR(a, v)  Xil_Out32(DMEM_BASE + (u32)(a), (v))
#define DMEM_RD(a)     Xil_In32(DMEM_BASE + (u32)(a))

/* ------------------------------------------------------------ instruction encoders */
#define OPC_MATRIX 0x2Bu
#define JAL_SELF   0x0000006Fu
enum { TR0 = 0, TR1 = 1, ACC0 = 4 };

static u32 e_addi(u32 rd, u32 rs1, s32 imm) { return (((u32)imm & 0xFFFu) << 20) | (rs1 << 15) | (rd << 7) | 0x13u; }
static u32 e_lui(u32 rd, u32 imm20)         { return ((imm20 & 0xFFFFFu) << 12) | (rd << 7) | 0x37u; }
static u32 e_lw(u32 rd, u32 rs1, s32 imm)   { return (((u32)imm & 0xFFFu) << 20) | (rs1 << 15) | (2u << 12) | (rd << 7) | 0x03u; }
static u32 e_sw(u32 rs2, u32 rs1, s32 imm)
{
    u32 i = (u32)imm & 0xFFFu;
    return ((i >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (2u << 12) | ((i & 0x1Fu) << 7) | 0x23u;
}
static u32 e_jal(u32 rd, s32 off)
{
    u32 i = (u32)off & 0x1FFFFFu;
    return (((i >> 20) & 1u) << 31) | (((i >> 1) & 0x3FFu) << 21) | (((i >> 11) & 1u) << 20) |
           (((i >> 12) & 0xFFu) << 12) | (rd << 7) | 0x6Fu;
}
static u32 enc_cfg(u32 f4, u32 uimm10) { return (f4 << 28) | ((uimm10 & 0x3FFu) << 15) | OPC_MATRIX; }
static u32 enc_ls(u32 f4, u32 st, u32 rs2, u32 rs1, u32 dsz, u32 md)
{
    return (f4 << 28) | (1u << 26) | (st << 25) | (rs2 << 20) | (rs1 << 15) | (dsz << 10) | (md << 7) | OPC_MATRIX;
}
static u32 enc_mma(u32 f4, u32 sup, u32 ms2, u32 ssz, u32 ms1, u32 dsz, u32 md)
{
    return (f4 << 28) | (2u << 26) | (sup << 23) | (ms2 << 20) | (ssz << 18) | (ms1 << 15) | (dsz << 10) | (md << 7) | OPC_MATRIX;
}
static int li(u32 *p, u32 rd, u32 v)                 /* lui + addi, as rv32if_asm.svh */
{
    u32 lo = v & 0xFFFu;
    p[0] = e_lui(rd, (v + 0x800u) >> 12);
    p[1] = e_addi(rd, rd, (lo & 0x800u) ? (s32)lo - 0x1000 : (s32)lo);
    return 2;
}

/* ------------------------------------------------------------ interrupt */
static XScuGic gic;
static volatile u32 isr_count, isr_status, isr_after_w1c, isr_cycles, isr_exit;

static void soc_isr(void *ref)
{
    (void)ref;
    u32 st = RD(R_IRQ_STATUS);
    if (st & IRQ_DONE) {
        isr_cycles = RD(R_CYCLES);
        isr_exit = RD(R_EXIT);
    }
    WR(R_IRQ_STATUS, st);                  /* W1C: irq falls in the cycle of this write       */
    isr_after_w1c = RD(R_IRQ_STATUS);      /* read back: the posted write has reached the IP  */
    isr_status |= st;
    isr_count++;
}

static int gic_init(void)
{
    XScuGic_Config *cfg = XScuGic_LookupConfig(XPAR_SCUGIC_SINGLE_DEVICE_ID);
    if (cfg == NULL || XScuGic_CfgInitialize(&gic, cfg, cfg->CpuBaseAddress) != XST_SUCCESS) return -1;
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT, (Xil_ExceptionHandler)XScuGic_InterruptHandler, &gic);
    XScuGic_SetPriorityTriggerType(&gic, SOC_IRQ_ID, 0xA0, 0x1);   /* 0x1 = level, active high */
    if (XScuGic_Connect(&gic, SOC_IRQ_ID, (Xil_InterruptHandler)soc_isr, NULL) != XST_SUCCESS) return -1;
    XScuGic_Enable(&gic, SOC_IRQ_ID);
    Xil_ExceptionEnable();
    return 0;
}

/* ------------------------------------------------------------ SoC helpers */
static int errors;
static void check(const char *what, u32 got, u32 want)
{
    if (got != want) {
        errors++;
        printf("  [FAIL] %s: 0x%08x, expected 0x%08x\r\n", what, (unsigned)got, (unsigned)want);
    }
}

/* Core in reset, both memories cleared (as after configuration), program into IMEM. */
static void soc_load(const u32 *prog, int n)
{
    WR(R_CTRL, 0);
    for (u32 i = 0; i < IMEM_WORDS; i++) IMEM_WR(i, i < (u32)n ? prog[i] : 0u);
    for (u32 i = 0; i < DMEM_WORDS; i++) DMEM_WR(4u * i, 0u);
}

/* RUN 0 -> 1 with the watchdog and both interrupts on; wait for the ISR. */
static int soc_run(u32 max_cycles, u32 timeout_us)
{
    WR(R_CTRL, 0);
    WR(R_MAXC, max_cycles);
    WR(R_IRQ_EN, IRQ_DONE | IRQ_TIMEOUT);
    isr_count = 0;
    isr_status = 0;
    WR(R_CTRL, 1);                         /* clears CYCLES, MDONE_CNT, IRQ_STATUS, EXIT_CODE */
    for (u32 t = 0; isr_count == 0; t++) {
        if (t >= timeout_us) {
            printf("  [FAIL] no interrupt: PC=0x%08x STATUS=0x%x CYCLES=%u\r\n",
                   (unsigned)RD(R_PC), (unsigned)RD(R_STATUS), (unsigned)RD(R_CYCLES));
            errors++;
            return -1;
        }
        usleep(1);
    }
    return 0;
}

static u32 mreg_read(u32 id, u32 row, u32 beat)
{
    WR(R_MSEL, (beat << 16) | (row << 8) | id);
    return RD(R_MDATA);
}

/* ------------------------------------------------------------ 1. GEMM int8 4x4x16 */
#define A_AD 0x000u
#define B_AD 0x040u
#define C_AD 0x080u
#define D_AD 0x0C0u
#define FLAG_AD 0x3F0u
#define TOHOST 0x3FF0u

static u32 lcg = 1u;
static u32 rnd(void) { lcg = lcg * 1103515245u + 12345u; return lcg >> 8; }

static void test_gemm(int runs)
{
    u32 prog[40];
    int n = 0;
    n += li(prog + n, 10, A_AD); n += li(prog + n, 11, B_AD);
    n += li(prog + n, 12, C_AD); n += li(prog + n, 13, D_AD);
    prog[n++] = e_addi(14, 0, 16);
    prog[n++] = enc_cfg(2, 4); prog[n++] = enc_cfg(3, 4); prog[n++] = enc_cfg(1, 16);   /* msettile m n k */
    prog[n++] = enc_ls(0, 0, 14, 10, 0, TR0);                                          /* mlae8  tr0     */
    prog[n++] = enc_ls(1, 0, 14, 11, 0, TR1);                                          /* mlbe8  tr1     */
    prog[n++] = enc_ls(2, 0, 14, 12, 2, ACC0);                                         /* mlce32 acc0    */
    prog[n++] = enc_mma(1, 3, TR1, 0, TR0, 2, ACC0);                                   /* mmacc.w.b      */
    prog[n++] = enc_ls(2, 1, 14, 13, 2, ACC0);                                         /* msce32 acc0    */
    prog[n++] = e_lw(20, 13, 0);
    prog[n++] = e_addi(20, 20, 1);
    prog[n++] = e_sw(20, 0, FLAG_AD);                                                  /* D[0][0] + 1    */
    prog[n++] = e_addi(21, 0, 1);
    n += li(prog + n, 22, TOHOST);
    prog[n++] = e_sw(21, 22, 0);                                                       /* TOHOST = 1     */
    prog[n++] = JAL_SELF;
    const u32 jal_addr = 4u * (u32)(n - 1);

    printf("1. GEMM int8 4x4x16, %d data sets, end by interrupt\r\n", runs);
    for (int run = 0; run < runs; run++) {
        static s8 A[4][16], B[4][16];
        static u32 C[4][4], E[4][4];
        int e0 = errors;
        for (int r = 0; r < 4; r++) {
            for (int k = 0; k < 16; k++) { A[r][k] = (s8)rnd(); B[r][k] = (s8)rnd(); }
            for (int c = 0; c < 4; c++) C[r][c] = rnd() & 0xFFFFFFu;
        }
        A[0][0] = B[0][0] = -128;
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) {
                u32 s = C[i][j];
                for (int k = 0; k < 16; k++) s += (u32)((s32)A[i][k] * (s32)B[j][k]);
                E[i][j] = s;
            }

        soc_load(prog, n);
        for (int r = 0; r < 4; r++)
            for (int b = 0; b < 4; b++) {
                u32 wa = 0, wb = 0;
                for (int x = 3; x >= 0; x--) {
                    wa = (wa << 8) | (u8)A[r][4 * b + x];
                    wb = (wb << 8) | (u8)B[r][4 * b + x];
                }
                DMEM_WR(A_AD + 16u * r + 4u * b, wa);
                DMEM_WR(B_AD + 16u * r + 4u * b, wb);
                DMEM_WR(C_AD + 16u * r + 4u * b, C[r][b]);
            }

        if (soc_run(1000000u, 100000u) != 0) continue;
        u32 st = RD(R_STATUS), cyc = RD(R_CYCLES), pc = RD(R_PC);
        printf("  run %d: CYCLES %u (%u.%02u us at 100 MHz), PC 0x%08x, MDONE_CNT %u, EXIT_CODE %u\r\n",
               run + 1, (unsigned)cyc, (unsigned)(cyc / 100u), (unsigned)(cyc % 100u), (unsigned)pc,
               (unsigned)RD(R_MDONE), (unsigned)RD(R_EXIT));
        check("interrupts", isr_count, 1);
        check("IRQ_STATUS in the ISR", isr_status, IRQ_DONE);
        check("IRQ_STATUS after W1C (ISR)", isr_after_w1c, 0);
        check("STATUS", st & 0x3Fu, ST_RUNNING | ST_HALTED | ST_MDONE | ST_EXIT);
        check("CYCLES (ISR) = CYCLES (now)", isr_cycles, cyc);
        check("EXIT_CODE", isr_exit, 1);
        check("MDONE_CNT", RD(R_MDONE), 8);
        check("MTILEM", RD(R_MTILEM), 4);
        check("MTILEN", RD(R_MTILEN), 4);
        check("MTILEK", RD(R_MTILEK), 16);
        if (pc < jal_addr || pc > jal_addr + 12u) check("PC (jal x0,0 + 0..12)", pc, jal_addr);
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++) {
                check("acc0 (MREG, RUN = 1)", mreg_read(ACC0, (u32)i, (u32)j), E[i][j]);
                check("D (DMEM)", DMEM_RD(D_AD + 16u * i + 4u * j), E[i][j]);
            }
        check("DMEM[0x3F0] = D[0][0] + 1", DMEM_RD(FLAG_AD), E[0][0] + 1u);
        WR(R_CTRL, 0);
        check("CYCLES kept after RUN = 0", RD(R_CYCLES), cyc);
        check("interrupts after RUN = 0", isr_count, 1);
        printf("  run %d: %s\r\n", run + 1, errors == e0 ? "PASS" : "FAIL");
    }
}

/* ------------------------------------------------------------ 2. watchdog */
static void test_watchdog(void)
{
    const u32 max = 10000u;
    u32 prog[2] = { e_addi(1, 1, 1), e_jal(0, -4) };          /* endless loop, never jal x0,0 */
    int e0 = errors;
    printf("2. Watchdog: endless loop, MAX_CYCLES = %u\r\n", (unsigned)max);
    soc_load(prog, 2);
    if (soc_run(max, 100000u) == 0) {
        u32 st = RD(R_STATUS), c1 = RD(R_CYCLES);
        check("interrupts", isr_count, 1);
        check("IRQ_STATUS in the ISR", isr_status, IRQ_TIMEOUT);
        check("IRQ_STATUS after W1C (ISR)", isr_after_w1c, 0);
        check("STATUS running | timeout, not halted", st & (ST_RUNNING | ST_HALTED | ST_TIMEOUT),
              ST_RUNNING | ST_TIMEOUT);
        check("CYCLES >= MAX_CYCLES", c1 >= max, 1);
        usleep(100);                                            /* core still running */
        check("CYCLES still counting", RD(R_CYCLES) > c1, 1);
        check("no further interrupt (no storm)", isr_count, 1);
        printf("  timeout after %u cycles, PC 0x%08x\r\n", (unsigned)c1, (unsigned)RD(R_PC));
    }
    WR(R_CTRL, 0);
    check("STATUS running = 0 after RUN = 0", RD(R_STATUS) & ST_RUNNING, 0);
    printf("  %s\r\n", errors == e0 ? "PASS" : "FAIL");
}

int main(void)
{
    printf("\r\n== rv32if_xif_soc: registers 0x%08x, IMEM 0x%08x, DMEM 0x%08x, IRQ %u ==\r\n",
           SOC_BASE, IMEM_BASE, DMEM_BASE, (unsigned)SOC_IRQ_ID);
    u32 id = RD(R_ID), cfg = RD(R_CONFIG);
    if (id != 0x4B4C544Eu) {
        printf("ID = 0x%08x: wrong (bitstream not loaded?)\r\n", (unsigned)id);
        return 1;
    }
    printf("CONFIG 0x%08x: version %u, IMEM %u KB, DMEM %u KB, CV-X-IF %u\r\n", (unsigned)cfg,
           (unsigned)(cfg & 0xFFu), (unsigned)((1u << ((cfg >> 8) & 0xFFu)) / 1024u),
           (unsigned)((1u << ((cfg >> 16) & 0xFFu)) / 1024u), (unsigned)((cfg >> 24) & 1u));
    if (gic_init() != 0) {
        printf("GIC setup failed\r\n");
        return 1;
    }
    test_gemm(5);
    test_watchdog();
    printf("RESULT: %s (%d errors)\r\n", errors ? "FAIL" : "PASS", errors);
    return errors != 0;
}
