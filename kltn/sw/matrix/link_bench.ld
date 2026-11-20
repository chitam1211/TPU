/* Benchmark layout for larger matrices: code at 0x0000-0x0FFF, stack below 0x3F00 (MARK at
   0x3FE0 and TOHOST at 0x3FF0 stay free), data from 0x4000 to the end of the 64 KiB RAM of
   tb_matrix_regress.sv (dump the C arrays with +dump_lo/+dump_hi). */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
    . = 0x0;
    .text : { *(.text.init) *(.text .text.*) }
    ASSERT(. <= 0x1000, "code does not fit below 0x1000")
    . = 0x4000;
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
    .data   : { *(.data .data.* .sdata .sdata.*) }
    .bss    : { *(.bss .bss.* .sbss .sbss.* COMMON) }
    ASSERT(. <= 0x10000, "data does not fit in 64 KiB")
    /DISCARD/ : { *(.comment) *(.note*) *(.riscv.attributes) }
}
