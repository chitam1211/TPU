# SoC RV32IF + matrix coprocessor (CV-X-IF) trên Kria K26 (KR260 / KV260)

PS (Cortex-A53) nạp chương trình vào BRAM của board qua AXI, điều khiển và nhận ngắt từ
`rv32if_xif_soc` (core RV32IF có forwarding + core ma trận nối qua CV-X-IF). Clock PL:
`pl_clk0` = 100 MHz cho toàn bộ SoC. Giải thích cơ chế ngắt / dừng / watchdog / TOHOST và so sánh
với bản của partner (`fpga/kr260`): [docs/soc_xif_ngat_halt.pdf](../../docs/soc_xif_ngat_halt.pdf).

```
 PS (A53: Linux hoặc bare-metal)
   │ M_AXI_HPM0_FPD (AXI4, 32 bit)
   ▼
 SmartConnect ─┬─► rvm/s_axi  (AXI4-Lite)  rv32if_xif_soc: thanh ghi điều khiển
               ├─► imem_ctrl  AXI BRAM Controller ─► imem_bram port A ┐ True Dual Port
               └─► dmem_ctrl  AXI BRAM Controller ─► dmem_bram port A ┘ (16 KB / 64 KB)
 rv32if_xif_soc: IMEM ─► imem_bram port B (fetch), DMEM ─► dmem_bram port B (load/store)
                 core_matrix_xif = core (XIF = 1) + matrix_xif_coproc
 pl_ps_irq0[0] ◄── irq = |(IRQ_STATUS & IRQ_EN)   (GIC SPI 121, level high)
```

## Bản đồ địa chỉ (PS)

| Địa chỉ | Kích thước | Khối |
|---|---|---|
| 0xA000_0000 | 4 KB | `rvm`: thanh ghi `rv32if_xif_soc` (bảng dưới) |
| 0xA001_0000 | 16 KB | `imem_ctrl`: IMEM (core thấy ở địa chỉ 0x0000–0x3FFF) |
| 0xA002_0000 | 64 KB | `dmem_ctrl`: DMEM (core thấy ở địa chỉ 0x0000–0xFFFF) |

PS đọc/ghi IMEM, DMEM bất cứ lúc nào (không khóa như bản partner): đọc kết quả trong DMEM khi
RUN = 1 vẫn được. Thanh ghi (chi tiết: PDF mục 9, hoặc đầu file `rtl/core_matrix_xif/rv32if_xif_soc.v`):

| Offset | Tên | | Nội dung |
|---|---|---|---|
| 0x00 | CTRL | RW | [0] RUN. 0→1: core chạy từ PC 0, xóa CYCLES/MDONE_CNT/IRQ_STATUS/EXIT_CODE |
| 0x04 | STATUS | RO | [0] running [1] halted [2] matrix_busy [3] đã có matrix_done [4] timeout [5] đã ghi TOHOST |
| 0x08 | CYCLES | RO | số chu kỳ tới đúng lệnh `jal x0,0` (không cộng thời gian phát hiện dừng) |
| 0x0C | PC | RO | địa chỉ fetch (khi dừng: lệnh `jal x0,0` + 0..12, do fetch liên tục) |
| 0x10/14/18 | MTILEM/N/K | RO | CSR tile |
| 0x1C | MDONE_CNT | RO | số lệnh ma trận đã xong |
| 0x20 / 0x24 | MREG_SEL / MREG_DATA | RW | đọc/ghi thanh ghi ma trận (chỉ khi RUN = 1) |
| 0x28 | ID | RO | 0x4B4C544E ("KLTN") |
| 0x2C | IRQ_EN | RW | [0] done [1] timeout |
| 0x30 | IRQ_STATUS | R/W1C | [0] done [1] timeout; ghi 1 để xóa |
| 0x34 | EXIT_CODE | RO | giá trị lệnh `sw` cuối cùng vào TOHOST (0x3FF0) |
| 0x38 | MAX_CYCLES | RW | watchdog, 0 = tắt |
| 0x3C | CONFIG | RO | [7:0] version 2, [15:8] IMEM_AW, [23:16] DMEM_AW, [24] CV-X-IF |

## Thư mục

