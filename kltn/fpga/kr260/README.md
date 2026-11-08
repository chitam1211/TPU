# RV32IF + Matrix trên KR260 (AXI4-Lite)

PS (Cortex-A53) điều khiển hệ thống RV32IF + matrix (`core_matrix`) qua một slave AXI4-Lite
nối vào `M_AXI_HPM0_FPD`, tại địa chỉ **0xA000_0000** (16 KB). Clock PL: `pl_clk0` = 100 MHz.

```
 PS (A53, Linux / bare-metal)
   │ M_AXI_HPM0_FPD (32 bit)
   ▼
 SmartConnect ──► rv32if_matrix_axi (AXI4-Lite slave, thanh ghi điều khiển)
                     └─ rv32if_matrix_soc
                          ├─ IMEM 256 word ◄─┐ host (khi RUN=0) / core
                          ├─ DMEM 256 word ◄─┘
                          └─ core_matrix (RV32IF + matrix_core_v2)
   pl_ps_irq0[0] ◄── irq = halted
```

## Thư mục

| File | Nội dung |
|---|---|
| `rtl/rv32if_matrix_soc.v` | core + IMEM/DMEM + cổng host vào bộ nhớ + phát hiện dừng |
| `rtl/rv32if_matrix_axi.v` | AXI4-Lite slave, thanh ghi điều khiển (top của module reference trong BD) |
| `tb/tb_rv32if_matrix_axi.sv` | testbench AXI cơ bản (bản đồ thanh ghi + 1 chương trình GEMM) |
| `tb/tb_kr260_programs.sv` | testbench AXI 12 kịch bản P1–P8, chỉ đi qua bus AXI4-Lite như PS |
| `tb/run_tb.sh` | chạy cả 2 testbench (iverilog 12) |
| `tb/tb_matrix_pkg.sv`, `tb/rv32if_asm.svh` | hàm mã hóa lệnh / mô hình tham chiếu dùng cho 2 testbench |
| `tcl/build_kr260.tcl` | tạo project + block design KR260, build tới bitstream, xuất `.bit/.hwh/.bin/.xsa` |
| `sw/rvm_host.py` | điều khiển từ Linux (Kria-PYNQ hoặc `/dev/mem`) |
| `sw/linux/rv32if_matrix.dtsi`, `shell.json` | overlay cho `xmutil`/`fpgautil` (Kria Ubuntu) |
| `sw/baremetal/main.c` | ứng dụng Vitis standalone (JTAG) |

`rv32if_matrix_soc.v` có cùng cấu trúc với file top `rv32if_matrix_microprocessor.v` (core_matrix + IMEM + DMEM,
CPU nối thẳng với core ma trận, không dùng CV-X-IF), chỉ thêm cổng host vào 2 bộ nhớ và mạch phát hiện dừng,
vì file top không có đường nào để nạp IMEM/DMEM từ bên ngoài. File top không bị sửa.

## Bản đồ thanh ghi

| Offset | Tên | | Mô tả |
|---|---|---|---|
| 0x0000 | CTRL | RW | bit0 RUN: 1 = nhả reset core (chạy từ PC=0), 0 = giữ reset. Cạnh lên xóa CYCLES/MDONE_CNT |
| 0x0004 | STATUS | RO | bit0 running, bit1 halted, bit2 matrix_busy, bit3 đã có matrix_done |
| 0x0008 | CYCLES | RO | số chu kỳ từ RUN=1 đến khi halted (**gồm 64 chu kỳ phát hiện dừng**) |
| 0x000C | PC | RO | pc_address |
| 0x0010/14/18 | MTILEM/N/K | RO | CSR tile hiện tại |
| 0x001C | MDONE_CNT | RO | số lệnh ma trận đã xong |
| 0x0020 | MREG_SEL | RW | [2:0] reg id (0-3 tr0-3, 4-7 acc0-3), [10:8] row, [18:16] beat |
| 0x0024 | MREG_DATA | RW | ghi/đọc 1 beat 32 bit của thanh ghi ma trận đang chọn |
| 0x0028 | ID | RO | 0x4B4C544E ("KLTN") |
| 0x1000–0x13FF | IMEM | RW | chỉ khi RUN=0 |
| 0x2000–0x23FF | DMEM | RW | chỉ khi RUN=0 (khi RUN=1: ghi bị bỏ qua, đọc trả 0xDEADBEEF) |

**Kết thúc chương trình**: lệnh cuối phải là `jal x0, 0` (0x0000006F). Khi lệnh fetch gần nhất là lệnh
này liên tục 64 chu kỳ và matrix_busy = 0 thì `halted` bật (và `irq`).

**Trình tự dùng**:
1. `CTRL = 0` → ghi IMEM, DMEM. Dữ liệu ma trận đi vào qua DMEM + lệnh `mlae*/mlbe*/mlce32` trong chương trình.
2. `CTRL = 1` → poll `STATUS.halted` (hoặc chờ IRQ).
3. Đọc thanh ghi ma trận qua MREG **khi vẫn RUN=1**.
4. `CTRL = 0` → đọc DMEM. GPR/FPR không đọc được từ host: chương trình phải `sw`/`fsw` kết quả ra DMEM.

**MREG chỉ có tác dụng khi RUN=1**: thanh ghi ma trận (`matrix_regfile`) reset đồng bộ cùng core
(`core_rst_n`), nên khi RUN=0 ghi MREG bị bỏ qua và đọc ra 0; mỗi lần RUN 0→1 các thanh ghi ma trận về 0.
Chỉ số ngoài phạm vi (row/beat ≥ 4) đọc ra 0, ghi bị bỏ qua.

