# RV32I Pipeline + Matrix Core Integration

This is an experimental CPU-swap path using:

- `../rv32i-pipeline-processor`: cloned 5-stage RISC-V CPU repository.
- `../rv32i-pipeline-processor/rv32i-pipeline-processor/src`: original RV32I CPU source.
- `../rv32i-pipeline-processor/rme_rtl/core_matrix.v`: copied/modified CPU core that issues matrix custom instructions.
- `../rv32i-pipeline-processor/rme_rtl/matrix_core_v2.sv`: copied matrix datapath without DMA/AXI.
- `picorv32-matrix-coprocessor/sim/tb_rv32i_matrix_core.sv`: demo testbench.

The `rv32i-pipeline-processor` subfolder was chosen instead of `rv32im-pipeline-processor`
because the matrix custom-instruction demo only needs base RV32I fetch/decode/pipeline flow.
The RV32IM version adds integer multiply/divide support that is not needed for proving the
matrix datapath integration.

The PicoRV32 coprocessor RTL remains unchanged. The RV32I path keeps its own copied
matrix modules under `../rv32i-pipeline-processor/rme_rtl` so this experiment can evolve
independently.

## What Works

The pipeline CPU fetches matrix custom instructions with opcode `7'b0101011`
and sends them into `matrix_core_v2`.

The demo executes:

- `msettilemi 4`
- `msettileni 4`
- `msettileki 4`
- `mzero acc0`
- `mmaccu.w.b acc0, tr0, tr1`

Matrix data is preloaded through the simple host regfile port, not through DMA.
The testbench checks:

```text
A =
1   2   3   4
5   6   7   8
9   10  11  12
13  14  15  16

B =
1   2   3   4
5   6   7   8
9   10  11  12
13  14  15  16

C =
90   100  110  120
202  228  254  280
314  356  398  440
426  484  542  600
```

## Current Limitation

This is a low-intrusion bridge, not a full custom-instruction pipeline
integration yet. The cloned CPU does not currently stall the whole pipeline
while the matrix core is busy.

Because of that, the demo leaves enough NOPs between matrix instructions.
The next serious step is to add a matrix busy/ready stall path to:

- program counter
- fetch/decode pipeline register
- decode/execute pipeline register
- custom instruction writeback path, if a matrix instruction writes a GPR

## Run

From repository root:

```powershell
powershell -ExecutionPolicy Bypass -File picorv32-matrix-coprocessor\tools\run_rv32i_matrix_demo.ps1
```

Expected terminal marker:

```text
RV32I_MATRIX_CORE_TEST_PASS
```
