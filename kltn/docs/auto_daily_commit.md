# Checkpoint Git hằng ngày cho KLTN

Script: `kltn/scripts/auto_daily_commit.py`. Chạy bằng Python 3.9+ và Git có hỗ trợ
`git add --pathspec-from-file` (Git 2.25+). Không cần pip, AI API hay dịch vụ cloud.

## 1. Chạy dry-run trước khi cài scheduler

Trong WSL Ubuntu, bắt buộc chạy và đọc danh sách file/thông điệp trước khi bật lịch:

```bash
cd /mnt/c/TPU/TPU
python3 kltn/scripts/auto_daily_commit.py --dry-run
```

Ví dụ khi mới thêm bộ automation này (ngày thực tế lấy theo giờ hệ thống):

```text
========================================
KLTN DAILY COMMIT
Date: 2026-09-15
Branch: master
Repository: /mnt/c/TPU/TPU
Files changed: 3
  Added    'kltn/docs/auto_daily_commit.md'
  Added    'kltn/scripts/auto_daily_commit.py'
  Added    'kltn/scripts/test_auto_daily_commit.py'
Generated commit message:
Daily KLTN update 2026-09-15

- Add daily Git checkpoint setup guide
- Add daily Git checkpoint automation
- Add daily Git checkpoint tests

========================================
Preview only: no git add, commit or push. Untracked whitespace is checked after staging in a normal run.
```

Dry-run và `--show-summary` không chạy `git add`, commit hoặc push, kể cả khi có
`--push` hay `AUTO_PUSH=true`. Chúng có ghi log/lock ngoài repository. File mới
chưa tracked được đọc để phân tích; kiểm tra whitespace bằng Git cho những file
này diễn ra sau stage trong lần chạy thật. File tracked được kiểm tra ngay.

## 2. Chạy thủ công

Chạy từ root repository:

```bash
# Chỉ xem summary
python3 kltn/scripts/auto_daily_commit.py --show-summary

# Tạo checkpoint local; mặc định không push
python3 kltn/scripts/auto_daily_commit.py

# Cho phép push sau commit mới thành công, chỉ trong lần chạy này
python3 kltn/scripts/auto_daily_commit.py --push

# Cách tương đương bằng biến môi trường
AUTO_PUSH=true python3 kltn/scripts/auto_daily_commit.py
```

`AUTO_PUSH` mặc định `false`. Khi không có thay đổi phù hợp thì kết thúc với mã 0,
không tạo commit rỗng và không push, dù đã bật tùy chọn push. Nếu lần push trước
thất bại, commit local vẫn còn; sau khi kiểm tra, có thể chạy thủ công
`git push origin master` để đẩy commit đang chờ. Không có rollback hay force push.

Kiểm tra Git identity trong **WSL** trước lần chạy thật:

```bash
git config user.name
git config user.email
git remote -v
date
```

Nếu identity chưa có, tự đặt `git config user.name "Tên của bạn"` và
`git config user.email "email của bạn"`. Script không tự sửa cấu hình Git.
SSH key/agent cần khả dụng cho đúng user WSL nếu bật push. Scheduler không tự nhập
passphrase hay lưu mật khẩu. Giữ push tắt khi mới thiết lập.

## 3. Phạm vi và điều kiện an toàn

- Chỉ xét `kltn/`, root `README.md` và `.gitignore`; kiểm tra root từ vị trí script
  và yêu cầu origin đúng `git@github.com:chitam1211/TPU.git`.
- Dừng với mã 1 và ghi log khi sai branch, detached HEAD, conflict, merge/rebase/
  cherry-pick/revert/bisect đang chạy, Git command thất bại hoặc whitespace lỗi.
  Không tự chuyển branch.
- Nếu index có thay đổi được stage sẵn, lần chạy thật dừng để không trộn phần
  người dùng đã chọn vào checkpoint. Hãy commit phần đó hoặc tự unstage những
  file muốn đưa vào lần chạy sau. Dry-run vẫn cho xem thay đổi cuối cùng so với HEAD.
