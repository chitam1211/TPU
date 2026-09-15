# Checkpoint Git khi đăng nhập và mỗi 4 giờ cho KLTN

Script: `kltn/scripts/auto_daily_commit.py`. Chạy bằng Python 3.9+ và Git có hỗ trợ
`git add --pathspec-from-file` (Git 2.25+). Không cần pip, AI API hay dịch vụ cloud.

Windows Task Scheduler gọi script khi user đăng nhập, sau đó lặp mỗi 4 giờ.
Mỗi lần script chạy một lượt rồi thoát; không có vòng lặp/sleep 4 giờ trong Python.
Chỉ tạo checkpoint nếu có thay đổi hợp lệ mới. Không đổi source thì các lần chạy
sau trả mã 0, không stage, không tạo empty commit, không amend và không push.

Title dùng giờ local của WSL tại thời điểm bắt đầu lần chạy:
`KLTN checkpoint YYYY-MM-DD HH:MM`. Có thể có nhiều checkpoint cùng ngày, ví dụ
`KLTN checkpoint 2026-09-15 13:30` và `KLTN checkpoint 2026-09-15 17:30`.
Hai lần chạy thủ công trong cùng phút có thể có title giống nhau theo format này;
commit hash vẫn phân biệt chúng. Script không dùng title/ngày để chặn commit mới.

## 1. Chạy dry-run trước khi cài scheduler

Trong WSL Ubuntu, bắt buộc chạy và đọc danh sách file/thông điệp trước khi bật lịch:

```bash
cd /mnt/c/TPU/TPU
python3 kltn/scripts/auto_daily_commit.py --dry-run
```

Ví dụ khi sửa bộ automation này (timestamp thực tế lấy theo giờ hệ thống):

```text
========================================
KLTN CHECKPOINT
Date: 2026-09-15 17:30
Branch: master
Repository: /mnt/c/TPU/TPU
Files changed: 3
  Modified 'kltn/docs/auto_daily_commit.md'
  Modified 'kltn/scripts/auto_daily_commit.py'
  Modified 'kltn/scripts/test_auto_daily_commit.py'
Generated commit message:
KLTN checkpoint 2026-09-15 17:30

- Update daily Git checkpoint setup guide
- Update daily Git checkpoint automation
- Update daily Git checkpoint tests

========================================
Preview only: no git add, commit or push. Untracked whitespace is checked after staging in a normal run.
```

Dry-run và `--show-summary` không chạy `git add`, commit hoặc push, kể cả khi có
`--push` hay `AUTO_PUSH=true`. Chúng ghi log ngoài repository, **không tạo hay giữ
lock**, và không xóa lock của lần chạy khác. File mới
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

Khi không có thay đổi hợp lệ, terminal in chính xác:

```text
No KLTN changes to commit.
```

Các dòng `Skip ...` có thể xuất hiện trước đó để giải thích file bị loại.
`--push` và `AUTO_PUSH=true` chỉ dành cho lần chạy bạn chủ động bật push; **không
đặt `AUTO_PUSH=true` trong profile WSL hoặc cấu hình scheduler**. Lịch bên dưới
không truyền `--push` và giữ auto push tắt.

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
- File `~/.local/state/kltn-auto-commit/auto_commit.lock` dùng `flock` không chờ
  trên WSL (Windows dùng byte-range lock), ngăn hai instance trong cùng state dir.
  Nếu process khác đang giữ lock, in `WARNING: Another KLTN checkpoint is running;
  skipping this run.`, log `SKIPPED_LOCK` rồi thoát **mã 0**.
  Hệ điều hành nhả lock khi process kết thúc, kể cả bị kill. File có thể còn lại
  nhưng không khóa lần chạy sau; không xóa file lock để tránh race giữa các process.
  Không thao tác Git thủ công đồng thời; lock này không khóa editor, Git GUI hay
  tiến trình Git khác. Chọn **một** scheduler và chạy nhất quán trong WSL, không
  chạy song song từ Windows. Script kiểm tra lại HEAD/index trước commit.
- Hook/config Git hiện có vẫn được tôn trọng. Lần chạy thủ công bổ sung có thể tạo
  thêm checkpoint trong cùng ngày; script không giới hạn cứng một commit/ngày.

