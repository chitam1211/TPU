import sys
import os
from pathlib import Path
SCRIPT_DIR = Path(__file__).resolve().parent

# Import các thành phần của trình mô phỏng
from .iss import Simulator
from .state_manager import load_state_from_files, save_state_to_files
from .matrix_input import run_interactive_setup
from .reset_state import reset_all_files_to_default  # Import hàm reset

def main():
    """
    Main function to orchestrate the entire simulation process.
    """
    
    # Set UTF-8 encoding for stdout
    if sys.stdout.encoding != 'utf-8':
        import io
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
    
    # Define file paths
    root_dir = SCRIPT_DIR.parent 
    assembler_dir = root_dir / "assembler"
    iss_dir = SCRIPT_DIR 
    machine_code_file = assembler_dir / "machine_code.txt"

    # --- Handle flags ---
    if len(sys.argv) > 1:
        # Handle --setup flag
        if sys.argv[1] in ['--setup', '-s']:
            print("--- Running Setup Mode ---")
            run_interactive_setup()
            print("\nSetup complete. Run again without '--setup' flag to simulate.")
            return # Exit after setup

        # Handle --reset flag
        if sys.argv[1] in ['--reset', '-r']:
            print("--- Running Reset Mode ---")
            reset_all_files_to_default()
            print("Reset complete. Starting simulation with clean state.")

    # --- 1. Initialize Simulator (Create objects in RAM) ---
    print("--- 1. Initializing Simulator (In RAM) ---")
    my_simulator = Simulator()
    
    # --- 2. Load State from Files into RAM ---
    # (This will read 7 .txt files and populate my_simulator)
    load_state_from_files(my_simulator)

    # --- 3. Read Machine Code (Input) ---
    print(f"--- 2. Reading Machine Code from '{machine_code_file}' ---")
    try:
        with open(machine_code_file, "r") as f:
            instructions = [line.strip() for line in f if line.strip() and not line.startswith('#')]
        if not instructions:
            print(f"Warning: Machine code file '{machine_code_file}' is empty.")
            return
        my_simulator.load_program(instructions)
        print(f"Loaded {len(instructions)} instructions.")
    except FileNotFoundError:
        print(f"ERROR: File '{machine_code_file}' not found.")
        print("Have you run assembler/assembler.py to generate it?")
        return
    except Exception as e:
        print(f"ERROR reading machine code file: {e}")
        return

    # --- 4. Run Simulation (Entirely in RAM) ---
    print("--- 3. Starting Simulation Loop (Running in RAM) ---")
    my_simulator.run()
    
    # --- 5. Save Final State from RAM to Files ---
    print("--- 4. Saving Final State from RAM to Files ---")
    save_state_to_files(my_simulator)
    
    print("\n--- Simulation Complete ---")

if __name__ == "__main__":
    main()
# python -m iss.run_simulator
# python -m iss.run_simulator -r # Run reset mode