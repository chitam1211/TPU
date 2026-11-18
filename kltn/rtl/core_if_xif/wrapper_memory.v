module wrappermem (
    input wire [31:0] data_i,
    input wire [1:0] byteadd,
    input wire [2:0] fun3,
    input wire mem_en,
    input wire Load,
    input wire data_valid,
    input wire [31:0] wrap_load_in,
    output reg [3:0] masking,
    output reg [31:0] data_o,
    output reg [31:0] wrap_load_out
);
    wire [31:0] shifted_load = wrap_load_in >> {byteadd, 3'b000};
    always @(*) begin
        masking = 4'b0000;
        data_o = 32'b0;
        wrap_load_out = 32'b0;
        if (mem_en) begin
            case (fun3)
                3'b000: begin // SB
                    masking = 4'b0001 << byteadd;
                    data_o = data_i << {byteadd, 3'b000};
                end
                3'b001: begin // SH (naturally aligned accesses)
                    masking = 4'b0011 << byteadd;
                    data_o = data_i << {byteadd, 3'b000};
                end
                3'b010: begin // SW / FSW: preserve all 32 bits
                    masking = 4'b1111;
                    data_o = data_i;
                end
                default: begin end
            endcase
        end
        if (Load || data_valid) begin
            case (fun3)
                3'b000: wrap_load_out = {{24{shifted_load[7]}}, shifted_load[7:0]};
                3'b001: wrap_load_out = {{16{shifted_load[15]}}, shifted_load[15:0]};
                3'b010: wrap_load_out = wrap_load_in; // LW / FLW, including NaN payload
                3'b100: wrap_load_out = {24'b0, shifted_load[7:0]};
                3'b101: wrap_load_out = {16'b0, shifted_load[15:0]};
                default: begin end
            endcase
        end
    end
endmodule
