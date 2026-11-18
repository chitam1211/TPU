// IEEE-754 binary32 fused multiply-add, implemented with integer RTL only.
// result = (-1)^negate_product * a*b + (-1)^negate_addend * c, rounded once.
// Flags are {NV,DZ,OF,UF,NX}; tininess is detected after rounding.
// The four RV32F instructions select the negations: FMADD (0,0), FMSUB (0,1),
//   FNMSUB (1,0), FNMADD (1,1). DZ is never set.
// Handshake: start is accepted only in IDLE; busy is high while computing;
//   done pulses for one cycle together with result/flags. Reset cancels.
// rm: 0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM; 5..7 set illegal_rm (no result, no flags).
// FSM: IDLE -> CLASSIFY -> MULTIPLY -> ALIGN -> ADD -> NORMALIZE -> ROUND -> IDLE;
//   CLASSIFY returns directly to IDLE for special operands.
module fp32_fma (
    input wire clk, rst, start, negate_product, negate_addend,
    input wire [31:0] a, b, c,
    input wire [2:0] rm,
    output wire busy,
    output reg done,
    output reg [31:0] result,
    output reg [4:0] flags,
    output reg illegal_rm
);
    localparam IDLE=3'd0, CLASSIFY=3'd1, MULTIPLY=3'd2, ALIGN=3'd3, ADD=3'd4,
               NORMALIZE=3'd5, ROUND=3'd6;
    reg [2:0] state;
    reg [31:0] aa, bb, cc;             // operands latched at start
    reg [2:0] mode;                    // rounding mode latched at start
    reg neg_p, neg_c, sign_p, sign_c, sign, c_zero;
    // 24-bit significand: hidden bit + 23 fraction bits, normalized to [2^23, 2^24).
    reg [23:0] sig_a, sig_b, sig_c;
    // Exponents such that value = sig * 2^(exp - 150) (bias 127 + 23 fraction bits).
    reg signed [9:0] exp_a, exp_b, exp_c;
    reg signed [11:0] lsb_exp;         // weight of frame bit 0: value = mag * 2^lsb_exp
    reg [47:0] product;                // exact 24 x 24 -> 48-bit product, never rounded
    // 80-bit frame: product and addend aligned to one LSB weight; bit 79 takes the carry.
    reg [79:0] frame_p, frame_c, mag;
    // Operand classes from the encoding (IEEE 754-2019 3.4).
    wire nan_a = (&aa[30:23]) && (|aa[22:0]);
    wire nan_b = (&bb[30:23]) && (|bb[22:0]);
    wire nan_c = (&cc[30:23]) && (|cc[22:0]);
    // Signaling NaN: quiet bit (fraction MSB) clear.
    wire snan = (nan_a && !aa[22]) || (nan_b && !bb[22]) || (nan_c && !cc[22]);
    wire inf_a = (&aa[30:23]) && !(|aa[22:0]);
    wire inf_b = (&bb[30:23]) && !(|bb[22:0]);
    wire inf_c = (&cc[30:23]) && !(|cc[22:0]);
    // +0 and -0 both count as zero (sign bit ignored).
    wire zero_a = aa[30:0] == 0;
    wire zero_b = bb[30:0] == 0;
    wire zero_c = cc[30:0] == 0;
    // Effective signs of the product term and of the addend after negation.
    wire psign = aa[31] ^ bb[31] ^ neg_p;
    wire csign = cc[31] ^ neg_c;
    // RISC-V requires NV for inf*0 even when the addend is a quiet NaN.
    wire inf_times_zero = (inf_a && zero_b) || (inf_b && zero_a);
    assign busy = state != IDLE;

    // 1 when the kept significand must be incremented (IEEE 754-2019 4.3).
    // m = rounding mode, s = sign, lsb = last kept bit, g = guard, st = sticky.
    function round_up;
        input [2:0] m;
        input s, lsb, g, st;
        case (m)
            0: round_up = g && (st || lsb); // RNE
            2: round_up = s && (g || st);   // RDN
            3: round_up = !s && (g || st);  // RUP
            4: round_up = g;                // RMM
            default: round_up = 0;          // RTZ
        endcase
    endfunction

    // lead_* = index of the highest 1 in each fraction (last match wins), used to
    // normalize subnormal operands; the loop unrolls into a priority encoder.
    integer i, lead_a, lead_b, lead_c;
    always @(*) begin
        lead_a = 0; lead_b = 0; lead_c = 0;
        for (i=0; i<23; i=i+1) begin
            if (aa[i]) lead_a = i;
            if (bb[i]) lead_b = i;
            if (cc[i]) lead_c = i;
        end
    end

    // Both terms are placed in an 80-bit frame whose bit 78 is the larger term's
    // top exponent. A term shifted below bit 0 is jammed into bit 0 (sticky);
    // that only happens when the other term dominates, so no cancellation is lost.
    integer exp_p, exp_q, top_p, top_c, big, shift_p, shift_c;
    reg sticky_p, sticky_c;
    reg [79:0] placed_p, placed_c;
    always @(*) begin
        // LSB weights: product bit 0 = 2^(exp_a + exp_b - 300), sig_c bit 0 = 2^(exp_c - 150).
        exp_p = exp_a + exp_b - 300;
        exp_q = exp_c - 150;
        // Weights of the highest possible bits: product bit 47, sig_c bit 23.
        top_p = exp_p + 47;
        top_c = exp_q + 23;
        big = (c_zero || top_p >= top_c) ? top_p : top_c;
        // Left shift that puts each term's bit 0 at weight 2^(big - 78) = frame bit 0.
        shift_p = exp_p - (big - 78);
        shift_c = exp_q - (big - 78);
        // Sticky = OR of the bits that fall below frame bit 0 on a right shift.
        sticky_p = 0;
        sticky_c = 0;
        for (i=0; i<48; i=i+1)
            if (i < -shift_p) sticky_p = sticky_p | product[i];
        for (i=0; i<24; i=i+1)
            if (i < -shift_c) sticky_c = sticky_c | sig_c[i];
        placed_p = shift_p >= 0 ? {32'b0,product} << shift_p :
                                  ({32'b0,product} >> (-shift_p)) | {79'b0,sticky_p};
        placed_c = c_zero ? 80'b0 :
                   shift_c >= 0 ? {56'b0,sig_c} << shift_c :
                                  ({56'b0,sig_c} >> (-shift_c)) | {79'b0,sticky_c};
    end

    // NORMALIZE (cycle 1): mag * 2^lsb_exp -> 24 kept bits + guard/sticky, both at
    // the delivered precision and at 24-bit unbounded precision (for tininess).
    integer k, exact_exp, target_exp, shift, shift_u;
    reg [79:0] shifted, shifted_u;
    reg guard_bit, sticky_bit, guard_u, sticky_u;
    always @(*) begin
        // k = position of the leading 1 of the sum magnitude (priority encoder).
        k = 0;
        for (i=0; i<80; i=i+1)
            if (mag[i]) k = i;
        // Unbiased exponent of the exact result.
        exact_exp = k + lsb_exp;
        // Below 2^-126 the format is subnormal: the exponent stays at -126.
        target_exp = exact_exp < -126 ? -126 : exact_exp;
        // Bits to drop so the kept LSB has weight 2^(target_exp - 23).
        shift = target_exp - 23 - lsb_exp;
        // Same, ignoring the exponent range (always 24 significant bits).
        shift_u = k - 23;
        shifted = shift < 0 ? mag << (-shift) : mag >> shift;
        shifted_u = shift_u < 0 ? mag << (-shift_u) : mag >> shift_u;
        // Guard = first dropped bit; sticky = OR of all lower dropped bits.
        guard_bit = 0; sticky_bit = 0;
        guard_u = 0; sticky_u = 0;
        for (i=0; i<80; i=i+1) begin
            if (i == shift-1) guard_bit = mag[i];
            if (i < shift-1) sticky_bit = sticky_bit | mag[i];
            if (i == shift_u-1) guard_u = mag[i];
            if (i < shift_u-1) sticky_u = sticky_u | mag[i];
        end
    end

    // Registered between NORMALIZE and ROUND.
    reg [23:0] norm_sig;
    reg norm_guard, norm_sticky, norm_zero;
    // _u: the unbounded-exponent rounding, used only to decide tininess.
    reg norm_ones_u, norm_lsb_u, norm_guard_u, norm_sticky_u;
    reg signed [11:0] norm_exact_exp, norm_target_exp;

    // ROUND (cycle 2): one 25-bit increment and result packing.
    integer round_exp;
    reg [24:0] rounded;
    reg inexact, increment, carry_u, tiny, overflow_inf;
    reg [7:0] exp_field;
    reg [31:0] packed_result;
    reg [4:0] packed_flags;
    always @(*) begin
        round_exp = norm_target_exp;
        // Any dropped nonzero bit makes the result inexact (NX, IEEE 7.6).
        inexact = norm_guard | norm_sticky;
        increment = round_up(mode, sign, norm_sig[0], norm_guard, norm_sticky);
        // Tiny unless rounding to 24 bits with unbounded exponent reaches 2^-126
        // (RISC-V F: tininess after rounding, IEEE 7.5).
        carry_u = norm_ones_u && round_up(mode, sign, norm_lsb_u, norm_guard_u, norm_sticky_u);
        tiny = norm_exact_exp < -126 && !(norm_exact_exp == -127 && carry_u);
        // 25-bit add catches the carry when 1.11..1 rounds up to 10.00..0.
        rounded = {1'b0,norm_sig} + increment;
        if (rounded[24]) begin
            rounded = rounded >> 1;
            round_exp = round_exp + 1;
        end
        // Overflow gives infinity unless the direction rounds toward zero for this
        // sign (RTZ, RDN on +, RUP on -), which gives the largest finite value.
        overflow_inf = mode == 0 || mode == 4 ||
                       (mode == 2 && sign) || (mode == 3 && !sign);
        packed_result = 0;
        packed_flags = 0;
        exp_field = 0;
        // Exact zero sum of opposite terms: +0, or -0 under RDN (IEEE 6.3).
        if (norm_zero) begin
            packed_result = {mode == 2, 31'b0}; // exact cancellation
        end else if (round_exp > 127) begin
            // Overflow (IEEE 7.4): OF and NX.
            packed_result = overflow_inf ? {sign,8'hff,23'b0} :
                                           {sign,8'hfe,23'h7fffff};
            packed_flags = 5'b00101;
        end else begin
            // No hidden bit after rounding: subnormal or zero, encoded with E = 0.
            if (rounded[23]) exp_field = round_exp + 127;
            packed_result = {sign,exp_field,rounded[22:0]};
            // NX = inexact; UF = tiny and inexact (IEEE 7.5).
            packed_flags[0] = inexact;
            packed_flags[1] = inexact && tiny;
        end
    end

    // FSM: one state per cycle.
    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            state <= IDLE; done <= 0; result <= 0; flags <= 0;
            illegal_rm <= 0; aa <= 0; bb <= 0; cc <= 0; mode <= 0;
            neg_p <= 0; neg_c <= 0; sign_p <= 0; sign_c <= 0; sign <= 0; c_zero <= 0;
            sig_a <= 0; sig_b <= 0; sig_c <= 0; exp_a <= 0; exp_b <= 0; exp_c <= 0;
            lsb_exp <= 0; product <= 0; frame_p <= 0; frame_c <= 0; mag <= 0;
            norm_sig <= 0; norm_guard <= 0; norm_sticky <= 0; norm_zero <= 0;
            norm_ones_u <= 0; norm_lsb_u <= 0; norm_guard_u <= 0; norm_sticky_u <= 0;
            norm_exact_exp <= 0; norm_target_exp <= 0;
        end else begin
            done <= 0;
            case (state)
                // IDLE: latch operands, negations and rounding mode on start.
                IDLE: if (start) begin
                    aa <= a; bb <= b; cc <= c; mode <= rm;
                    neg_p <= negate_product; neg_c <= negate_addend;
                    flags <= 0; illegal_rm <= 0; state <= CLASSIFY;
                end
                // CLASSIFY: finish special cases now; otherwise unpack and go on.
                CLASSIFY: begin
                    sign_p <= psign; sign_c <= csign; c_zero <= zero_c;
                    // Default: finish now. Only the normal-operand branch overrides.
                    state <= IDLE; done <= 1;
                    if (mode > 4) begin
                        illegal_rm <= 1; result <= 0;
                    // NaN in, or inf * 0: canonical NaN 0x7fc00000.
                    end else if (nan_a || nan_b || nan_c || inf_times_zero) begin
                        // NV for a signaling NaN or for inf * 0 (IEEE 7.2, RISC-V F).
                        result <= 32'h7fc00000; flags <= {snan || inf_times_zero,4'b0};
                    // inf product + inf addend of opposite sign: invalid (IEEE 7.2).
                    end else if ((inf_a || inf_b) && inf_c && psign != csign) begin
                        result <= 32'h7fc00000; flags <= 5'b10000;
                    // Infinite product dominates: signed infinity, exact.
                    end else if (inf_a || inf_b) begin
                        result <= {psign,8'hff,23'b0};
                    // Infinite addend dominates: signed infinity, exact.
                    end else if (inf_c) begin
                        result <= {csign,8'hff,23'b0};
                    // Zero product: result is c exactly; 0 + 0 takes the IEEE 6.3 sign.
                    end else if (zero_a || zero_b) begin
                        if (zero_c) result <= {psign == csign ? psign : mode == 2, 31'b0};
                        else result <= {csign,cc[30:0]};
                    end else begin
                        state <= MULTIPLY; done <= 0;
                    end
                    // Unpack a, b, c: subnormals are shifted up so the leading 1 is bit 23.
                    if (aa[30:23] == 0) begin
                        sig_a <= {1'b0,aa[22:0]} << (23 - lead_a); exp_a <= lead_a - 22;
                    end else begin
                        sig_a <= {1'b1,aa[22:0]}; exp_a <= {2'b0,aa[30:23]};
                    end
                    if (bb[30:23] == 0) begin
                        sig_b <= {1'b0,bb[22:0]} << (23 - lead_b); exp_b <= lead_b - 22;
                    end else begin
                        sig_b <= {1'b1,bb[22:0]}; exp_b <= {2'b0,bb[30:23]};
                    end
                    if (cc[30:23] == 0) begin
                        sig_c <= {1'b0,cc[22:0]} << (23 - lead_c); exp_c <= lead_c - 22;
                    end else begin
                        sig_c <= {1'b1,cc[22:0]}; exp_c <= {2'b0,cc[30:23]};
                    end
                end
                // MULTIPLY: exact product, kept unrounded (that is the "fused" part).
                MULTIPLY: begin
                    product <= sig_a * sig_b;
                    state <= ALIGN;
                end
                // ALIGN: register both terms placed in the common 80-bit frame.
                ALIGN: begin
                    frame_p <= placed_p;
                    frame_c <= placed_c;
                    lsb_exp <= big - 78;
                    state <= ADD;
                end
                // ADD: sign-magnitude add; on opposite signs subtract the smaller term.
                ADD: begin
                    if (sign_p == sign_c) begin
                        mag <= frame_p + frame_c; sign <= sign_p;
                    end else if (frame_p >= frame_c) begin
                        mag <= frame_p - frame_c; sign <= sign_p;
                    end else begin
                        mag <= frame_c - frame_p; sign <= sign_c;
                    end
                    state <= NORMALIZE;
                end
                // NORMALIZE: register the normalized significand and rounding bits.
                NORMALIZE: begin
                    norm_sig <= shifted[23:0];
                    norm_guard <= guard_bit; norm_sticky <= sticky_bit;
                    norm_zero <= mag == 0;
                    // All 24 unbounded bits set: rounding up would carry to 2^(k+1).
                    norm_ones_u <= &shifted_u[23:0]; norm_lsb_u <= shifted_u[0];
                    norm_guard_u <= guard_u; norm_sticky_u <= sticky_u;
                    norm_exact_exp <= exact_exp; norm_target_exp <= target_exp;
                    state <= ROUND;
                end
                // ROUND: output the packed result and flags computed above.
                ROUND: begin
                    result <= packed_result;
                    flags <= packed_flags;
                    done <= 1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
