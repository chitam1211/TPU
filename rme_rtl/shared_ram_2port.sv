`timescale 1ns / 1ps

module shared_ram_2port #(
    parameter int MEM_WORDS = 4096,
    parameter     MEM_INIT_FILE = "none"
)(
    input  logic        clk,
    input  logic        resetn,

    // PicoRV32 native memory port
    input  logic        cpu_mem_valid,
    input  logic [31:0] cpu_mem_addr,
    input  logic [31:0] cpu_mem_wdata,
    input  logic [3:0]  cpu_mem_wstrb,
    output logic        cpu_mem_ready,
    output logic [31:0] cpu_mem_rdata,

    // Matrix DMA AXI-like slave port
    input  logic [31:0] s_axi_awaddr,
    input  logic [7:0]  s_axi_awlen,
    input  logic [2:0]  s_axi_awsize,
    input  logic [1:0]  s_axi_awburst,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,

    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wlast,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,

    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,

    input  logic [31:0] s_axi_araddr,
    input  logic [7:0]  s_axi_arlen,
    input  logic [2:0]  s_axi_arsize,
    input  logic [1:0]  s_axi_arburst,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,

    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rlast,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready
);

    localparam int ADDR_WIDTH = (MEM_WORDS <= 2) ? 1 : $clog2(MEM_WORDS);
    localparam bit HAS_MEM_INIT_FILE = (MEM_INIT_FILE != "none");

    logic        aw_active;
    logic [31:0] aw_addr;
    logic [7:0]  aw_len;
    logic [7:0]  aw_beat;

    logic        ar_active;
    logic [31:0] ar_addr;
    logic [7:0]  ar_len;
    logic [7:0]  ar_beat;

    function automatic logic [ADDR_WIDTH-1:0] word_index(
        input logic [31:0] byte_addr,
        input logic [7:0]  beat
    );
        logic [31:0] idx;
        begin
            idx = byte_addr[31:2] + {24'b0, beat};
            word_index = idx[ADDR_WIDTH-1:0];
        end
    endfunction

    logic [ADDR_WIDTH-1:0] cpu_word_addr;
    logic [ADDR_WIDTH-1:0] axi_waddr;
    logic [ADDR_WIDTH-1:0] axi_araddr0;
    logic [ADDR_WIDTH-1:0] axi_rnext_addr;

    assign cpu_word_addr  = word_index(cpu_mem_addr, 8'd0);
    assign axi_waddr      = word_index(aw_addr, aw_beat);
    assign axi_araddr0    = word_index(s_axi_araddr, 8'd0);
    assign axi_rnext_addr = word_index(ar_addr, ar_beat + 8'd1);

    assign s_axi_awready = !aw_active && !s_axi_bvalid;
    assign s_axi_wready  = aw_active;
    assign s_axi_bresp   = 2'b00;

    assign s_axi_arready = !ar_active;
    assign s_axi_rresp   = 2'b00;

`ifdef SYNTHESIS
    // Vivado synthesis path: instantiate Xilinx XPM RAM directly. This avoids
    // fragile RAM inference templates for a mixed CPU + DMA true-dual-port RAM.
    logic [31:0] xpm_douta;
    logic [31:0] xpm_doutb;

    logic        cpu_pending;
    logic        cpu_fire;

    logic        axi_w_fire;
    logic        axi_ar_fire;
    logic        axi_r_fire;
    logic        axi_r_read_issue;
    logic [ADDR_WIDTH-1:0] axi_r_read_addr;

    logic        xpm_enb;
    logic [3:0]  xpm_web;
    logic [ADDR_WIDTH-1:0] xpm_addrb;
    logic [31:0] xpm_dinb;

    assign cpu_fire = cpu_mem_valid && !cpu_pending && !cpu_mem_ready;

    assign axi_w_fire       = s_axi_wvalid && s_axi_wready;
    assign axi_ar_fire      = s_axi_arvalid && s_axi_arready;
    assign axi_r_fire       = s_axi_rvalid && s_axi_rready;
    assign axi_r_read_issue = axi_ar_fire || (axi_r_fire && !s_axi_rlast);
    assign axi_r_read_addr  = axi_ar_fire ? axi_araddr0 : axi_rnext_addr;

    assign xpm_enb   = axi_w_fire || axi_r_read_issue;
    assign xpm_web   = axi_w_fire ? s_axi_wstrb : 4'b0000;
    assign xpm_addrb = axi_w_fire ? axi_waddr : axi_r_read_addr;
    assign xpm_dinb  = s_axi_wdata;

    assign cpu_mem_rdata = xpm_douta;
    assign s_axi_rdata   = xpm_doutb;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            cpu_pending   <= 1'b0;
            cpu_mem_ready <= 1'b0;
        end else begin
            cpu_mem_ready <= cpu_pending;

            if (cpu_pending) begin
                cpu_pending <= 1'b0;
            end
            if (cpu_fire) begin
                cpu_pending <= 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!resetn) begin
            aw_active    <= 1'b0;
            aw_addr      <= 32'b0;
            aw_len       <= 8'b0;
            aw_beat      <= 8'b0;
            s_axi_bvalid <= 1'b0;

            ar_active    <= 1'b0;
            ar_addr      <= 32'b0;
            ar_len       <= 8'b0;
            ar_beat      <= 8'b0;
            s_axi_rvalid <= 1'b0;
            s_axi_rlast  <= 1'b0;
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin
                aw_active <= 1'b1;
                aw_addr   <= s_axi_awaddr;
                aw_len    <= s_axi_awlen;
                aw_beat   <= 8'b0;
            end

            if (axi_w_fire) begin
                if (s_axi_wlast || aw_beat == aw_len) begin
                    aw_active    <= 1'b0;
                    s_axi_bvalid <= 1'b1;
                end else begin
                    aw_beat <= aw_beat + 8'd1;
                end
            end

            if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end

            if (axi_ar_fire) begin
                ar_active    <= 1'b1;
                ar_addr      <= s_axi_araddr;
                ar_len       <= s_axi_arlen;
                ar_beat      <= 8'b0;
                s_axi_rvalid <= 1'b1;
                s_axi_rlast  <= (s_axi_arlen == 8'd0);
            end else if (axi_r_fire) begin
                if (s_axi_rlast) begin
                    ar_active    <= 1'b0;
                    s_axi_rvalid <= 1'b0;
                    s_axi_rlast  <= 1'b0;
                end else begin
                    ar_beat      <= ar_beat + 8'd1;
                    s_axi_rvalid <= 1'b1;
                    s_axi_rlast  <= (ar_beat + 8'd1 == ar_len);
                end
            end
        end
    end

    xpm_memory_tdpram #(
        .ADDR_WIDTH_A(ADDR_WIDTH),
        .ADDR_WIDTH_B(ADDR_WIDTH),
        .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(8),
        .BYTE_WRITE_WIDTH_B(8),
        .CASCADE_HEIGHT(0),
        .CLOCKING_MODE("common_clock"),
        .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE(MEM_INIT_FILE),
        .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(MEM_WORDS * 32),
        .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_A(32),
        .READ_DATA_WIDTH_B(32),
        .READ_LATENCY_A(1),
        .READ_LATENCY_B(1),
        .READ_RESET_VALUE_A("0"),
        .READ_RESET_VALUE_B("0"),
        .RST_MODE_A("SYNC"),
        .RST_MODE_B("SYNC"),
        .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0),
        .USE_MEM_INIT(HAS_MEM_INIT_FILE),
        .USE_MEM_INIT_MMI(0),
        .WAKEUP_TIME("disable_sleep"),
        .WRITE_DATA_WIDTH_A(32),
        .WRITE_DATA_WIDTH_B(32),
        .WRITE_MODE_A("read_first"),
        .WRITE_MODE_B("read_first")
    ) u_xpm_mem (
        .dbiterra(),
        .dbiterrb(),
        .douta(xpm_douta),
        .doutb(xpm_doutb),
        .sbiterra(),
        .sbiterrb(),
        .addra(cpu_word_addr),
        .addrb(xpm_addrb),
        .clka(clk),
        .clkb(clk),
        .dina(cpu_mem_wdata),
        .dinb(xpm_dinb),
        .ena(cpu_fire),
        .enb(xpm_enb),
        .injectdbiterra(1'b0),
        .injectdbiterrb(1'b0),
        .injectsbiterra(1'b0),
        .injectsbiterrb(1'b0),
        .regcea(1'b1),
        .regceb(1'b1),
        .rsta(!resetn),
        .rstb(!resetn),
        .sleep(1'b0),
        .wea(cpu_fire ? cpu_mem_wstrb : 4'b0000),
        .web(xpm_web)
    );
`else
    // Icarus/portable simulation path. The public debug tasks below are used by
    // tb_soc_top to preload and inspect the byte-lane memory.
    (* ram_style = "block" *) logic [7:0] mem_b0 [0:MEM_WORDS-1];
    (* ram_style = "block" *) logic [7:0] mem_b1 [0:MEM_WORDS-1];
    (* ram_style = "block" *) logic [7:0] mem_b2 [0:MEM_WORDS-1];
    (* ram_style = "block" *) logic [7:0] mem_b3 [0:MEM_WORDS-1];
    logic [31:0] init_words [0:MEM_WORDS-1];

    initial begin
        for (int idx = 0; idx < MEM_WORDS; idx++) begin
            init_words[idx] = 32'b0;
            mem_b0[idx] = 8'b0;
            mem_b1[idx] = 8'b0;
            mem_b2[idx] = 8'b0;
            mem_b3[idx] = 8'b0;
        end

        if (HAS_MEM_INIT_FILE) begin
            $readmemh(MEM_INIT_FILE, init_words);
            for (int idx = 0; idx < MEM_WORDS; idx++) begin
                mem_b0[idx] = init_words[idx][7:0];
                mem_b1[idx] = init_words[idx][15:8];
                mem_b2[idx] = init_words[idx][23:16];
                mem_b3[idx] = init_words[idx][31:24];
            end
        end
    end

    task automatic debug_write_word(
        input int unsigned word_addr,
        input logic [31:0] data
    );
        begin
            if (word_addr < MEM_WORDS) begin
                mem_b0[word_addr[ADDR_WIDTH-1:0]] = data[7:0];
                mem_b1[word_addr[ADDR_WIDTH-1:0]] = data[15:8];
                mem_b2[word_addr[ADDR_WIDTH-1:0]] = data[23:16];
                mem_b3[word_addr[ADDR_WIDTH-1:0]] = data[31:24];
            end
        end
    endtask

    function automatic logic [31:0] debug_read_word(
        input int unsigned word_addr
    );
        begin
            if (word_addr < MEM_WORDS) begin
                debug_read_word = {
                    mem_b3[word_addr[ADDR_WIDTH-1:0]],
                    mem_b2[word_addr[ADDR_WIDTH-1:0]],
                    mem_b1[word_addr[ADDR_WIDTH-1:0]],
                    mem_b0[word_addr[ADDR_WIDTH-1:0]]
                };
            end else begin
                debug_read_word = 32'b0;
            end
        end
    endfunction

    always_ff @(posedge clk) begin
        if (!resetn) begin
            cpu_mem_ready <= 1'b0;
            cpu_mem_rdata <= 32'b0;
        end else begin
            cpu_mem_ready <= 1'b0;

            if (cpu_mem_valid && !cpu_mem_ready) begin
                cpu_mem_ready <= 1'b1;
                cpu_mem_rdata <= {
                    mem_b3[cpu_word_addr],
                    mem_b2[cpu_word_addr],
                    mem_b1[cpu_word_addr],
                    mem_b0[cpu_word_addr]
                };

                if (cpu_mem_wstrb[0]) mem_b0[cpu_word_addr] <= cpu_mem_wdata[7:0];
                if (cpu_mem_wstrb[1]) mem_b1[cpu_word_addr] <= cpu_mem_wdata[15:8];
                if (cpu_mem_wstrb[2]) mem_b2[cpu_word_addr] <= cpu_mem_wdata[23:16];
                if (cpu_mem_wstrb[3]) mem_b3[cpu_word_addr] <= cpu_mem_wdata[31:24];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!resetn) begin
            aw_active    <= 1'b0;
            aw_addr      <= 32'b0;
            aw_len       <= 8'b0;
            aw_beat      <= 8'b0;
            s_axi_bvalid <= 1'b0;

            ar_active    <= 1'b0;
            ar_addr      <= 32'b0;
            ar_len       <= 8'b0;
            ar_beat      <= 8'b0;
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= 32'b0;
            s_axi_rlast  <= 1'b0;
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin
                aw_active <= 1'b1;
                aw_addr   <= s_axi_awaddr;
                aw_len    <= s_axi_awlen;
                aw_beat   <= 8'b0;
            end

            if (s_axi_wvalid && s_axi_wready) begin
                if (s_axi_wstrb[0]) mem_b0[axi_waddr] <= s_axi_wdata[7:0];
                if (s_axi_wstrb[1]) mem_b1[axi_waddr] <= s_axi_wdata[15:8];
                if (s_axi_wstrb[2]) mem_b2[axi_waddr] <= s_axi_wdata[23:16];
                if (s_axi_wstrb[3]) mem_b3[axi_waddr] <= s_axi_wdata[31:24];

                if (s_axi_wlast || aw_beat == aw_len) begin
                    aw_active    <= 1'b0;
                    s_axi_bvalid <= 1'b1;
                end else begin
                    aw_beat <= aw_beat + 8'd1;
                end
            end

            if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end

            if (s_axi_arvalid && s_axi_arready) begin
                ar_active    <= 1'b1;
                ar_addr      <= s_axi_araddr;
                ar_len       <= s_axi_arlen;
                ar_beat      <= 8'b0;
                s_axi_rvalid <= 1'b1;
                s_axi_rdata  <= {
                    mem_b3[axi_araddr0],
                    mem_b2[axi_araddr0],
                    mem_b1[axi_araddr0],
                    mem_b0[axi_araddr0]
                };
                s_axi_rlast  <= (s_axi_arlen == 8'd0);
            end

            if (s_axi_rvalid && s_axi_rready) begin
                if (ar_beat == ar_len) begin
                    ar_active    <= 1'b0;
                    s_axi_rvalid <= 1'b0;
                    s_axi_rlast  <= 1'b0;
                end else begin
                    ar_beat     <= ar_beat + 8'd1;
                    s_axi_rdata <= {
                        mem_b3[axi_rnext_addr],
                        mem_b2[axi_rnext_addr],
                        mem_b1[axi_rnext_addr],
                        mem_b0[axi_rnext_addr]
                    };
                    s_axi_rlast <= (ar_beat + 8'd1 == ar_len);
                end
            end
        end
    end
`endif

endmodule
