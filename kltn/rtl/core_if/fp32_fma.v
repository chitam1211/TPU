// IEEE-754 binary32 fused multiply-add, implemented with integer RTL only.
// result = (-1)^negate_product * a*b + (-1)^negate_addend * c, rounded once.
// Flags are {NV,DZ,OF,UF,NX}; tininess is detected after rounding.
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
    reg [31:0] aa, bb, cc;
    reg [2:0] mode;
    reg neg_p, neg_c, sign_p, sign_c, sign, c_zero;
    reg [23:0] sig_a, sig_b, sig_c;
    reg signed [9:0] exp_a, exp_b, exp_c;
    reg signed [11:0] lsb_exp;
    reg [47:0] product;
    reg [79:0] frame_p, frame_c, mag;
    wire nan_a = (&aa[30:23]) && (|aa[22:0]);
    wire nan_b = (&bb[30:23]) && (|bb[22:0]);
    wire nan_c = (&cc[30:23]) && (|cc[22:0]);
    wire snan = (nan_a && !aa[22]) || (nan_b && !bb[22]) || (nan_c && !cc[22]);
    wire inf_a = (&aa[30:23]) && !(|aa[22:0]);
    wire inf_b = (&bb[30:23]) && !(|bb[22:0]);
    wire inf_c = (&cc[30:23]) && !(|cc[22:0]);
    wire zero_a = aa[30:0] == 0;
    wire zero_b = bb[30:0] == 0;
    wire zero_c = cc[30:0] == 0;
    wire psign = aa[31] ^ bb[31] ^ neg_p;
    wire csign = cc[31] ^ neg_c;
    // RISC-V requires NV for inf*0 even when the addend is a quiet NaN.
    wire inf_times_zero = (inf_a && zero_b) || (inf_b && zero_a);
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
        exp_p = exp_a + exp_b - 300;
        exp_q = exp_c - 150;
        top_p = exp_p + 47;
        top_c = exp_q + 23;
        big = (c_zero || top_p >= top_c) ? top_p : top_c;
        shift_p = exp_p - (big - 78);
        shift_c = exp_q - (big - 78);
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
        k = 0;
        for (i=0; i<80; i=i+1)
            if (mag[i]) k = i;
        exact_exp = k + lsb_exp;
        target_exp = exact_exp < -126 ? -126 : exact_exp;
        shift = target_exp - 23 - lsb_exp;
        shift_u = k - 23;
        shifted = shift < 0 ? mag << (-shift) : mag >> shift;
        shifted_u = shift_u < 0 ? mag << (-shift_u) : mag >> shift_u;
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
        if (norm_zero) begin
            packed_result = {mode == 2, 31'b0}; // exact cancellation
        end else if (round_exp > 127) begin
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
                IDLE: if (start) begin
                    aa <= a; bb <= b; cc <= c; mode <= rm;
                    neg_p <= negate_product; neg_c <= negate_addend;
                    flags <= 0; illegal_rm <= 0; state <= CLASSIFY;
                end
                CLASSIFY: begin
                    sign_p <= psign; sign_c <= csign; c_zero <= zero_c;
                    state <= IDLE; done <= 1;
                    if (mode > 4) begin
                        illegal_rm <= 1; result <= 0;
                    end else if (nan_a || nan_b || nan_c || inf_times_zero) begin
                        result <= 32'h7fc00000; flags <= {snan || inf_times_zero,4'b0};
                    end else if ((inf_a || inf_b) && inf_c && psign != csign) begin
                        result <= 32'h7fc00000; flags <= 5'b10000;
                    end else if (inf_a || inf_b) begin
                        result <= {psign,8'hff,23'b0};
                    end else if (inf_c) begin
                        result <= {csign,8'hff,23'b0};
                    end else if (zero_a || zero_b) begin
                        if (zero_c) result <= {psign == csign ? psign : mode == 2, 31'b0};
                        else result <= {csign,cc[30:0]};
                    end else begin
                        state <= MULTIPLY; done <= 0;
                    end
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
                MULTIPLY: begin
                    product <= sig_a * sig_b;
                    state <= ALIGN;
                end
                ALIGN: begin
                    frame_p <= placed_p;
                    frame_c <= placed_c;
                    lsb_exp <= big - 78;
                    state <= ADD;
                end
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
                NORMALIZE: begin
                    norm_sig <= shifted[23:0];
                    norm_guard <= guard_bit; norm_sticky <= sticky_bit;
                    norm_zero <= mag == 0;
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
