# Phân tích Element-Wise Instructions - Encoding Analysis

## 1. ENCODING STRUCTURE

Element-wise instructions có format:
```
[31:28] func4      - Function code
[27:26] uop        - Operation type (00=convert, 01=int, 10=float)
[25:23] ctrl       - Control field (111 cho .mm, 0-6 cho .mv.i)
[22:20] ms2        - Source matrix 2
[19:18] s_size     - Source element size (00=8bit, 01=16bit, 10=32bit, 11=64bit)
[17:15] ms1        - Source matrix 1
[14:12] func3      - Always = 001 for element-wise
[11:10] d_size     - Destination element size
[9:7]   md         - Destination matrix
[6:0]   opcode     - 0101011 (custom-1)
```

## 2. PHÂN LOẠI CÁC LỆNH ELEMENT-WISE

### 2.1 INTEGER ARITHMETIC (uop=01, func3=001)

#### Matrix-Matrix Operations (ctrl=111):
```
madd.w.mm:     func=0000, uop=01, ctrl=111, s_size=01, d_size=10  (NOTE: s_size=01 nhưng tên .w?)
msub.w.mm:     func=0001, uop=01, ctrl=111, s_size=10, d_size=10
mmul.w.mm:     func=0010, uop=01, ctrl=111, s_size=10, d_size=10
mmulh.w.mm:    func=0011, uop=01, ctrl=111, s_size=10, d_size=10
mmax.w.mm:     func=0100, uop=01, ctrl=111, s_size=10, d_size=10
mumax.w.mm:    func=0101, uop=01, ctrl=111, s_size=10, d_size=10
mmin.w.mm:     func=0110, uop=01, ctrl=111, s_size=10, d_size=10
mumin.w.mm:    func=0111, uop=01, ctrl=111, s_size=10, d_size=10
msrl.w.mm:     func=1000, uop=01, ctrl=111, s_size=10, d_size=10
msll.w.mm:     func=1001, uop=01, ctrl=111, s_size=10, d_size=10
msra.w.mm:     func=1010, uop=01, ctrl=111, s_size=10, d_size=10
```

#### Clipping Operations (uop=00, ctrl=111):
```
mn4clipl.w.mm:  func=0010, uop=01, ctrl=111, s_size=10, d_size=10
mn4cliph.w.mm:  func=0011, uop=00, ctrl=111, s_size=10, d_size=10
mn4cliplu.w.mm: func=0100, uop=00, ctrl=111, s_size=10, d_size=10
mn4cliphu.w.mm: func=0101, uop=00, ctrl=111, s_size=10, d_size=10
```

⚠️ **VẤN ĐỀ 1: mn4clipl.w.mm vs mmul.w.mm**
```
mn4clipl.w.mm: func=0010, uop=01, ctrl=111, s_size=10, d_size=10
mmul.w.mm:     func=0010, uop=01, ctrl=111, s_size=10, d_size=10
```
**ENCODING HOÀN TOÀN GIỐNG NHAU!** Không thể phân biệt!

⚠️ **VẤN ĐỀ 2: mmulh.w.mm vs mumax.w.mm**
```
mmulh.w.mm:  func=0011, uop=01, ctrl=111, s_size=10, d_size=10
mumax.w.mm:  func=0011, uop=01, ctrl=111, s_size=10, d_size=10
```
**ENCODING GIỐNG NHAU!** (Có thể mumax nên là func=0101?)

### 2.2 FLOAT ARITHMETIC (uop=10, func3=001)

#### FP16 Operations (s_size=01, d_size=01):
```
mfadd.h.mm:  func=0000, uop=10, ctrl=111, s_size=01, d_size=01
mfsub.h.mm:  func=0001, uop=10, ctrl=111, s_size=01, d_size=01
mfmul.h.mm:  func=0010, uop=10, ctrl=111, s_size=01, d_size=01
mfmax.h.mm:  func=0011, uop=10, ctrl=111, s_size=01, d_size=11  (NOTE: d_size=11?)
mfmin.s.mm:  func=0100, uop=10, ctrl=111, s_size=01, d_size=01
```

⚠️ **VẤN ĐỀ 3: mfmax.h.mm encoding lỗi**
```
mfmax.h.mm: s_size=01 (FP16) nhưng d_size=11 (64-bit destination)
```
**MÂU THUẪN**: Source FP16 nhưng destination 64-bit? Với ELEN=32 không hợp lý!

