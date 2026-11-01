# Bare-metal start for tb/matrix/tb_matrix_regress.sv: set the stack, run main, then store 1
# to TOHOST (0x3FF0), which ends the simulation and dumps the state.
    .section .text.init
    .globl _start
_start:
    li   sp, 0x3F00
    call main
    li   t0, 0x3FF0
    li   t1, 1
    sw   t1, 0(t0)
1:  j    1b