## 4A. Cron trong WSL: phương án phụ mỗi 4 giờ

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
0 */4 * * * cd /mnt/c/TPU/TPU && AUTO_PUSH=false /usr/bin/python3 /mnt/c/TPU/TPU/kltn/scripts/auto_daily_commit.py >> /home/chitam/.local/state/kltn-auto-commit/scheduler.log 2>&1
```

Nếu cron chưa được cài, cài gói `cron` bằng package manager Ubuntu trước.
Kiểm tra `crontab -l`, `service cron status` và `date`. Lịch theo múi giờ cron/
hệ thống WSL: 00:00, 04:00, 08:00, 12:00, 16:00, 20:00. Cron không có trigger
Windows login như Task Scheduler bên dưới. WSL đã bật systemd
có thể dùng `sudo systemctl enable --now cron` để khởi động dịch vụ cùng distro.

Cron cần WSL và daemon cron đang chạy khi đến giờ; không tự khởi động distro
đang dừng và không đảm bảo chạy bù lịch đã bỏ lỡ. Xem tài liệu
[crontab của Ubuntu](https://manpages.ubuntu.com/manpages/bionic/man5/crontab.5.html).

**Tắt:** chạy `crontab -e`, xóa hoặc thêm `#` trước riêng dòng KLTN. Không dùng
`crontab -r` vì sẽ xóa cả những lịch khác.

## 4B. Windows Task Scheduler: At log on + Every 4 hours (khuyến nghị)

