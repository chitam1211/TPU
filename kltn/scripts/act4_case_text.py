"""Texts for act4_explain_cases.py: hand-written fadd.s cases and per-category wording."""

# fadd.s: hand-picked cases (one per special case), kept as in the first version.
# predict = expected (result, fflags) per mode; checked against Sail by the main script.
FADD_CASES = [
    dict(
        id="0", title="Phép tính thường: 1.5 + 2.0",
        fs1=0x3FC00000, fs2=0x40000000, modes=["rne"],
        predict={"rne": (0x40600000, 0x00)},
        purpose="""Kiểm tra đường đi cơ bản của bộ cộng FP với hai số thường (normal),
cùng dấu, số mũ gần nhau: tách trường -> căn số mũ -> cộng mantissa -> chuẩn hóa
-> đóng gói. Kết quả biểu diễn được chính xác nên không cần làm tròn. Đây là
testcase "đối chứng": nếu sai ở đây thì datapath cơ bản đã sai.""",
        why="""1.5 = 1.1b x 2^0 ; 2.0 = 1.0b x 2^1.
Chênh lệch số mũ = 1 -> dịch mantissa của 1.5 sang phải 1 bit: 0.11b x 2^1.
Cộng mantissa: 0.11b + 1.00b = 1.11b -> 1.11b x 2^1 = 3.5 (đã ở dạng 1.xxx, không cần chuẩn hóa).
Đóng gói: dấu 0, số mũ 1 + 127 = 128 = 0x80, mantissa .1100...0
-> 0 10000000 11000000000000000000000 = 0x40600000.
Không có bit nào bị dịch ra ngoài -> kết quả chính xác -> fflags = 0."""),
    dict(
        id="1", title="Làm tròn + chênh lệch số mũ rất lớn: 1.0 + subnormal nhỏ nhất",
        fs1=0x3F800000, fs2=0x00000001, modes=["rne", "rup"],
        predict={"rne": (0x3F800000, 0x01), "rup": (0x3F800001, 0x01)},
        purpose="""Kiểm tra bit sticky và các chế độ làm tròn. Toán hạng nhỏ (2^-149) nhỏ hơn
toán hạng lớn tới 149 bậc nhị phân, nên khi căn số mũ nó bị dịch ra ngoài toàn bộ
độ rộng mantissa. Phần cứng chỉ còn nhớ "có bit 1 bị mất" qua bit sticky.
Nếu bit sticky bị bỏ qua thì RUP sẽ sai (trả 1.0 thay vì 1.0 + 1 ulp) và NX không bật.""",
        why="""Giá trị đúng = 1 + 2^-149: lớn hơn 1.0 một chút, nhỏ hơn số float kế tiếp
1 + 2^-23 (0x3F800001) và rất gần 1.0 (không phải điểm giữa).
- RNE (gần nhất): số gần nhất là 1.0 -> 0x3F800000.
- RUP (về +vô cực): phải chọn số >= giá trị đúng -> 1 + 2^-23 = 0x3F800001.
Cả hai trường hợp đều đã bỏ đi phần 2^-149 (hoặc làm tròn lên) -> kết quả không
chính xác -> bật NX (fflags = 0x01). Không tràn trên/dưới -> chỉ có NX."""),
    dict(
        id="2", title="Số lớn nhất + số nhỏ: làm tròn sát biên tràn",
        fs1=0x7F7FFFFF, fs2=0x3F800000, modes=["rne", "rup"],
        predict={"rne": (0x7F7FFFFF, 0x01), "rup": (0x7F800000, 0x05)},
        purpose="""Kiểm tra làm tròn ngay tại số hữu hạn lớn nhất: cùng một phép tính, có chế
độ làm tròn giữ nguyên số lớn nhất, có chế độ làm tròn lên thành vô cực (tràn).
Phát hiện lỗi khi phần cứng chỉ kiểm tra tràn TRƯỚC khi làm tròn.""",
        why="""max = (2 - 2^-23) x 2^127 = 0x7F7FFFFF; 1 ulp của max = 2^104.
1.0 nhỏ hơn 1 ulp rất nhiều -> giá trị đúng = max + 1, chỉ hơn max một chút.
- RNE: số gần nhất là max -> 0x7F7FFFFF, mất phần +1 -> NX (0x01).
- RUP: phải chọn số >= max + 1. Số float tiếp theo sau max là 2^128, vượt
  phạm vi -> TRÀN TRÊN -> kết quả +vô cực = 0x7F800000, cờ OF + NX (0x05).
(Tràn luôn kèm NX vì kết quả trả về không bằng giá trị đúng.)"""),
    dict(
        id="2b", title="Ví dụ trong ảnh: số lớn nhất + subnormal âm, làm tròn xuống",
        fs1=0x7F7FFFFF, fs2=0x80400000, modes=["rdn"],
        predict={"rdn": (0x7F7FFFFE, 0x01)},
        purpose="""Hai toán hạng khác dấu -> bộ cộng thực hiện phép TRỪ mantissa. Kết hợp với
làm tròn về -vô cực (RDN) để kiểm tra làm tròn đúng hướng khi kết quả nằm ngay
dưới một số float biểu diễn được.""",
        why="""0x80400000 = -2^-127 (subnormal âm). Giá trị đúng = max - 2^-127: nhỏ hơn max
một chút, nằm giữa 0x7F7FFFFE (= max - 1 ulp) và max.
- RDN (về -vô cực): phải chọn số <= giá trị đúng -> 0x7F7FFFFE.
  (RNE sẽ cho max = 0x7F7FFFFF vì max gần hơn.)
Kết quả khác giá trị đúng -> NX (0x01)."""),
    dict(
        id="3", title="Triệt tiêu: số thường nhỏ nhất - subnormal lớn nhất",
        fs1=0x00800000, fs2=0x807FFFFF, modes=["rne"],
        predict={"rne": (0x00000001, 0x00)},
        purpose="""Hai số gần bằng nhau, khác dấu -> hầu hết các bit triệt tiêu nhau, kết quả nhỏ
hơn toán hạng rất nhiều. Kiểm tra: (1) bộ đếm số 0 đứng đầu (LZC) và dịch trái để
chuẩn hóa, (2) kết quả rơi vào vùng subnormal phải được đóng gói đúng (mũ = 0),
(3) cờ UF KHÔNG được bật sai.""",
        why="""0x00800000 = 2^-126 (số thường nhỏ nhất);
0x807FFFFF = -(2^-126 - 2^-149) (subnormal lớn nhất, mang dấu âm).
Tổng = 2^-126 - 2^-126 + 2^-149 = 2^-149 = subnormal nhỏ nhất = 0x00000001.
Kết quả biểu diễn chính xác -> không NX. RISC-V (IEEE 754, xét "tiny" sau làm tròn)
chỉ bật UF khi kết quả vừa tiny vừa KHÔNG chính xác -> không UF -> fflags = 0.
(Phép cộng/trừ hai số float không bao giờ cho kết quả subnormal không chính xác,
nên fadd/fsub không bao giờ bật UF.)"""),
    dict(
        id="4", title="(+0) + (-0): dấu của số 0 phụ thuộc chế độ làm tròn",
        fs1=0x00000000, fs2=0x80000000, modes=["rne", "rdn"],
        predict={"rne": (0x00000000, 0x00), "rdn": (0x80000000, 0x00)},
        purpose="""Kiểm tra quy tắc dấu của số 0 trong IEEE 754: khi tổng của hai toán hạng khác
dấu bằng đúng 0, dấu kết quả do chế độ làm tròn quyết định.""",
        why="""IEEE 754 (mục 6.3): tổng của hai số 0 khác dấu (hoặc x + (-x)) là +0 ở mọi chế
độ làm tròn, TRỪ RDN (làm tròn về -vô cực) cho -0.
- RNE: +0 = 0x00000000.
- RDN: -0 = 0x80000000.
Phép tính chính xác, không ngoại lệ -> fflags = 0."""),
    dict(
        id="4b", title="x + (-x): triệt tiêu hoàn toàn",
        fs1=0x3F800000, fs2=0xBF800000, modes=["rne", "rdn"],
        predict={"rne": (0x00000000, 0x00), "rdn": (0x80000000, 0x00)},
        purpose="""Mantissa sau khi trừ bằng 0 hoàn toàn. Phần cứng phải nhận ra kết quả = 0 (không
cố chuẩn hóa một mantissa toàn 0) và gán dấu theo chế độ làm tròn như trường hợp 4.""",
        why="""1.0 + (-1.0) = 0 chính xác.
Theo cùng quy tắc IEEE 754 như trường hợp 4: RNE -> +0 (0x00000000),
RDN -> -0 (0x80000000). Không ngoại lệ -> fflags = 0."""),
    dict(
        id="5", title="Subnormal + subnormal",
        fs1=0x00000001, fs2=0x00000001, modes=["rne"],
        predict={"rne": (0x00000002, 0x00)},
        purpose="""Kiểm tra xử lý số subnormal: trường mũ = 0 nghĩa là bit ẩn = 0 (dạng 0.xxx) và
số mũ thật cố định là -126 (không phải -127). Nếu phần cứng luôn thêm bit ẩn = 1
thì kết quả sẽ sai hoàn toàn.""",
        why="""0x00000001 = 0.000...01b x 2^-126 = 2^-149.
Hai số cùng số mũ (-126), không cần căn: 0.0...01 + 0.0...01 = 0.0...10 -> 2^-148.
Kết quả vẫn là subnormal: trường mũ = 0, mantissa = 2 -> 0x00000002.
Chính xác -> không NX, không UF -> fflags = 0."""),
    dict(
        id="6", title="Từ subnormal lên số thường",
        fs1=0x007FFFFF, fs2=0x00000001, modes=["rne"],
        predict={"rne": (0x00800000, 0x00)},
        purpose="""Tổng hai số subnormal tràn sang bit 23 (bit ẩn) -> kết quả thành số thường.
Kiểm tra phần cứng tăng trường mũ từ 0 lên 1 đúng cách.""",
        why="""0x007FFFFF = 0.111...1b x 2^-126 (subnormal lớn nhất) ; 0x00000001 = 2^-149.
Cộng: 0.111...1 + 0.000...1 = 1.000...0 -> 1.0 x 2^-126 = 2^-126.
Đây là số thường nhỏ nhất: trường mũ = 1, mantissa = 0 -> 0x00800000.
(Về mặt bit, cộng hai giá trị 32 bit 0x007FFFFF + 1 = 0x00800000: carry chạy vào
trường mũ - đây là lý do định dạng IEEE đặt mũ ngay trên mantissa.)
Chính xác -> fflags = 0."""),
    dict(
        id="7", title="Tràn trên: max + max",
        fs1=0x7F7FFFFF, fs2=0x7F7FFFFF, modes=["rne", "rtz"],
        predict={"rne": (0x7F800000, 0x05), "rtz": (0x7F7FFFFF, 0x05)},
        purpose="""Kiểm tra tràn trên (overflow) thực sự và giá trị trả về khi tràn theo từng chế
độ làm tròn: không phải chế độ nào cũng trả về vô cực.""",
        why="""max + max = 2 x max = (2 - 2^-23) x 2^128 > max -> TRÀN.
IEEE 754 quy định kết quả khi tràn theo chế độ làm tròn:
- RNE: +vô cực = 0x7F800000.
- RTZ (về 0): không bao giờ làm tròn ra xa 0 -> trả về số lớn nhất 0x7F7FFFFF.
Cả hai: cờ OF + NX = 0x05 (tràn luôn là kết quả không chính xác)."""),
    dict(
        id="8", title="Vô cực + số hữu hạn",
        fs1=0x7F800000, fs2=0x3F800000, modes=["rne"],
        predict={"rne": (0x7F800000, 0x00)},
        purpose="""Kiểm tra nhánh xử lý đặc biệt khi một toán hạng là vô cực (mũ = 255,
mantissa = 0): kết quả phải đi qua đường "special" chứ không qua datapath cộng.""",
        why="""+vô cực + 1.0 = +vô cực. Đây là kết quả chính xác theo IEEE 754
(vô cực là giá trị hợp lệ) -> 0x7F800000, không bật cờ nào (không phải OF:
OF chỉ bật khi hai số HỮU HẠN cho kết quả quá lớn)."""),
    dict(
        id="9", title="Vô cực - vô cực",
        fs1=0x7F800000, fs2=0xFF800000, modes=["rne"],
        predict={"rne": (0x7FC00000, 0x10)},
        purpose="""Kiểm tra phép toán không hợp lệ (invalid operation): phải sinh NaN và bật NV.""",
        why="""(+vô cực) + (-vô cực) không xác định (không có giá trị đúng).
IEEE 754: invalid operation -> kết quả là quiet NaN, cờ NV.
RISC-V quy định NaN sinh ra luôn là canonical NaN 0x7FC00000.
-> 0x7FC00000, fflags = NV = 0x10."""),
    dict(
        id="10", title="qNaN có payload làm đầu vào",
        fs1=0x7FFFFFFF, fs2=0x3F800000, modes=["rne"],
        predict={"rne": (0x7FC00000, 0x00)},
        purpose="""Kiểm tra truyền NaN: RISC-V khác nhiều kiến trúc khác ở chỗ KHÔNG giữ payload
của NaN đầu vào. Đồng thời kiểm tra qNaN không được bật NV.""",
        why="""0x7FFFFFFF: mũ = 255, mantissa != 0 -> NaN; bit 22 = 1 -> quiet NaN,
payload = 0x3FFFFF.
Phép toán với NaN cho kết quả NaN. Đặc tả RISC-V F (mục "NaN Generation and
Propagation"): kết quả NaN luôn là canonical NaN 0x7FC00000, không lan truyền payload.
qNaN không phải phép toán không hợp lệ -> không NV -> fflags = 0."""),
    dict(
        id="11", title="sNaN làm đầu vào",
        fs1=0x7F800001, fs2=0x3F800000, modes=["rne"],
        predict={"rne": (0x7FC00000, 0x10)},
        purpose="""Phân biệt sNaN với qNaN: cùng là NaN nhưng sNaN phải bật cờ NV khi tham gia
phép toán số học. Lỗi thường gặp là xử lý mọi NaN giống nhau.""",
        why="""0x7F800001: mũ = 255, mantissa != 0 -> NaN; bit 22 = 0 -> signaling NaN.
IEEE 754: phép toán số học với sNaN -> invalid operation -> bật NV.
Kết quả: canonical NaN 0x7FC00000 (giống trường hợp 10), fflags = NV = 0x10."""),
]


