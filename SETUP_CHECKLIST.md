# Setup checklist for a new machine

Follow these steps in order after cloning the project.

## Step 1. Clone the repository
```bash
git clone https://github.com/chitam1211/TPU.git
cd TPU
git checkout oop_ver
```

## Step 2. Check the Python version
```bash
python --version
```

Required: Python 3.8 or newer.

If the version is too old:

- Windows: download from https://www.python.org/downloads/
- Linux or macOS: install with your package manager, for example python3.10

## Step 3. Run the validation script
```bash
python validate_setup.py
```

If all checks pass, skip Step 4 and go to Step 5.

## Step 4. Fix common issues

### Error: Cannot import iss
```bash
pwd
```

You should be in the project root directory, not inside iss.

### Error: Python version too old
```bash
python3.10 --version
```

Install a newer Python version and retry.

### Error: Missing files
```bash
git pull origin oop_ver
git status
```

### Warning: numpy not installed
```bash
pip install numpy
```

Numpy is optional and only required for float16 tests.

## Step 5. Run a quick simulator test
```bash
python -m iss.run_simulator
```

Optional test script:
```bash
cd iss
python test_loadstore.py
```

## Step 6. VS Code setup

1. Open the TPU folder in VS Code
2. Install the Python extension (ms-python.python)
3. Install the Pylance extension (ms-python.vscode-pylance)
4. Reload the window
5. Check the Problems panel for errors

## Step 7. Final validation
```bash
python validate_setup.py
```

Expected result:
```
Passed: 8/8
ALL CHECKS PASSED
```

---

## Advanced troubleshooting

### Windows encoding errors
```powershell
$env:PYTHONIOENCODING="utf-8"
python -m iss.run_simulator
```

### Pylance attribute not found

This is addressed in .vscode/settings.json. Reload the VS Code window if it persists.

### Import errors with __init__.py present
```bash
rm -rf iss/__pycache__
rm -rf assembler/__pycache__
```

On Windows:
```powershell
rmdir /s iss\__pycache__
rmdir /s assembler\__pycache__
```

---

After all checks pass, you can:

- Run the simulator: python -m iss.run_simulator
- Run the assembler: cd assembler and python assembler.py
- Run tests: cd iss and python test_loadstore.py
- Commit changes: git add . and git commit -m "message" and git push
