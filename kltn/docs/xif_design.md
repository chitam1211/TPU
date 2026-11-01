# Ghép core RV32IF với core ma trận qua CORE-V eXtension Interface (CV-X-IF)

Bản thiết kế, chưa sửa RTL. Nhánh `xif`, tạo từ `RV32IF` tại `af9561e` (31/10/2026).

## 1. Mục tiêu và phạm vi

Thay giao tiếp riêng hiện nay giữa core RV32IF và core ma trận (các dây `matrix_*` trong
`rtl/matrix_if/core_matrix.v`) bằng giao tiếp chuẩn **CV-X-IF v1.0.0** (OpenHW Group, bản
"Ratified Release", https://github.com/openhwgroup/core-v-xif).

Trong phạm vi:

- Core in-order 32 bit, một hart, **chạy chặn**: lệnh ma trận đứng ở EX cho đến khi có kết quả,
  như hiện nay. Mỗi lúc chỉ có một lệnh ma trận đang thực hiện.
- Các giao tiếp con: issue, register, commit, result, memory request/response, memory result.
- `matrix_core_v2` và các khối bên trong **không sửa**. Mọi chuyển đổi nằm trong một adapter.

Ngoài phạm vi (giữ như hiện nay, ghi rõ ở mục 9):

- Bẫy lệnh không hợp lệ: core không có trap, lệnh bị coprocessor từ chối được xem như NOP.
- Chạy song song lệnh vô hướng với lệnh ma trận (cần scoreboard theo `id`, commit trễ, xử lý
  `commit_kill`). Đây là hướng mở rộng sau.
- Giao tiếp compressed, ECS (mstatus.xs/fs/vs), đọc/ghi cặp thanh ghi.

## 2. Hiện trạng: `core_matrix.v`

```
 core_matrix.v (bản sao Core.v + phần ma trận, 747 dòng)          matrix_core_v2 (giữ nguyên)
 ┌──────────────────────────────────────────────┐              ┌──────────────────────────────┐
 │ ID: opcode 0x2B -> matrix_decode              │              │ matrix_dispatch (giải mã,    │
 │     hazard: mx_uses_rs1 / mx_uses_rs2         │              │   accept, kết quả GPR)       │
 │ EX: matrix_go (mức, khi lệnh ở EX)   ────────►│ matrix_valid │ tile_ls, mac int/fp, ew,     │
 │     instruction_execute, alu_in_a/b  ────────►│ insn,rs1,rs2 │ ew fp, misc, regfile         │
 │     matrix_wait -> execute_wait (stall)       │◄──── done    │                              │
 │     kết quả GPR -> đường WB (alu_res)         │◄──── wb_*    │                              │
 │ MEM: mux cổng dữ liệu khi matrix_mem_request  │◄──── mem_*   │ (xung 1 chu kỳ, không ready) │
 └──────────────────────────────────────────────┘              └──────────────────────────────┘
```

Các điểm của RTL hiện tại ảnh hưởng tới thiết kế:

1. Lệnh ma trận được phát ở EX khi `execute_valid && matrix_execute && !memory_wait`. Lệnh
   giữ nguyên ở EX (cùng `instruction_execute`, `alu_in_a/b`) cho tới `matrix_done`.
2. `matrix_core_v2` đọc `matrix_insn`, `matrix_rs1`, `matrix_rs2` **trong suốt** quá trình chạy:
   một số khối tự chốt khi bắt đầu (tile_ls, ew, misc), nhưng `matrix_dispatch` và phần cấu hình
   dùng trực tiếp. Vì vậy đầu vào phải **giữ ổn định cho tới khi xong**.
3. `matrix_dispatch` có cơ chế `accept_block`: sau khi một lệnh xong, cùng mã lệnh đó chỉ được
   nhận lại sau khi `matrix_valid` hạ xuống ít nhất một chu kỳ.
4. `matrix_tile_ls` phát yêu cầu bộ nhớ dạng **xung một chu kỳ** (trạng thái `*_REQ`) và giả
   sử bộ nhớ nhận ngay. Với load, nó chờ `mem_rvalid`. Với store, nó không chờ gì.
5. Mã ma trận không được hỗ trợ (`matrix_supported = 0`) đi qua pipeline như NOP.
6. `Core.v` (dùng cho ACT4, lockstep, KV260) và `core_matrix.v` là **hai bản sao** của cùng
   một pipeline. Mỗi lần sửa core phải sửa ở hai nơi (ví dụ commit `55f7481`).

## 3. Cấu hình CV-X-IF

| Tham số | Giá trị | Lý do |
|---|---|---|
| `X_NUM_RS` | 2 | lệnh ma trận chỉ đọc `rs1`, `rs2`; register file có 2 cổng đọc |
| `X_ID_WIDTH` | 3 | nhỏ nhất cho phép; chỉ một lệnh đang thực hiện |
| `X_RFR_WIDTH` / `X_RFW_WIDTH` | 32 / 32 | RV32, không đọc/ghi cặp thanh ghi |
| `X_NUM_HARTS` / `X_HARTID_WIDTH` | 1 / 1 | một hart |
| `X_MISA` | 0 | extension ma trận không phải extension chuẩn |
| `X_DUALREAD` / `X_DUALWRITE` | 0 / 0 | |
| `X_ISSUE_REGISTER_SPLIT` | 0 | phát ở EX khi `rs1`, `rs2` đã sẵn sàng: issue và register cùng chu kỳ |
| `X_MEM_WIDTH` | 32 | cổng dữ liệu 32 bit |

## 4. Kiến trúc mới

```
 core_matrix_xif (top mới, cùng danh sách cổng với core_matrix.v)
 ┌──────────────────────────────────────────────────────────────────────────────────────────┐
 │  core (rtl/core_if/Core.v + cổng XIF)      matrix_xif_adapter          matrix_core_v2       │
 │  ┌────────────────────────┐  issue      ┌────────────────────┐       ┌──────────────────┐ │
 │  │ EX: phát lệnh 0x2B     │────────────►│ chốt instr/rs/id    │ valid │ (không đổi)      │ │
 │  │                        │  register   │ xung matrix_valid   │──────►│                  │ │
 │  │                        │────────────►│ giữ insn/rs ổn định │ insn  │                  │ │
 │  │                        │  commit     │                     │ rs1/2 │                  │ │
 │  │                        │────────────►│ done/wb -> result   │◄──────│ done, wb_*       │ │
 │  │ stall tới result       │◄────────────│                     │       │                  │ │
 │  │ MEM: phục vụ mem_req   │◄────────────│ mem_* -> mem_req    │◄──────│ mem_* (tile_ls)  │ │
 │  │      trả mem_result    │────────────►│ mem_result -> rdata │──────►│ rdata, rvalid    │ │
 │  └────────────────────────┘             └────────────────────┘       └──────────────────┘ │
 └──────────────────────────────────────────────────────────────────────────────────────────┘
```

Lựa chọn chính: **thêm cổng XIF vào `Core.v`** thay vì sửa `core_matrix.v`. Lợi ích:

- Chỉ còn **một** pipeline. `core_matrix.v` được thay bằng một top mỏng gồm core, adapter và
  `matrix_core_v2`.
- `core` vẫn dùng một mình cho ACT4, lockstep và đo trên KV260. Khi không gắn coprocessor, cổng
  XIF được nối cố định (`issue_ready = 1`, `accept = 0`), nên lệnh 0x2B là NOP như hiện nay.
- Core không còn phải biết lệnh ma trận nào đọc thanh ghi nào hay ghi `rd`. Đó là thông tin
  của coprocessor, đúng tinh thần XIF.

## 5. Ánh xạ tín hiệu

Hướng ghi theo phía core: "ra" là core → coprocessor.

| Giao tiếp | Tín hiệu / trường | Hướng | Phía core (nguồn / đích) | Phía adapter |
|---|---|---|---|---|
| issue | `issue_valid` | ra | `execute_valid && opcode == 0x2B && !memory_wait && !đã phát` | |
| | `issue_ready` | vào | | `state == IDLE` |
| | `issue_req.instr` | ra | `instruction_execute` | chốt vào `insn_q` |
| | `issue_req.id` | ra | bộ đếm 3 bit, tăng sau mỗi lần phát | chốt vào `id_q` |
| | `issue_req.hartid` | ra | 0 | |
| | `issue_resp.accept` | vào | lưu lại, `0` → lệnh thành NOP | `matrix_supported` (tổ hợp theo `instr`) |
| | `issue_resp.writeback` | vào | (chỉ để kiểm tra) | `mmovw.x.m` với `rd != 0` |
| | `issue_resp.register_read` | vào | (chỉ để kiểm tra) | `{mx_uses_rs2, mx_uses_rs1}` (chuyển từ core sang) |
| | `issue_resp.loadstore` | vào | (chỉ để kiểm tra) | nhóm load/store (`uop == 01`) |
| register | `register_valid` / `register_ready` | ra / vào | bằng `issue_valid` / `issue_ready` (split = 0) | |
| | `register.rs[0]`, `rs[1]` | ra | `alu_in_a`, `alu_in_b` | chốt vào `rs1_q`, `rs2_q` |
| | `register.rs_valid` | ra | `2'b11` (hazard đã xử lý ở ID) | |
| commit | `commit_valid` | ra | xung trong chu kỳ issue được nhận | điều kiện để bắt đầu |
| | `commit.id`, `commit_kill` | ra | `id` của lệnh vừa phát, `0` | |
| result | `result_valid` | vào | hết stall khi `result_valid && result_ready` | `matrix_done` hoặc kết quả đang giữ |
| | `result_ready` | ra | `1` khi lệnh ma trận đang chờ ở EX | |
| | `result.data`, `rd`, `we` | vào | đi vào đường WB như `matrix_wb_value` hiện nay | `matrix_wb_data`, `matrix_wb_rd`, `matrix_wb_we` |
| | `result.id`, `exc`, `err`, `dbg` | vào | không dùng | `id_q`, `0`, `0`, `0` |
| mem | `mem_valid` | vào | chiếm cổng dữ liệu (thay cho mux hiện nay) | `matrix_mem_request` |
| | `mem_ready` | ra | `1` khi MEM trống; luôn đúng khi lệnh ma trận ở EX | |
| | `mem_req.addr`, `we`, `be`, `wdata` | vào | `alu_out_address`, `data_mem_we_re`, `mask`, `store_data_out` | `matrix_mem_addr/we/wstrb/wdata` |
| | `mem_req.size`, `mode`, `attr`, `spec` | vào | bỏ qua | `2` (word), `2'b11`, `0`, `0` |
| | `mem_req.last` | vào | bỏ qua | xem mục 9, câu hỏi 2 |
| | `mem_resp.exc`, `exccode`, `dbg` | ra | `0` | |
| mem result | `mem_result_valid` | ra | `data_mem_valid` của yêu cầu do coprocessor phát | `matrix_mem_rvalid` |
| | `mem_result.rdata` | ra | `load_data_in` | `matrix_mem_rdata` |
| | `mem_result.err`, `dbg` | ra | `0` | |

## 6. Hành vi

### 6.1 Phía core (`Core.v`)

- **Phát lệnh:** khi lệnh opcode 0x2B ở EX, `issue_valid = 1`. Do `X_ISSUE_REGISTER_SPLIT = 0`,
  register được gửi cùng lúc, với `rs_valid = 11`.
- **Hazard ở ID:** core không giải mã lệnh ma trận nữa, nên coi mọi lệnh 0x2B là **đọc cả `rs1`
  và `rs2`**. Cách này đúng nhưng có thể dừng thêm khi trường `rs` không dùng trùng với một thanh
  ghi đang chờ ghi. Hồi quy ở mục 8 cho thấy số chu kỳ thêm vào. Nếu muốn giữ đúng số chu kỳ cũ,
  có thể giữ `mx_uses_rs*` trong core như một "gợi ý" (câu hỏi 4).
- **Commit:** cùng chu kỳ với issue, `commit_kill = 0`. Lệnh đã ở EX nên mọi lệnh nhánh cũ hơn
  đã xử lý xong, không có gì hủy được nó.
- **Stall:** `matrix_wait` cũ được thay bằng `xif_wait = lệnh đã accept && !(result_valid && result_ready)`,
  OR vào `execute_wait`.
- **Bị từ chối (`accept = 0`):** không stall, lệnh đi tiếp như NOP, giống hiện nay.
- **Ghi `rd`:** khi có result với `we = 1`, `result.data` thay cho kết quả ALU, và lệnh đi qua
  MEM/WB như một lệnh ALU. Phần giữ kết quả (`matrix_wb_hold`) được giữ lại.
- **Cổng dữ liệu:** khi `mem_valid = 1`, địa chỉ, `we`, `mask`, dữ liệu ghi lấy từ `mem_req`
  (thay bộ mux ở `core_matrix.v:706-711`). `mem_result_valid = data_mem_valid` cho các yêu cầu
  của coprocessor.

### 6.2 Phía adapter (`matrix_xif_adapter.sv`)

Máy trạng thái bốn trạng thái:

| Trạng thái | Việc | Chuyển |
|---|---|---|
| `IDLE` | `issue_ready = 1`; `accept = matrix_supported` (giải mã tổ hợp trên `issue_req.instr`) | issue + accept + commit (kill = 0) → `START` |
| `START` | `matrix_valid = 1` đúng một chu kỳ; `insn`, `rs1`, `rs2` lấy từ thanh ghi chốt | → `BUSY` |
| `BUSY` | giữ `insn/rs` ổn định; chuyển tiếp `mem_*` | `matrix_done` → nếu `result_ready` thì `IDLE`, nếu không thì `RESULT` |
| `RESULT` | giữ `result_valid` và `result` cho tới khi `result_ready` | → `IDLE` |

- Chốt `insn/rs` và phát `matrix_valid` một chu kỳ sau issue giải quyết điểm 2 và 3 ở mục 2:
  đầu vào ổn định suốt lệnh, và `matrix_valid` luôn về 0 giữa hai lệnh nên `accept_block` được xóa.
- `result_valid = matrix_done` trong `BUSY` (đi thẳng, không thêm chu kỳ). Thanh ghi ở trạng thái
  `RESULT` chỉ dùng khi core chưa sẵn sàng.
- Spec cho phép coprocessor chạy trước khi commit nếu hoàn tác được. Adapter **chờ commit**, vì
  lệnh ma trận ghi bộ nhớ và thanh ghi ma trận, không hoàn tác được. Với core này, commit đến
  cùng chu kỳ issue nên không mất gì.
- `matrix_supported` lúc issue phải tính trên `issue_req.instr` (tổ hợp). Sau đó
  `matrix_core_v2` nhận `insn_q`. Hai giá trị này bằng nhau.

### 6.3 Giản đồ thời gian: một lệnh `mmovw.x.m x10, acc0, x6`

```
chu kỳ           t        t+1       t+2  ...  t+L      t+L+1
EX               mmovw    mmovw     mmovw     mmovw    (lệnh sau)
issue_valid      1
issue/reg/commit ▲ (cùng chu kỳ)
adapter          IDLE     START     BUSY ...  BUSY     IDLE
matrix_valid              1
matrix_done                                   1
result_valid                                  1        (we=1, rd=x10)
execute_wait     1        1         1         0
```

So với hiện nay, `matrix_valid` đến muộn **một chu kỳ** (do chốt ở `START`). Ước tính thêm
**khoảng 1 chu kỳ cho mỗi lệnh ma trận** được accept. Bộ hồi quy có 179 lệnh ma trận trên tổng
7 683 chu kỳ, tức thêm khoảng 2,3 %. Con số đo thật sẽ có sau khi làm xong.

## 7. File

| File | Việc |
|---|---|
| `rtl/xif/cvxif_pkg.sv` | tham số mục 3, struct cho từng giao tiếp (tên trường theo spec v1.0.0) |
| `rtl/xif/matrix_xif_adapter.sv` | mục 6.2 |
| `rtl/core_if/Core.v` | thêm cổng XIF (mục 6.1); bỏ cách phát lệnh ma trận riêng |
| `rtl/xif/core_matrix_xif.v` | top: `core` + adapter + `matrix_core_v2`, **cùng cổng với `core_matrix.v`** |
| `tb/xif/xif_checker.sv` | bộ kiểm tra giao thức gắn vào bus XIF (mục 8) |
| `rtl/matrix_if/core_matrix.v` | giữ lại làm bản đối chứng cho tới khi XIF qua hết kiểm tra, sau đó xóa |

## 8. Kiểm chứng

**Baseline đã có (việc B).** `tb/matrix/tb_matrix_regress.sv`, `scripts/gen_matrix_regress.py`,
`scripts/run_matrix_regress.py`. Bảy chương trình, không chèn NOP:

| Case | Nội dung | Lệnh ma trận | Chu kỳ (`core_matrix`) |
|---|---|---|---|
| `ls` | load/store A, B (8 và 32 bit), C; tile đủ và thiếu; hai stride; `msettile*` qua rs1; `mrelease` | 25 | 885 |
| `mm_int` | `mmaccu/us/su/mmacc.w.b`, cộng dồn, tile 3×4×7 | 25 | 1 074 |
| `mm_fp` | `mfmacc.s` 4×4×4 và 2×3×3 | 14 | 552 |
| `ew_int` | 11 phép `.w`, mỗi phép dạng `.mm` và `.mv` | 50 | 2 639 |
| `ew_fp` | 5 phép FP32 `.mm` với NaN, ∞, ±0, subnormal | 15 | 876 |
| `misc` | `mzero`, `mmov.mm`, `mmovw.x.m` (ghi GPR), `mmovw.m.x`, `mdupw`, 4 phép slide | 33 | 1 062 |
| `pipeline` | hazard rs1/rs2, lw/sw sát lệnh ma trận, FP xen kẽ, hai lệnh giống hệt liền nhau, nhánh nhảy qua lệnh ma trận, nhánh theo kết quả `mmovw.x.m`, 5 mã bị từ chối | 17 (+5 từ chối, 1 bị bỏ qua) | 595 |

Mỗi case được kiểm tra hai cách:

- **expect:** 282 word có giá trị suy ra được từ quy tắc đơn giản (sao chép, matmul số nguyên tính
  bằng Python, `mdupw`, kết quả vô hướng). Tất cả đều khớp trên `core_matrix`.
- **golden:** toàn bộ trạng thái cuối và thứ tự lệnh retire được ghi ở `tb/matrix/golden/`. Bao
  gồm GPR, FPR, 8 thanh ghi ma trận, `mtilem/n/k` và RAM `0x1000`–`0x3FEF`.

Sau khi làm XIF, phải đạt: **trạng thái và thứ tự retire trùng golden 7/7**. Số chu kỳ được báo
cáo, dự kiến tăng khoảng 1 chu kỳ mỗi lệnh.

**Bộ kiểm tra giao thức** (`xif_checker.sv`, assertion trong mô phỏng):

1. `issue_req` ổn định khi `issue_valid && !issue_ready`; tương tự cho `result`, `mem_req`.
2. `register_valid == issue_valid`, `register_ready == issue_ready` (split = 0).
3. Mỗi lệnh được accept có **đúng một** result; không có result cho lệnh bị từ chối.
4. Result không đến trước commit của cùng `id`; `result.id` khớp lệnh đang chờ.
5. `result.we` khớp `issue_resp.writeback`.
6. `mem_valid` chỉ xuất hiện khi lệnh hiện tại có `loadstore = 1`; `mem_valid → mem_ready`.
7. Số `mem_result` bằng số `mem_req` của load.

**Hồi quy phần vô hướng:** vì `Core.v` có thay đổi, chạy lại ACT4 119 ELF (RTL, netlist) và
lockstep. Số chu kỳ phải **trùng** kết quả hiện có (`reports/act4_runs/20261031_164609_all`),
vì core không gắn coprocessor thì hành vi không đổi.

**Tổng hợp KV260:** tài nguyên và Fmax của `core` (so với số hiện có) và của
`core_matrix_xif` (so với `core_matrix`).

## 9. Chỗ lệch so với spec và câu hỏi cần thống nhất

1. **Không có bẫy lệnh không hợp lệ.** Spec yêu cầu core báo illegal instruction khi lệnh bị
   từ chối và core cũng không hiểu. Core này không có trap (đã thống nhất là ngoài phạm vi), nên
   lệnh đó là NOP. Ghi rõ là sai khác có chủ ý.
2. **`mem_req.last`.** Spec yêu cầu `last = 1` ở giao dịch cuối của mỗi lệnh. `matrix_tile_ls`
   không đưa thông tin này ra ngoài. Có hai cách:
   - (a) thêm một cổng `mem_last` vào `matrix_tile_ls` (khoảng 1 dòng, cần bạn cùng nhóm đồng ý);
   - (b) adapter tự tính từ `mtilem/n/k` và kích thước phần tử (lặp lại logic của tile_ls).

   Core này không dùng `last`, nên nó chỉ ảnh hưởng tính đúng chuẩn. Đề xuất (a).
3. **`mem_ready`: làm đủ bắt tay valid/ready.** Mục tiêu tiếp theo là AXI, nơi bus có thể chưa
   nhận yêu cầu, nên không dựa vào việc core luôn nhận ngay. `matrix_tile_ls` hiện phát yêu cầu
   một chu kỳ rồi đi tiếp (store không chờ gì cả), nên adapter không thể tự giữ hộ mà không có
   giới hạn. Cách đúng: thêm đầu vào `mem_ready` cho `matrix_tile_ls` và giữ nguyên trạng thái
   `ST_LOAD_REQ`/`ST_STORE_REQ` (cùng địa chỉ, dữ liệu) cho tới khi `mem_ready = 1`. Khi
   `mem_ready` luôn bằng 1 thì hành vi và số chu kỳ không đổi (golden phải trùng). Cần bạn cùng
   nhóm đồng ý, gộp chung với cổng `mem_last` ở câu 2. Với bộ nhớ hiện tại core luôn trả
   `mem_ready = 1` (MEM trống khi lệnh ma trận ở EX); testbench của adapter sẽ thử `mem_ready`
   ngẫu nhiên.
4. **Hazard bảo thủ.** Coi mọi lệnh 0x2B đọc cả `rs1`, `rs2` (đúng tinh thần XIF, có thể chậm
   hơn vài chu kỳ), hay giữ `mx_uses_rs*` trong core (số chu kỳ như cũ, nhưng core lại phải biết
   về lệnh ma trận)?
5. **Chỉ offload opcode 0x2B.** Spec cho phép core offload mọi lệnh nó không hiểu. Để đơn giản và
   giữ ACT4 không đổi, chỉ offload custom-1 (0x2B). *Đã chốt.*
6. **Kết quả cho store.** Giữ đúng spec: core phát `mem_result` cho mọi `mem_req`, cả load lẫn
   store, và adapter có đủ cổng nhận. `matrix_tile_ls` hiện chỉ dùng kết quả của load; adapter
   vẫn đếm số `mem_result` (checker kiểm tra mỗi `mem_req` có đúng một kết quả) để phần mở rộng
   sau này (ví dụ báo lỗi bus qua `err`) dùng được ngay. *Đã chốt.*

## 10. Thứ tự làm

1. `cvxif_pkg.sv` và `matrix_xif_adapter.sv`, cùng một testbench nhỏ chỉ cho adapter, có checker.
2. Thêm cổng XIF vào `Core.v`. Chạy ACT4 RTL 119 ELF: phải PASS với số chu kỳ trùng kết quả cũ.
3. Top `core_matrix_xif.v`. Chạy `run_matrix_regress.py --dut core_matrix_xif --core uut.u_core`:
   phải trùng golden 7/7.
4. Netlist và lockstep cho `core`; tổng hợp KV260 cho `core` và `core_matrix_xif`.
5. Xóa `core_matrix.v` khi đã đạt đủ các bước trên.
