from simulator_functions import *
from pathlib import Path

def Simulator(input_file_path, output_file_path):
    i = 0
    with open(input_file_path, "r", encoding="utf-8") as input_file, open(output_file_path, "w+", encoding="utf-8") as output_file:
        lines = input_file.readlines()
    
        while i < len(lines):
            line = lines[i].strip()
            #binary_to_data(line, current_address)
            PC["value"] = binary_to_data_Matrix(line, PC["value"])
            i = int(PC["value"])//4
    
    # PrintMemory(output_file_path)

def main():
    base_dir = Path(__file__).resolve().parent
    input_file_path = base_dir / "machine_code.txt"
    output_file_path = base_dir / "simulator_output.txt"
    
    open(output_file_path, "w").close()
    
    Simulator(input_file_path, output_file_path)
    
if __name__ == "__main__":
    main()  