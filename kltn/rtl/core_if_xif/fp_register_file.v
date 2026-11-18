module fp_register_file (
    input  wire        clk,
    input  wire        rst,
    input  wire        en,

    input  wire [4:0]  rs1,
    input  wire [4:0]  rs2,
    input  wire [4:0]  rs3,
    input  wire [4:0]  rd,

    input  wire [31:0] data,

    output wire [31:0] op_a,
    output wire [31:0] op_b,
    output wire [31:0] op_c
);

    reg [31:0] register [0:31];
    integer i;

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            for (i = 0; i < 32; i = i + 1) begin
                register[i] <= 32'b0;
            end
        end
        else if (en) begin
            register[rd] <= data;
        end
    end

    assign op_a = register[rs1];
    assign op_b = register[rs2];
    assign op_c = register[rs3];

endmodule