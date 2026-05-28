`timescale 1ns / 1ps

module soc_top #(
	parameter int CPU_MEM_WORDS = 4096,
	parameter int AXI_MEM_WORDS = 4096,
	parameter     MEM_INIT_FILE = "soc_init.mem"
)(
	input  logic clk,
	input  logic resetn,

	// Minimal observable outputs for synthesis/debug. Without any top-level
	// outputs, Vivado can legally trim the whole SoC away.
	output logic        trap_o,
	output logic        pcpi_valid_o,
	output logic        pcpi_wait_o,
	output logic        pcpi_ready_o,
	output logic [31:0] pcpi_insn_o
);
	localparam int SHARED_MEM_WORDS = (CPU_MEM_WORDS > AXI_MEM_WORDS) ? CPU_MEM_WORDS : AXI_MEM_WORDS;

	// ------------------------------------------------------------------
	// PicoRV32 core
	// ------------------------------------------------------------------
	logic trap;

	logic        mem_valid;
	logic        mem_instr;
	logic        mem_ready;
	logic [31:0] mem_addr;
	logic [31:0] mem_wdata;
	logic [ 3:0] mem_wstrb;
	logic [31:0] mem_rdata;

	logic        pcpi_valid;
	logic [31:0] pcpi_insn;
	logic [31:0] pcpi_rs1;
	logic [31:0] pcpi_rs2;
	logic        pcpi_wr;
	logic [31:0] pcpi_rd;
	logic        pcpi_wait;
	logic        pcpi_ready;
	logic        trace_valid;
	logic [35:0] trace_data;

	assign trap_o       = trap;
	assign pcpi_valid_o = pcpi_valid;
	assign pcpi_wait_o  = pcpi_wait;
	assign pcpi_ready_o = pcpi_ready;
	assign pcpi_insn_o  = pcpi_insn;

	picorv32 #(
		.ENABLE_PCPI(1),
		.PROGADDR_RESET(32'h0000_0000)
	) u_cpu (
		.clk(clk),
		.resetn(resetn),
		.trap(trap),

		.mem_valid(mem_valid),
		.mem_instr(mem_instr),
		.mem_ready(mem_ready),
		.mem_addr(mem_addr),
		.mem_wdata(mem_wdata),
		.mem_wstrb(mem_wstrb),
		.mem_rdata(mem_rdata),

		.mem_la_read(),
		.mem_la_write(),
		.mem_la_addr(),
		.mem_la_wdata(),
		.mem_la_wstrb(),

		.pcpi_valid(pcpi_valid),
		.pcpi_insn(pcpi_insn),
		.pcpi_rs1(pcpi_rs1),
		.pcpi_rs2(pcpi_rs2),
		.pcpi_wr(pcpi_wr),
		.pcpi_rd(pcpi_rd),
		.pcpi_wait(pcpi_wait),
		.pcpi_ready(pcpi_ready),

		.irq(32'b0),
		.eoi(),

		.trace_valid(trace_valid),
		.trace_data(trace_data)
	);

	// ------------------------------------------------------------------
	// Matrix coprocessor core
	// ------------------------------------------------------------------
	logic [31:0] m_axi_awaddr;
	logic [7:0]  m_axi_awlen;
	logic [2:0]  m_axi_awsize;
	logic [1:0]  m_axi_awburst;
	logic        m_axi_awvalid;
	logic        m_axi_awready;

	logic [31:0] m_axi_wdata;
	logic [3:0]  m_axi_wstrb;
	logic        m_axi_wlast;
	logic        m_axi_wvalid;
	logic        m_axi_wready;

	logic [1:0]  m_axi_bresp;
	logic        m_axi_bvalid;
	logic        m_axi_bready;

	logic [31:0] m_axi_araddr;
	logic [7:0]  m_axi_arlen;
	logic [2:0]  m_axi_arsize;
	logic [1:0]  m_axi_arburst;
	logic        m_axi_arvalid;
	logic        m_axi_arready;

	logic [31:0] m_axi_rdata;
	logic [1:0]  m_axi_rresp;
	logic        m_axi_rlast;
	logic        m_axi_rvalid;
	logic        m_axi_rready;

	matrix_core u_matrix (
		.clk(clk),
		.resetn(resetn),

		.pcpi_valid(pcpi_valid),
		.pcpi_insn(pcpi_insn),
		.pcpi_rs1(pcpi_rs1),
		.pcpi_rs2(pcpi_rs2),
		.pcpi_wr(pcpi_wr),
		.pcpi_rd(pcpi_rd),
		.pcpi_wait(pcpi_wait),
		.pcpi_ready(pcpi_ready),

		.m_axi_awaddr(m_axi_awaddr),
		.m_axi_awlen(m_axi_awlen),
		.m_axi_awsize(m_axi_awsize),
		.m_axi_awburst(m_axi_awburst),
		.m_axi_awvalid(m_axi_awvalid),
		.m_axi_awready(m_axi_awready),

		.m_axi_wdata(m_axi_wdata),
		.m_axi_wstrb(m_axi_wstrb),
		.m_axi_wlast(m_axi_wlast),
		.m_axi_wvalid(m_axi_wvalid),
		.m_axi_wready(m_axi_wready),

		.m_axi_bresp(m_axi_bresp),
		.m_axi_bvalid(m_axi_bvalid),
		.m_axi_bready(m_axi_bready),

		.m_axi_araddr(m_axi_araddr),
		.m_axi_arlen(m_axi_arlen),
		.m_axi_arsize(m_axi_arsize),
		.m_axi_arburst(m_axi_arburst),
		.m_axi_arvalid(m_axi_arvalid),
		.m_axi_arready(m_axi_arready),

		.m_axi_rdata(m_axi_rdata),
		.m_axi_rresp(m_axi_rresp),
		.m_axi_rlast(m_axi_rlast),
		.m_axi_rvalid(m_axi_rvalid),
		.m_axi_rready(m_axi_rready)
	);

	// ------------------------------------------------------------------
	// Shared system RAM: CPU native port + matrix DMA AXI-like port
	// ------------------------------------------------------------------
	shared_ram_2port #(
		.MEM_WORDS(SHARED_MEM_WORDS),
		.MEM_INIT_FILE(MEM_INIT_FILE)
	) u_mem (
		.clk(clk),
		.resetn(resetn),

		.cpu_mem_valid(mem_valid),
		.cpu_mem_addr(mem_addr),
		.cpu_mem_wdata(mem_wdata),
		.cpu_mem_wstrb(mem_wstrb),
		.cpu_mem_ready(mem_ready),
		.cpu_mem_rdata(mem_rdata),

		.s_axi_awaddr(m_axi_awaddr),
		.s_axi_awlen(m_axi_awlen),
		.s_axi_awsize(m_axi_awsize),
		.s_axi_awburst(m_axi_awburst),
		.s_axi_awvalid(m_axi_awvalid),
		.s_axi_awready(m_axi_awready),

		.s_axi_wdata(m_axi_wdata),
		.s_axi_wstrb(m_axi_wstrb),
		.s_axi_wlast(m_axi_wlast),
		.s_axi_wvalid(m_axi_wvalid),
		.s_axi_wready(m_axi_wready),

		.s_axi_bresp(m_axi_bresp),
		.s_axi_bvalid(m_axi_bvalid),
		.s_axi_bready(m_axi_bready),

		.s_axi_araddr(m_axi_araddr),
		.s_axi_arlen(m_axi_arlen),
		.s_axi_arsize(m_axi_arsize),
		.s_axi_arburst(m_axi_arburst),
		.s_axi_arvalid(m_axi_arvalid),
		.s_axi_arready(m_axi_arready),

		.s_axi_rdata(m_axi_rdata),
		.s_axi_rresp(m_axi_rresp),
		.s_axi_rlast(m_axi_rlast),
		.s_axi_rvalid(m_axi_rvalid),
		.s_axi_rready(m_axi_rready)
	);

endmodule