- Lọc `.log`, `.jou`, `.vcd`, `.wdb`, `.wcfg`, `.str`, `.zip`, `.pyc`, `.pyo`,
  `__pycache__`, build/cache/Vivado directories, `kltn/reports/**/before/`,
  backup và `frozen_before.json`. Thận trọng bỏ **mọi PDF**, kể cả PDF chưa có
  trong `.gitignore`; nếu cần version PDF thì commit thủ công.
- Dùng `git check-ignore --no-index` để bỏ cả file đã tracked nhưng hiện bị ignore.
  Các file tracked generated vẫn tồn tại trong lịch sử; script không tự untrack.
  Submodule/thư mục cần xử lý thủ công.
- Tách Added/Modified/Deleted; rename được mô tả là Remove + Add. Nhóm mô tả
  theo chức năng, tối đa 10 dòng; ít thay đổi thì ít dòng. Heuristic dùng tên file,
  thư mục và dòng thay đổi; không khẳng định tính đúng đắn của RTL.
- Đọc status, diff, diff stat và cached diff. Sau stage, tạo lại message từ nội
  dung cached để mô tả phần sẽ commit. Không chạy kiểm thử chức năng RTL/ISS.
- Chạy `git diff --check` trên worktree và `git diff --cached --check` trước commit.
  Lỗi whitespace ở file tracked ngoài phạm vi cũng có thể chặn lần chạy.
- Khi lỗi xảy ra **sau stage** (whitespace file mới, hook, identity...), giữ nguyên
  source và index để bạn kiểm tra bằng `git status`, `git diff --cached`.
  Script không tự unstage/discard. Sau khi sửa, tự commit hoặc unstage rồi chạy lại.
- Lock ngoài repo ngăn hai lần chạy script đồng thời trong cùng môi trường/user.
  Không thao tác Git thủ công đồng thời; lock này không khóa editor, Git GUI hay
  tiến trình Git khác. Chọn **một** scheduler và chạy nhất quán trong WSL, không
  chạy song song từ Windows. Script kiểm tra lại HEAD/index trước commit.
- Hook/config Git hiện có vẫn được tôn trọng. Lần chạy thủ công bổ sung có thể tạo
  thêm checkpoint trong cùng ngày; script không giới hạn cứng một commit/ngày.

## 4A. Cron trong WSL: 23:30 mỗi ngày

Sau khi dry-run đạt yêu cầu, trong WSL tạo thư mục output ngoài repository:

```bash
mkdir -p "$HOME/.local/state/kltn-auto-commit"
sudo service cron start
crontab -e
```

Thêm dòng dưới đây. `/home/chitam` theo user trong yêu cầu; thay bằng kết quả
`printf '%s\n' "$HOME"` nếu home thực tế khác. Đường dẫn chương trình và project
đều tuyệt đối; output stdout/stderr được nối vào file ngoài repo.

```cron
30 23 * * * cd /mnt/c/TPU/TPU && AUTO_PUSH=false /usr/bin/python3 /mnt/c/TPU/TPU/kltn/scripts/auto_daily_commit.py >> /home/chitam/.local/state/kltn-auto-commit/scheduler.log 2>&1
```

Nếu cron chưa được cài, cài gói `cron` bằng package manager Ubuntu trước.
Kiểm tra `crontab -l`, `service cron status` và `date`. Lịch theo múi giờ cron/
hệ thống WSL; xác nhận giờ Việt Nam nếu muốn 23:30 Việt Nam. WSL đã bật systemd
có thể dùng `sudo systemctl enable --now cron` để khởi động dịch vụ cùng distro.

