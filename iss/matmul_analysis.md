# Phân tích Matmul Instructions - Encoding Conflicts

## [ERROR] CÁC LỆNH CÓ MÂU THUẪN ENCODING

### Nhóm 1: FP8-E5M2 conflicts
```
mfmacc.h.e5:  size_sup=000, s_size=00, d_size=01  (FP8-E5M2 → FP16)
mfmacc.s.e5:  size_sup=000, s_size=00, d_size=10  (FP8-E5M2 → FP32)
```
**Vấn đề**: Không thể phân biệt chỉ bằng size_sup

### Nhóm 2: FP8-E4M3 conflicts  
```
mfmacc.h.e4:  size_sup=001, s_size=00, d_size=01  (FP8-E4M3 → FP16)
mfmacc.s.e4:  size_sup=001, s_size=00, d_size=10  (FP8-E4M3 → FP32)
```
**Vấn đề**: Không thể phân biệt chỉ bằng size_sup

### Nhóm 3: Double precision conflicts
```
mfmacc.d.s:   size_sup=000, s_size=10, d_size=11  (FP32 → FP64)
mfmacc.s:     size_sup=000, s_size=10, d_size=10  (FP32 → FP32)
```
**Vấn đề**: Cùng size_sup=000, s_size=10

## [OK] CÁC LỆNH KHÔNG CÓ MÂU THUẪN (Nên giữ lại)

### Floating-point (rõ ràng):
1. [OK] **mfmacc.bf16.e5** - size_sup=100, s_size=00, d_size=01 (FP8-E5M2 → BF16)
2. [OK] **mfmacc.bf16.e4** - size_sup=101, s_size=00, d_size=01 (FP8-E4M3 → BF16)
3. [OK] **mfmacc.h** - size_sup=000, s_size=01, d_size=01 (FP16 → FP16)
4. [OK] **mfmacc.s.h** - size_sup=000, s_size=01, d_size=10 (FP16 → FP32)
5. [OK] **mfmacc.s.bf16** - size_sup=001, s_size=01, d_size=10 (BF16 → FP32)
6. [OK] **mfmacc.s** - size_sup=000, s_size=10, d_size=10 (FP32 → FP32)

### Integer (rõ ràng):
7. [OK] **mmacc.w.b** - size_sup=011 (INT8 signed×signed → INT32)
8. [OK] **mmaccu.w.b** - size_sup=000 (INT8 unsigned×unsigned → INT32)
9. [OK] **mmaccus.w.b** - size_sup=001 (INT8 unsigned×signed → INT32)
10. [OK] **mmaccsu.w.b** - size_sup=010 (INT8 signed×unsigned → INT32)

## [X] CÁC LỆNH NÊN LOẠI BỎ

### Do mâu thuẫn encoding:
- [X] mfmacc.h.e5, mfmacc.s.e5 (xung đột với nhau)
- [X] mfmacc.h.e4, mfmacc.s.e4 (xung đột với nhau)
- [X] mfmacc.d.s, mfmacc.d (xung đột với mfmacc.s, chưa rõ ràng)

### Do không cần thiết cho ML đơn giản:
- [X] mfmacc.s.tf32 (TensorFloat-32 - format đặc biệt, chưa phổ biến)
- [X] mmacc.d.h, mmaccu.d.h, mmaccus.d.h, mmaccsu.d.h (INT16→INT64 - ít dùng trong ML)
- [X] Tất cả lệnh packed (pmmacc.*) - format phức tạp, không rõ spec
- [X] mmacc.w.bp (bit-packed - không rõ format)

## [ANALYSIS] ĐÁNH GIÁ TÁC ĐỘNG ĐẾN HỌC MÁY

### Các lệnh cốt lõi cho ML (10 lệnh):
1. [OK] **mfmacc.s** (FP32×FP32→FP32) - **QUAN TRỌNG NHẤT**
   - Standard precision cho hầu hết ML workloads
   
2. [OK] **mfmacc.s.h** (FP16×FP16→FP32) - **QUAN TRỌNG**
   - Mixed precision training (phổ biến trong deep learning)
   
3. [OK] **mfmacc.s.bf16** (BF16×BF16→FP32) - **QUAN TRỌNG**
   - BFloat16 training (xu hướng hiện đại: TPU, A100)
   
4. [OK] **mfmacc.h** (FP16×FP16→FP16) - **HỮU ÍCH**
   - Inference optimization, mobile ML
   
5. [OK] **mfmacc.bf16.e5**, **mfmacc.bf16.e4** - **HỮU ÍCH**
   - Extreme quantization cho inference (FP8→BF16)
   
6. [OK] **mmacc.w.b** và variants (INT8→INT32) - **QUAN TRỌNG**
   - Quantized inference (BERT, ResNet, MobileNet quantized)
   - Edge deployment

### Các lệnh bị loại bỏ - Tác động:
- [X] **mfmacc.h.e5/e4, mfmacc.s.e5/e4**: Có thể thay bằng bf16.e5/e4
- [X] **mfmacc.d.s, mfmacc.d**: FP64 ít dùng trong ML (chỉ dùng trong scientific computing)
- [X] **INT64 operations**: Không cần trong neural networks
- [X] **TF32**: Có thể dùng FP32 thay thế (độ chính xác tương đương cho ML)

## [GOAL] KẾT LUẬN

### Có thể áp dụng cho ML đơn giản: [OK] **HOÀN TOÀN CÓ THỂ**

Với 10 lệnh còn lại, simulator hỗ trợ đủ cho:

#### Training:
- [OK] FP32 training (standard)
- [OK] Mixed precision FP16/BF16 training (modern)
- [OK] Full precision accumulation (FP32 accumulator)

#### Inference:
- [OK] FP16 inference (mobile, edge)
- [OK] BF16 inference (cloud)
- [OK] INT8 quantized inference (production)
- [OK] FP8 extreme quantization (experimental)

#### Các mô hình có thể chạy:
- [OK] CNNs: ResNet, VGG, MobileNet, EfficientNet
- [OK] Transformers: BERT, GPT (small models), ViT
- [OK] RNNs: LSTM, GRU
- [OK] Classical ML: SVM, Linear/Logistic Regression

### Không ảnh hưởng nghiêm trọng vì:
1. Các lệnh cốt lõi (FP32, FP16, BF16, INT8) đều có
2. Precision widening được hỗ trợ đầy đủ
3. Mixed precision training khả thi
4. Quantized inference khả thi
5. Standard ML frameworks (PyTorch, TensorFlow) chủ yếu dùng FP32/FP16/BF16/INT8

## [NOTE] KHUYẾN NGHỊ TRIỂN KHAI

### Priority 1 (Bắt buộc):
1. mfmacc.s (FP32×FP32)
2. mmacc.w.b + variants (INT8 quantized)

### Priority 2 (Rất nên có):
3. mfmacc.s.h (FP16→FP32)
4. mfmacc.s.bf16 (BF16→FP32)
5. mfmacc.h (FP16×FP16)

### Priority 3 (Nice to have):
6. mfmacc.bf16.e5/e4 (FP8 extreme quantization)

### Có thể bỏ qua:
- Tất cả lệnh FP64
- Tất cả lệnh INT64
- Tất cả lệnh packed/special format
- TensorFloat-32
