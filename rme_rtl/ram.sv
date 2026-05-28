`timescale 1ns / 1ps

module matrix_ram #(
	parameter ADDR_WIDTH = 32,
	parameter DATA_WIDTH = 32,
	parameter MEM_BYTES  = 4096
)(
	input  wire                     clk,
	input  wire                     resetn,

	// AXI4-Lite write address channel
	input  wire [ADDR_WIDTH-1:0]    s_axi_awaddr,
	input  wire                     s_axi_awvalid,
	output reg                      s_axi_awready,

	// AXI4-Lite write data channel
	input  wire [DATA_WIDTH-1:0]    s_axi_wdata,
	input  wire [3:0]               s_axi_wstrb,
	input  wire                     s_axi_wvalid,
	output reg                      s_axi_wready,

	// AXI4-Lite write response channel
	output reg  [1:0]               s_axi_bresp,
	output reg                      s_axi_bvalid,
	input  wire                     s_axi_bready,

	// AXI4-Lite read address channel
	input  wire [ADDR_WIDTH-1:0]    s_axi_araddr,
	input  wire                     s_axi_arvalid,
	output reg                      s_axi_arready,

	// AXI4-Lite read data channel
	output reg  [DATA_WIDTH-1:0]    s_axi_rdata,
	output reg  [1:0]               s_axi_rresp,
	output reg                      s_axi_rvalid,
	input  wire                     s_axi_rready
);

	localparam integer WORD_BYTES = DATA_WIDTH / 8;
	localparam integer WORDS = MEM_BYTES / WORD_BYTES;
	localparam integer ADDR_LSB = $clog2(WORD_BYTES);
	localparam integer ADDR_MSB = ADDR_LSB + $clog2(WORDS) - 1;

	reg [DATA_WIDTH-1:0] mem [0:WORDS-1];

	// Internal latches for read address
	reg [ADDR_WIDTH-1:0] araddr_latched;
	reg                   ar_pending;

	// Simple ready/valid handling
	always @(posedge clk) begin
		if (!resetn) begin
			s_axi_awready <= 0;
			s_axi_wready  <= 0;
			s_axi_bvalid  <= 0;
			s_axi_bresp   <= 2'b00;

			s_axi_arready <= 0;
			s_axi_rvalid  <= 0;
			s_axi_rresp   <= 2'b00;
			s_axi_rdata   <= {DATA_WIDTH{1'b0}};

			araddr_latched <= {ADDR_WIDTH{1'b0}};
			ar_pending     <= 0;
		end else begin
			// Default ready signals
			s_axi_awready <= 1'b1;
			s_axi_wready  <= 1'b1;
			s_axi_arready <= 1'b1;

			// Write transaction
			if (s_axi_awvalid && s_axi_awready && s_axi_wvalid && s_axi_wready) begin
				integer word_index;
				word_index = s_axi_awaddr[ADDR_MSB:ADDR_LSB];
				if (word_index < WORDS) begin
					if (s_axi_wstrb[0]) mem[word_index][7:0]   <= s_axi_wdata[7:0];
					if (s_axi_wstrb[1]) mem[word_index][15:8]  <= s_axi_wdata[15:8];
					if (s_axi_wstrb[2]) mem[word_index][23:16] <= s_axi_wdata[23:16];
					if (s_axi_wstrb[3]) mem[word_index][31:24] <= s_axi_wdata[31:24];
				end
				s_axi_bvalid <= 1'b1;
				s_axi_bresp  <= 2'b00;
			end

			if (s_axi_bvalid && s_axi_bready) begin
				s_axi_bvalid <= 1'b0;
			end

			// Read address latch
			if (s_axi_arvalid && s_axi_arready) begin
				araddr_latched <= s_axi_araddr;
				ar_pending <= 1'b1;
			end

			// 1-cycle read latency
			if (ar_pending) begin
				integer r_index;
				r_index = araddr_latched[ADDR_MSB:ADDR_LSB];
				if (r_index < WORDS) begin
					s_axi_rdata <= mem[r_index];
				end else begin
					s_axi_rdata <= {DATA_WIDTH{1'b0}};
				end
				s_axi_rvalid <= 1'b1;
				s_axi_rresp  <= 2'b00;
				ar_pending   <= 1'b0;
			end

			if (s_axi_rvalid && s_axi_rready) begin
				s_axi_rvalid <= 1'b0;
			end
		end
	end

endmodule
