# TPU Simulator - RISC-V Matrix Extension

## Overview
This project is an instruction set simulator for the RISC-V Matrix Extension. It supports these instruction groups:

- Matrix multiply-accumulate
- Load and store
- Elementwise operations
- Configuration

## Requirements

- Python 3.8 or newer
- numpy is optional and only needed for float16 tests

Optional Python packages:

- numpy for float16 tests
- streamlit and pandas for the web app

Standard library modules used include struct, random, subprocess, pathlib, os, sys, re, math.

## Setup

### Quick start
```bash
git clone <repository-url>
cd TPU
python validate_setup.py
```

Optional installs:
```bash
pip install numpy
pip install streamlit pandas
```

## Setup checklist

Follow these steps on a new machine.

### Step 1. Clone the repository
```bash
git clone https://github.com/chitam1211/TPU.git
cd TPU
git checkout oop_ver
```

### Step 2. Check the Python version
```bash
python --version
```

Required: Python 3.8 or newer.

### Step 3. Run the validation script
```bash
python validate_setup.py
```

If all checks pass, skip Step 4 and go to Step 5.

### Step 4. Fix common issues

Error: Cannot import iss
```bash
pwd
```

You should be in the project root directory, not inside iss.

Error: Python version too old
```bash
python3.10 --version
```

Error: Missing files
```bash
git pull origin oop_ver
git status
```

Warning: numpy not installed
```bash
pip install numpy
```

### Step 5. Run a quick simulator test
```bash
python -m iss.run_simulator
```

Optional test script:
```bash
cd iss
python test_loadstore.py
```

### Step 6. VS Code setup

1. Open the TPU folder in VS Code
2. Install the Python extension (ms-python.python)
3. Install the Pylance extension (ms-python.vscode-pylance)
4. Reload the window
5. Check the Problems panel for errors

### Step 7. Final validation
```bash
python validate_setup.py
```

Expected result:
```
Passed: 9/9
ALL CHECKS PASSED
```

## Advanced troubleshooting

Windows encoding errors:
```powershell
$env:PYTHONIOENCODING="utf-8"
python -m iss.run_simulator
```

Pylance attribute not found:

This is addressed in .vscode/settings.json. Reload the VS Code window if it persists.

Import errors with __init__.py present:
```bash
rm -rf iss/__pycache__
rm -rf assembler/__pycache__
```

On Windows:
```powershell
rmdir /s iss\__pycache__
rmdir /s assembler\__pycache__
```

After all checks pass, you can:

- Run the simulator: python -m iss.run_simulator
- Run the assembler: cd assembler and python assembler.py
- Run tests: cd iss and python test_loadstore.py
- Commit changes: git add . and git commit -m "message" and git push

## Project layout
```
TPU/
├── assembler/          # Assembly encoder
│   ├── assembler.py
│   ├── assembly.txt    # Input assembly
│   └── machine_code.txt # Output machine code
│
├── iss/                # Instruction set simulator
│   ├── iss.py          # Main simulator
│   ├── components.py   # CPU components
│   ├── definitions.py  # Constants and definitions
│   ├── converters.py   # Float and int converters
│   ├── logic_*.py      # Instruction logic
│   ├── state_manager.py
│   ├── run_simulator.py
│   ├── test_loadstore.py
│   └── *.txt           # State files
│
└── README.md
```

## Usage

### Run the simulator
```bash
python -m iss.run_simulator
```

### Run load and store tests
```bash
cd iss
python test_loadstore.py
```

The test script runs five cases:

1. mlae32 and msae32 for float32 load and store
2. mlae16 and msae16 for float16 load and store
3. mlbe8 and msbe8 for int8 load and store
4. mlce32 and msce32 for float32 column load and store
5. mlce8 and msce8 for int8 column load and store

### Basic workflow

1. Write assembly code to assembler/assembly.txt
2. Run the assembler: cd assembler and python assembler.py
3. Run the simulator: cd .. and python -m iss.run_simulator
4. Inspect state files in iss/

## State files in iss

- memory.txt - RAM contents
- gpr.txt - 32 general purpose registers
- matrix.txt - tile registers, integer
- matrix_float.txt - tile registers, float
- acc.txt - accumulator registers, integer
- acc_float.txt - accumulator registers, float
- config.txt - CSR configuration registers
- status.txt - status flags

## Troubleshooting

### Import errors
If you see ModuleNotFoundError or cannot import name:

- Run from the project root directory
- Use python -m iss.run_simulator instead of python iss/run_simulator.py

### Float16 errors
If test_loadstore.py fails on float16:
```bash
pip install numpy
```

### Windows encoding errors
If you see UnicodeEncodeError:

- The code attempts to set UTF-8 automatically
- You can also set PYTHONIOENCODING to utf-8

## Features

### Simulator

- Matrix multiply-accumulate, signed, unsigned, and mixed
- Float operations, FP16, FP32, BF16
- Load and store, alignment, block, and column modes
- Elementwise operations
- Configuration via CSR
- RAM simulation and state persistence to text files

### Test scripts

- Random data generation
- Sequential testing
- Automatic verification
- Detailed result display

## Binary printing

The test scripts can print binary instruction encodings and register values.

What it shows:

- 32 bit instruction encoding
- 512 bit register dumps split into four 128 bit chunks, little endian

Key module:

- iss/binary_print_utils.py provides instruction and register formatting helpers

Tests that use it:

- iss/test_elementwise.py
- iss/test_matmul.py
- iss/test_loadstore.py
- iss/test_misc.py

Example commands:

```bash
cd iss
python test_elementwise.py --auto
python test_matmul.py --auto
python test_loadstore.py --auto
python test_misc.py --auto
```

Data type notes:

- float32 and int32 produce full 512 bit output
- float16 and int8 are padded to 512 bits

## Contributing
To report bugs or contribute, please open an issue or a pull request.


