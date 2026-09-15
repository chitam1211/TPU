// FP32 addition/subtraction, own integer RTL. rm: RNE, RTZ, RDN, RUP, RMM.
// start is accepted only while idle; done pulses for one cycle. Reset cancels.
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
    reg [31:0] aa, bb;
    reg subtract;
    reg [2:0] mode;
    reg sign_big, same_sign;
    reg [26:0] large_m, small_m;
    reg [27:0] sum;
    reg [8:0] exponent;
    reg [7:0] distance;
    wire sign_b = bb[31] ^ subtract;
    wire nan_a = (&aa[30:23]) && (|aa[22:0]);
    wire nan_b = (&bb[30:23]) && (|bb[22:0]);
    wire snan = (nan_a && !aa[22]) || (nan_b && !bb[22]);
    wire inf_a = (&aa[30:23]) && !(|aa[22:0]);
    wire inf_b = (&bb[30:23]) && !(|bb[22:0]);
    wire [7:0] exp_a = aa[30:23] == 0 ? 8'd1 : aa[30:23];
    wire [7:0] exp_b = bb[30:23] == 0 ? 8'd1 : bb[30:23];
    wire [26:0] mant_a = {|aa[30:23], aa[22:0], 3'b0};
    wire [26:0] mant_b = {|bb[30:23], bb[22:0], 3'b0};
    assign busy = state != IDLE;

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

    reg increment;
    reg [24:0] rounded;
    reg [8:0] rounded_exp;
    reg [23:0] rounded_mant;
    reg inexact, overflow_inf;
    always @(*) begin
        inexact = |sum[2:0];
        case (mode)
            0: increment = sum[2] && (sum[1] || sum[0] || sum[3]);
            1: increment = 0;
            2: increment = sign_big && inexact;
            3: increment = !sign_big && inexact;
            4: increment = sum[2];
            default: increment = 0;
        endcase
        rounded = {1'b0, sum[26:3]} + {24'b0, increment};
        rounded_exp = exponent;
        rounded_mant = rounded[23:0];
        if (rounded[24]) begin
            rounded_exp = exponent + 1'b1;
            rounded_mant = rounded[24:1];
        end
        overflow_inf = mode == 0 || mode == 4 ||
                       (mode == 2 && sign_big) || (mode == 3 && !sign_big);
    end

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            state <= IDLE; done <= 0; result <= 0; flags <= 0;
            illegal_rm <= 0; aa <= 0; bb <= 0; subtract <= 0; mode <= 0;
            sign_big <= 0; same_sign <= 0; large_m <= 0; small_m <= 0;
            sum <= 0; exponent <= 0; distance <= 0;
        end else begin
            done <= 0;
            case (state)
                IDLE: if (start) begin
                    aa <= a; bb <= b; subtract <= sub; mode <= rm;
                    flags <= 0; illegal_rm <= 0; state <= CLASSIFY;
                end
                CLASSIFY: begin
                    if (mode > 4) begin
                        illegal_rm <= 1; result <= 0; done <= 1; state <= IDLE;
                    end else if (nan_a || nan_b || (inf_a && inf_b && aa[31] != sign_b)) begin
                        result <= 32'h7fc00000;
                        flags <= {snan || (inf_a && inf_b && aa[31] != sign_b), 4'b0};
                        done <= 1; state <= IDLE;
                    end else if (inf_a || inf_b) begin
                        result <= {inf_a ? aa[31] : sign_b, 8'hff, 23'b0};
                        done <= 1; state <= IDLE;
                    end else begin
                        same_sign <= aa[31] == sign_b;
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
                ALIGN: begin small_m <= shift_jam(small_m, distance); state <= ADD; end
                ADD: begin
                    sum <= same_sign ? {1'b0,large_m} + {1'b0,small_m} :
                                       {1'b0,large_m} - {1'b0,small_m};
                    state <= NORMALIZE;
                end
                NORMALIZE: begin
                    if (sum == 0) begin
                        result <= {same_sign ? sign_big : (mode == 2), 31'b0};
                        done <= 1; state <= IDLE;
                    end else if (sum[27]) begin
                        sum <= {1'b0, sum[27:2], sum[1] | sum[0]};
                        exponent <= exponent + 1'b1; state <= ROUND;
                    end else if (!sum[26] && exponent > 1) begin
                        sum <= sum << 1; exponent <= exponent - 1'b1;
                    end else state <= ROUND;
                end
                ROUND: begin
                    if (rounded_exp >= 255) begin
                        result <= overflow_inf ? {sign_big,8'hff,23'b0} :
                                                 {sign_big,8'hfe,23'h7fffff};
                        flags <= 5'b00101; // OF + NX
                    end else begin
                        result <= {sign_big,
                            ((rounded_exp == 1 && !rounded_mant[23]) ? 8'b0 : rounded_exp[7:0]),
                            rounded_mant[22:0]};
                        flags <= {3'b0, (rounded_exp == 1 && !rounded_mant[23] && inexact), inexact};
                    end
                    done <= 1; state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
