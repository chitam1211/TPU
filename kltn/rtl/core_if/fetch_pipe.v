// One IF/ID slot. Core releases stall only for an accepted fetch response.
module fetch_pipe(
  input wire clk,
  input wire rst,
  input wire stall,
  input wire [31:0] pre_address_pc,
  input wire [31:0] instruction_fetch,
  input wire next_select,
  input wire branch_result,
  input wire jalr,
  input wire load,
  output reg [31:0] pre_address_out,
  output reg [31:0] instruction
);
  always @(posedge clk or negedge rst) begin
    if (!rst) begin
      pre_address_out <= 0;
      instruction <= 0;
    end else if (next_select || branch_result || jalr) begin
      pre_address_out <= 0;
      instruction <= 0;
    end else if (!stall && !load) begin
      pre_address_out <= pre_address_pc;
      instruction <= instruction_fetch;
    end
  end
endmodule
