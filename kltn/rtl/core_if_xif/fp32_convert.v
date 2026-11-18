// RV32F FCVT between binary32 and signed/unsigned 32-bit integers.
// Flags are {NV,DZ,OF,UF,NX}; conversion can only raise NV or NX.
// ALIGN (negate, leading-one detect, shift, guard/sticky) and ROUND (increment,
// range check, negate, pack) are separate cycles.
module fp32_convert (
    input wire clk, rst, start, to_float, unsigned_mode,
    input wire [31:0] a,
    input wire [2:0] rm,
    output wire busy,
    output reg done,
    output reg [31:0] result,
    output reg [4:0] flags,
    output reg illegal_rm
);
    localparam IDLE=2'd0, ALIGN=2'd1, ROUND=2'd2;
    reg [1:0] state;
    reg [31:0] operand;
    reg [2:0] mode;
    reg direction, unsigned_r;
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

    // ALIGN: value is the significand (to float) or integer part (to int).
    reg al_sign, al_special, al_zero, al_guard, al_sticky;
    reg [32:0] al_value;
    reg [7:0] al_exponent;
    reg [31:0] al_special_result;
    reg [31:0] magnitude;
    reg [23:0] significand;
    integer i, leading, shift, effective_exp;
    always @(*) begin
        al_sign = 0; al_special = 0; al_zero = 0; al_guard = 0; al_sticky = 0;
        al_value = 0; al_exponent = 0; al_special_result = 0;
        magnitude = 0; significand = 0; leading = 0; shift = 0; effective_exp = 0;
        if (direction) begin
            // Integer -> binary32: every input is finite, and NX is the only flag.
            al_sign = !unsigned_r && operand[31];
            magnitude = al_sign ? (~operand + 32'd1) : operand;
            al_zero = magnitude == 0;
            for (i=0; i<32; i=i+1)
                if (magnitude[i]) leading = i;
            shift = leading - 23;
            if (shift > 0) begin
                al_value = magnitude >> shift;
                for (i=0; i<32; i=i+1) begin
                    if (i == shift-1) al_guard = magnitude[i];
                    if (i < shift-1) al_sticky = al_sticky | magnitude[i];
                end
            end else begin
                al_value = magnitude << (-shift);
            end
            al_exponent = leading + 127;
        end else begin
            // Binary32 -> integer: round first; range-check the rounded value.
            al_sign = operand[31];
            significand = operand[30:23] == 0 ? {1'b0,operand[22:0]} : {1'b1,operand[22:0]};
            effective_exp = operand[30:23] == 0 ? 1 : operand[30:23];
            shift = 150 - effective_exp;
            if (operand[30:23] == 8'hff || operand[30:23] >= 8'd160) begin
                al_special = 1;
                // RISC-V saturates NaN to the positive limit, regardless of sign.
                if (operand[30:23] == 8'hff && operand[22:0] != 0)
                    al_special_result = unsigned_r ? 32'hffffffff : 32'h7fffffff;
                else
                    al_special_result = al_sign ? (unsigned_r ? 32'b0 : 32'h80000000) :
                                                  (unsigned_r ? 32'hffffffff : 32'h7fffffff);
            end else if (shift <= 0) begin
                al_value = {9'b0,significand} << (-shift);
            end else if (shift <= 24) begin
                al_value = significand >> shift;
                for (i=0; i<24; i=i+1) begin
                    if (i == shift-1) al_guard = significand[i];
                    if (i < shift-1) al_sticky = al_sticky | significand[i];
                end
            end else begin
                al_sticky = |significand;
            end
        end
    end

    // Registered between ALIGN and ROUND.
    reg r_sign, r_special, r_zero, r_guard, r_sticky;
    reg [32:0] r_value;
    reg [7:0] r_exponent;
    reg [31:0] r_special_result;

    reg [33:0] rounded, limit;
    reg [7:0] exponent_out;
    reg inexact, increment;
    reg [31:0] calculated_result;
    reg [4:0] calculated_flags;
    always @(*) begin
        inexact = r_guard | r_sticky;
        increment = round_up(mode, r_sign, r_value[0], r_guard, r_sticky);
        rounded = {1'b0,r_value} + increment;
        exponent_out = r_exponent;
        limit = unsigned_r ? 34'h0ffffffff : (r_sign ? 34'h080000000 : 34'h07fffffff);
        calculated_result = 0;
        calculated_flags = 0;
        if (direction) begin
            if (!r_zero) begin
                if (rounded[24]) begin
                    rounded = rounded >> 1;
                    exponent_out = exponent_out + 1'b1;
                end
                calculated_result = {r_sign,exponent_out,rounded[22:0]};
                calculated_flags[0] = inexact;
            end
        end else if (r_special) begin
            calculated_flags[4] = 1;
            calculated_result = r_special_result;
        end else if (rounded > limit || (unsigned_r && r_sign && rounded != 0)) begin
            calculated_flags[4] = 1;
            calculated_result = r_sign ? (unsigned_r ? 32'b0 : 32'h80000000) :
                                         (unsigned_r ? 32'hffffffff : 32'h7fffffff);
        end else begin
            calculated_result = r_sign ? (~rounded[31:0] + 32'd1) : rounded[31:0];
            calculated_flags[0] = inexact;
        end
    end

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            state <= IDLE; done <= 0; result <= 0; flags <= 0;
            illegal_rm <= 0; operand <= 0; mode <= 0;
            direction <= 0; unsigned_r <= 0;
            r_sign <= 0; r_special <= 0; r_zero <= 0; r_guard <= 0; r_sticky <= 0;
            r_value <= 0; r_exponent <= 0; r_special_result <= 0;
        end else begin
            done <= 0;
            case (state)
                IDLE: if (start) begin
                    operand <= a; mode <= rm; direction <= to_float;
                    unsigned_r <= unsigned_mode;
                    flags <= 0; illegal_rm <= 0; state <= ALIGN;
                end
                ALIGN: begin
                    r_sign <= al_sign; r_special <= al_special; r_zero <= al_zero;
                    r_guard <= al_guard; r_sticky <= al_sticky;
                    r_value <= al_value; r_exponent <= al_exponent;
                    r_special_result <= al_special_result;
                    state <= ROUND;
                end
                ROUND: begin
                    if (mode > 4) begin
                        result <= 0; flags <= 0; illegal_rm <= 1;
                    end else begin
                        result <= calculated_result;
                        flags <= calculated_flags;
                    end
                    done <= 1; state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
