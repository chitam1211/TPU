# iss/logic_config.py
class ConfigLogic:
    def execute_config(self, instruction):
        """Thực thi các lệnh cấu hình (đã bao gồm mrelease)."""
        func4 = instruction[0:4]
        ctrl_bit_25 = instruction[6]
        
        # 1. Lệnh MRELEASE
        if func4 == "0000":
            print(f"  -> Executing: mrelease")
            self.csr_ref.write('mstatus_ms', 1) 
            print(f"     -> (Simulated: mstatus.MS set to 01)")

        # 2. Lệnh MSETTILEK
        elif func4 == "0001":
            target_csr = "mtilek"
            if ctrl_bit_25 == '0': # msettileki
                imm10_bin = instruction[7:17]
                value = int(imm10_bin, 2)
                print(f"  -> Executing: msettileki {value}")
            else: # msettilek
                rs1_bin = instruction[12:17]
                value = self.gpr_ref.read(int(rs1_bin, 2))
                print(f"  -> Executing: msettilek x{int(rs1_bin, 2)} (value={value})")
            
            self.csr_ref.write(target_csr, value) 
            print(f"     -> {target_csr} set to {value}")

        # 3. Lệnh MSETTILEM
        elif func4 == "0010":
            target_csr = "mtilem"
            # ... (logic của msettilem) ...
            if ctrl_bit_25 == '0':
                imm10_bin = instruction[7:17]
                value = int(imm10_bin, 2)
                print(f"  -> Executing: msettilemi {value}")
            else:
                rs1_bin = instruction[12:17]
                value = self.gpr_ref.read(int(rs1_bin, 2))
                print(f"  -> Executing: msettilem x{int(rs1_bin, 2)} (value={value})")
            self.csr_ref.write(target_csr, value) 
            print(f"     -> {target_csr} set to {value}")
            
        # 4. Lệnh MSETTILEN
        elif func4 == "0011":
            target_csr = "mtilen"
            # ... (logic của msettilen) ...
            if ctrl_bit_25 == '0':
                imm10_bin = instruction[7:17]
                value = int(imm10_bin, 2)
                print(f"  -> Executing: msettileni {value}")
            else:
                rs1_bin = instruction[12:17]
                value = self.gpr_ref.read(int(rs1_bin, 2))
                print(f"  -> Executing: msettilen x{int(rs1_bin, 2)} (value={value})")
            self.csr_ref.write(target_csr, value) 
            print(f"     -> {target_csr} set to {value}")
        
        # 5. Lỗi
        else:
             print(f"  -> ERROR: Unknown configuration instruction with func4={func4}")