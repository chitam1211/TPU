#!/usr/bin/env python3
"""
Validation script to check if TPU project is set up correctly.
Run this on any machine after git pull to verify setup.

Usage:
    python validate_setup.py
"""

import sys
import os
from pathlib import Path
import importlib.util

def check_python_version():
    """Check Python version >= 3.8"""
    print("\n[1/8] Checking Python version...")
    version = sys.version_info
    if version.major < 3 or (version.major == 3 and version.minor < 8):
        print(f"    ❌ FAIL: Python {version.major}.{version.minor} detected")
        print(f"    Required: Python 3.8+")
        return False
    print(f"    ✅ PASS: Python {version.major}.{version.minor}.{version.micro}")
    return True

def check_project_structure():
    """Check required directories and files exist"""
    print("\n[2/8] Checking project structure...")
    required_items = [
        ('iss/', True),
        ('iss/__init__.py', False),
        ('iss/iss.py', False),
        ('iss/components.py', False),
        ('iss/run_simulator.py', False),
        ('assembler/', True),
        ('assembler/__init__.py', False),
        ('assembler/assembler.py', False),
        ('requirements.txt', False),
        ('README.md', False),
        ('.vscode/settings.json', False),
    ]
    
    all_ok = True
    for item, is_dir in required_items:
        path = Path(item)
        if is_dir:
            exists = path.is_dir()
            type_str = "Directory"
        else:
            exists = path.is_file()
            type_str = "File"
        
        if exists:
            print(f"    ✅ {type_str}: {item}")
        else:
            print(f"    ❌ MISSING: {item}")
            all_ok = False
    
    return all_ok

def check_imports():
    """Check if main modules can be imported"""
    print("\n[3/8] Checking module imports...")
    modules_to_check = [
        ('iss', 'iss package'),
        ('iss.iss', 'iss.Simulator'),
        ('iss.components', 'iss.components'),
        ('iss.definitions', 'iss.definitions'),
    ]
    
    all_ok = True
    for module_name, display_name in modules_to_check:
        try:
            importlib.import_module(module_name)
            print(f"    ✅ Import: {display_name}")
        except ImportError as e:
            print(f"    ❌ FAIL: Cannot import {display_name}")
            print(f"       Error: {e}")
            all_ok = False
    
    return all_ok

def check_mixin_classes():
    """Check if all mixin classes are present"""
    print("\n[4/8] Checking mixin classes...")
    try:
        from iss.components import MatrixAccelerator
        
        # Check if MatrixAccelerator has methods from all mixins
        required_methods = [
            ('execute_config', 'ConfigLogic'),
            ('execute_matmul', 'MatmulLogic'),
            ('execute_load_store', 'LoadStoreLogic'),
            ('execute_element_wise', 'ElementwiseLogic'),
            ('execute_misc', 'MiscLogic'),
        ]
        
        all_ok = True
        for method_name, mixin_name in required_methods:
            if hasattr(MatrixAccelerator, method_name):
                print(f"    ✅ Method: {method_name} (from {mixin_name})")
            else:
                print(f"    ❌ MISSING: {method_name} (from {mixin_name})")
                all_ok = False
        
        return all_ok
    except Exception as e:
        print(f"    ❌ FAIL: Cannot check mixins")
        print(f"       Error: {e}")
        return False

def check_required_attributes():
    """Check if MatrixAccelerator has required attributes"""
    print("\n[5/8] Checking MatrixAccelerator attributes...")
    try:
        from iss.components import MatrixAccelerator, RegisterFile, CSRFile, MainMemory
        
        # Create instances
        gpr = RegisterFile()
        csr = CSRFile()
        mem = MainMemory(1024)
        ma = MatrixAccelerator(csr, gpr, mem)
        
        required_attrs = [
            'tr_int', 'tr_float', 'acc_int', 'acc_float',
            'rownum', 'elements_per_row_tr', 'elements_per_row_acc',
            'csr_ref', 'gpr_ref', 'memory'
        ]
        
        all_ok = True
        for attr in required_attrs:
            if hasattr(ma, attr):
                print(f"    ✅ Attribute: {attr}")
            else:
                print(f"    ❌ MISSING: {attr}")
                all_ok = False
        
        return all_ok
    except Exception as e:
        print(f"    ❌ FAIL: Cannot create MatrixAccelerator")
        print(f"       Error: {e}")
        return False

def check_optional_dependencies():
    """Check optional dependencies"""
    print("\n[6/8] Checking optional dependencies...")
    try:
        import numpy
        print(f"    ✅ numpy {numpy.__version__} (for float16 support)")
        has_numpy = True
    except ImportError:
        print(f"    ⚠️  numpy not installed (float16 tests will use fallback)")
        has_numpy = False
    
    return True  # Optional, so always return True

def check_encoding_support():
    """Check if UTF-8 encoding is supported"""
    print("\n[7/8] Checking UTF-8 encoding support...")
    try:
        # Test UTF-8 encoding
        test_str = "Test UTF-8: ✓ ✗ → ← ↑ ↓"
        encoded = test_str.encode('utf-8')
        decoded = encoded.decode('utf-8')
        if test_str == decoded:
            print(f"    ✅ UTF-8 encoding: Supported")
            return True
        else:
            print(f"    ❌ UTF-8 encoding: Failed")
            return False
    except Exception as e:
        print(f"    ❌ UTF-8 encoding: Error - {e}")
        return False

def check_simulator_run():
    """Test if simulator can be instantiated"""
    print("\n[8/8] Testing simulator instantiation...")
    try:
        from iss.iss import Simulator
        sim = Simulator()
        print(f"    ✅ Simulator created successfully")
        return True
    except Exception as e:
        print(f"    ❌ FAIL: Cannot create Simulator")
        print(f"       Error: {e}")
        return False

def main():
    """Run all validation checks"""
    print("="*70)
    print("TPU PROJECT VALIDATION")
    print("="*70)
    print(f"Python: {sys.version}")
    print(f"Platform: {sys.platform}")
    print(f"Working Directory: {os.getcwd()}")
    print("="*70)
    
    checks = [
        check_python_version,
        check_project_structure,
        check_imports,
        check_mixin_classes,
        check_required_attributes,
        check_optional_dependencies,
        check_encoding_support,
        check_simulator_run,
    ]
    
    results = []
    for check_func in checks:
        try:
            result = check_func()
            results.append(result)
        except Exception as e:
            print(f"\n    ❌ UNEXPECTED ERROR: {e}")
            results.append(False)
    
    # Summary
    print("\n" + "="*70)
    print("VALIDATION SUMMARY")
    print("="*70)
    
    passed = sum(results)
    total = len(results)
    
    print(f"Passed: {passed}/{total}")
    
    if all(results):
        print("\n✅ ALL CHECKS PASSED! Project is ready to use.")
        print("\nYou can now run:")
        print("  python -m iss.run_simulator")
        return 0
    else:
        print("\n❌ SOME CHECKS FAILED! Please fix the issues above.")
        print("\nCommon fixes:")
        print("  1. Make sure you're in the TPU/ root directory")
        print("  2. Run: git pull origin oop_ver")
        print("  3. Check Python version: python --version")
        print("  4. Install numpy (optional): pip install numpy")
        return 1

if __name__ == '__main__':
    sys.exit(main())