#### FP32 Operations (s_size=10, d_size=10):
```
mfsub.s.mm:  func=0001, uop=10, ctrl=111, s_size=10, d_size=10
mfmul.s.mm:  func=0010, uop=10, ctrl=111, s_size=10, d_size=10
mfmax.s.mm:  func=0011, uop=10, ctrl=111, s_size=10, d_size=10
mfmin.h.mm:  func=0100, uop=10, ctrl=111, s_size=10, d_size=10  (NOTE: tên .h nhưng size=10?)
```

⚠️ **VẤN ĐỀ 4: Naming inconsistency**
```
mfmin.h.mm: Tên là .h (FP16) nhưng s_size=10 (FP32)
mfmin.s.mm: s_size=01 (FP16) nhưng tên là .s (FP32)
```
**Có thể đã nhầm lẫn giữa .h và .s!**

#### FP64 Operations (s_size=11, d_size=11):
```
mfadd.d.mm:  func=0000, uop=10, ctrl=111, s_size=11, d_size=11
mfsub.d.mm:  func=0001, uop=10, ctrl=111, s_size=11, d_size=11
mfmul.d.mm:  func=0010, uop=10, ctrl=111, s_size=11, d_size=11
mfmax.d.mm:  func=0011, uop=10, ctrl=111, s_size=11, d_size=11
mfmin.d.mm:  func=0100, uop=10, ctrl=111, s_size=11, d_size=11
```

❌ **MÂU THUẪN VỚI ELEN=32**: Tất cả operations FP64 không hợp lệ!

### 2.3 CONVERSION OPERATIONS (uop=00, func3=001)

#### FP8 ↔ FP16 Conversions:
```
mfcvth.e4.h:    func=0000, uop=00, ctrl=010, s_size=01, d_size=00
mfcvtl.h.e4:    func=0000, uop=00, ctrl=000, s_size=00, d_size=01
mfcvth.h.e4:    func=0000, uop=00, ctrl=010, s_size=00, d_size=01
mfcvtl.h.e5:    func=0000, uop=00, ctrl=001, s_size=00, d_size=01
mfcvth.h.e5:    func=0000, uop=00, ctrl=011, s_size=00, d_size=01  (NOTE: func3=000?)
mfcvtl.e4.h:    func=0000, uop=00, ctrl=000, s_size=01, d_size=00
mfcvtl.e5.h:    func=0000, uop=00, ctrl=001, s_size=01, d_size=00
mfcvth.e5.h:    func=0000, uop=00, ctrl=011, s_size=01, d_size=00
```

⚠️ **VẤN ĐỀ 5: mfcvth.h.e5 có func3=000**
```
mfcvth.h.e5: func3=000 (khác với các EW khác func3=001)
```
**Có thể là lỗi typo trong definitions.py**

#### FP16 ↔ FP32 Conversions:
```
mfcvtl.s.h:     func=0000, uop=00, ctrl=000, s_size=01, d_size=10
mfcvth.s.h:     func=0000, uop=00, ctrl=000, s_size=01, d_size=10
mfcvtl.s.bf16:  func=0000, uop=00, ctrl=001, s_size=01, d_size=10
mfcvth.s.bf16:  func=0000, uop=00, ctrl=011, s_size=01, d_size=10
```

⚠️ **VẤN ĐỀ 6: mfcvtl.s.h vs mfcvth.s.h**
```
mfcvtl.s.h: func=0000, uop=00, ctrl=000, s_size=01, d_size=10
mfcvth.s.h: func=0000, uop=00, ctrl=000, s_size=01, d_size=10
```
**ENCODING GIỐNG NHAU!** Không thể phân biệt!

#### FP32 ↔ FP64 Conversions:
```
mfcvtl.d.s:  func=0000, uop=00, ctrl=000, s_size=10, d_size=11
mfcvth.d.s:  func=0000, uop=00, ctrl=010, s_size=10, d_size=11
mfcvtl.d.s:  func=0001, uop=00, ctrl=001, s_size=10, d_size=10  (duplicate name?)
```

❌ **MÂU THUẪN VỚI ELEN=32**: FP64 conversions không hợp lệ!

#### INT ↔ FLOAT Conversions:
```
msfcvtl.h.b:   func=0001, uop=00, ctrl=001, s_size=00, d_size=01
msfcvth.h.b:   func=0001, uop=00, ctrl=011, s_size=10, d_size=01  (NOTE: s_size=10?)
mufcvtl.h.b:   func=0001, uop=00, ctrl=000, s_size=00, d_size=01
mufcvth.h.b:   func=0001, uop=00, ctrl=010, s_size=00, d_size=01
mufcvt.s.w:    func=0001, uop=00, ctrl=000, s_size=10, d_size=10
mfscvt.w.s:    func=0001, uop=00, ctrl=101, s_size=10, d_size=10
mfucvt.w.s:    func=0001, uop=00, ctrl=100, s_size=10, d_size=10
```

