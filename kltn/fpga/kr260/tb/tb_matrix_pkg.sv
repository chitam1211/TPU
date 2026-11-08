`timescale 1ns / 1ps
// =============================================================================
// tb_matrix_pkg.sv
// -----------------------------------------------------------------------------
// Package dung chung cho tat ca testbench trong thu muc Verify/.
//   1. Hang so + ham ma hoa (encode) lenh ma tran theo dung bo decode cua RTL
//      (Source_code/rme_rtl/matrix_dispatch.sv).
//   2. Reference model (mo hinh tham chieu) de tinh ket qua mong doi:
//        - ALU so nguyen element-wise (madd/msub/.../msra)
//        - FP32 FMA chinh xac tuyet doi (exact) + lam tron RNE + co fflags
//        - FP32 min/max theo ngu nghia RISC-V F
//        - Bo sinh so gia ngau nhien LCG (co dinh seed -> ket qua lap lai duoc)
//
// Dinh dang lenh 32-bit (opcode custom 0101011):
//   [31:28] func4 | [27:26] uop | [25:23] ctrl/imm3 | [22:20] ms2 | [19:18] s_size
//   [17:15] ms1   | [14:12] func3 | [11:10] d_size  | [9:7]  md   | [6:0] opcode
//   uop (func3=000): 00 = config, 01 = load/store, 10 = matmul, 11 = misc
//   func3 = 001   : element-wise (uop 01 = integer, uop 10 = FP)
// So hieu thanh ghi ma tran 3-bit: 0..3 = tr0..tr3 (tile), 4..7 = acc0..acc3.
// =============================================================================
package tb_matrix_pkg;

    localparam logic [6:0] OPC_MATRIX = 7'b0101011;

    // ---- Kich thuoc kien truc cua RTL hien tai --------------------------------
    localparam int ROWS  = 4;   // so hang moi thanh ghi ma tran
    localparam int BEATS = 4;   // so word 32-bit moi hang (TRLEN = ARLEN = 128 bit)
    localparam int MAX_M = 4;   // mtilem toi da (lon hon -> illegal)
    localparam int MAX_N = 4;   // mtilen toi da
    localparam int MAX_K = 16;  // mtilek toi da

    // ---- Ma so thanh ghi ma tran ------------------------------------------------
    localparam logic [2:0] TR0 = 3'd0, TR1 = 3'd1, TR2 = 3'd2, TR3 = 3'd3;
    localparam logic [2:0] ACC0 = 3'd4, ACC1 = 3'd5, ACC2 = 3'd6, ACC3 = 3'd7;

    // ---- Mot so hang so FP32 hay dung --------------------------------------------
    localparam logic [31:0] FP_POS_ZERO = 32'h0000_0000;
    localparam logic [31:0] FP_NEG_ZERO = 32'h8000_0000;
    localparam logic [31:0] FP_ONE      = 32'h3F80_0000;
    localparam logic [31:0] FP_TWO      = 32'h4000_0000;
    localparam logic [31:0] FP_HALF     = 32'h3F00_0000;
    localparam logic [31:0] FP_POS_INF  = 32'h7F80_0000;
    localparam logic [31:0] FP_NEG_INF  = 32'hFF80_0000;
    localparam logic [31:0] FP_QNAN     = 32'h7FC0_0000; // canonical NaN
    localparam logic [31:0] FP_SNAN     = 32'h7F80_0001; // signaling NaN
    localparam logic [31:0] FP_MAX      = 32'h7F7F_FFFF; // so huu han lon nhat
    localparam logic [31:0] FP_MIN_NORM = 32'h0080_0000; // 2^-126
    localparam logic [31:0] FP_MIN_SUB  = 32'h0000_0001; // 2^-149
    localparam logic [31:0] FP_MAX_SUB  = 32'h007F_FFFF;

    // =========================================================================
    // 1. HAM MA HOA LENH
    // =========================================================================
    // Truong tong quat (dung cho misc / matmul / element-wise).
    function automatic logic [31:0] enc_raw(
        input logic [3:0] func4, input logic [1:0] uop, input logic [2:0] ctrl3,
        input logic [2:0] ms2,   input logic [1:0] s_size, input logic [2:0] ms1,
        input logic [2:0] func3, input logic [1:0] d_size, input logic [2:0] md);
        return {func4, uop, ctrl3, ms2, s_size, ms1, func3, d_size, md, OPC_MATRIX};
    endfunction

    // Config: msettile{k,m,n}[i] / mrelease.
    //   func4: 0000 mrelease, 0001 K, 0010 M, 0011 N
    //   use_rs1 = 1 -> dang thanh ghi (rs1 o [19:15]); 0 -> dang immediate uimm10 o [24:15]
    function automatic logic [31:0] enc_cfg(
        input logic [3:0] func4, input logic use_rs1,
        input logic [9:0] uimm10, input logic [4:0] rs1);
        if (use_rs1) return {func4, 2'b00, 1'b1, 5'b0, rs1, 3'b000, 5'b0, OPC_MATRIX};
        else         return {func4, 2'b00, 1'b0, uimm10, 3'b000, 5'b0, OPC_MATRIX};
    endfunction

    // Load/store tile: func4 0000 = A, 0001 = B, 0010 = C ; ls 0 = load, 1 = store
    //   rs2 = thanh ghi chua stride (byte), rs1 = thanh ghi chua dia chi base
    //   d_size: 00 = e8, 01 = e16, 10 = e32, 11 = e64
    function automatic logic [31:0] enc_ls(
        input logic [3:0] func4, input logic is_store, input logic [4:0] rs2,
        input logic [4:0] rs1, input logic [1:0] d_size, input logic [2:0] md);
        return {func4, 2'b01, is_store, rs2, rs1, 3'b000, d_size, md, OPC_MATRIX};
    endfunction

    // Matmul: func4 0000 = FP (mfmacc), 0001 = INT (mmacc*)
    //   size_sup (INT): 000 mmaccu, 001 mmaccus, 010 mmaccsu, 011 mmacc
    function automatic logic [31:0] enc_mma(
        input logic [3:0] func4, input logic [2:0] size_sup, input logic [2:0] ms2,
        input logic [1:0] s_size, input logic [2:0] ms1, input logic [1:0] d_size,
        input logic [2:0] md);
        return enc_raw(func4, 2'b10, size_sup, ms2, s_size, ms1, 3'b000, d_size, md);
    endfunction

    // Element-wise: uop 01 = integer (.w), uop 10 = FP (.s)
    //   ctrl3 = 111 -> dang .mm ; ctrl3 = 0..3 -> dang .mv.i (chon hang cua ms1)
    function automatic logic [31:0] enc_ew(
        input logic [3:0] func4, input logic [1:0] uop, input logic [2:0] ctrl3,
        input logic [2:0] ms2, input logic [2:0] ms1, input logic [2:0] md);
        return enc_raw(func4, uop, ctrl3, ms2, 2'b10, ms1, 3'b001, 2'b10, md);
    endfunction

    // mmovw.x.m rd, ms2, rs1 : GPR[rd] = ms2[rs1 / 4][rs1 % 4]
    function automatic logic [31:0] enc_mmovw_x_m(
        input logic [4:0] rd, input logic [2:0] ms2, input logic [4:0] rs1);
        return {4'b0010, 2'b11, 1'b0, 2'b10, ms2, rs1, 3'b000, rd, OPC_MATRIX};
    endfunction

    // mmovw.m.x md, rs2, rs1 : md[rs1 / 4][rs1 % 4] = GPR[rs2]
    function automatic logic [31:0] enc_mmovw_m_x(
        input logic [2:0] md, input logic [4:0] rs2, input logic [4:0] rs1);
        return {4'b0011, 2'b11, 1'b1, rs2, rs1, 3'b000, 2'b10, md, OPC_MATRIX};
    endfunction

    // mdupw.m.x md, rs2 : moi phan tu cua md = GPR[rs2]
    function automatic logic [31:0] enc_mdupw_m_x(input logic [2:0] md, input logic [4:0] rs2);
        return {4'b0011, 2'b11, 1'b0, rs2, 5'b0, 3'b000, 2'b10, md, OPC_MATRIX};
    endfunction

    // =========================================================================
    // 2. REFERENCE MODEL SO NGUYEN
    // =========================================================================
    // ALU element-wise 32-bit. Ngu nghia: md = ms2 OP ms1 (a = ms1, b = ms2).
    // Khong co bao hoa (xmsaten = 0: RTL chua co duong ghi CSR xmsaten).
    function automatic logic [31:0] ref_ew_int(input logic [3:0] func4,
                                               input logic [31:0] a, input logic [31:0] b);
        logic signed [63:0] sa, sb, prod;
        sa = $signed(a);
        sb = $signed(b);
        case (func4)
            4'b0000: return b + a;                                       // madd
            4'b0001: return a - b;                                       // msub = ms1 - ms2 (proposal 5.5.1)
            4'b0010: return b * a;                                       // mmul (32 bit thap)
            4'b0011: begin prod = sb * sa; return prod[63:32]; end       // mmulh (32 bit cao, co dau)
            4'b0100: return ($signed(a) > $signed(b)) ? a : b;           // mmax  (co dau)
            4'b0101: return (a > b) ? a : b;                             // mumax (khong dau)
            4'b0110: return ($signed(a) < $signed(b)) ? a : b;           // mmin  (co dau)
            4'b0111: return (a < b) ? a : b;                             // mumin (khong dau)
            4'b1000: return b >> a[4:0];                                 // msrl
            4'b1001: return b << a[4:0];                                 // msll
            4'b1010: return $signed(b) >>> a[4:0];                       // msra
            default: return 32'h0;
        endcase
    endfunction

    // Lay byte thu idx (0..3) cua word va mo rong len 32 bit (co/khong dau)
    function automatic logic [31:0] ext8(input logic [31:0] word, input int idx, input logic is_unsigned);
        logic [7:0] b;
        b = word[idx*8 +: 8];
        return is_unsigned ? {24'b0, b} : {{24{b[7]}}, b};
    endfunction

    // =========================================================================
    // 3. REFERENCE MODEL FP32 (IEEE-754, lam tron RNE, co fflags)
    // =========================================================================
    // ref_fma32(a, b, c) = round_RNE(a * b + c) tinh CHINH XAC (khong double-round).
    // Tra ve {flags[4:0], bits[31:0]}; flags = {NV, DZ, OF, UF, NX}.
    //   - NaN dau ra luon la canonical NaN 0x7FC00000 (giong RISC-V).
    //   - Underflow: tininess phat hien SAU khi lam tron (theo dac ta matrix).
    // Dung chung cho: add = fma(ms1, 1.0, ms2); sub = fma(-ms1, 1.0, ms2);
    //                 mul = fma(ms1, ms2, +-0) ; mfmacc = chuoi fma.
    localparam int FW = 640; // do rong du de cong chinh xac moi cap so FP32

    function automatic logic [36:0] ref_fma32(input logic [31:0] a, input logic [31:0] b,
                                              input logic [31:0] c);
        logic sa, sb, sc, sp, sr;
        logic a_nan, b_nan, c_nan, a_snan, b_snan, c_snan;
        logic a_inf, b_inf, c_inf, a_zero, b_zero, c_zero;
        logic inv_prod, prod_inf, nv;
        logic [23:0] ma, mb, mc;
        logic [47:0] mp;
        int ea, eb, ec, ep, emin, p, e, lsb, q, lsb24, e_r;
        logic [FW-1:0] P, C, R;
        logic [25:0] kept, kept24;
        logic guard, sticky, inexact, tiny, of, uf, g24, s24;
        logic [31:0] bits;
        logic [7:0] biased;

        sa = a[31]; sb = b[31]; sc = c[31];
        sp = sa ^ sb;
        a_nan = (a[30:23] == 8'hFF) && (a[22:0] != 0);
        b_nan = (b[30:23] == 8'hFF) && (b[22:0] != 0);
        c_nan = (c[30:23] == 8'hFF) && (c[22:0] != 0);
        a_snan = a_nan && !a[22]; b_snan = b_nan && !b[22]; c_snan = c_nan && !c[22];
        a_inf = (a[30:23] == 8'hFF) && (a[22:0] == 0);
        b_inf = (b[30:23] == 8'hFF) && (b[22:0] == 0);
        c_inf = (c[30:23] == 8'hFF) && (c[22:0] == 0);
        a_zero = (a[30:0] == 0); b_zero = (b[30:0] == 0); c_zero = (c[30:0] == 0);

        // ---- Truong hop dac biet: NaN / Inf ----
        inv_prod = (a_inf && b_zero) || (b_inf && a_zero);
        prod_inf = (a_inf || b_inf) && !a_nan && !b_nan && !inv_prod;
        nv = a_snan || b_snan || c_snan || inv_prod || (prod_inf && c_inf && (sp != sc));
        if (a_nan || b_nan || c_nan || nv) return {nv, 4'b0000, FP_QNAN};
        if (prod_inf) return {5'b0, sp, 8'hFF, 23'b0};
        if (c_inf)    return {5'b0, sc, 8'hFF, 23'b0};

        // ---- Gia tri = (-1)^s * M * 2^E ----
        ma = {(a[30:23] != 0), a[22:0]}; ea = (a[30:23] == 0) ? -149 : int'(a[30:23]) - 150;
        mb = {(b[30:23] != 0), b[22:0]}; eb = (b[30:23] == 0) ? -149 : int'(b[30:23]) - 150;
        mc = {(c[30:23] != 0), c[22:0]}; ec = (c[30:23] == 0) ? -149 : int'(c[30:23]) - 150;
        mp = ma * mb;
        ep = ea + eb;

        // ---- Cong chinh xac tren luoi 2^emin ----
        emin = (ep < ec) ? ep : ec;
        P = {{(FW-48){1'b0}}, mp} << (ep - emin);
        C = {{(FW-24){1'b0}}, mc} << (ec - emin);
        if (mp == 0) P = '0;
        if (mc == 0) C = '0;
        if (sp == sc)      begin R = P + C; sr = sp; end
        else if (P > C)    begin R = P - C; sr = sp; end
        else if (C > P)    begin R = C - P; sr = sc; end
        else               begin R = '0;    sr = 1'b0; end

        if (R == 0) begin
            // Ket qua bang 0 chinh xac: cung dau -> giu dau, khac dau -> +0 (RNE)
            sr = (P == 0 && C == 0) ? ((sp == sc) ? sp : 1'b0) : 1'b0;
            return {5'b0, sr, 31'b0};
        end

        // ---- Chuan hoa ----
        p = -1;
        for (int i = FW-1; i >= 0; i--) if (p < 0 && R[i]) p = i;
        e = p + emin;                         // so mu cua bit dan dau (khong gioi han)

        // tininess sau lam tron (do chinh xac 24 bit, so mu khong gioi han)
        lsb24 = p - 23;
        if (lsb24 <= 0) begin kept24 = 26'(R << (-lsb24)); g24 = 0; s24 = 0; end
        else begin
            kept24 = 26'(R >> lsb24);
            g24 = R[lsb24-1];
            s24 = (lsb24 > 1) ? ((R << (FW - lsb24 + 1)) != 0) : 1'b0;
        end
        kept24 = kept24 + ((g24 && (s24 || kept24[0])) ? 26'd1 : 26'd0);
        e_r = e + (kept24[24] ? 1 : 0);
        tiny = (e_r < -126);

        // ---- Lam tron that (co tinh vung subnormal) ----
        lsb = (e >= -126) ? (p - 23) : (-149 - emin);
        if (lsb <= 0) begin kept = 26'(R << (-lsb)); guard = 0; sticky = 0; end
        else begin
            kept = 26'(R >> lsb);
            guard = R[lsb-1];
            sticky = (lsb > 1) ? ((R << (FW - lsb + 1)) != 0) : 1'b0;
        end
        q = lsb + emin;                       // trong so cua bit thap nhat cua kept
        inexact = guard || sticky;
        kept = kept + ((guard && (sticky || kept[0])) ? 26'd1 : 26'd0);
        if (kept[24]) begin kept = kept >> 1; q = q + 1; end

        of = 1'b0;
        if (kept[23]) begin
            if (q + 150 >= 255) of = 1'b1;
            else begin
                biased = 8'(q + 150);
                bits = {sr, biased, kept[22:0]};
            end
        end else begin
            bits = {sr, 8'h00, kept[22:0]};   // subnormal hoac 0
        end
        if (of) return {5'b00101, sr, 8'hFF, 23'b0};   // tran so -> Inf, co OF|NX
        uf = tiny && inexact;
        return {1'b0, 1'b0, 1'b0, uf, inexact, bits};
    endfunction

    // Ham tien ich cho element-wise FP: tra ve {flags, bits}
    function automatic logic [36:0] ref_fadd(input logic [31:0] ms2, input logic [31:0] ms1);
        return ref_fma32(ms1, FP_ONE, ms2);                       // ms2 + ms1
    endfunction
    function automatic logic [36:0] ref_fsub(input logic [31:0] ms2, input logic [31:0] ms1);
        return ref_fma32({~ms1[31], ms1[30:0]}, FP_ONE, ms2);     // ms2 - ms1
    endfunction
    function automatic logic [36:0] ref_fmul(input logic [31:0] ms2, input logic [31:0] ms1);
        return ref_fma32(ms1, ms2, {ms1[31] ^ ms2[31], 31'b0});   // ms2 * ms1
    endfunction

    function automatic logic fp_is_nan(input logic [31:0] v);
        return (v[30:23] == 8'hFF) && (v[22:0] != 0);
    endfunction
    function automatic logic fp_lt(input logic [31:0] x, input logic [31:0] y); // x < y, -0 < +0
        if (x[31] != y[31]) return x[31];
        else if (!x[31])    return x[30:0] < y[30:0];
        else                return x[30:0] > y[30:0];
    endfunction
    // fmax/fmin theo RISC-V: 1 NaN -> tra toan hang con lai; 2 NaN -> canonical NaN;
    // sNaN -> co NV. x = ms2, y = ms1.
    function automatic logic [36:0] ref_fminmax(input logic [31:0] x, input logic [31:0] y,
                                                input logic is_max);
        logic nv;
        logic [31:0] r;
        nv = (fp_is_nan(x) && !x[22]) || (fp_is_nan(y) && !y[22]);
        if (fp_is_nan(x) && fp_is_nan(y)) r = FP_QNAN;
        else if (fp_is_nan(x))            r = y;
        else if (fp_is_nan(y))            r = x;
        else if (is_max)                  r = fp_lt(x, y) ? y : x;
        else                              r = fp_lt(y, x) ? y : x;
        return {nv, 4'b0, r};
    endfunction

    // =========================================================================
    // 4. SINH SO GIA NGAU NHIEN (LCG 32-bit, deterministic)
    // =========================================================================
    function automatic logic [31:0] lcg_next(input logic [31:0] s);
        return s * 32'd1664525 + 32'd1013904223;
    endfunction

    // So FP32 "binh thuong" ngau nhien trong khoang ~[2^-8, 2^8), dau ngau nhien
    function automatic logic [31:0] fp_from_rand(input logic [31:0] r);
        logic [7:0] ex;
        ex = 8'd119 + {5'b0, r[26:24]} + {5'b0, r[29:27]} + {7'b0, r[30]};
        return {r[31], ex, r[22:0]};
    endfunction

    // Doi so nguyen nho (-2^24..2^24) sang FP32 chinh xac (dung tao du lieu de doc)
    function automatic logic [31:0] fp_from_int(input int v);
        logic s;
        logic [31:0] m;
        int e;
        if (v == 0) return 32'h0;
        s = (v < 0);
        m = s ? -v : v;
        e = 31;
        while (!m[31]) begin m = m << 1; e = e - 1; end
        return {s, 8'(e + 127), m[30:8]};
    endfunction

endpackage
