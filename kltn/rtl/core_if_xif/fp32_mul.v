// IEEE-754 binary32 multiply, implemented with integer RTL only.
// Flags are {NV,DZ,OF,UF,NX}; tininess is detected after rounding.
// Computes a * b (FMUL.S). DZ is never set by multiplication.
// Handshake: start is accepted only in IDLE; busy is high while computing;
//   done pulses for one cycle together with result/flags. Reset cancels.
// rm: 0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM; 5..7 set illegal_rm (no result, no flags).
// FSM: IDLE -> CLASSIFY -> MULTIPLY -> NORMALIZE -> ROUND -> IDLE;
//   CLASSIFY returns directly to IDLE for special operands.
module fp32_mul (
    input wire clk, rst, start,
    input wire [31:0] a, b,
    input wire [2:0] rm,
    output wire busy,
    output reg done,
    output reg [31:0] result,
    output reg [4:0] flags,
    output reg illegal_rm
);
    localparam IDLE=3'd0, CLASSIFY=3'd1, MULTIPLY=3'd2, NORMALIZE=3'd3, ROUND=3'd4;
    reg [2:0] state;
    reg [31:0] aa, bb;                 // operands latched at start
    reg [2:0] mode;                    // rounding mode latched at start
    reg sign;
    reg [47:0] product;                // exact 24 x 24 -> 48-bit significand product
    // Biased exponents (subnormal uses 1); value = sig * 2^(exp - 150).
    reg [8:0] exp_a, exp_b;
    // 24-bit significand: hidden bit (0 for subnormal) + 23 fraction bits.
    reg [23:0] sig_a, sig_b;
    // Operand classes from the encoding (IEEE 754-2019 3.4).
    wire nan_a = (&aa[30:23]) && (|aa[22:0]);
    wire nan_b = (&bb[30:23]) && (|bb[22:0]);
    // Signaling NaN: quiet bit (fraction MSB) clear.
    wire snan = (nan_a && !aa[22]) || (nan_b && !bb[22]);
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

    integer i;
    // Result value is product * 2^base_exp.
    // NORMALIZE (cycle 1): value -> 24 kept bits + guard/sticky, both at the
    // delivered precision and at 24-bit unbounded precision (for tininess).
    integer k, exact_exp, target_exp, shift, shift_u, base_exp;
    reg [47:0] shifted, shifted_u;
    reg guard_bit, sticky_bit, guard_u, sticky_u;
    always @(*) begin
        // k = position of the leading 1 of the product (priority encoder; the loop
        // unrolls into combinational logic). Subnormal inputs may put it low.
        k = 0;
        for (i=0; i<48; i=i+1)
            if (product[i]) k = i;
        // Weight of product bit 0: 2^(exp_a - 150) * 2^(exp_b - 150), hence 300.
        base_exp = $signed({1'b0,exp_a}) + $signed({1'b0,exp_b}) - 300;
        // Unbiased exponent of the exact result.
        exact_exp = k + base_exp;
        // Below 2^-126 the format is subnormal: the exponent stays at -126.
        target_exp = exact_exp < -126 ? -126 : exact_exp;
        // Bits to drop so the kept LSB has weight 2^(target_exp - 23).
        shift = target_exp - 23 - base_exp;
        // Same, ignoring the exponent range (always 24 significant bits).
        shift_u = k - 23;
        shifted = shift < 0 ? product << (-shift) : product >> shift;
        shifted_u = shift_u < 0 ? product << (-shift_u) : product >> shift_u;
        // Guard = first dropped bit; sticky = OR of all lower dropped bits.
        guard_bit = 0; sticky_bit = 0;
        guard_u = 0; sticky_u = 0;
        for (i=0; i<48; i=i+1) begin
            if (i == shift-1) guard_bit = product[i];
            if (i < shift-1) sticky_bit = sticky_bit | product[i];
            if (i == shift_u-1) guard_u = product[i];
            if (i < shift_u-1) sticky_u = sticky_u | product[i];
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
        // RISC-V F: tininess after rounding (IEEE 7.5).
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

    // FSM: one state per cycle.
    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            state <= IDLE; done <= 0; result <= 0; flags <= 0;
            illegal_rm <= 0; aa <= 0; bb <= 0; mode <= 0;
            sign <= 0; product <= 0; exp_a <= 0; exp_b <= 0;
            sig_a <= 0; sig_b <= 0;
            norm_sig <= 0; norm_guard <= 0; norm_sticky <= 0;
            norm_ones_u <= 0; norm_lsb_u <= 0; norm_guard_u <= 0; norm_sticky_u <= 0;
            norm_exact_exp <= 0; norm_target_exp <= 0;
        end else begin
            done <= 0;
            case (state)
                // IDLE: latch operands and rounding mode on start.
                IDLE: if (start) begin
                    aa <= a; bb <= b; mode <= rm;
                    flags <= 0; illegal_rm <= 0; state <= CLASSIFY;
                end
                // CLASSIFY: finish special cases now; otherwise unpack and go on.
                CLASSIFY: begin
                    // Sign of a product is the XOR of the operand signs (IEEE 6.3).
                    sign <= aa[31] ^ bb[31];
                    if (mode > 4) begin
                        illegal_rm <= 1; result <= 0; done <= 1; state <= IDLE;
                    // NaN in, or inf * 0: canonical NaN 0x7fc00000.
                    end else if (nan_a || nan_b || ((inf_a && zero_b) || (inf_b && zero_a))) begin
                        result <= 32'h7fc00000;
                        // NV for a signaling NaN or for inf * 0 (IEEE 7.2).
                        flags <= {snan || (inf_a && zero_b) || (inf_b && zero_a),4'b0};
                        done <= 1; state <= IDLE;
                    // inf * finite nonzero: signed infinity, exact.
                    end else if (inf_a || inf_b) begin
                        result <= {aa[31] ^ bb[31],8'hff,23'b0};
                        done <= 1; state <= IDLE;
                    // 0 * finite: signed zero, exact.
                    end else if (zero_a || zero_b) begin
                        result <= {aa[31] ^ bb[31],31'b0};
                        done <= 1; state <= IDLE;
                    end else begin
                        // Unpack; subnormals keep exponent 1 and hidden bit 0.
                        exp_a <= aa[30:23] == 0 ? 9'd1 : {1'b0,aa[30:23]};
                        exp_b <= bb[30:23] == 0 ? 9'd1 : {1'b0,bb[30:23]};
                        sig_a <= {|aa[30:23],aa[22:0]};
                        sig_b <= {|bb[30:23],bb[22:0]};
                        state <= MULTIPLY;
                    end
                end
                // MULTIPLY: exact integer product of the significands (no rounding yet).
                MULTIPLY: begin
                    product <= sig_a * sig_b;
                    state <= NORMALIZE;
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