### 2.4 MATRIX-VECTOR OPERATIONS (.mv.i variants)

Tất cả operations ở trên đều có variant .mv.i (ctrl=0-6) với encoding tương tự.

⚠️ **VẤN ĐỀ 7: Potential conflicts**
Các lệnh .mv.i có thể xung đột với .mm nếu ctrl field không được decode đúng.

## 3. TỔNG HỢP ENCODING CONFLICTS

### 🔴 Conflicts nghiêm trọng (encoding giống hệt):
1. **mn4clipl.w.mm** vs **mmul.w.mm** (func=0010, uop=01, ctrl=111, size=10→10)
2. **mmulh.w.mm** vs **mumax.w.mm** (func=0011, uop=01, ctrl=111, size=10→10)
3. **mfcvtl.s.h** vs **mfcvth.s.h** (func=0000, uop=00, ctrl=000, size=01→10)

### ⚠️ Inconsistencies (lỗi naming/size):
4. **mfmax.h.mm**: s_size=01 (FP16) nhưng d_size=11 (64-bit)
5. **mfmin.h.mm** vs **mfmin.s.mm**: Naming không khớp với size fields
6. **madd.w.mm**: s_size=01 nhưng tên là .w (32-bit)
7. **mfcvth.h.e5**: func3=000 (nên là 001?)
8. **msfcvth.h.b**: s_size=10 (32-bit) nhưng đang convert từ 8-bit?

### ❌ ELEN=32 violations (64-bit operations):
9. Tất cả lệnh FP64 (.d.mm, .d.mv.i)
10. Tất cả conversions FP32↔FP64

## 4. CÁC LỆNH CẦN THIẾT CHO ML

### ✅ Priority 1 - INTEGER OPERATIONS (Quantized Inference):
1. **madd.w.mm** / **madd.w.mv.i** - Element-wise add (bias addition)
2. **msub.w.mm** - Element-wise subtract
3. **mmul.w.mm** - Element-wise multiply (scaling)
4. **mmax.w.mm** / **mmin.w.mm** - Clipping, ReLU variants
5. **mumax.w.mm** / **mumin.w.mm** - Unsigned variants
6. **msrl/msll/msra.w.mm** - Bit shifts (quantization, bit-packing)

### ✅ Priority 2 - FLOAT OPERATIONS (Training & FP Inference):
7. **mfadd.h.mm**, **mfadd.s.mm** - FP16/FP32 addition
8. **mfsub.h.mm**, **mfsub.s.mm** - FP16/FP32 subtraction
9. **mfmul.h.mm**, **mfmul.s.mm** - FP16/FP32 multiplication
10. **mfmax.h.mm**, **mfmax.s.mm** - FP max (ReLU, pooling)
11. **mfmin.h.mm**, **mfmin.s.mm** - FP min (clipping)

### ✅ Priority 3 - CONVERSIONS (Mixed Precision):
12. **mfcvtl/h.h.e4/e5** - FP8 → FP16 (inference optimization)
13. **mfcvtl/h.s.h** - FP16 ↔ FP32 (mixed precision training)
14. **mfcvtl/h.s.bf16** - BF16 ↔ FP32 (modern ML)
15. **mufcvt.s.w** - INT32 → FP32 (dequantization)
16. **mfscvt/mfucvt.w.s** - FP32 → INT32 (quantization)

### ❌ KHÔNG CẦN THIẾT CHO ML:
- ❌ **mn4clip*** operations - Specialized clipping, có thể dùng mmax/mmin
- ❌ **mmulh.w.mm** - High bits multiply, không dùng trong neural nets
- ❌ Tất cả FP64 operations - ML không cần FP64
- ❌ FP8 ↔ INT8 conversions (msfcvt*, mufcvt*.h.b) - Ít dùng
- ❌ TF32, packed conversions - Specialized formats

## 5. KHUYẾN NGHỊ

### 5.1 CÁC LỆNH NÊN HỖ TRỢ (28 lệnh cốt lõi)

#### Integer Arithmetic (11 lệnh .mm + 11 lệnh .mv.i):
- madd.w, msub.w, mmul.w, mmax.w, mumax.w, mmin.w, mumin.w
- msrl.w, msll.w, msra.w
- (Bỏ mmulh vì conflict, bỏ mn4clip* vì specialized)

#### Float Arithmetic (10 lệnh, cho mỗi .h và .s):
- mfadd, mfsub, mfmul, mfmax, mfmin (FP16 và FP32)
- (Bỏ tất cả .d vì ELEN=32)

