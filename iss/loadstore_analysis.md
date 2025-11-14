# PHÂN TÍCH CHI TIẾT: LOADSTORE INSTRUCTIONS

## 1. ENCODING STRUCTURE

Load/Store instructions có format:
```
[31:28] func4    - Function code
[27:26] uop      - Luôn = 01 cho loadstore
[25]    ls       - 0=Load, 1=Store
[24:20] rs2      - GPR stride
[19:17] rs1      - GPR base address
[16:15] -        - Reserved
[14:12] func3    - Luôn = 000
[11:10] d_size   - Element size (00=8bit, 01=16bit, 10=32bit, 11=64bit)
[9:7]   md/ms3   - Matrix register (0-3: TR, 4-7: ACC)
[6:0]   opcode   - 0101011 (custom-1)
```

## 2. DANH SÁCH CÁC LỆNH

### 2.1 NON-TRANSPOSED OPERATIONS

#### Matrix A (func4=0000, uop=01)
- `mlae8`  : Load  A 8-bit  (func=0000, uop=01, ls=0, d_size=00)
- `mlae16` : Load  A 16-bit (func=0000, uop=01, ls=0, d_size=01)
- `mlae32` : Load  A 32-bit (func=0000, uop=01, ls=0, d_size=10)
- `mlae64` : Load  A 64-bit (func=0000, uop=01, ls=0, d_size=11)
- `msae8`  : Store A 8-bit  (func=0000, uop=01, ls=1, d_size=00)
- `msae16` : Store A 16-bit (func=0000, uop=01, ls=1, d_size=01)
- `msae32` : Store A 32-bit (func=0000, uop=01, ls=1, d_size=10)
- `msae64` : Store A 64-bit (func=0000, uop=01, ls=1, d_size=11)

#### Matrix B (func4=0001, uop=01)
- `mlbe8`  : Load  B 8-bit  (func=0001, uop=01, ls=0, d_size=00)
- `mlbe16` : Load  B 16-bit (func=0001, uop=01, ls=0, d_size=01)
- `mlbe32` : Load  B 32-bit (func=0001, uop=01, ls=0, d_size=10)
- `mlbe64` : Load  B 64-bit (func=0001, uop=01, ls=0, d_size=11)
- `msbe8`  : Store B 8-bit  (func=0001, uop=01, ls=1, d_size=00)
- `msbe16` : Store B 16-bit (func=0001, uop=01, ls=1, d_size=01)
- `msbe32` : Store B 32-bit (func=0001, uop=01, ls=1, d_size=10)
- `msbe64` : Store B 64-bit (func=0001, uop=01, ls=1, d_size=11)

#### Matrix C (func4=0010, uop=01)
- `mlce8`  : Load  C 8-bit  (func=0010, uop=01, ls=0, d_size=00)
- `mlce16` : Load  C 16-bit (func=0010, uop=01, ls=0, d_size=01)
- `mlce32` : Load  C 32-bit (func=0010, uop=01, ls=0, d_size=10)
- `mlce64` : Load  C 64-bit (func=0010, uop=01, ls=0, d_size=11)
- `msce8`  : Store C 8-bit  (func=0010, uop=01, ls=1, d_size=00)
- `msce16` : Store C 16-bit (func=0010, uop=01, ls=1, d_size=01)
- `msce32` : Store C 32-bit (func=0010, uop=01, ls=1, d_size=10)
- `msce64` : Store C 64-bit (func=0010, uop=01, ls=1, d_size=11)

#### Whole Register (func4=0011, uop=01)
- `mlme8`  : Load  MEM 8-bit  (func=0011, uop=01, ls=0, d_size=00)
- `mlme16` : Load  MEM 16-bit (func=0011, uop=01, ls=0, d_size=01)
- `mlme32` : Load  MEM 32-bit (func=0011, uop=01, ls=0, d_size=10)
- `mlme64` : Load  MEM 64-bit (func=0011, uop=01, ls=0, d_size=11)
- `msme8`  : Store MEM 8-bit  (func=0011, uop=01, ls=1, d_size=00)
- `msme16` : Store MEM 16-bit (func=0011, uop=01, ls=1, d_size=01)
- `msme32` : Store MEM 32-bit (func=0011, uop=01, ls=1, d_size=10)
- `msme64` : Store MEM 64-bit (func=0011, uop=01, ls=1, d_size=11)

### 2.2 TRANSPOSED OPERATIONS