| File | Nội dung |
|---|---|
| `tcl/build_soc_xif.tcl` | tạo project + block design, build tới bitstream, xuất `.bit/.bin/.hwh/.xsa`, `soc_summary.txt` |
| `../../scripts/run_vivado_soc_xif.ps1`, `.sh` | chạy Vivado (Windows) từ PowerShell / WSL, mỗi lần chạy một thư mục riêng |
| `sw/soc_host.py` | điều khiển từ Linux trên board: demo GEMM tự kiểm tra, chạy file ảnh chương trình, so với mô phỏng |
| `sw/baremetal/main.c` | ứng dụng Vitis standalone: GEMM kết thúc bằng **ngắt** (GIC) + thử watchdog |
| `sw/linux/rv32if_xif_soc.dtsi`, `shell.json` | overlay cho `xmutil` (Kria Ubuntu) |
| `../../tb/soc_xif/` | testbench RTL của SoC (534 điểm × 2 chế độ BRAM) + `host_sim.py` (chạy `soc_host.py` trên RTL) |

## 1. Mô phỏng (trước khi lên board)

```bash
cd /mnt/c/TPU/TPU/kltn
bash tb/soc_xif/run.sh          # -> SOC_XIF_ALL_PASS
```

Gồm: `tb_rv32if_xif_soc.sv` (P1–P12, 534 PASS, chạy với BRAM WRITE_FIRST và NO_CHANGE), sau đó
`host_sim.py` chạy **chính code của `sw/soc_host.py`** trên RTL: demo GEMM 5 bộ dữ liệu và các
chương trình C của `sw/matrix` (nếu đã build bằng `python3 scripts/run_matrix_sw.py`), so DMEM với
log mô phỏng gốc (3068/3068 word mỗi chương trình).

## 2. Build bitstream (Vivado 2022.2, từ WSL)

```bash
cd /mnt/c/TPU/TPU/kltn
./scripts/run_vivado_soc_xif.sh                 # 100 MHz, KR260, tới bitstream (mặc định)
./scripts/run_vivado_soc_xif.sh 100 impl        # chỉ synth + impl + báo cáo (đo timing / tài nguyên)
./scripts/run_vivado_soc_xif.sh 100 bd          # chỉ tạo project + block design để mở GUI
./scripts/run_vivado_soc_xif.sh 100 full --board kv260 --strategy Performance_Explore
```

| Thư mục | Nội dung |
|---|---|
| `reports/vivado/runs/<thời gian>_soc_xif_<mode>_<MHz>MHz/` | `soc_summary.txt` (WNS, tài nguyên từng khối, chi phí phần "SoC glue"), `address_map.txt`, `*.rpt`, `vivado.log`, `run_info.txt` |
| `build/vivado/runs/<cùng tên>/proj/soc.xpr` | project Vivado (mở GUI để xem block design) |
| `build/vivado/runs/<cùng tên>/out/` | `rv32if_xif_soc.bit`, `.bin`, `.hwh`, `.xsa` |

Script kiểm tra sau khi validate: 2 BRAM phải là True Dual Port, 32 bit × (kích thước/4) word,
không bật output register (read latency 1 như `tb/soc_xif/bram_tdp_model.v`); sai là dừng với lỗi.

**Đổi kích thước bộ nhớ**: sửa `imem_kb` / `dmem_kb` trong `tcl/build_soc_xif.tcl`. Range của 2 BRAM
Controller (độ sâu BRAM) và tham số `IMEM_AW` / `DMEM_AW` của `rv32if_xif_soc` đổi cùng lúc;
`soc_host.py` đọc CONFIG và báo lỗi nếu kích thước khác với hằng số của nó (`IMEM_BYTES`, `DMEM_BYTES`).
**Đổi tần số**: tham số đầu (MHz), sửa thêm `assigned-clock-rates` trong `.dtsi`.

## 3. Chạy trên board

### Cách A: Kria Ubuntu 22.04 (`xmutil`) + `soc_host.py`

Chép lên board: `out/rv32if_xif_soc.bin`, `sw/linux/rv32if_xif_soc.dtsi`, `sw/linux/shell.json`, `sw/soc_host.py`.