Cron cần WSL và daemon cron đang chạy khi đến giờ; không tự khởi động distro
đang dừng và không đảm bảo chạy bù lịch đã bỏ lỡ. Xem tài liệu
[crontab của Ubuntu](https://manpages.ubuntu.com/manpages/bionic/man5/crontab.5.html).

**Tắt:** chạy `crontab -e`, xóa hoặc thêm `#` trước riêng dòng KLTN. Không dùng
`crontab -r` vì sẽ xóa cả những lịch khác.

## 4B. Windows Task Scheduler gọi WSL: khuyến nghị

Cách này gọi `wsl.exe` để khởi động Ubuntu khi Windows còn bật, nên phù hợp hơn
cron nếu bạn thường đóng WSL. Cú pháp chọn distro/user dựa trên
[lệnh WSL của Microsoft](https://learn.microsoft.com/en-us/windows/wsl/basic-commands).

1. Trong PowerShell chạy `wsl.exe -l -q` để xác nhận tên distro, rồi chạy thử:

   ```powershell
   wsl.exe -d Ubuntu -u chitam -- bash -lc "cd /mnt/c/TPU/TPU && /usr/bin/python3 kltn/scripts/auto_daily_commit.py --dry-run"
   ```

2. Tạo thư mục log bằng lệnh `mkdir -p` ở phần cron trong WSL. Mở **Task Scheduler
   → Create Task**, đặt tên `KLTN Daily Commit`. Dùng tài khoản Windows đã cài
   distro Ubuntu này; không dùng SYSTEM. Nếu muốn chạy lúc đã đăng xuất, chọn
   **Run whether user is logged on or not** và thiết lập thông tin đăng nhập theo
   giao diện Windows; không lưu mật khẩu vào script.
3. **Triggers → New → Daily → 23:30** (múi giờ Windows).
4. **Actions → Start a program**:

   Program/script:

   ```text
   C:\Windows\System32\wsl.exe
   ```

   Add arguments (một dòng; thay `Ubuntu`, `chitam`, `/home/chitam` nếu cần):

   ```text
   -d Ubuntu -u chitam -- bash -lc "cd /mnt/c/TPU/TPU && AUTO_PUSH=false /usr/bin/python3 /mnt/c/TPU/TPU/kltn/scripts/auto_daily_commit.py >> /home/chitam/.local/state/kltn-auto-commit/scheduler.log 2>&1"
   ```

   Start in: có thể để trống vì đã dùng đường dẫn tuyệt đối.
5. **Settings:** bật **Run task as soon as possible after a scheduled start is
   missed**; chọn **Do not start a new instance** nếu task đang chạy. Tính năng
   chạy bù có thể có độ trễ, theo
   [StartWhenAvailable](https://learn.microsoft.com/en-us/windows/win32/taskschd/tasksettings-startwhenavailable).
6. **Conditions:** nếu muốn chạy khi máy sleep, cân nhắc **Wake the computer to run
   this task**, phụ thuộc cấu hình nguồn/phần cứng. Xem
   [WakeToRun](https://learn.microsoft.com/en-us/windows/win32/taskschd/tasksettings-waketorun).
   Máy tắt hoàn toàn thì không chạy đúng giờ; dùng tùy chọn chạy bù khi bật lại.
7. Sau khi xem dry-run, lưu task. **Run** sẽ chạy thật và có thể tạo commit ngay.
   Kiểm tra **Last Run Result** (`0x0` thành công) và log; một lần không có thay
   đổi cũng trả về thành công.

**Tắt:** Task Scheduler → `KLTN Daily Commit` → **Disable**. Bật lại bằng **Enable**;
có thể **Delete** riêng task này nếu không còn dùng. Chỉ cấu hình một trong hai cách.

## 5. Xem log và chạy kiểm thử

```bash
# Log của script: no-op, preview, commit hash/message, push và lỗi
tail -n 100 ~/.local/state/kltn-auto-commit/auto_commit.log

# Output đầy đủ của scheduler
tail -n 100 ~/.local/state/kltn-auto-commit/scheduler.log

# Lịch sử checkpoint local
git log -5 --format=fuller

# Unit/integration tests dùng repository tạm, không push mạng
cd /mnt/c/TPU/TPU
python3 -B -m unittest discover -s kltn/scripts -p test_auto_daily_commit.py -v
```

Nếu đã đặt `XDG_STATE_HOME`, log script nằm trong
`$XDG_STATE_HOME/kltn-auto-commit/auto_commit.log`; cập nhật đường dẫn redirect
scheduler tương ứng. Script từ chối đặt state/log bên trong repository.
Log được nối thêm, chưa có rotation tự động.

Việc thêm các file này chưa tự cài cron/Task Scheduler. Hoàn tất dry-run ở bước 1
rồi chọn và thiết lập scheduler ở bước 4 để bắt đầu chạy mỗi ngày.