#### Matrix A Transposed (func4=0100, uop=01)
- `mlate8`  : Load  A^T 8-bit  (func=0100, uop=01, ls=0, d_size=00)
- `mlate16` : Load  A^T 16-bit (func=0100, uop=01, ls=0, d_size=01)
- `mlate32` : Load  A^T 32-bit (func=0100, uop=01, ls=0, d_size=10)
- `mlate64` : Load  A^T 64-bit (func=0100, uop=01, ls=0, d_size=11)
- `msate8`  : Store A^T 8-bit  (func=0100, uop=01, ls=1, d_size=00)
- `msate16` : Store A^T 16-bit (func=0100, uop=01, ls=1, d_size=01)
- `msate32` : Store A^T 32-bit (func=0100, uop=01, ls=1, d_size=10)
- `msate64` : Store A^T 64-bit (func=0100, uop=01, ls=1, d_size=11)

#### Matrix B Transposed (func4=0101, uop=01)
- `mlbte8`  : Load  B^T 8-bit  (func=0101, uop=01, ls=0, d_size=00)
- `mlbte16` : Load  B^T 16-bit (func=0101, uop=01, ls=0, d_size=01)
- `mlbte32` : Load  B^T 32-bit (func=0101, uop=01, ls=0, d_size=10)
- `mlbte64` : Load  B^T 64-bit (func=0101, uop=01, ls=0, d_size=11)
- `msbte8`  : Store B^T 8-bit  (func=0101, uop=01, ls=1, d_size=00)
- `msbte16` : Store B^T 16-bit (func=0101, uop=01, ls=1, d_size=01)
- `msbte32` : Store B^T 32-bit (func=0101, uop=01, ls=1, d_size=10)
- `msbte64` : Store B^T 64-bit (func=0101, uop=01, ls=1, d_size=11)

#### Matrix C Transposed (func4=0110, uop=01)
- `mlcte8`  : Load  C^T 8-bit  (func=0110, uop=01, ls=0, d_size=00)
- `mlcte16` : Load  C^T 16-bit (func=0110, uop=01, ls=0, d_size=01)
- `mlcte32` : Load  C^T 32-bit (func=0110, uop=01, ls=0, d_size=10)
- `mlcte64` : Load  C^T 64-bit (func=0110, uop=01, ls=0, d_size=11)
- `mscte8`  : Store C^T 8-bit  (func=0110, uop=01, ls=1, d_size=00)
- `mscte16` : Store C^T 16-bit (func=0110, uop=01, ls=1, d_size=01)
- `mscte32` : Store C^T 32-bit (func=0110, uop=01, ls=1, d_size=10)
- `mscte64` : Store C^T 64-bit (func=0110, uop=01, ls=1, d_size=11)

## 3. PHÂN TÍCH ENCODING CONFLICTS

### 3.1 KIỂM TRA UNIQUENESS

Encoding được xác định bởi: `func4[3:0] + uop[1:0] + ls[0] + d_size[1:0]`

Tổng cộng: 7 func4 × 2 ls × 4 d_size = 56 lệnh

**KẾT LUẬN: KHÔNG CÓ ENCODING CONFLICTS**

Mỗi lệnh có encoding duy nhất:
- func4 phân biệt loại operation (A/B/C/MEM, transposed hay không)
- ls bit phân biệt Load/Store
- d_size phân biệt element size
- uop luôn = 01 cho tất cả loadstore

### 3.2 KIỂM TRA SPEC AMBIGUITY

Tuy encoding rõ ràng, nhưng có vấn đề về **định nghĩa hoạt động**:

#### **VẤN ĐỀ 1: WHOLE REGISTER LOAD/STORE (mlme/msme)**
- Spec **KHÔNG RÕ RÀNG** về:
  - Layout trong memory như thế nào?
  - Load/Store theo hàng hay cột?
  - Có transpose không?
  - Có dùng được với cả TR và ACC không?

#### **VẤN ĐỀ 2: 64-BIT ELEMENTS**
- ELEN=32 (maximum element width = 32 bits)
- Các lệnh 64-bit (`mlae64`, `mlbe64`, etc.) **MÂU THUẪN VỚI ELEN=32**
- Không rõ cách xử lý khi element size > ELEN

#### **VẤN ĐỀ 3: TRANSPOSED OPERATIONS**
- Spec không rõ ràng về:
  - Memory layout khi transpose (row-major hay column-major?)
  - Stride được áp dụng như thế nào?
  - Alignment requirements?

## 4. ĐÁNH GIÁ ẢNH HƯỞNG ĐẾN ML

### 4.1 CÁC LỆNH CẦN THIẾT CHO ML

