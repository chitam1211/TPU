# Setup Checklist cho máy mới

Khi pull code về máy mới, làm theo thứ tự:

## ✅ Bước 1: Pull code
```bash
git clone https://github.com/chitam1211/TPU.git
cd TPU
git checkout oop_ver
```

## ✅ Bước 2: Kiểm tra Python version
```bash
python --version
# Cần: Python 3.8 trở lên
```

Nếu không đủ version:
- Windows: Tải từ https://www.python.org/downloads/
- Linux/Mac: `sudo apt install python3.10` hoặc `brew install python@3.10`

## ✅ Bước 3: Chạy validation script
```bash
python validate_setup.py
```

**Nếu ALL CHECKS PASSED → Bỏ qua bước 4, nhảy tới bước 5!**

**Nếu có lỗi → Làm bước 4**

## ✅ Bước 4: Fix các lỗi thường gặp

### Lỗi: "Cannot import iss"
```bash
# Kiểm tra bạn đang ở đúng thư mục TPU/
pwd  # hoặc cd (Windows)

# Phải thấy: /path/to/TPU
# Không phải: /path/to/TPU/iss
```

### Lỗi: "Python version too old"
```bash
# Cài Python mới hơn
python3.10 --version  # Thử các version khác
```

### Lỗi: "Missing files"
```bash
# Pull lại code
git pull origin oop_ver
git status  # Kiểm tra có file nào bị xóa không
```

### Cảnh báo: "numpy not installed"
```bash
# Optional - chỉ cần nếu muốn test float16
pip install numpy
```

## ✅ Bước 5: Test chạy simulator
```bash
# Test 1: Chạy với reset
python -m iss.run_simulator -r

# Test 2: Chạy bình thường  
python -m iss.run_simulator

# Test 3: Chạy test script (nếu có)
cd iss
python test_loadstore.py
```

## ✅ Bước 6: Kiểm tra VS Code (nếu dùng VS Code)

1. Mở thư mục TPU trong VS Code
2. Cài extension: Python (ms-python.python)
3. Cài extension: Pylance (ms-python.vscode-pylance)
4. Reload window: `Ctrl+Shift+P` → "Developer: Reload Window"
5. Kiểm tra PROBLEMS tab → không có lỗi đỏ

## ✅ Bước 7: Xác nhận hoạt động

Chạy validation một lần nữa:
```bash
python validate_setup.py
```

Kết quả mong đợi:
```
Passed: 8/8
✅ ALL CHECKS PASSED! Project is ready to use.
```

---

## 🔧 Troubleshooting nâng cao

### Lỗi encoding trên Windows
```powershell
# Set encoding cho terminal
$env:PYTHONIOENCODING="utf-8"
python -m iss.run_simulator
```

### Lỗi Pylance "attribute not found"
```
Đã fix bằng .vscode/settings.json
Nếu vẫn lỗi → Reload VS Code window
```

### Import lỗi dù có __init__.py
```bash
# Xóa cache Python
rm -rf iss/__pycache__
rm -rf assembler/__pycache__

# Hoặc trên Windows:
rmdir /s iss\__pycache__
rmdir /s assembler\__pycache__
```

---

Khi tất cả checks PASS, bạn có thể:

- ✅ Chạy simulator: `python -m iss.run_simulator`
- ✅ Chạy assembler: `cd assembler && python assembler.py`
- ✅ Chạy tests: `cd iss && python test_loadstore.py`
- ✅ Sửa code và commit: `git add . && git commit -m "..." && git push`
