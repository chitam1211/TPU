// Only the unprivileged floating-point CSR aliases; not a general CSR bank.
module fp_csr (
    input wire clk, rst,
    input wire [11:0] read_addr,
    output reg [31:0] read_data,
    input wire write_en,
    input wire [11:0] write_addr,
    input wire [1:0] write_op,
    input wire [31:0] write_data,
    input wire flags_en,
    input wire [4:0] flags_in,
    output wire [2:0] frm,
    output wire [4:0] fflags
);
    reg [7:0] fcsr, next_fcsr;
    reg [7:0] old_value, new_value;
    assign frm = fcsr[7:5];
    assign fflags = fcsr[4:0];
    always @(*) begin
        case (read_addr)
            12'h001: read_data = {27'b0,fcsr[4:0]};
            12'h002: read_data = {29'b0,fcsr[7:5]};
            12'h003: read_data = {24'b0,fcsr};
            default: read_data = 0;
        endcase
        case (write_addr)
            12'h001: old_value = {3'b0,fcsr[4:0]};
            12'h002: old_value = {5'b0,fcsr[7:5]};
            default: old_value = fcsr;
        endcase
        case (write_op)
            2'b01: new_value = write_data[7:0];
            2'b10: new_value = old_value | write_data[7:0];
            2'b11: new_value = old_value & ~write_data[7:0];
            default: new_value = old_value;
        endcase
        next_fcsr = fcsr;
        if (write_en) begin
            case (write_addr)
                12'h001: next_fcsr[4:0] = new_value[4:0];
                12'h002: next_fcsr[7:5] = new_value[2:0];
                12'h003: next_fcsr = new_value;
                default: begin end
            endcase
        end
        // If both occur, newly raised flags survive a software clear.
        if (flags_en) next_fcsr[4:0] = next_fcsr[4:0] | flags_in;
    end
    always @(posedge clk or negedge rst)
        if (!rst) fcsr <= 0;
        else fcsr <= next_fcsr;
endmodule