```bash
sudo apt install device-tree-compiler
dtc -@ -O dtb -o rv32if_xif_soc.dtbo rv32if_xif_soc.dtsi
sudo mkdir -p /lib/firmware/xilinx/rv32if_xif_soc
sudo cp rv32if_xif_soc.bin rv32if_xif_soc.dtbo shell.json /lib/firmware/xilinx/rv32if_xif_soc/
sudo xmutil unloadapp
sudo xmutil loadapp rv32if_xif_soc
sudo python3 soc_host.py                          # demo GEMM int8, 5 bộ dữ liệu -> RESULT: PASS
```

Chạy các chương trình C của `sw/matrix` và so với mô phỏng: trên máy (WSL) chạy
`python3 scripts/run_matrix_sw.py`, chép các thư mục `sim/build/matrix_sw/core_matrix/<case>/`
(mỗi thư mục có `mem.hex` + `sim.log`) lên board, rồi:

```bash
sudo python3 soc_host.py --case i8_8x8x8 f32_10x10x10 ...     # -> RESULT: PASS
sudo python3 soc_host.py --image mem.hex --dump 0x1000:0x1100  # một chương trình bất kỳ
```

`--image` nhận file `objcopy -O verilog` (như `run_matrix_sw.py` tạo) hoặc mỗi dòng một word;
cùng một file được nạp vào IMEM (16 KB đầu) và DMEM, phần còn lại của 2 bộ nhớ được xóa về 0.
Kết thúc chạy được nhận bằng cách hỏi vòng IRQ_STATUS (không cần driver ngắt trên Linux);
watchdog mặc định 2 s (`--max-cycles`).

### Cách B: Kria-PYNQ

Chép `rv32if_xif_soc.bit` và `rv32if_xif_soc.hwh` (cùng tên, cùng thư mục) và `soc_host.py`:

```bash
sudo -E python3 soc_host.py --bit rv32if_xif_soc.bit
```

### Cách C: bare-metal qua JTAG (Vitis 2022.2), có dùng ngắt

1. Vitis: *Create Platform* từ `out/rv32if_xif_soc.xsa`, CPU `psu_cortexa53_0`, OS standalone.
2. *Create Application* (Empty C) → thêm `sw/baremetal/main.c`.
3. Cắm micro-USB (JTAG + UART), mở terminal 115200 trên cổng UART thứ 2.
4. *Run As → Launch Hardware* (bật *Reset entire system*, *Program FPGA*). Nếu Vitis không chiếm
   được core (board boot từ QSPI), trong XSCT chạy trước:
   `targets -set -filter {name =~ "PSU"}; mwr 0xff5e0200 0x0100; rst -system`.

UART in số chu kỳ từng lần chạy, kết quả watchdog và `RESULT: PASS`. ISR đọc IRQ_STATUS, xóa
bằng W1C và đọc lại trước khi trả về (GIC level-sensitive: irq phải xuống trước end-of-interrupt).

## Số liệu mô phỏng (phải ra đúng trên board)

| Chương trình | CYCLES (SoC này) | Bản partner / mô phỏng `core_matrix` |
|---|---|---|
| Demo GEMM int8 4x4x16 (`soc_host.py`, P1 + ghi TOHOST) | 389 | — |
| P1 GEMM int8 4x4x16 (tb) | 384 | 481 (gồm 64 chu kỳ phát hiện dừng) |
| `i8_8x8x8` (C, `sw/matrix`) | 1111 | 1411 (tới lệnh ghi TOHOST) |
| `f32_10x10x10` (C) | 6288 | 7109 |

## Ghi chú

- Lệnh cuối của chương trình phải là `jal x0, 0` (`sw/matrix/start.S` ghi 1 vào TOHOST rồi `j 1b`).
- Thanh ghi ma trận (MREG) reset cùng core: chỉ đọc/ghi được khi RUN = 1; IMEM/DMEM thì luôn đọc được.
- RTL dùng trong build: `rtl/core_if_xif` (trừ `Microprocessor.v`), `rtl/matrix_if` với các file của
  `rtl/matrix_if_xif` thay file cùng tên, `matrix_xif_adapter.sv`, `rtl/core_matrix_xif/*` (cùng bộ
  file với `tb/soc_xif/run.sh` và luồng OOC `fpga/kv260/implement_ooc_xif.tcl`).
- Fmax đo OOC của core + coprocessor ≈ 119 MHz (đường găng `fp_mac`), nên 100 MHz có dư timing.
