// IEEE-754 binary32 divide and square root, implemented with integer RTL only.
// Restoring radix-2 recurrence: one quotient/root bit per cycle, 27 iterations.
// Flags are {NV,DZ,OF,UF,NX}; tininess is detected after rounding.
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
    reg [31:0] aa, bb;
    reg [2:0] mode;
    reg op_sqrt, sign;
    reg [4:0] count;
    reg [23:0] sig_a, sig_b;
    reg signed [9:0] exp_a, exp_b, base;
    reg [26:0] q;
    reg [31:0] rem;
    reg [53:0] radicand;
    wire nan_a = (&aa[30:23]) && (|aa[22:0]);
    wire nan_b = (&bb[30:23]) && (|bb[22:0]);
    wire snan_a = nan_a && !aa[22];
    wire snan_b = nan_b && !bb[22];
    wire inf_a = (&aa[30:23]) && !(|aa[22:0]);
    wire inf_b = (&bb[30:23]) && !(|bb[22:0]);
    wire zero_a = aa[30:0] == 0;
    wire zero_b = bb[30:0] == 0;
    assign busy = state != IDLE;

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
    integer sqrt_base;
    always @(*) sqrt_base = (exp_a - 150 - (exp_odd ? 1 : 0)) / 2 - 14;

    wire [31:0] rem_shift = {rem[29:0], radicand[53:52]};
    wire [31:0] trial = {3'b0, q, 2'b01};

    // Result value is q * 2^base, plus a nonzero tail when rem != 0.
    // NORMALIZE (cycle 1): value -> 24 kept bits + guard/sticky, both at the
    // delivered precision and at 24-bit unbounded precision (for tininess).
    integer k, exact_exp, target_exp, shift, shift_u, base_exp;
    reg [26:0] shifted, shifted_u;
    reg guard_bit, sticky_bit, guard_u, sticky_u;
    always @(*) begin
        k = 0;
        for (i=0; i<27; i=i+1)
            if (q[i]) k = i;
        base_exp = base;
        exact_exp = k + base_exp;
        target_exp = exact_exp < -126 ? -126 : exact_exp;
        shift = target_exp - 23 - base_exp;
        shift_u = k - 23;
        shifted = shift < 0 ? q << (-shift) : q >> shift;
        shifted_u = shift_u < 0 ? q << (-shift_u) : q >> shift_u;
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
        inexact = norm_guard | norm_sticky;
        increment = round_up(mode, sign, norm_sig[0], norm_guard, norm_sticky);
        // Tiny unless rounding to 24 bits with unbounded exponent reaches 2^-126.
        carry_u = norm_ones_u && round_up(mode, sign, norm_lsb_u, norm_guard_u, norm_sticky_u);
        tiny = norm_exact_exp < -126 && !(norm_exact_exp == -127 && carry_u);
        rounded = {1'b0,norm_sig} + increment;
        if (rounded[24]) begin
            rounded = rounded >> 1;
            round_exp = round_exp + 1;
        end
        overflow_inf = mode == 0 || mode == 4 ||
                       (mode == 2 && sign) || (mode == 3 && !sign);
        packed_result = 0;
        packed_flags = 0;
        exp_field = 0;
        if (round_exp > 127) begin
            packed_result = overflow_inf ? {sign,8'hff,23'b0} :
                                           {sign,8'hfe,23'h7fffff};
            packed_flags = 5'b00101;
        end else begin
            if (rounded[23]) exp_field = round_exp + 127;
            packed_result = {sign,exp_field,rounded[22:0]};
            packed_flags[0] = inexact;
            packed_flags[1] = inexact && tiny;
        end
    end

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
                IDLE: if (start) begin
                    aa <= a; bb <= b; mode <= rm; op_sqrt <= is_sqrt;
                    flags <= 0; illegal_rm <= 0; state <= CLASSIFY;
                end
                CLASSIFY: begin
                    sign <= op_sqrt ? 1'b0 : aa[31] ^ bb[31];
                    state <= IDLE; done <= 1;
                    if (mode > 4) begin
                        illegal_rm <= 1; result <= 0;
                    end else if (op_sqrt) begin
                        if (nan_a) begin
                            result <= 32'h7fc00000; flags <= {snan_a,4'b0};
                        end else if (zero_a) begin
                            result <= aa;
                        end else if (aa[31]) begin
                            result <= 32'h7fc00000; flags <= 5'b10000;
                        end else if (inf_a) begin
                            result <= 32'h7f800000;
                        end else begin
                            state <= PREPARE; done <= 0;
                        end
                    end else if (nan_a || nan_b) begin
                        result <= 32'h7fc00000; flags <= {snan_a || snan_b,4'b0};
                    end else if ((inf_a && inf_b) || (zero_a && zero_b)) begin
                        result <= 32'h7fc00000; flags <= 5'b10000;
                    end else if (inf_a || zero_b) begin
                        result <= {aa[31] ^ bb[31],8'hff,23'b0};
                        flags <= {1'b0,zero_b && !inf_a,3'b0};
                    end else if (inf_b || zero_a) begin
                        result <= {aa[31] ^ bb[31],31'b0};
                    end else begin
                        state <= PREPARE; done <= 0;
                    end
                    if (aa[30:23] == 0) begin
                        sig_a <= {1'b0,aa[22:0]} << (23 - lead_a);
                        exp_a <= lead_a - 22;
                    end else begin
                        sig_a <= {1'b1,aa[22:0]};
                        exp_a <= {2'b0,aa[30:23]};
                    end
                    if (bb[30:23] == 0) begin
                        sig_b <= {1'b0,bb[22:0]} << (23 - lead_b);
                        exp_b <= lead_b - 22;
                    end else begin
                        sig_b <= {1'b1,bb[22:0]};
                        exp_b <= {2'b0,bb[30:23]};
                    end
                end
                PREPARE: begin
                    q <= 0; count <= 26;
                    if (op_sqrt) begin
                        rem <= 0;
                        radicand <= exp_odd ? {1'b0,sig_a,29'b0} : {2'b0,sig_a,28'b0};
                        base <= sqrt_base;
                    end else begin
                        rem <= {8'b0,sig_a};
                        base <= exp_a - exp_b - 26;
                    end
                    state <= ITERATE;
                end
                ITERATE: begin
                    if (op_sqrt) begin
                        radicand <= radicand << 2;
                        if (rem_shift >= trial) begin
                            rem <= rem_shift - trial; q <= {q[25:0],1'b1};
                        end else begin
                            rem <= rem_shift; q <= {q[25:0],1'b0};
                        end
                    end else if (rem >= {8'b0,sig_b}) begin
                        rem <= (rem - {8'b0,sig_b}) << 1; q <= {q[25:0],1'b1};
                    end else begin
                        rem <= rem << 1; q <= {q[25:0],1'b0};
                    end
                    if (count == 0) state <= NORMALIZE;
                    else count <= count - 1;
                end
                NORMALIZE: begin
                    norm_sig <= shifted[23:0];
                    norm_guard <= guard_bit; norm_sticky <= sticky_bit;
                    norm_ones_u <= &shifted_u[23:0]; norm_lsb_u <= shifted_u[0];
                    norm_guard_u <= guard_u; norm_sticky_u <= sticky_u;
                    norm_exact_exp <= exact_exp; norm_target_exp <= target_exp;
                    state <= ROUND;
                end
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
