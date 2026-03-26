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

## Setup

### 1. Clone the repository
```bash
git clone <repository-url>
cd TPU
```

### 2. Validate the setup (recommended on a new machine)
```bash
python validate_setup.py
```

This script checks:

- Python version
- Project structure
- Module imports
- Mixin classes
- Required attributes
- UTF-8 encoding support

### 2b. Check whether your code matches the remote repository
```bash
python check_sync.py
```

This script checks:

- Current git branch
- Remote comparison
- Uncommitted changes
- Code differences

### 3. Install dependencies (optional)
```bash
pip install -r requirements.txt
```

Or install numpy only if needed:
```bash
pip install numpy
```

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
└── requirements.txt
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

## Contributing
To report bugs or contribute, please open an issue or a pull request.


