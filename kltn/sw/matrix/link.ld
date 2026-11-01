/* Code at 0x0000-0x0FFF, data from 0x1000 (inside the range tb_matrix_regress.sv dumps:
   0x1000-0x3FEF), stack below 0x3F00, TOHOST at 0x3FF0. The testbench loads the whole image,
   so data needs no copy at start-up and .bss is already zero. */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
    . = 0x0;
    .text : { *(.text.init) *(.text .text.*) }
    ASSERT(. <= 0x1000, "code does not fit below 0x1000")
    . = 0x1000;
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
    .data   : { *(.data .data.* .sdata .sdata.*) }
    .bss    : { *(.bss .bss.* .sbss .sbss.* COMMON) }
    ASSERT(. <= 0x3E00, "data overlaps the stack")
    /DISCARD/ : { *(.comment) *(.note*) *(.riscv.attributes) }
}
