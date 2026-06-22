# Lenh chay testbench Matrix Core v2

Chay cac lenh duoi day tai thu muc goc repo:

```powershell
cd C:\TPU\TPU
```

## Lenh ngan gon

```powershell
.\mt.cmd all
```

Chay toan bo testbench: `config`, `load/store`, `misc`, `ew`, `mac`, va smoke test he thong RV32I.

Luu y: `all` o day co nghia la chay tat ca testbench hien co. No khong co nghia la test toan bo moi lenh trong spec PDF. Testbench hien tai chi cover cac lenh RTL v2 dang support.

```powershell
.\mt.cmd config
```

Test nhom CONFIG: `mrelease`, `msettilem`, `msettilemi`, `msettilen`, `msettileni`, `msettilek`, `msettileki`.

```powershell
.\mt.cmd ls
```

Test nhom LOAD/STORE: `mlae8`, `msae8`, `mlbe8`, `msbe8`, `mlce32`, `msce32`.

```powershell
.\mt.cmd misc
```

Test nhom MISC: `mzero`, `mmov.mm`, `mmovw.x.m`, `mmovw.m.x`, `mdupw.m.x`, `mrslidedown`, `mrslideup`, `mcslidedown.w`, `mcslideup.w`.

```powershell
.\mt.cmd ew
```

Test nhom element-wise: 10 lenh `.mm` va 10 lenh `.mv`.

```powershell
.\mt.cmd mac
```

Test nhom MAC: `mmaccu.w.b`, `mmaccus.w.b`, `mmaccsu.w.b`, `mmacc.w.b`.

```powershell
.\mt.cmd system
```

Chay smoke test tich hop he thong RV32I 5-stage + matrix core.

## Lenh in chi tiet du lieu

Them `verbose` o cuoi lenh de in them input, duong xu ly mau, RTL result va ISS/golden result:

```powershell
.\mt.cmd all verbose
.\mt.cmd config verbose
.\mt.cmd ls verbose
.\mt.cmd misc verbose
.\mt.cmd ew verbose
.\mt.cmd mac verbose
.\mt.cmd system verbose
```

Nen dung verbose theo tung nhom truoc, vi `all verbose` se in kha nhieu dong.

Format verbose hien tai tap trung vao viec doi chieu theo tung beat:

```text
BEFORE ...: du lieu nguon truoc khi lenh ghi ket qua
AFTER ...:
  row beat | HW after write | ISS expected | status
  0   0   | 0x........     | 0x........   | OK
```

Voi LOAD/STORE, verbose se in:

- RAM truoc khi `ml*`
- matrix register sau khi `ml*`
- matrix register truoc khi `ms*`
- RAM sau khi `ms*`
- ket qua phan cung so voi ket qua ISS/golden theo tung row/beat

Voi EW, MISC va MAC, verbose se in du lieu nguon truoc lenh va bang ket qua sau writeback:

```text
row/beat hoac row/col | ket qua phan cung | ket qua ISS | OK/DIFF
```

## Lenh PowerShell goc

Neu khong muon dung `mt.cmd`, co the goi script truc tiep:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_matrix_tests.ps1 -Only all
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_matrix_tests.ps1 -Only config
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_matrix_tests.ps1 -Only ls
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_matrix_tests.ps1 -Only misc
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_matrix_tests.ps1 -Only ew
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_matrix_tests.ps1 -Only mac
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_matrix_tests.ps1 -Only system
```

Ban verbose tuong ung:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_matrix_tests.ps1 -Only mac -Detailed
```

## File ket qua

Script se tu sinh golden reference vao:

```text
sim/golden/
```

Log compile va log chay duoc luu o:

```text
sim/<ten_testbench>.iverilog.log
sim/<ten_testbench>.vvp.log
```

Neu test pass, terminal se co cac dong dang:

```text
MATRIX_CONFIG_V2_TEST_PASS
MATRIX_LOAD_STORE_V2_TEST_PASS
MATRIX_MISC_V2_TEST_PASS
MATRIX_EW_V2_TEST_PASS
MATRIX_MAC_V2_TEST_PASS
RV32I_MATRIX_SYSTEM_TEST_PASS
```

Script cung in ra danh sach lenh duoc cover truoc khi chay test, vi du:

```text
== matrix instruction coverage ==
[misc] mrslidedown tr1, tr0, 1              0x5c8000ab
[misc] mrslideup tr2, tr0, 1                0x6c80012b
== total matrix instructions listed: 9 ==
```

## Cong cu can co

May can co cac lenh sau trong `PATH`:

```text
python
iverilog
vvp
```

## Pham vi lenh duoc test hien tai

Hien tai `.\mt.cmd all` cover cac lenh RTL v2 dang support:

| Nhom | So lenh test | Lenh duoc cover |
| --- | ---: | --- |
| CONFIG | 7 | `mrelease`, `msettilem`, `msettilemi`, `msettilen`, `msettileni`, `msettilek`, `msettileki` |
| LOAD/STORE | 6 | `mlae8`, `msae8`, `mlbe8`, `msbe8`, `mlce32`, `msce32` |
| MAC | 4 | `mmaccu.w.b`, `mmaccus.w.b`, `mmaccsu.w.b`, `mmacc.w.b` |
| MISC | 9 | `mzero`, `mmov.mm`, `mmovw.x.m`, `mmovw.m.x`, `mdupw.m.x`, `mrslidedown`, `mrslideup`, `mcslidedown.w`, `mcslideup.w` |
| EW | 20 | `madd/msub/mmul/mmax/mumax/mmin/mumin/msrl/msll/msra` voi ca `.mm` va `.mv` |

Tong cong: 46 lenh duoc test trong module-level testbench.

## Nhung lenh/spec feature chua cover

Mot so lenh co trong spec/assembler nhung RTL v2 hien chua support hoac chua test:

- `mcslidedown.b`, `mcslidedown.h`, `mcslidedown.d`
- `mcslideup.b`, `mcslideup.h`, `mcslideup.d`
- cac lenh pack/broadcast neu co trong spec
- cac bien the element width khac ngoai `.w` neu co
- cac lenh floating-point neu spec co nhung RTL chua hien thuc

`system` test chi la smoke test tich hop CPU pipeline + matrix core. No khong chay het tat ca 46 lenh; coverage day du nam o cac testbench rieng: `config`, `ls`, `misc`, `ew`, `mac`.
