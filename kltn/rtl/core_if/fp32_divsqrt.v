// IEEE-754 binary32 divide and square root, implemented with integer RTL only.
// Restoring radix-2 recurrence: one quotient/root bit per cycle, 27 iterations.
// Flags are {NV,DZ,OF,UF,NX}; tininess is detected after rounding.
// Computes a / b, or sqrt(a) when is_sqrt = 1 (b is then ignored).
// Handshake: start is accepted only in IDLE; busy is high while computing;
//   done pulses for one cycle together with result/flags. Reset cancels.
// rm: 0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM; 5..7 set illegal_rm (no result, no flags).
// FSM: IDLE -> CLASSIFY -> PREPARE -> ITERATE (x27) -> NORMALIZE -> ROUND -> IDLE;
//   CLASSIFY returns directly to IDLE for special operands.
module fp32_divsqrt (
    input wire clk, rst, start, is_sqrt,
    input wire [31:0] a, b,
    input wire [2:0] rm,
    output wire busy,
    output reg done,
    output reg [31:0] result,
    output reg [4:0] flags,
    output reg illegal_rm
);
    localparam IDLE=3'd0, CLASSIFY=3'd1, PREPARE=3'd2, ITERATE=3'd3, NORMALIZE=3'd4, ROUND=3'd5;
    reg [2:0] state;
    reg [31:0] aa, bb;                 // operands latched at start
    reg [2:0] mode;                    // rounding mode latched at start
    reg op_sqrt, sign;
    reg [4:0] count;                   // remaining iterations (26 down to 0)
    // 24-bit significand: hidden bit + 23 fraction bits, always in [2^23, 2^24).
    reg [23:0] sig_a, sig_b;
    // Exponents such that value = sig * 2^(exp - 150) (bias 127 + 23 fraction bits).
    reg signed [9:0] exp_a, exp_b, base;
    reg [26:0] q;                      // quotient/root bits; value = q * 2^base
    reg [31:0] rem;                    // partial remainder
    reg [53:0] radicand;               // sqrt input sig * 2^28 (or 2^29), 2 bits per step
    // Operand classes from the encoding (IEEE 754-2019 3.4).
    wire nan_a = (&aa[30:23]) && (|aa[22:0]);
    wire nan_b = (&bb[30:23]) && (|bb[22:0]);
    // Signaling NaN: quiet bit (fraction MSB) clear.
    wire snan_a = nan_a && !aa[22];
    wire snan_b = nan_b && !bb[22];
    wire inf_a = (&aa[30:23]) && !(|aa[22:0]);
    wire inf_b = (&bb[30:23]) && !(|bb[22:0]);
    // +0 and -0 both count as zero (sign bit ignored).
    wire zero_a = aa[30:0] == 0;
    wire zero_b = bb[30:0] == 0;
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

    // Subnormal significands are normalized so both recurrences see [2^23, 2^24).
    // lead_a/lead_b = index of the highest 1 in the fraction (last match wins);
    // the loop unrolls into a combinational priority encoder, not a per-cycle loop.
    integer i, lead_a, lead_b;
    always @(*) begin
        lead_a = 0; lead_b = 0;
        for (i=0; i<23; i=i+1) begin
            if (aa[i]) lead_a = i;
            if (bb[i]) lead_b = i;
        end
    end

    // Square root needs an even exponent: an odd one doubles the significand.
    wire exp_odd = exp_a[0];
    // Root exponent: half of (exp - 150), made even; -14 undoes the 2^28 scaling
    // of the radicand (sqrt(2^28) = 2^14).
    integer sqrt_base;
    always @(*) sqrt_base = (exp_a - 150 - (exp_odd ? 1 : 0)) / 2 - 14;

    // Digit-by-digit square root: bring down the next 2 radicand bits, then
    // compare with the trial value 4*q + 1.
    wire [31:0] rem_shift = {rem[29:0], radicand[53:52]};
    wire [31:0] trial = {3'b0, q, 2'b01};

    // Result value is q * 2^base, plus a nonzero tail when rem != 0.
    // NORMALIZE (cycle 1): value -> 24 kept bits + guard/sticky, both at the
    // delivered precision and at 24-bit unbounded precision (for tininess).
    integer k, exact_exp, target_exp, shift, shift_u, base_exp;
    reg [26:0] shifted, shifted_u;
    reg guard_bit, sticky_bit, guard_u, sticky_u;
    always @(*) begin
        // k = position of the leading 1 of q (priority encoder).
        k = 0;
        for (i=0; i<27; i=i+1)
            if (q[i]) k = i;
        base_exp = base;
        // Unbiased exponent of the exact result.
        exact_exp = k + base_exp;
        // Below 2^-126 the format is subnormal: the exponent stays at -126.
        target_exp = exact_exp < -126 ? -126 : exact_exp;
        // Bits to drop so the kept LSB has weight 2^(target_exp - 23).
        shift = target_exp - 23 - base_exp;
        // Same, ignoring the exponent range (always 24 significant bits).
        shift_u = k - 23;
        shifted = shift < 0 ? q << (-shift) : q >> shift;
        shifted_u = shift_u < 0 ? q << (-shift_u) : q >> shift_u;
        // Guard = first dropped bit; sticky = OR of the rest and of the remainder.
        guard_bit = 0; sticky_bit = |rem;
        guard_u = 0; sticky_u = |rem;
        for (i=0; i<27; i=i+1) begin
            if (i == shift-1) guard_bit = q[i];
            if (i < shift-1) sticky_bit = sticky_bit | q[i];
            if (i == shift_u-1) guard_u = q[i];
            if (i < shift_u-1) sticky_u = sticky_u | q[i];
        end
    end

    // Registered between NORMALIZE and ROUND.
    reg [23:0] norm_sig;
    reg norm_guard, norm_sticky;
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
        // Tiny unless rounding to 24 bits with unbounded exponent reaches 2^-126.
        carry_u = norm_ones_u && round_up(mode, sign, norm_lsb_u, norm_guard_u, norm_sticky_u);
        // RISC-V F: tininess after rounding (IEEE 7.5): 1.11..1 x 2^-127 that
        // rounds up to 2^-126 is not tiny.
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
        if (round_exp > 127) begin
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

    // FSM: one state per cycle; ITERATE repeats 27 times.
    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            state <= IDLE; done <= 0; result <= 0; flags <= 0;
            illegal_rm <= 0; aa <= 0; bb <= 0; mode <= 0;
            op_sqrt <= 0; sign <= 0; count <= 0;
            sig_a <= 0; sig_b <= 0; exp_a <= 0; exp_b <= 0; base <= 0;
            q <= 0; rem <= 0; radicand <= 0;
            norm_sig <= 0; norm_guard <= 0; norm_sticky <= 0;
            norm_ones_u <= 0; norm_lsb_u <= 0; norm_guard_u <= 0; norm_sticky_u <= 0;
            norm_exact_exp <= 0; norm_target_exp <= 0;
        end else begin
            done <= 0;
            case (state)
                // IDLE: latch operands, operation and rounding mode on start.
                IDLE: if (start) begin
                    aa <= a; bb <= b; mode <= rm; op_sqrt <= is_sqrt;
                    flags <= 0; illegal_rm <= 0; state <= CLASSIFY;
                end
                // CLASSIFY: finish special cases now; otherwise unpack and go on.
                CLASSIFY: begin
                    sign <= op_sqrt ? 1'b0 : aa[31] ^ bb[31];
                    // Default: finish now. Only the normal-operand branches override.
                    state <= IDLE; done <= 1;
                    if (mode > 4) begin
                        illegal_rm <= 1; result <= 0;
                    end else if (op_sqrt) begin
                        // NaN in: canonical NaN 0x7fc00000; NV only for sNaN (IEEE 7.2).
                        if (nan_a) begin
                            result <= 32'h7fc00000; flags <= {snan_a,4'b0};
                        // sqrt(+-0) = +-0, sign kept (IEEE 6.3), exact.
                        end else if (zero_a) begin
                            result <= aa;
                        // sqrt of a negative number is invalid: NaN and NV (IEEE 7.2).
                        end else if (aa[31]) begin
                            result <= 32'h7fc00000; flags <= 5'b10000;
                        // sqrt(+inf) = +inf, exact.
                        end else if (inf_a) begin
                            result <= 32'h7f800000;
                        end else begin
                            state <= PREPARE; done <= 0;
                        end
                    // Divide, NaN in: canonical NaN; NV only for sNaN.
                    end else if (nan_a || nan_b) begin
                        result <= 32'h7fc00000; flags <= {snan_a || snan_b,4'b0};
                    // inf/inf and 0/0 are invalid: NaN and NV (IEEE 7.2).
                    end else if ((inf_a && inf_b) || (zero_a && zero_b)) begin
                        result <= 32'h7fc00000; flags <= 5'b10000;
                    // inf/x and x/0 give signed infinity; DZ only for finite x/0 (7.3).
                    end else if (inf_a || zero_b) begin
                        result <= {aa[31] ^ bb[31],8'hff,23'b0};
                        flags <= {1'b0,zero_b && !inf_a,3'b0};
                    // x/inf and 0/x give signed zero, exact.
                    end else if (inf_b || zero_a) begin
                        result <= {aa[31] ^ bb[31],31'b0};
                    end else begin
                        state <= PREPARE; done <= 0;
                    end
                    // Unpack a: subnormals are shifted up so the leading 1 is bit 23.
                    if (aa[30:23] == 0) begin
                        sig_a <= {1'b0,aa[22:0]} << (23 - lead_a);
                        exp_a <= lead_a - 22;
                    end else begin
                        sig_a <= {1'b1,aa[22:0]};
                        exp_a <= {2'b0,aa[30:23]};
                    end
                    // Unpack b the same way.
                    if (bb[30:23] == 0) begin
                        sig_b <= {1'b0,bb[22:0]} << (23 - lead_b);
                        exp_b <= lead_b - 22;
                    end else begin
                        sig_b <= {1'b1,bb[22:0]};
                        exp_b <= {2'b0,bb[30:23]};
                    end
                end
                // PREPARE: initialise the recurrence and the result exponent.
                PREPARE: begin
                    q <= 0; count <= 26;
                    if (op_sqrt) begin
                        rem <= 0;
                        // 54-bit radicand = sig * 2^28, or 2*sig * 2^28 for an odd exponent.
                        radicand <= exp_odd ? {1'b0,sig_a,29'b0} : {2'b0,sig_a,28'b0};
                        base <= sqrt_base;
                    end else begin
                        rem <= {8'b0,sig_a};
                        // q = sig_a/sig_b * 2^26, so a/b = q * 2^(exp_a - exp_b - 26).
                        base <= exp_a - exp_b - 26;
                    end
                    state <= ITERATE;
                end
                // ITERATE: one restoring step per cycle, appending one bit to q.
                ITERATE: begin
                    if (op_sqrt) begin
                        // Sqrt: subtract the trial value if it fits, root bit = 1.
                        radicand <= radicand << 2;
                        if (rem_shift >= trial) begin
                            rem <= rem_shift - trial; q <= {q[25:0],1'b1};
                        end else begin
                            rem <= rem_shift; q <= {q[25:0],1'b0};
                        end
                    // Divide: subtract the divisor if it fits, quotient bit = 1.
                    end else if (rem >= {8'b0,sig_b}) begin
                        rem <= (rem - {8'b0,sig_b}) << 1; q <= {q[25:0],1'b1};
                    end else begin
                        rem <= rem << 1; q <= {q[25:0],1'b0};
                    end
                    if (count == 0) state <= NORMALIZE;
                    else count <= count - 1;
                end
                // NORMALIZE: register the normalized significand and rounding bits.
                NORMALIZE: begin
                    norm_sig <= shifted[23:0];
                    norm_guard <= guard_bit; norm_sticky <= sticky_bit;
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