Cách này gọi `wsl.exe` để khởi động Ubuntu khi Windows còn bật, nên phù hợp hơn
cron nếu bạn thường đóng WSL. Cú pháp chọn distro/user dựa trên
[lệnh WSL của Microsoft](https://learn.microsoft.com/en-us/windows/wsl/basic-commands).

1. Trong PowerShell chạy `wsl.exe -l -q` để xác nhận tên distro, rồi chạy thử:

   ```powershell
   wsl.exe -d Ubuntu -- bash -lc "cd /mnt/c/TPU/TPU && python3 kltn/scripts/auto_daily_commit.py --dry-run"
   ```

2. Trong WSL chạy `mkdir -p ~/.local/state/kltn-auto-commit` **trước khi bật task**;
   shell mở file redirect trước khi Python chạy nên thư mục này phải tồn tại.
   Mở **Task Scheduler → Create Task**, đặt tên `KLTN Checkpoint`.
   Nếu đã có task `KLTN Daily Commit`, sửa task đó hoặc disable nó trước khi tạo
   task mới để tránh hai lịch song song. Dùng tài khoản Windows đã cài distro
   Ubuntu này; không dùng SYSTEM. Xác nhận default user của Ubuntu là user chứa
   Git identity và log bằng `wsl.exe -d Ubuntu -- whoami`.
   Nếu muốn chạy lúc đã đăng xuất, chọn
   **Run whether user is logged on or not** và thiết lập thông tin đăng nhập theo
   giao diện Windows; không lưu mật khẩu vào script.
3. **Triggers → New** (hoặc sửa trigger cũ):

   - **Begin the task: At log on**.
   - Chọn user Windows của bạn (**Specific user**).
   - **Repeat task every: 4 hours** (có thể gõ `4 hours` nếu không có trong danh sách).
   - **For a duration of: Indefinitely**.
   - Bật **Enabled**. Xóa/tắt trigger Daily 23:30 cũ nếu có.

   Logon trigger hỗ trợ repetition; thời gian lặp tính từ lúc trigger chạy,
   ví dụ login lúc 09:10 thì tiếp theo 13:10, 17:10 khi máy khả dụng. Xem
   [LogonTrigger](https://learn.microsoft.com/en-us/windows/win32/taskschd/taskschedulerschema-logontrigger-triggergroup-element)
   và [Repeating a Task](https://learn.microsoft.com/en-us/windows/win32/taskschd/repeating-a-task).
4. **Actions → Start a program**:

   Program/script:

   ```text
   C:\Windows\System32\wsl.exe
   ```

   Add arguments (một dòng; thay `Ubuntu` nếu distro có tên khác):

   ```text
   -d Ubuntu -- bash -lc "cd /mnt/c/TPU/TPU && python3 kltn/scripts/auto_daily_commit.py >> ~/.local/state/kltn-auto-commit/task_scheduler.log 2>&1"
   ```

   Start in: có thể để trống vì đã dùng đường dẫn tuyệt đối.
5. **Settings:**

   - **Allow task to be run on demand**.
   - **Run task as soon as possible after a scheduled start is missed**.
   - **If the task is already running: Do not start a new instance**.

   Tính năng
   chạy bù có thể có độ trễ, theo
   [StartWhenAvailable](https://learn.microsoft.com/en-us/windows/win32/taskschd/tasksettings-startwhenavailable).
6. **Conditions:** nếu muốn chạy khi máy sleep, cân nhắc **Wake the computer to run
   this task**, phụ thuộc cấu hình nguồn/phần cứng. Xem
   [WakeToRun](https://learn.microsoft.com/en-us/windows/win32/taskschd/tasksettings-waketorun).
   Máy tắt hoàn toàn thì không chạy đúng giờ; dùng tùy chọn chạy bù khi bật lại.
7. Sau khi xem dry-run, lưu task. **Run** sẽ chạy thật và có thể tạo commit ngay.
   Kiểm tra **Last Run Result** (`0x0` thành công) và log; một lần không có thay
   đổi cũng trả về thành công.

**Tắt:** Task Scheduler → `KLTN Checkpoint` (hoặc tên task cũ đã sửa) → **Disable**.
Bật lại bằng **Enable**;
có thể **Delete** riêng task này nếu không còn dùng. Chỉ cấu hình một trong hai cách.

## 5. Xem log và chạy kiểm thử

```bash
# Log của script: no-op, preview, commit hash/message, push và lỗi
tail -n 100 ~/.local/state/kltn-auto-commit/auto_commit.log

# Output đầy đủ của Windows Task Scheduler
tail -n 100 ~/.local/state/kltn-auto-commit/task_scheduler.log

# Lịch sử checkpoint local
git log -5 --format=fuller

# Unit/integration tests dùng repository tạm, không push mạng
cd /mnt/c/TPU/TPU
python3 -B -m unittest discover -s kltn/scripts -p test_auto_daily_commit.py -v
python3 -m py_compile kltn/scripts/auto_daily_commit.py kltn/scripts/test_auto_daily_commit.py
```

Mỗi lần chạy ghi JSON một dòng trong `auto_commit.log`: `timestamp` có múi giờ,
`branch`, `files_changed` (số file hợp lệ), `result`, `commit_hash`, `mode`, message
và chi tiết. Khi bị chặn trước bước đếm file, `files_changed=0` và
`files_counted=false` để phân biệt với một lần đã kiểm tra xong nhưng không có thay đổi.

| Result | Ý nghĩa | Exit code |
| --- | --- | --- |
| `NO_CHANGES` | Không có thay đổi hợp lệ | 0 |
| `COMMITTED` | Tạo checkpoint local, có commit hash | 0 |
| `BLOCKED_STAGED_CHANGES` | Index có phần người dùng đã stage | 1 |
| `BLOCKED_WRONG_BRANCH` | Sai branch hoặc detached HEAD | 1 |
| `BLOCKED_CONFLICT` | Có merge conflict | 1 |
| `ERROR` | Git/I/O/whitespace hoặc thao tác repository chưa hoàn tất | 1 |
| `PREVIEW` | Dry-run/summary có thay đổi, không commit | 0 |
| `SKIPPED_LOCK` | Instance khác đang giữ lock | 0 |

Nếu chủ động bật push, log ghi `COMMITTED` trước khi push; nếu push lỗi, ghi thêm
`ERROR` kèm hash của commit đã giữ lại. Log của phiên bản cũ dạng text vẫn được giữ;
những dòng mới dùng JSON. Kiểm thử chỉ tạo commit trong repository tạm.

Nếu đã đặt `XDG_STATE_HOME`, log script nằm trong
`$XDG_STATE_HOME/kltn-auto-commit/auto_commit.log`; cập nhật đường dẫn redirect
scheduler tương ứng. Script từ chối đặt state/log bên trong repository.
Log được nối thêm, chưa có rotation tự động.

Việc thêm các file này chưa tự cài cron/Task Scheduler. Hoàn tất dry-run ở bước 1
rồi chọn và thiết lập scheduler ở bước 4 để chạy khi login và mỗi 4 giờ.
