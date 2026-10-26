// FP32 addition/subtraction (FADD.S / FSUB.S), own integer RTL, multi-cycle FSM.
// Computes a + b, or a - b when sub = 1, on IEEE 754 binary32 operands.
// Handshake: start is accepted only in IDLE; busy is high while a result is being
//   computed; done pulses for one cycle together with result/flags. Reset cancels.
// rm encoding (RISC-V): 0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM; 5..7 raise illegal_rm
//   (the core resolves DYN before this unit, so a reserved mode cancels the instruction).
// flags = {NV, DZ, OF, UF, NX}; DZ is never set by add/sub.
// FSM: IDLE -> CLASSIFY -> ALIGN -> ADD -> NORMALIZE (repeats) -> ROUND -> IDLE.
//   CLASSIFY and NORMALIZE may also finish early (special operands, exact zero).
module fp32_addsub (
    input wire clk, rst, start, sub,
    input wire [31:0] a, b,
    input wire [2:0] rm,
    output wire busy,
    output reg done,
    output reg [31:0] result,
    output reg [4:0] flags,
    output reg illegal_rm
);
    localparam IDLE=0, CLASSIFY=1, ALIGN=2, ADD=3, NORMALIZE=4, ROUND=5;
    reg [2:0] state;
    reg [31:0] aa, bb;                    // operands latched at start
    reg subtract;
    reg [2:0] mode;                       // rounding mode latched at start
    reg sign_big, same_sign;              // sign of the larger operand; effective add?
    reg [26:0] large_m, small_m;          // significands, larger magnitude first
    reg [27:0] sum;                       // [27] carry-out, [26:3] significand, [2:0] G R S
    reg [8:0] exponent;                   // biased exponent of the result, 9 bits for carry
    reg [7:0] distance;                   // exponent difference = alignment shift
    // Subtraction is addition with the sign of b flipped.
    wire sign_b = bb[31] ^ subtract;
    // Operand classes from the encoding (IEEE 754-2019 3.4): E = 255 and F != 0 is NaN.
    wire nan_a = (&aa[30:23]) && (|aa[22:0]);
    wire nan_b = (&bb[30:23]) && (|bb[22:0]);
    // Signaling NaN: quiet bit (fraction MSB, bit 22) is 0.
    wire snan = (nan_a && !aa[22]) || (nan_b && !bb[22]);
    // E = 255 and F = 0 is infinity.
    wire inf_a = (&aa[30:23]) && !(|aa[22:0]);
    wire inf_b = (&bb[30:23]) && !(|bb[22:0]);
    // Subnormal (E = 0) uses exponent 1, i.e. 2^-126, with hidden bit 0 below.
    wire [7:0] exp_a = aa[30:23] == 0 ? 8'd1 : aa[30:23];
    wire [7:0] exp_b = bb[30:23] == 0 ? 8'd1 : bb[30:23];
    // 27-bit significand: hidden bit (1 if E != 0), 23 fraction bits, 3 zero bits for G R S.
    wire [26:0] mant_a = {|aa[30:23], aa[22:0], 3'b0};
    wire [26:0] mant_b = {|bb[30:23], bb[22:0], 3'b0};
    assign busy = state != IDLE;

    // Shift right by amount, OR-ing every bit shifted out into bit 0 (sticky "jam"),
    // so rounding still knows that a non-zero remainder was lost.
    function [26:0] shift_jam;
        input [26:0] value;
        input [7:0] amount;
        reg sticky;
        integer i;
        begin
            sticky = 0;
            for (i=0; i<27; i=i+1)
                if (i < amount) sticky = sticky | value[i];
            shift_jam = amount >= 27 ? 27'b0 : value >> amount;
            shift_jam[0] = shift_jam[0] | sticky;
        end
    endfunction

    // Rounding of the normalized sum (used in ROUND): sum[3] = LSB, sum[2] = G,
    // sum[1] = R, sum[0] = S. Directions per IEEE 754-2019 4.3.
    reg increment;
    reg [24:0] rounded;
    reg [8:0] rounded_exp;
    reg [23:0] rounded_mant;
    reg inexact, overflow_inf;
    always @(*) begin
        // Any non-zero discarded bit: result is inexact (NX, IEEE 7.6).
        inexact = |sum[2:0];
        case (mode)
            // RNE: above half, or exactly half with odd LSB (ties to even).
            0: increment = sum[2] && (sum[1] || sum[0] || sum[3]);
            // RTZ: truncate.
            1: increment = 0;
            // RDN: round magnitude up only for negative results.
            2: increment = sign_big && inexact;
            // RUP: round magnitude up only for positive results.
            3: increment = !sign_big && inexact;
            // RMM: half or more rounds away from zero.
            4: increment = sum[2];
            default: increment = 0;
        endcase
        // 25-bit add catches the carry when 1.11..1 rounds up to 10.00..0.
        rounded = {1'b0, sum[26:3]} + {24'b0, increment};
        rounded_exp = exponent;
        rounded_mant = rounded[23:0];
        // Rounding carry: renormalize by one bit and bump the exponent.
        if (rounded[24]) begin
            rounded_exp = exponent + 1'b1;
            rounded_mant = rounded[24:1];
        end
        // Overflow result (IEEE 7.4): infinity, or the largest finite value when the
        // direction rounds toward zero for this sign (RTZ, RDN on +, RUP on -).
        overflow_inf = mode == 0 || mode == 4 ||
                       (mode == 2 && sign_big) || (mode == 3 && !sign_big);
    end

    // FSM: one state per cycle; NORMALIZE repeats once per left shift.
    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            state <= IDLE; done <= 0; result <= 0; flags <= 0;
            illegal_rm <= 0; aa <= 0; bb <= 0; subtract <= 0; mode <= 0;
            sign_big <= 0; same_sign <= 0; large_m <= 0; small_m <= 0;
            sum <= 0; exponent <= 0; distance <= 0;
        end else begin
            done <= 0;
            case (state)
                // IDLE: latch operands, operation and rounding mode on start.
                IDLE: if (start) begin
                    aa <= a; bb <= b; subtract <= sub; mode <= rm;
                    flags <= 0; illegal_rm <= 0; state <= CLASSIFY;
                end
                // CLASSIFY: special cases finish here; otherwise order by magnitude.
                CLASSIFY: begin
                    if (mode > 4) begin // reserved rounding mode: no result, no flags
                        illegal_rm <= 1; result <= 0; done <= 1; state <= IDLE;
                    end else if (nan_a || nan_b || (inf_a && inf_b && aa[31] != sign_b)) begin
                        // NaN input or inf - inf: canonical quiet NaN (RISC-V F 20.1.3).
                        result <= 32'h7fc00000;
                        // NV for a signaling NaN or for inf - inf (IEEE 7.2).
                        flags <= {snan || (inf_a && inf_b && aa[31] != sign_b), 4'b0};
                        done <= 1; state <= IDLE;
                    end else if (inf_a || inf_b) begin
                        // Infinity plus a finite value (or same-sign inf) is exact: no flags.
                        result <= {inf_a ? aa[31] : sign_b, 8'hff, 23'b0};
                        done <= 1; state <= IDLE;
                    end else begin
                        same_sign <= aa[31] == sign_b;
                        // Bits [30:0] compare as unsigned integers in magnitude order.
                        if (aa[30:0] >= bb[30:0]) begin
                            large_m <= mant_a; small_m <= mant_b;
                            exponent <= {1'b0, exp_a}; distance <= exp_a - exp_b;
                            sign_big <= aa[31];
                        end else begin
                            large_m <= mant_b; small_m <= mant_a;
                            exponent <= {1'b0, exp_b}; distance <= exp_b - exp_a;
                            sign_big <= sign_b;
                        end
                        state <= ALIGN;
                    end
                end
                // ALIGN: shift the smaller significand to the larger exponent.
                ALIGN: begin small_m <= shift_jam(small_m, distance); state <= ADD; end
                // ADD: large >= small, so the difference is never negative; sign = sign_big.
                ADD: begin
                    sum <= same_sign ? {1'b0,large_m} + {1'b0,small_m} :
                                       {1'b0,large_m} - {1'b0,small_m};
                    state <= NORMALIZE;
                end
                // NORMALIZE: bring the leading 1 to bit 26, one bit per cycle.
                NORMALIZE: begin
                    if (sum == 0) begin
                        // Exact zero (IEEE 6.3): same signs keep the sign, e.g. -0 + -0 = -0;
                        // opposite signs give +0, or -0 under RDN.
                        result <= {same_sign ? sign_big : (mode == 2), 31'b0};   
                        done <= 1; state <= IDLE;
                    end else if (sum[27]) begin
                        // Carry-out: shift right once, keeping the lost bit in sticky.
                        sum <= {1'b0, sum[27:2], sum[1] | sum[0]};
                        exponent <= exponent + 1'b1; state <= ROUND;
                    end else if (!sum[26] && exponent > 1) begin
                        // Cancellation: shift left; stops at exponent 1 (subnormal range).
                        sum <= sum << 1; exponent <= exponent - 1'b1;
                    end else state <= ROUND;
                end
                // ROUND: apply the rounding computed above, pack the result, set flags.
                ROUND: begin
                    if (rounded_exp >= 255) begin
                        // Overflow (IEEE 7.4): +-inf or +-max finite, flags OF and NX.
                        result <= overflow_inf ? {sign_big,8'hff,23'b0} :
                                                 {sign_big,8'hfe,23'h7fffff};
                        flags <= 5'b00101; // OF + NX
                    end else begin
                        // Exponent 1 without hidden bit is a subnormal: encode E = 0.
                        result <= {sign_big,
                            ((rounded_exp == 1 && !rounded_mant[23]) ? 8'b0 : rounded_exp[7:0]),
                            rounded_mant[22:0]};
                        // UF = tiny after rounding and inexact (IEEE 7.5), NX = inexact.
                        // A tiny sum is always exact in add/sub, so UF stays 0 in practice.
                        flags <= {3'b0, (rounded_exp == 1 && !rounded_mant[23] && inexact), inexact};
                    end
                    done <= 1; state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
