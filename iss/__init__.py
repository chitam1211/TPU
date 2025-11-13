"""
ISS (Instruction Set Simulator) Package
RISC-V Matrix Extension Simulator
"""

# Export main classes
from .iss import Simulator
from .components import RegisterFile, CSRFile, MatrixAccelerator, MainMemory
from .state_manager import load_state_from_files, save_state_to_files
from .definitions import XLEN, ELEN, ROWNUM, ELEMENTS_PER_ROW_TR

__all__ = [
    'Simulator',
    'RegisterFile',
    'CSRFile', 
    'MatrixAccelerator',
    'MainMemory',
    'load_state_from_files',
    'save_state_to_files',
    'XLEN',
    'ELEN',
    'ROWNUM',
    'ELEMENTS_PER_ROW_TR',
]
