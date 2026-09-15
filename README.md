# KLTN - RISC-V RV32IF with FP32 Matrix Extension

## Overview

This repository contains the graduation thesis project:

**Designing a microprocessor based on the RISC-V RV32IF instruction set architecture with floating-point matrix extension.**

The project extends the previous RV32I processor and integer matrix coprocessor by adding:

- RV32IF 5-stage pipelined processor
- Floating-point register file
- Scalar FP32 instruction support
- FP32 matrix operations
- Matrix coprocessor integration
- RTL verification and ISA-based reference checking
- FPGA-oriented implementation and evaluation

## Project Structure

```text
TPU/
└── kltn/
    ├── rtl/
    │   ├── core/        # RV32I baseline
    │   ├── core_if/     # RV32IF development
    │   └── matrix/      # Matrix coprocessor
    │
    ├── tb/              # RTL testbenches
    ├── assembler/       # Instruction assembler
    ├── iss/             # Instruction set simulator
    ├── scripts/         # Test and utility scripts
    ├── constraints/     # FPGA constraints
    ├── docs/            # Project documentation
    └── reports/         # Development reports
```

## Current Development

The current development focuses on extending the RV32I baseline processor to RV32IF.

Current work includes:

- Integer register file fixes
- FP32 register file
- FLW and FSW support
- FP32 FADD.S and FSUB.S execution
- FCSR, rounding mode, and floating-point exception support
- RTL testbenches for scalar floating-point functions
- Pipeline control and hazard handling for floating-point instructions

The matrix subsystem currently contains the inherited integer matrix accelerator and will be extended with FP32 matrix processing.

## Matrix Extension Scope

The floating-point matrix extension focuses on FP32 operations.

Planned FP32 matrix instructions include:

- Matrix multiply-accumulate: `mfmacc.s`
- Element-wise addition: `mfadd.s.mm`
- Element-wise subtraction: `mfsub.s.mm`
- Element-wise multiplication: `mfmul.s.mm`
- Element-wise maximum: `mfmax.s.mm`
- Element-wise minimum: `mfmin.s.mm`

The project does not target FP8, FP16, BF16, FP64, or mixed-precision matrix operations.

## Verification

The design is verified using:

- RTL unit testbenches
- Integration testbenches
- Controlled and randomized test cases
- ISA reference model comparison
- Cycle and CPI measurements
- FPGA synthesis reports

FPGA evaluation focuses on:

- FMAX
- LUT usage
- Flip-flop usage
- BRAM usage

## Development Directory

Main project directory:

```bash
cd kltn
```

## Main RTL Directories

```text
kltn/rtl/core/
```

Original RV32I baseline used as a reference.

```text
kltn/rtl/core_if/
```

Active RV32IF processor development.

```text
kltn/rtl/matrix/
```

Matrix coprocessor and matrix execution units.

## Testbench Directory

```text
kltn/tb/
```

Contains RTL testbenches for the processor and floating-point modules.

## Scripts

```text
kltn/scripts/
```

Contains scripts used for test generation and regression testing.

## Notes

Generated simulation files, build outputs, logs, waveform files, archives, and local reference documents are excluded from version control through `.gitignore`.