# What each instruction computes (header of its file).
INSN_DOC = {
    "flw": "flw rd, offset(rs1): nạp 32 bit từ bộ nhớ (địa chỉ rs1 + offset) vào thanh ghi float rd, giữ nguyên từng bit.",
    "fsw": "fsw rs2, offset(rs1): ghi 32 bit của thanh ghi float rs2 ra bộ nhớ (địa chỉ rs1 + offset), giữ nguyên từng bit.",
    "fadd.s": "fadd.s rd, rs1, rs2, rm: rd = rs1 + rs2, làm tròn theo rm.",
    "fsub.s": "fsub.s rd, rs1, rs2, rm: rd = rs1 - rs2, làm tròn theo rm.",
    "fmul.s": "fmul.s rd, rs1, rs2, rm: rd = rs1 x rs2, làm tròn theo rm.",
    "fdiv.s": "fdiv.s rd, rs1, rs2, rm: rd = rs1 / rs2, làm tròn theo rm.",
    "fsqrt.s": "fsqrt.s rd, rs1, rm: rd = căn bậc hai của rs1, làm tròn theo rm.",
    "fmadd.s": "fmadd.s rd, rs1, rs2, rs3, rm: rd = rs1 x rs2 + rs3, tính chính xác rồi làm tròn MỘT lần.",
    "fmsub.s": "fmsub.s rd, rs1, rs2, rs3, rm: rd = rs1 x rs2 - rs3, làm tròn một lần.",
    "fnmsub.s": "fnmsub.s rd, rs1, rs2, rs3, rm: rd = -(rs1 x rs2) + rs3, làm tròn một lần.",
    "fnmadd.s": "fnmadd.s rd, rs1, rs2, rs3, rm: rd = -(rs1 x rs2) - rs3, làm tròn một lần.",
    "fsgnj.s": "fsgnj.s rd, rs1, rs2: rd = độ lớn (31 bit thấp) của rs1, bit dấu của rs2. Chỉ thao tác bit, không bật cờ.",
    "fsgnjn.s": "fsgnjn.s rd, rs1, rs2: rd = độ lớn của rs1, bit dấu NGƯỢC của rs2. Chỉ thao tác bit, không bật cờ.",
    "fsgnjx.s": "fsgnjx.s rd, rs1, rs2: rd = độ lớn của rs1, dấu = dấu rs1 XOR dấu rs2. Chỉ thao tác bit, không bật cờ.",
    "fmin.s": "fmin.s rd, rs1, rs2: rd = số nhỏ hơn trong rs1, rs2 (coi -0 < +0; nếu một toán hạng là NaN thì lấy toán hạng kia).",
    "fmax.s": "fmax.s rd, rs1, rs2: rd = số lớn hơn trong rs1, rs2 (coi -0 < +0; nếu một toán hạng là NaN thì lấy toán hạng kia).",
    "feq.s": "feq.s rd, rs1, rs2: rd (thanh ghi nguyên) = 1 nếu rs1 == rs2, ngược lại 0.",
    "flt.s": "flt.s rd, rs1, rs2: rd (thanh ghi nguyên) = 1 nếu rs1 < rs2, ngược lại 0.",
    "fle.s": "fle.s rd, rs1, rs2: rd (thanh ghi nguyên) = 1 nếu rs1 <= rs2, ngược lại 0.",
    "fcvt.w.s": "fcvt.w.s rd, rs1, rm: rd (int32 có dấu) = rs1 (float) làm tròn về số nguyên theo rm.",
    "fcvt.wu.s": "fcvt.wu.s rd, rs1, rm: rd (uint32 không dấu) = rs1 (float) làm tròn về số nguyên theo rm.",
    "fcvt.s.w": "fcvt.s.w rd, rs1, rm: rd (float) = rs1 (int32 có dấu) đổi sang float32, làm tròn theo rm.",
    "fcvt.s.wu": "fcvt.s.wu rd, rs1, rm: rd (float) = rs1 (uint32 không dấu) đổi sang float32, làm tròn theo rm.",
    "fmv.x.w": "fmv.x.w rd, rs1: rd (thanh ghi nguyên) = 32 bit của rs1 (float), chép nguyên, không đổi giá trị.",
    "fmv.w.x": "fmv.w.x rd, rs1: rd (float) = 32 bit của rs1 (nguyên), chép nguyên, không đổi giá trị.",
    "fclass.s": "fclass.s rd, rs1: rd = mặt nạ 10 bit, đúng 1 bit bằng 1 cho biết loại của rs1.",
}

