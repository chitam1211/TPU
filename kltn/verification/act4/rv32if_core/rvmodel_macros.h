#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

/*
 * ACT4 places tohost/fromhost in the test ELF.
 * The testbench observes stores to the address of tohost.
 */
#define RVMODEL_DATA_SECTION \
.pushsection .tohost,"aw",@progbits; \
.balign 8; \
.global tohost; \
tohost: .dword 0; \
.balign 8; \
.global fromhost; \
fromhost: .dword 0; \
.popsection;

/*
 * This core currently runs bare-metal tests without privileged boot code.
 */
#define RVMODEL_BOOT
#define RVMODEL_BOOT_TO_MMODE

/*
 * PASS: write 1 to tohost.
 */
#define RVMODEL_HALT_PASS \
li x1, 1; \
la t0, tohost; \
sw x1, 0(t0); \
sw x0, 4(t0); \
1: j 1b;

/*
 * FAIL: write 3 to tohost.
 */
#define RVMODEL_HALT_FAIL \
li x1, 3; \
la t0, tohost; \
sw x1, 0(t0); \
sw x0, 4(t0); \
1: j 1b;

/*
 * No console is implemented in the verification platform.
 */
#define RVMODEL_IO_INIT(_R1, _R2, _R3)
#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)

/*
 * ACT4 requires an interrupt contract even when the selected F tests do not
 * exercise interrupts. The current DUT has no interrupt source, so the
 * external-interrupt operations are empty. Sail overrides these definitions
 * with its verification-only CLINT and interrupt generator when producing
 * reference signatures.
 */
#define RVMODEL_INTERRUPT_LATENCY 1
#define RVMODEL_TIMER_INT_SOON_DELAY 5000
#define RVMODEL_SET_MEXT_INT(_R1, _R2)
#define RVMODEL_CLR_MEXT_INT(_R1, _R2)
#define RVMODEL_MSIP_ADDRESS 0x02000000

#endif