Neural networks cần:
1. **Load input/weights (Matrix A/B)**: Cần thiết
2. **Load/Store activations (Matrix C)**: Cần thiết  
3. **Support 8-bit quantization**: Quan trọng cho INT8 inference
4. **Support FP16/BF16**: Quan trọng cho mixed-precision training
5. **Support FP32**: Cần thiết cho training

### 4.2 CÁC LỆNH KHÔNG CẦN THIẾT

[X] **64-bit operations (mlae64, mlbe64, etc.)**
- Mâu thuẫn với ELEN=32
- Neural networks không dùng FP64/INT64
- Loại bỏ: 16 lệnh (8 load + 8 store)

[X] **Whole register operations (mlme/msme)**
- Định nghĩa không rõ ràng
- Không cần thiết (có thể dùng mlae/mlbe/mlce thay thế)
- Loại bỏ: 8 lệnh (4 load + 4 store)

[?] **Transposed operations (mlate, mlbte, mlcte)**
- Có thể hữu ích cho một số trường hợp
- Nhưng spec không rõ ràng về memory layout
- **GIỮ LẠI** nhưng cần implementation cẩn thận

## 5. KHUYẾN NGHỊ

### 5.1 CÁC LỆNH NÊN HỖ TRỢ (32 lệnh)

**Non-transposed A (4 lệnh):**
- `mlae8`, `mlae16`, `mlae32` - Load Matrix A
- `msae8`, `msae16`, `msae32` - Store Matrix A

**Non-transposed B (4 lệnh):**
- `mlbe8`, `mlbe16`, `mlbe32` - Load Matrix B
- `msbe8`, `msbe16`, `msbe32` - Store Matrix B

**Non-transposed C (4 lệnh):**
- `mlce8`, `mlce16`, `mlce32` - Load Matrix C
- `msce8`, `msce16`, `msce32` - Store Matrix C

**Transposed A (4 lệnh):**
- `mlate8`, `mlate16`, `mlate32` - Load Matrix A^T
- `msate8`, `msate16`, `msate32` - Store Matrix A^T

**Transposed B (4 lệnh):**
- `mlbte8`, `mlbte16`, `mlbte32` - Load Matrix B^T
- `msbte8`, `msbte16`, `msbte32` - Store Matrix B^T

**Transposed C (4 lệnh):**
- `mlcte8`, `mlcte16`, `mlcte32` - Load Matrix C^T
- `mscte8`, `mscte16`, `mscte32` - Store Matrix C^T

### 5.2 CÁC LỆNH LOẠI BỎ (24 lệnh)

**64-bit operations (16 lệnh):**
- All `*e64` variants (mlae64, msae64, mlbe64, etc.)
- Reason: Contradicts ELEN=32, not used in ML

**Whole register operations (8 lệnh):**
- All `mlme*` and `msme*` (mlme8, mlme16, mlme32, mlme64, msme8, etc.)
- Reason: Spec unclear, not needed for ML

## 6. IMPACT ANALYSIS

### 6.1 ML FUNCTIONALITY PRESERVED

[OK] **INT8 Inference**: Có mlae8/mlbe8/mlce8 (load activations, weights, results)
[OK] **FP16 Training**: Có mlae16/mlbe16/mlce16  
[OK] **BF16 Training**: Có mlae16/mlbe16/mlce16 (BF16 cùng size với FP16)
[OK] **FP32 Training**: Có mlae32/mlbe32/mlce32
[OK] **Transpose support**: Có mlate*/mlbte*/mlcte* cho các thuật toán cần transpose

### 6.2 REMOVED FEATURES

[X] **FP64/INT64**: Không ảnh hưởng (không dùng trong ML)
[X] **Whole register load/store**: Không ảnh hưởng (có thể dùng regular load/store)

## 7. KẾT LUẬN

**LOADSTORE INSTRUCTIONS KHÔNG CÓ ENCODING CONFLICTS** nhưng có:
- 16 lệnh mâu thuẫn với spec (64-bit với ELEN=32)
- 8 lệnh có định nghĩa không rõ ràng (whole register)

**LOẠI BỎ 24 LỆNH, GIỮ LẠI 32 LỆNH:**
- Đủ cho tất cả use cases ML (INT8, FP16, BF16, FP32)
- Hỗ trợ cả transposed và non-transposed operations
- Encoding rõ ràng, không mâu thuẫn
- Implementation đơn giản, dễ test

**CHẤT LƯỢNG SPEC: TỐT**
- Encoding nhất quán
- Chỉ cần loại bỏ các lệnh mâu thuẫn với ELEN=32
- Transposed operations cần clarification nhưng có thể implement theo cách hợp lý
