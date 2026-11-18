// Shared RV32F comparison and min/max datapath.
// Comparison operation is funct3: 000=FLE, 001=FLT, 010=FEQ.
// No rounding is performed. Flags use the architectural {NV,DZ,OF,UF,NX} order.
module fp32_compare (
    input wire [31:0] a, b,
    input wire [2:0] operation,
    output reg [31:0] result,
    output reg [4:0] flags,
    output reg [31:0] min_result, max_result,
    output wire [4:0] minmax_flags
);
    wire a_nan = (&a[30:23]) && (|a[22:0]);
    wire b_nan = (&b[30:23]) && (|b[22:0]);
    wire signaling_nan = (a_nan && !a[22]) || (b_nan && !b[22]);
    wire unordered = a_nan || b_nan;
    wire both_zero = (a[30:0] == 0) && (b[30:0] == 0);
    wire equal_value = (a == b) || both_zero;
    // Binary32 magnitudes are ordered lexicographically, including subnormals
    // and infinities. Negative numbers reverse the magnitude ordering.
    wire less_value = !both_zero && ((a[31] != b[31]) ? a[31] :
                      (a[31] ? (a[30:0] > b[30:0]) : (a[30:0] < b[30:0])));
    assign minmax_flags = {signaling_nan, 4'b0000};
    always @(*) begin
        if (a_nan && b_nan) begin
            min_result = 32'h7fc00000;
            max_result = 32'h7fc00000;
        end else if (a_nan) begin
            min_result = b;
            max_result = b;
        end else if (b_nan) begin
            min_result = a;
            max_result = a;
        end else if (both_zero) begin
            // MIN(-0,+0)=-0 and MAX(-0,+0)=+0, in either operand order.
            min_result = {a[31] | b[31], 31'b0};
            max_result = {a[31] & b[31], 31'b0};
        end else begin
            min_result = less_value ? a : b;
            max_result = less_value ? b : a;
        end
    end
    always @(*) begin
        result = 32'b0;
        flags = 5'b0;
        case (operation)
            3'b000, 3'b001: begin
                flags[4] = unordered;
                if (!unordered)
                    result = {31'b0, less_value || ((operation == 0) && equal_value)};
            end
            3'b010: begin
                flags[4] = signaling_nan;
                if (!unordered) result = {31'b0, equal_value};
            end
            default: begin end // Reserved encodings are rejected by fp_decode.
        endcase
    end
endmodule