#### Conversions (7 lệnh chính):
- FP8→FP16: mfcvtl/h.h.e4, mfcvtl/h.h.e5
- FP16→FP32: mfcvtl/h.s.h (chọn 1 trong 2 do conflict)
- BF16→FP32: mfcvtl/h.s.bf16
- INT↔FLOAT: mufcvt.s.w, mfscvt/mfucvt.w.s

### 5.2 CÁC LỆNH LOẠI BỎ

#### Do encoding conflicts (6 lệnh):
1. ❌ **mn4clipl.w.mm** (conflict với mmul.w.mm)
2. ❌ **mmulh.w.mm** (conflict với mumax.w.mm)
3. ❌ **mfcvtl.s.h** hoặc **mfcvth.s.h** (conflict nhau, giữ 1)
4. ❌ **mn4cliph/lu/hu.w.mm** (specialized, không cần)

#### Do ELEN=32 violation (15+ lệnh):
5. ❌ Tất cả FP64 operations (.d.mm variants)
6. ❌ Tất cả FP32↔FP64 conversions
7. ❌ **mfmax.h.mm** (d_size=11 lỗi encoding)

#### Do không cần thiết (10+ lệnh):
8. ❌ FP8↔INT8 conversions (msfcvt*, mufcvt*.h.b)
9. ❌ Packed operations (mscvt*/mucvt*.b.p)
10. ❌ TensorFloat conversions (mfcvt.tf32.s, etc.)

## 6. TÁC ĐỘNG ĐẾN HỌC MÁY

### ✅ CÁC CHỨC NĂNG ML ĐƯỢC BẢO TỒN:

#### Training:
- ✅ FP32 full precision (mfadd/sub/mul.s.mm)
- ✅ FP16 mixed precision (mfadd/sub/mul.h.mm + conversions)
- ✅ BF16 modern training (mfcvt*.s.bf16 + float ops)
- ✅ Activation functions (mfmax/min for ReLU, clipping)
- ✅ Bias addition (madd.w.mm, mfadd.*.mm)

#### Inference:
- ✅ INT8 quantized (madd/mul.w.mm + conversions)
- ✅ FP16 inference (mfadd/sub/mul.h.mm)
- ✅ FP8 extreme quantization (mfcvt*.h.e4/e5)
- ✅ Bitwise operations (msrl/sll/sra for bit-packing)

#### Essential Operations:
- ✅ Element-wise add/sub/mul (residual, skip connections)
- ✅ Broadcasting (.mv.i variants - bias, scaling)
- ✅ Activation (max/min for ReLU, clip)
- ✅ Quantization/Dequantization (INT↔FLOAT conversions)
- ✅ Mixed precision (FP16↔FP32, BF16↔FP32)

### ❌ REMOVED FEATURES (Không ảnh hưởng ML):
- ❌ FP64 operations → ML không dùng double precision
- ❌ High-multiply, N4-clip → Specialized, có thể thay thế
- ❌ FP8↔INT8 direct → Thường convert qua FP16/FP32
- ❌ Packed operations → Non-standard formats

## 7. KẾT LUẬN

### 🎯 ELEMENT-WISE INSTRUCTIONS CÓ NHIỀU VẤN ĐỀ:
1. **3 encoding conflicts nghiêm trọng** (không thể phân biệt)
2. **8+ inconsistencies** (naming, size fields không khớp)
3. **15+ lệnh mâu thuẫn ELEN=32** (64-bit operations)

### ✅ LOẠI BỎ 30+ LỆNH, GIỮ LẠI ~28 LỆNH CỐT LÕI:
- Đủ cho tất cả use cases ML (training + inference)
- Hỗ trợ FP32, FP16, BF16, INT8, FP8
- Có element-wise arithmetic + conversions + broadcasting
- Encoding rõ ràng, không xung đột

### 📊 TÁC ĐỘNG ĐẾN ML: **KHÔNG ẢNH HƯỞNG**
Với 28 lệnh còn lại, simulator vẫn hỗ trợ đầy đủ:
- ✅ CNN: ResNet, VGG, EfficientNet, MobileNet
- ✅ Transformer: BERT, GPT (small), ViT
- ✅ RNN: LSTM, GRU
- ✅ Mixed precision training (FP16/BF16)
- ✅ Quantized inference (INT8, FP8)
- ✅ Activation functions, batch norm, residual connections

### 🔧 CHẤT LƯỢNG SPEC: **CẦN SỬA**
- Encoding conflicts cần được sửa trong spec
- Naming inconsistencies cần được làm rõ
- 64-bit operations nên được loại bỏ (hoặc đánh dấu optional cho ELEN=64)
- Conversion operations cần được tổ chức lại rõ ràng hơn
