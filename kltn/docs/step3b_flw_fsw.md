# Checkpoint Step 3B — FLW/FSW end-to-end

Ngày: 13/09/2026. Phạm vi theo lựa chọn của nhóm: hoàn tất Step 3B và kiểm chứng FLW/FSW; chưa thực hiện FADD.S/FSUB.S. Step 3A đã PASS từ lượt trước. `rtl/core` và `rtl/matrix` được giữ nguyên; SHA-256 của các file trong hai thư mục đã được đối chiếu sau thay đổi.

## Datapath đã nối

- `Decode.v` instantiate `u_fp_regfile0`, dùng FPR 3R/1W đã có. Hai cổng đọc chưa dùng cho Step 3B được để trống có chủ đích, dành cho các lệnh FP arithmetic sau này.
- FLW tính địa chỉ bằng GPR `rs1` + immediate I, nạp nguyên 32 bit và ghi FPR ở WB.
- FSW tính địa chỉ bằng GPR `rs1` + immediate S, chọn `fp_op_b` làm store data. SW tiếp tục dùng GPR `op_b`.
- `fp_reg_write` truyền qua ID/EX (`decode_pipe`), EX/MEM (`execute_pipe`) và MEM/WB (`memory_pipe`), được reset, giữ khi stall và xóa khi bubble.
- `reg_write_wb` và `fp_reg_write_wb` là hai write-enable riêng. Một lệnh chỉ ghi một bank. `f0` có thể ghi và có dependency như các FPR khác; `x0` vẫn luôn bằng 0.

## Các sửa nền cần thiết cho kiểm chứng CPU

Việc chỉ nối dây không đủ để FLW/FSW chạy đúng trên core cũ. Các thay đổi sau chỉ áp dụng trong `rtl/core_if`:

1. **Stage validity và memory completion:** Core theo dõi lệnh hợp lệ tại ID/EX/MEM/WB. Chỉ đưa write-enable sang WB khi lệnh hoàn tất; lệnh load đang chờ không được ghi dữ liệu cũ hoặc ghi lặp.
2. **Bỏ cơ chế phát lại load trong tích hợp:** `Decode.valid` và `load_control_signal` được nối 0 trong Core. `controlunit` vẫn giữ giao diện cũ cho test decode, nhưng CPU dùng stall/bubble/valid tường minh. Nhờ đó `load_control` không kích nhầm GPR write-back cho FLW.
3. **Phụ thuộc thanh ghi:** Decode chờ các producer ở EX/MEM/WB ghi xong. So sánh tách bank x/f và xét toán hạng thực sự được dùng. Đã bỏ mux forwarding cũ có thể ghi đè immediate bằng kết quả ALU hoặc nhầm `xN` với `fN`.
4. **Fetch và redirect:** PC chỉ tiến khi nhận instruction response hợp lệ. IF/ID giữ lệnh khi chưa thể issue. Branch/JAL/JALR redirect ở EX, bỏ phản hồi fetch cũ nếu còn đang chờ; JALR xóa bit 0 của target.
5. **Điều khiển integer:** Các immediate arithmetic không còn dùng bit 30 của immediate như điều kiện funct7. JALR chọn PC+4 làm write-back. Control decoder có default cho các mux control để không suy ra latch.
6. **Memory formatting:** `wrapper_memory.v` dùng byte lane 2 bit và dịch dữ liệu rõ ràng; SB/SH lên lane cao được kiểm hồi quy. LW/FLW và SW/FSW bảo toàn toàn bộ word.
7. **Độc lập với matrix:** Thêm `rtl/core_if/memory_stage.v`; compile core_if không cần kéo file từ `rtl/matrix`.
8. **Khởi tạo instruction RAM:** `microprocessor` nhận tham số `IMEM_FILE`. Chuỗi rỗng mặc định không đọc file; đường dẫn được truyền qua `instruc_mem_top` vào `memory`, thay đường dẫn Linux cố định. Testbench nạp instruction/data RAM trực tiếp; không force hay gán trực tiếp thanh ghi CPU.

Đây là cơ chế chờ bảo thủ để giảm độ phức tạp kiểm chứng. Core vẫn có năm tầng, nhưng fetch một yêu cầu tại một thời điểm và chờ dependency thay vì forwarding, nên thông lượng có thể giảm. Chưa dùng checkpoint này để kết luận hiệu năng so với core cũ hoặc Giáp.

## Giao ước memory hiện tại

