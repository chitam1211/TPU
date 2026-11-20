// True dual-port block RAM as the Block Memory Generator builds it in BRAM controller mode:
// 32-bit words, byte address (bits [1:0] ignored), 4 byte write enables, read latency 1, no
// output register, DOUT holds its value while EN = 0. The model starts at zero (BRAM after
// configuration without an init file).
// WRITE_FIRST = 1: a write also puts the new word on DOUT (BMG "WRITE_FIRST", the default);
//               0: DOUT keeps the old value during a write ("NO_CHANGE", as rtl/core_if_xif/memory.v).
// Both ports writing the same word in the same cycle is undefined in the BRAM and not modelled.
module bram_tdp_model #(
    parameter AW          = 14,     // byte address bits: 2**AW bytes
    parameter WRITE_FIRST = 1
)(
    input  wire        clka,
    input  wire        ena,
    input  wire [3:0]  wea,
    input  wire [31:0] addra,
    input  wire [31:0] dina,
    output reg  [31:0] douta,
    input  wire        clkb,
    input  wire        enb,
    input  wire [3:0]  web,
    input  wire [31:0] addrb,
    input  wire [31:0] dinb,
    output reg  [31:0] doutb
);
    localparam WORDS = 1 << (AW - 2);
    reg [31:0] mem [0:WORDS-1];
    integer i;
    initial begin
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'h0;
        douta = 32'h0;
        doutb = 32'h0;
    end

    function [31:0] merge(input [31:0] old, input [31:0] d, input [3:0] we);
        merge = {we[3] ? d[31:24] : old[31:24], we[2] ? d[23:16] : old[23:16],
                 we[1] ? d[15:8]  : old[15:8],  we[0] ? d[7:0]   : old[7:0]};
    endfunction

    wire [AW-3:0] wa = addra[AW-1:2];
    wire [AW-3:0] wb = addrb[AW-1:2];

    always @(posedge clka) begin
        if (ena) begin
            if (wea != 4'b0) begin
                mem[wa] <= merge(mem[wa], dina, wea);
                if (WRITE_FIRST) douta <= merge(mem[wa], dina, wea);
            end else begin
                douta <= mem[wa];
            end
        end
    end

    always @(posedge clkb) begin
        if (enb) begin
            if (web != 4'b0) begin
                mem[wb] <= merge(mem[wb], dinb, web);
                if (WRITE_FIRST) doutb <= merge(mem[wb], dinb, web);
            end else begin
                doutb <= mem[wb];
            end
        end
    end
endmodule
