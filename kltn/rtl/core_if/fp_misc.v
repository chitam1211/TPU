// Combinational bit operations. No rounding and no floating-point exceptions.
module fp_misc (
    input wire [31:0] a, b,
    input wire [2:0] operation,
    output reg [31:0] result
);
    always @(*) begin
        result=0;
        case (operation)
            0: result=a;
            1: result={b[31],a[30:0]};
            2: result={~b[31],a[30:0]};
            3: result={a[31]^b[31],a[30:0]};
            4: begin
                if (a[30:23] == 8'hff) begin
                    if (a[22:0] == 0) result[a[31] ? 0 : 7]=1'b1;
                    else result[a[22] ? 9 : 8]=1'b1;
                end else if (a[30:23] == 0) begin
                    if (a[22:0] == 0) result[a[31] ? 3 : 4]=1'b1;
                    else result[a[31] ? 2 : 5]=1'b1;
                end else result[a[31] ? 1 : 6]=1'b1;
            end
            default: begin end
        endcase
    end
endmodule