- Hai cổng instruction/data độc lập; mỗi cổng tối đa một yêu cầu đang chờ.
- `request` được phát một chu kỳ; memory chấp nhận tại cạnh lên. Chưa có `grant/ready` để từ chối request.
- Memory trả `valid` cùng dữ liệu ổn định sau ít nhất một chu kỳ. Data memory trả completion cho **cả load và store**; core giữ MEM đến completion.
- `data_memory_top.valid` được đổi từ `load` trễ một chu kỳ thành `request` trễ một chu kỳ để đáp ứng giao ước này.
- Request mới không được phát lại trong thời gian chờ. Reset chung CPU/memory hủy transaction đang chờ và xóa write-enable.
- RAM demo hiện là 256 word/cổng, địa chỉ chọn `[9:2]`; không coi đây là hệ thống bộ nhớ 4 GiB hoàn chỉnh. Kiểm chứng giới hạn ở địa chỉ nằm trong RAM, word/halfword căn chỉnh tự nhiên. Chưa thêm trap cho truy cập sai căn chỉnh, lỗi bus hoặc opcode không hỗ trợ.

## Chạy kiểm chứng

Từ thư mục `kltn`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_core_if_tests.ps1
```

Script tìm project theo vị trí của nó, nên cũng có thể gọi từ thư mục khác. Mỗi test phải compile thành công, mô phỏng thoát thành công, có marker PASS và không có marker FAIL. Log nằm tại `reports/step3b_20260913/`, binary tại `sim/build/`.

| Test | Nội dung |
|---|---|
| `register_file` | Giữ kiểm tra GPR và x0 |
| `fp_register_file` | Giữ kiểm tra FPR 3R/1W và f0 |
| `alu` | Giữ kiểm tra integer ALU và shift |
| `fp_mem_decode` | FLW/FSW, các funct3 không hỗ trợ, chặn load và hồi quy decode |
| `fp_mem_e2e` | Chạy chương trình trên `microprocessor` và RAM RTL thực |
| `fp_mem_e2e_delayed` | Cùng chương trình/core/RAM, thêm độ trễ response phụ thuộc địa chỉ |

Hai test end-to-end kiểm:

- Round trip qua đủ `f0–f31`, 32 mẫu raw bits: ±0, ±1, qNaN/sNaN có payload, ±Inf, subnormal, normal biên và mẫu LFSR cố định.
- FLW → FSW liền nhau, không chèn NOP phần mềm; base address vừa được tính; immediate âm cho cả FLW và FSW.
- Hai lệnh FLW có encoding giống hệt nhau phải thực thi đủ hai lần.
- GPR/FPR cùng chỉ số không bị nhầm; SW và FSW lấy đúng nguồn; x0 không đổi và f0 ghi được.
- Kiểm thứ tự, số lượng, địa chỉ, mask và dữ liệu của từng request memory bằng danh sách kỳ vọng độc lập với state điều khiển DUT.
- LW/SW, SB/LB/LBU, SH/LH/LHU; immediate âm, ADD phụ thuộc; branch thuận/ngược, JAL và JALR; lệnh FP trên đường bị bỏ không tạo request.
- Reset sau khi FLW đã gửi request nhưng chưa ghi FPR, rồi chạy chương trình mới để phát hiện write-back cũ.

Đã chạy ngày 13/09/2026: `CORE_IF_STEP3B_TESTS_PASS (6/6)`, compile không có cảnh báo. Pha round-trip/hồi quy chính có 82 request memory và 35 lần ghi FPR ở cả hai cấu hình; test còn chạy thêm pha reset/restart. Thời gian pha chính là 419 chu kỳ với RAM mặc định và 961 chu kỳ khi làm trễ phản hồi. Các số này mô tả đúng chương trình test hiện tại, không phải benchmark so sánh với core cũ. Đây là kiểm chứng chức năng có hướng, chưa phải chứng nhận đầy đủ RV32I/RV32IF, coverage toàn ISA hay kết quả tổng hợp FPGA.

## Tiếp theo

Step 4 là tự viết và kiểm chứng FADD.S/FSUB.S, rồi nối vào giao diện write-back FPR đã có. Các lệnh F còn lại và FCSR/rounding/flags vẫn là công việc tiếp theo; matrix FP32 tiếp tục chờ scalar F ổn định theo bản bàn giao.

Bản sao trước thay đổi: `reports/step3b_20260913/before/core_if/`.