# Category -> (title, why it is tested). "family:key" overrides the plain key.
CATEGORY = {
    "normal": ("Phép tính thường",
               "Các toán hạng là số thường và kết quả biểu diễn được chính xác: kiểm tra datapath cơ bản\n"
               "(tách trường -> tính -> chuẩn hóa -> đóng gói) khi không cần làm tròn. Đây là testcase\n"
               "đối chứng: nếu sai ở đây thì đường tính cơ bản đã sai."),
    "round": ("Làm tròn (kết quả không chính xác)",
              "Kết quả đúng cần nhiều hơn 24 bit có nghĩa nên phải làm tròn. Kiểm tra các bit guard/sticky,\n"
              "logic chọn số theo rm và cờ NX."),
    "tie": ("Làm tròn khi hòa (cách đều hai số)",
            "Giá trị đúng nằm CHÍNH GIỮA hai số liền kề. RNE phải chọn số chẵn (bit cuối = 0), RMM chọn số\n"
            "xa 0. Lỗi thường gặp: luôn làm tròn lên khi hòa."),
    "modes": ("Cùng phép tính với 5 chế độ làm tròn",
              "Cùng toán hạng nhưng chạy với RNE, RTZ, RDN, RUP, RMM và cho các kết quả khác nhau. Kiểm tra\n"
              "phần cứng đọc đúng trường rm của lệnh và áp dụng đúng quy tắc từng chế độ."),
    "cancel": ("Triệt tiêu (hai số gần bằng nhau trừ nhau)",
               "Phần lớn các bit triệt tiêu, kết quả nhỏ hơn toán hạng nhiều lần: kiểm tra bộ đếm số 0 đứng\n"
               "đầu và phép dịch trái để chuẩn hóa."),
    "zero_sign": ("Kết quả bằng 0: dấu của số 0",
                  "Kết quả chính xác bằng 0. IEEE 754 quy định: hai số 0 cùng dấu giữ dấu đó; còn lại (+0 cộng -0,\n"
                  "x + (-x)) cho +0 ở mọi chế độ, riêng RDN cho -0. Kiểm tra logic dấu khi kết quả bằng 0."),
    "zero_in": ("Toán hạng bằng 0",
                "Một toán hạng là +-0: kết quả phải đúng giá trị và đúng dấu, không bật cờ."),
    "sub_in": ("Toán hạng subnormal",
               "Toán hạng subnormal (trường mũ = 0) không có bit ẩn 1 và có số mũ thật là -126. Kiểm tra bước\n"
               "tách trường xử lý đúng số subnormal."),
    "sub_out": ("Kết quả subnormal chính xác",
                "Kết quả nhỏ hơn số thường nhỏ nhất 2^-126 nhưng biểu diễn chính xác được bằng subnormal: phải\n"
                "đóng gói với trường mũ = 0 và KHÔNG bật UF (vì không mất bit nào)."),
    "underflow": ("Tràn dưới (underflow)",
                  "Kết quả quá nhỏ (tiny, < 2^-126) và không chính xác: phải bật UF + NX; kết quả được làm tròn\n"
                  "vào vùng subnormal hoặc về 0."),
    "overflow": ("Tràn trên (overflow)",
                 "Kết quả vượt số hữu hạn lớn nhất: phải bật OF + NX; giá trị trả về (vô cực hay số lớn nhất)\n"
                 "phụ thuộc chế độ làm tròn."),
    "inf": ("Toán hạng vô cực",
            "Có toán hạng +-vô cực nhưng phép toán vẫn hợp lệ: kết quả phải đi qua nhánh xử lý đặc biệt\n"
            "(không qua datapath số học) và không bật cờ."),
    "invalid": ("Phép toán không hợp lệ (NV)",
                "Phép toán không có giá trị đúng (vô cực - vô cực, 0 x vô cực, 0/0, vô cực/vô cực, căn số âm):\n"
                "phải trả canonical NaN 0x7FC00000 và bật NV."),
    "divzero": ("Chia cho 0 (DZ)",
                "Số hữu hạn khác 0 chia cho +-0: kết quả +-vô cực và bật DZ (không phải NV)."),
    "qnan": ("qNaN làm đầu vào",
             "Toán hạng là quiet NaN: kết quả là canonical NaN 0x7FC00000 (RISC-V không giữ payload) và\n"
             "KHÔNG bật NV."),
    "snan": ("sNaN làm đầu vào",
             "Toán hạng là signaling NaN: kết quả canonical NaN và BẮT BUỘC bật NV. sNaN khác qNaN ở bit 22\n"
             "của mantissa (sNaN: bit 22 = 0)."),
    "fused": ("Chỉ làm tròn một lần (đặc trưng của FMA)",
              "FMA tính a x b + c chính xác rồi mới làm tròn MỘT lần. Ở testcase này, cách tính rời (fmul rồi\n"
              "fadd, làm tròn hai lần) cho kết quả KHÁC: phát hiện lỗi làm tròn tích trung gian."),
    "div_by_inf": ("Chia cho vô cực",
                   "Số hữu hạn chia cho +-vô cực bằng +-0 chính xác, dấu là XOR hai dấu, không bật cờ."),
    "sqrt:exact": ("Căn chính xác (số chính phương)",
                   "Căn của toán hạng biểu diễn chính xác được (ví dụ căn 4 = 2): không làm tròn, không cờ."),
    "sqrt:round": ("Căn không chính xác",
                   "Căn của hầu hết các số là số vô tỉ: luôn phải làm tròn và bật NX. Kiểm tra vòng lặp tính căn\n"
                   "và bit sticky (phần dư khác 0)."),
    "sqrt:zero": ("Căn của +-0",
                  "Theo IEEE 754, căn(+0) = +0 và căn(-0) = -0, không bật cờ: -0 tuy có dấu âm nhưng không phải\n"
                  "phép toán không hợp lệ."),
    "sqrt:invalid": ("Căn của số âm",
                     "Căn của số âm (kể cả -vô cực, trừ -0) không xác định: canonical NaN và bật NV."),
    "f2i:exact": ("Số float là số nguyên",
                  "Toán hạng có giá trị nguyên: đổi chính xác, không làm tròn, không cờ."),
    "f2i:negative": ("Số âm có giá trị nguyên",
                     "Kiểm tra đổi số âm sang biểu diễn bù hai của int32."),
    "f2i:round": ("Có phần lẻ: làm tròn về số nguyên",
                  "Toán hạng có phần lẻ nên phải làm tròn về số nguyên theo rm và bật NX."),
    "f2i:tie": ("Phần lẻ đúng bằng 0.5",
                "Toán hạng nằm chính giữa hai số nguyên: RNE chọn số nguyên chẵn, RMM chọn số xa 0."),
    "f2i:small": ("Độ lớn nhỏ hơn 1",
                  "|x| < 1: kết quả là 0 hoặc +-1 tùy chế độ làm tròn, luôn bật NX."),
    "f2i:range": ("Ngoài phạm vi số nguyên",
                  "Giá trị (sau làm tròn) vượt phạm vi của kiểu nguyên đích: bật NV (không bật NX) và trả về\n"
                  "giá trị bão hòa (giới hạn gần nhất của phạm vi)."),
    "f2i:neg_wu": ("Số âm đổi sang số nguyên không dấu",
                   "uint32 không biểu diễn được số âm: nếu làm tròn ra <= -1 thì NV và trả 0; nếu làm tròn về 0\n"
                   "thì hợp lệ (chỉ NX)."),
    "f2i:nan": ("NaN đổi sang số nguyên",
                "NaN không có giá trị nguyên: RISC-V trả về 2^31 - 1 (fcvt.w.s) hoặc 2^32 - 1 (fcvt.wu.s) và bật NV."),
    "f2i:inf": ("Vô cực đổi sang số nguyên",
                "Vô cực vượt mọi phạm vi: NV và trả giá trị bão hòa (+vô cực -> giới hạn trên, -vô cực -> giới hạn dưới)."),
    "f2i:zero": ("Đổi +-0 sang số nguyên", "+-0 đổi thành 0, không bật cờ (số nguyên không có -0)."),
    "f2i:sub_in": ("Subnormal đổi sang số nguyên",
                   "Số subnormal rất gần 0: kết quả là 0 hoặc +-1 tùy rm, bật NX."),
    "i2f:zero": ("Số nguyên 0", "0 đổi thành +0, không cờ."),
    "i2f:exact": ("Số nguyên biểu diễn chính xác",
                  "Số nguyên có không quá 24 bit có nghĩa: float32 biểu diễn chính xác, không làm tròn."),
    "i2f:negative": ("Số nguyên âm", "Kiểm tra lấy dấu và độ lớn từ biểu diễn bù hai."),
    "i2f:round": ("Số nguyên lớn hơn 2^24: phải làm tròn",
                  "float32 chỉ có 24 bit có nghĩa: số nguyên dùng nhiều bit hơn phải làm tròn theo rm, bật NX."),
    "i2f:tie": ("Số nguyên nằm giữa hai float", "Làm tròn khi hòa: RNE chọn mantissa chẵn."),
    "i2f:int_min": ("Số âm nhỏ nhất -2^31",
                    "0x80000000 = -2^31: lấy độ lớn bằng bù hai dễ tràn 32 bit nếu xử lý sai; kết quả đúng là\n"
                    "-2^31 chính xác."),
    "cmp:less": ("rs1 < rs2", "So sánh hai số thường khác nhau."),
    "cmp:greater": ("rs1 > rs2", "So sánh hai số thường khác nhau."),
    "cmp:equal": ("rs1 = rs2", "So sánh hai số bằng nhau."),
    "cmp:zeros": ("So sánh +0 với -0", "IEEE 754 coi +0 bằng -0 dù bit dấu khác nhau."),
    "cmp:inf": ("So sánh với vô cực", "Vô cực vẫn so sánh được như một giá trị (lớn/nhỏ hơn mọi số hữu hạn)."),
    "cmp:sub_in": ("So sánh với subnormal", "Số subnormal phải được so sánh đúng giá trị (không bị coi như 0)."),
    "cmp:qnan": ("So sánh với qNaN",
                 "NaN không có thứ tự nên kết quả luôn 0. feq KHÔNG bật NV với qNaN, còn flt/fle bật NV (so\n"
                 "sánh có thứ tự với NaN là không hợp lệ)."),
    "cmp:snan": ("So sánh với sNaN", "Kết quả 0; cả feq, flt, fle đều bật NV vì toán hạng là sNaN."),
    "minmax:compare": ("Chọn số nhỏ/lớn hơn", "Hai số thường khác nhau."),
    "minmax:neg": ("Hai số âm", "Với số âm, số có độ lớn lớn hơn là số nhỏ hơn."),
    "minmax:equal": ("Hai số bằng nhau", "Kết quả là chính giá trị đó."),
    "minmax:zeros": ("+0 và -0", "RISC-V coi -0 < +0: fmin chọn -0, fmax chọn +0."),
    "minmax:inf": ("Có vô cực", "Vô cực tham gia so sánh như một giá trị bình thường."),
    "minmax:sub_in": ("Có subnormal", "Số subnormal phải được so sánh đúng giá trị."),
    "minmax:one_qnan": ("Một toán hạng là qNaN",
                        "RISC-V (từ đặc tả 2.2): nếu chỉ một toán hạng là NaN thì kết quả là toán hạng còn lại,\n"
                        "không bật NV với qNaN."),
    "minmax:both_nan": ("Cả hai toán hạng là NaN", "Kết quả là canonical NaN 0x7FC00000."),
    "minmax:snan": ("Có sNaN", "Vẫn chọn toán hạng còn lại (hoặc canonical NaN), nhưng BẬT NV vì có sNaN."),
    "sgnj:pp": ("rs1 dương, rs2 dương", "Kiểm tra bit dấu kết quả theo quy tắc của lệnh."),
    "sgnj:pn": ("rs1 dương, rs2 âm", "Kiểm tra bit dấu kết quả theo quy tắc của lệnh."),
    "sgnj:np": ("rs1 âm, rs2 dương", "Kiểm tra bit dấu kết quả theo quy tắc của lệnh."),
    "sgnj:nn": ("rs1 âm, rs2 âm", "Kiểm tra bit dấu kết quả theo quy tắc của lệnh."),
    "sgnj:zero": ("rs1 = +-0", "Lệnh chỉ thay bit dấu nên tạo được cả +0 và -0."),
    "sgnj:inf": ("rs1 = vô cực", "Vô cực cũng chỉ bị thay bit dấu."),
    "sgnj:nan": ("rs1 là NaN",
                 "Lệnh chỉ thao tác bit: NaN giữ nguyên payload (KHÔNG canonical hóa), sNaN không bật NV."),
    "move:normal": ("Số thường", "Chép nguyên 32 bit."),
    "move:negative": ("Số âm", "Bit dấu cũng được chép nguyên."),
    "move:zero": ("+0", "Chép nguyên 32 bit."),
    "move:neg_zero": ("-0", "-0 (0x80000000) phải giữ nguyên bit dấu."),
    "move:subnormal": ("Subnormal", "Không được làm tròn hay xóa subnormal về 0."),
    "move:inf": ("Vô cực", "Chép nguyên 32 bit."),
    "move:qnan": ("qNaN", "Chép nguyên, giữ payload: lệnh chuyển dữ liệu không canonical hóa NaN."),
    "move:snan": ("sNaN", "Chép nguyên và KHÔNG bật NV: đây là chuyển dữ liệu, không phải phép toán."),
    "imm_zero": ("Offset = 0", "Địa chỉ = rs1 + 0: dạng đơn giản nhất của lệnh truy cập bộ nhớ."),
    "imm_pos": ("Offset dương", "Kiểm tra bộ cộng địa chỉ rs1 + offset với offset dương."),
    "imm_odd": ("Offset lẻ (không chia hết cho 4)",
                "rs1 lẻ, offset lẻ nhưng tổng chia hết cho 4: kiểm tra phép cộng địa chỉ dùng đủ mọi bit,\n"
                "không giả định rs1 hay offset đã căn lề."),
    "imm_neg": ("Offset âm", "Immediate âm phải được mở rộng dấu (sign-extend) đúng trước khi cộng."),
    "imm_max": ("Offset lớn nhất +2047",
                "Giá trị dương lớn nhất của immediate 12 bit có dấu (0x7FF): kiểm tra giải mã immediate."),
    "imm_min": ("Offset nhỏ nhất -2048",
                "Immediate 0x800 có bit dấu = 1: phải mở rộng dấu thành 0xFFFFF800 (-2048); lỗi mở rộng dấu\n"
                "sẽ làm địa chỉ lệch 4096 byte."),
    "base_reg": ("Thanh ghi cơ sở rs1 khác",
                 "Dùng một thanh ghi nguyên bất kỳ làm rs1: kiểm tra phần cứng đọc đúng trường rs1 của lệnh."),
}
for _i, _n in enumerate(["-vô cực", "số âm thường", "subnormal âm", "-0", "+0",
                         "subnormal dương", "số dương thường", "+vô cực", "sNaN", "qNaN"]):
    CATEGORY[f"class:class{_i}"] = (f"Loại {_i}: {_n}",
                                    f"rs1 là {_n} -> fclass phải trả mặt nạ chỉ có bit {_i} = 1.")


