# TPU Simulator - RISC-V Matrix Extension

## Giới thiệu
Bộ mô phỏng (Instruction Set Simulator) cho RISC-V Matrix Extension, hỗ trợ các nhóm lệnh:
- Matrix Multiply-Accumulate (matmul)
- Load/Store
- Elementwise operations
- Configuration

## Yêu cầu hệ thống
- Python 3.8 trở lên
- numpy (optional, cho test với float16)

## Cài đặt

### 1. Clone repository
```bash
git clone <repository-url>
cd TPU
```

### 2. Cài đặt dependencies (optional)
```bash
pip install -r requirements.txt
```

Hoặc chỉ cài numpy nếu cần:
```bash
pip install numpy
```

## Cấu trúc thư mục
```
TPU/
├── assembler/          # Bộ dịch assembly
│   ├── assembler.py
│   ├── assembly.txt    # Input: mã assembly
│   └── machine_code.txt # Output: mã máy
│
├── iss/                # Instruction Set Simulator
│   ├── iss.py          # Main simulator
│   ├── components.py   # CPU components
│   ├── definitions.py  # Constants & definitions
│   ├── converters.py   # Float/int converters
│   ├── logic_*.py      # Instruction logic
│   ├── state_manager.py
│   ├── run_simulator.py
│   ├── test_loadstore.py  # Test script
│   └── *.txt           # State files
│
└── requirements.txt
```

## Cách sử dụng

### Chạy simulator cơ bản
```bash
# Từ thư mục TPU
python -m iss.run_simulator
```

### Chạy test load/store
```bash
cd iss
python test_loadstore.py
```

Test script sẽ chạy 5 test cases tuần tự:
1. mlae32/msae32 - Float32 load/store
2. mlae16/msae16 - Float16 load/store
3. mlbe8/msbe8 - Int8 load/store
4. mlce32/msce32 - Float32 column load/store
5. mlce8/msce8 - Int8 column load/store

### Workflow cơ bản
1. Viết mã assembly vào `assembler/assembly.txt`
2. Chạy assembler: `cd assembler && python assembler.py`
3. Chạy simulator: `cd .. && python -m iss.run_simulator`
4. Xem kết quả trong các file `.txt` trong thư mục `iss/`

## Các file state (iss/)
- `memory.txt` - 1KB RAM (0x000-0x3FF)
- `gpr.txt` - 32 general purpose registers
- `matrix.txt` - TR registers (integer)
- `matrix_float.txt` - TR registers (float)
- `acc.txt` - Accumulator registers (integer)
- `acc_float.txt` - Accumulator registers (float)
- `config.txt` - CSR configuration registers
- `status.txt` - Status flags

## Troubleshooting

### Lỗi import module
Nếu gặp lỗi `ModuleNotFoundError` hoặc `cannot import name`:
- Đảm bảo chạy từ thư mục gốc `TPU/`
- Chạy simulator bằng: `python -m iss.run_simulator` (không phải `python iss/run_simulator.py`)

### Lỗi với float16
Nếu test_loadstore.py báo lỗi với float16:
```bash
pip install numpy
```

### Lỗi encoding trên Windows
Nếu gặp lỗi `UnicodeEncodeError`:
- Đã được fix tự động trong code
- Hoặc set: `set PYTHONIOENCODING=utf-8`

## Tính năng

### Simulator
- ✅ Matrix multiply-accumulate (signed, unsigned, mixed)
- ✅ Float operations (FP16, FP32, BF16)
- ✅ Load/Store (alignment, block, column-wise)
- ✅ Elementwise operations
- ✅ Configuration via CSR
- ✅ 1KB RAM simulation
- ✅ State persistence to text files

### Test Script
- ✅ Random data generation
- ✅ Sequential testing (one test at a time)
- ✅ Automatic verification
- ✅ Detailed result display

## Đóng góp
Để report bug hoặc đóng góp, vui lòng tạo issue hoặc pull request.

## License
[Specify your license here]