## 1. Mô phỏng

```bash
cd kltn/fpga/kr260/tb
export PATH=/c/msys64/ucrt64/bin:$PATH   # neu iverilog chua co trong PATH (Git Bash)
bash run_tb.sh          # -> 2 x RESULT: PASS, log trong tb/build/
```

- `tb_rv32if_matrix_axi`: nạp 1 chương trình GEMM int8 qua AXI, so DMEM và acc0 (MREG), WSTRB, khóa bộ nhớ, chạy lại lần 2.
- `tb_kr260_programs` (395 điểm kiểm tra): mọi thao tác đi qua AXI như PS. IMEM được nạp đủ 256 word, phần sau
  chương trình để 0x00000000 (giống BRAM sau khi nạp bitstream).
  P1 GEMM int8 4x4x16 với 5 bộ dữ liệu, P2 GEMM FP32 + `mfadd.s.mm` + lệnh F, P3 GEMM K=64 trong vòng lặp,
  P4 chương trình scalar RV32I/F, P5 giao thức AXI (W trước AW, BREADY/RREADY trễ, WSTRB, khóa bộ nhớ),
  P6 chương trình không dừng + dừng bằng CTRL, P7 `s_axi_aresetn` giữa lúc chạy, P8 MREG.

Số chu kỳ đo trong mô phỏng (CYCLES, đã gồm 64 chu kỳ phát hiện dừng): GEMM int8 4x4x16 = 481,
GEMM FP32 4x4x4 = 595, GEMM int8 K=64 = 1278, chương trình scalar P4 = 690 (CPU `kltn/rtl/core_if` hiện tại). Trên board phải ra đúng các số này.

## 2. Build bitstream (Vivado 2022.2)

```powershell
mkdir kltn\fpga\kr260\build; cd kltn\fpga\kr260\build
E:\Xilinx\Vivado\2022.2\bin\vivado.bat -mode batch -source ..\tcl\build_kr260.tcl            # 100 MHz
E:\Xilinx\Vivado\2022.2\bin\vivado.bat -mode batch -source ..\tcl\build_kr260.tcl -tclargs 50 # 50 MHz
E:\Xilinx\Vivado\2022.2\bin\vivado.bat -mode batch -source ..\tcl\build_kr260.tcl -tclargs 100 bd  # chỉ tạo project/BD để mở GUI
```

Kết quả trong `build/out/`: `rv32if_matrix.bit`, `.hwh`, `.bin`, `.xsa`, `timing_summary.rpt`,
`utilization*.rpt`, `build_info.txt` (WNS). Project: `build/vivado/kr260_rv32if_matrix.xpr`.
Nếu WNS < 0, build lại với tần số thấp hơn và sửa `assigned-clock-rates` trong `.dtsi`.

## 3. Nạp lên KR260

### Cách A: Kria Ubuntu 22.04 (`xmutil`)

Chép lên board: `rv32if_matrix.bin`, `sw/linux/rv32if_matrix.dtsi`, `sw/linux/shell.json`, `sw/rvm_host.py`.

```bash
sudo apt install device-tree-compiler
dtc -@ -O dtb -o rv32if_matrix.dtbo rv32if_matrix.dtsi
sudo mkdir -p /lib/firmware/xilinx/rv32if_matrix
sudo cp rv32if_matrix.bin rv32if_matrix.dtbo shell.json /lib/firmware/xilinx/rv32if_matrix/
sudo xmutil unloadapp
sudo xmutil loadapp rv32if_matrix
sudo python3 rvm_host.py                 # demo -> RESULT: PASS
sudo python3 rvm_host.py --hex prog.hex --dmem data.hex --dump 64
```

### Cách B: Kria-PYNQ

Chép `rv32if_matrix.bit` và `rv32if_matrix.hwh` (cùng tên, cùng thư mục) và `rvm_host.py`:

```bash
sudo -E python3 rvm_host.py --bit rv32if_matrix.bit
```

### Cách C: bare-metal qua JTAG (Vitis 2022.2)

1. Vitis: *Create Platform* từ `build/out/rv32if_matrix.xsa`, CPU `psu_cortexa53_0`, OS standalone.
2. *Create Application* (Empty C) → thêm `sw/baremetal/main.c`.
3. Cắm micro-USB (JTAG + UART), mở terminal 115200 trên cổng UART thứ 2 (thường là COM lớn hơn).
4. *Run As → Launch Hardware* (Run configuration: bật *Reset entire system*, *Program FPGA*).
   KR260 boot từ QSPI; nếu Vitis không chiếm được core, trong XSCT chạy trước:
   `targets -set -filter {name =~ "PSU"}; mwr 0xff5e0200 0x0100; rst -system` (chuyển boot mode sang JTAG).

UART in `RESULT: PASS`.

## Ghi chú

- Lệnh ma trận và scalar dùng chung DMEM 1 KB (địa chỉ byte 0x000–0x3FF, bit [9:2]); địa chỉ ngoài vùng
  này bị quấn lại (giống `rv32if_matrix_microprocessor`).
- Core không có forwarding nhưng có interlock (stall theo phụ thuộc GPR/FPR, kể cả GPR ghi bởi `mmovw.x.m`),
  nên chương trình KHÔNG cần chèn NOP; NOP trong demo chỉ là thừa.
- Lệnh fetch đầu tiên sau reset là PC = 0.
- Nguồn RTL: CPU trong `kltn/rtl/core_if` (bỏ `Core.v`, `Microprocessor.v`), `core_matrix.v` và core ma trận trong
  `kltn/rtl/matrix_if`. CPU nối thẳng với core ma trận, không dùng CV-X-IF.
