`timescale 1ns / 1ps

`ifdef POST_SYNTH_SIM
module tb_soc_top;
    reg clk = 1'b0;
    reg resetn = 1'b0;
    reg trap_seen = 1'b0;

    wire trap_o;
    wire pcpi_valid_o;
    wire pcpi_wait_o;
    wire pcpi_ready_o;
    wire [31:0] pcpi_insn_o;

    always #5 clk = ~clk;

    // Post-synthesis/timing netlists do not preserve RTL parameters, debug
    // tasks, or internal hierarchy names. Keep this mode limited to top-level
    // pins so XSim can elaborate the synthesized design.
    soc_top uut (
        .clk(clk),
        .resetn(resetn),
        .trap_o(trap_o),
        .pcpi_valid_o(pcpi_valid_o),
        .pcpi_wait_o(pcpi_wait_o),
        .pcpi_ready_o(pcpi_ready_o),
        .pcpi_insn_o(pcpi_insn_o)
    );

    initial begin
        $display("POST_SYNTH_SIM enabled: synthesized netlist uses RAM init from soc_init.mem.");
        $display("This mode observes top-level PCPI/trap pins only; deep RAM/regfile checks remain RTL-only.");

        repeat (10) @(posedge clk);
        resetn <= 1'b1;

        repeat (4500) @(posedge clk);
        $display("POST_SYNTH_SIM finished at time %0t trap=%0b pcpi_valid=%0b pcpi_wait=%0b pcpi_ready=%0b pcpi_insn=0x%08x",
                 $time, trap_o, pcpi_valid_o, pcpi_wait_o, pcpi_ready_o, pcpi_insn_o);
        $finish;
    end

    always @(posedge clk) begin
        if (resetn && pcpi_valid_o) begin
            $display("PCPI top trace at time %0t: valid=%0b wait=%0b ready=%0b insn=0x%08x",
                     $time, pcpi_valid_o, pcpi_wait_o, pcpi_ready_o, pcpi_insn_o);
        end
        if (resetn && trap_o && !trap_seen) begin
            trap_seen <= 1'b1;
            $display("CPU trap asserted at time %0t", $time);
        end
    end
endmodule
`else

module tb_soc_top;
    reg clk = 1'b0;
    reg resetn = 1'b0;
    integer i;
    integer errors;
    integer start_mld_count;
    integer start_mst_count;
    integer start_matmul_count;
    integer scenario_id;
    integer active_matrix_scenario;
    reg [31:0] active_matrix_insn;
    reg trap_seen;
    reg pause_between_scenarios;
    reg trace_cycle;
    reg scenario_running;
    wire trap_o;
    wire pcpi_valid_o;
    wire pcpi_wait_o;
    wire pcpi_ready_o;
    wire [31:0] pcpi_insn_o;

    localparam bit LOG_PCPI_DONE = 1'b0;
    localparam bit LOG_AXI       = 1'b0;
    localparam bit LOG_REG_WRITE = 1'b0;
    localparam bit LOG_MAC_STEP  = 1'b0;
    localparam bit PAUSE_BETWEEN_SCENARIOS_DEFAULT = 1'b0;

    localparam int A_BASE_WORD = 32'h0000_0400 >> 2;
    localparam int B_BASE_WORD = 32'h0000_0500 >> 2;
    localparam int C_BASE_WORD = 32'h0000_0600 >> 2;
    localparam int D_BASE_WORD = 32'h0000_0700 >> 2;

    // 100 MHz clock
    always #5 clk = ~clk;

    soc_top #(
        .CPU_MEM_WORDS(4096),
        .AXI_MEM_WORDS(4096),
        .MEM_INIT_FILE("picorv32-matrix-coprocessor/sim/soc_init.mem")
    ) uut (
        .clk(clk),
        .resetn(resetn),
        .trap_o(trap_o),
        .pcpi_valid_o(pcpi_valid_o),
        .pcpi_wait_o(pcpi_wait_o),
        .pcpi_ready_o(pcpi_ready_o),
        .pcpi_insn_o(pcpi_insn_o)
    );

    task automatic mem_write(input integer word_addr, input [31:0] data);
        begin
            uut.u_mem.debug_write_word(word_addr, data);
        end
    endtask

    function automatic [31:0] mem_read(input integer word_addr);
        begin
            mem_read = uut.u_mem.debug_read_word(word_addr);
        end
    endfunction

    task automatic check_c(input integer idx, input [31:0] expected);
        begin
            if (mem_read(C_BASE_WORD + idx) !== expected) begin
                $display("ERROR C[%0d]: got 0x%08x expected 0x%08x", idx, mem_read(C_BASE_WORD + idx), expected);
                errors = errors + 1;
            end
        end
    endtask

    task automatic print_scenario_header(input integer id);
        begin
            $display("");
            unique case (id)
                1: begin
                    $display("================================================================");
                    $display("SCENARIO 1: DMA partial-row byte store");
                    $display("  Goal: load 1 byte into tr0, store 1 byte back, preserve sentinels");
                    $display("================================================================");
                end
                2: begin
                    $display("================================================================");
                    $display("SCENARIO 2: Zero-K matmul no-op");
                    $display("  Goal: mmaccu.w.b must complete when mtilek = 0");
                    $display("================================================================");
                end
                3: begin
                    $display("================================================================");
                    $display("SCENARIO 3: Packed-lite INT8 systolic matmul kernel");
                    $display("  Goal: A[4x16] * B[16x4] -> C[4x4] INT32");
                    $display("================================================================");
                end
                default: begin
                    $display("================================================================");
                    $display("SCENARIO %0d", id);
                    $display("================================================================");
                end
            endcase
        end
    endtask

    task automatic update_scenario(input [31:0] insn);
        begin
            if (insn == 32'h2204802b && scenario_id != 1) begin
                scenario_id = 1;
                scenario_running = 1'b1;
                print_scenario_header(1);
            end else if (insn == 32'h2202802b && scenario_id != 2) begin
                scenario_id = 2;
                scenario_running = 1'b1;
                print_scenario_header(2);
            end else if (insn == 32'h1203002b && scenario_id != 3) begin
                scenario_id = 3;
                scenario_running = 1'b1;
                print_scenario_header(3);
            end
        end
    endtask

    task automatic maybe_pause_after_scenario;
        begin
            if ((active_matrix_scenario == 1 && active_matrix_insn == 32'h0624002b) ||
                (active_matrix_scenario == 2 && active_matrix_insn == 32'h18100a2b) ||
                (active_matrix_scenario == 3 && active_matrix_insn == 32'h26220a2b)) begin
                scenario_running = 1'b0;
                $display("");
                $display("---- END SCENARIO %0d at time %0t ----", active_matrix_scenario, $time);
                if (pause_between_scenarios) begin
                    $display("Simulation paused. Inspect waveform, then continue/run to execute the next scenario.");
                    $stop;
                end
            end
        end
    endtask

    task automatic print_cycle_trace;
        begin
            $display("T=%0t SC%0d | PCPI v=%0b wait=%0b ready=%0b wr=%0b insn=%s | AXI AR=%0b/%0b R=%0b/%0b last=%0b AW=%0b/%0b W=%0b/%0b last=%0b B=%0b/%0b | DMA st=%0d r=%0d b=%0d reg_we=%0b id=%0d row=%0d beat=%0d | MAC st=%0d cyc=%0d we=%0b id=%0d row=%0d beat=%0d",
                $time,
                scenario_id,
                uut.pcpi_valid,
                uut.pcpi_wait,
                uut.pcpi_ready,
                uut.pcpi_wr,
                matrix_insn_name(uut.pcpi_insn),
                uut.m_axi_arvalid,
                uut.m_axi_arready,
                uut.m_axi_rvalid,
                uut.m_axi_rready,
                uut.m_axi_rlast,
                uut.m_axi_awvalid,
                uut.m_axi_awready,
                uut.m_axi_wvalid,
                uut.m_axi_wready,
                uut.m_axi_wlast,
                uut.m_axi_bvalid,
                uut.m_axi_bready,
                uut.u_matrix.u_dma.state,
                uut.u_matrix.u_dma.row_cnt,
                uut.u_matrix.u_dma.beat_cnt,
                uut.u_matrix.u_dma.reg_we,
                uut.u_matrix.u_dma.reg_id,
                uut.u_matrix.u_dma.reg_row_idx,
                uut.u_matrix.u_dma.reg_beat_idx,
                uut.u_matrix.u_mac.state,
                uut.u_matrix.u_mac.cycle_idx,
                uut.u_matrix.u_mac.mac_reg_we,
                uut.u_matrix.u_mac.mac_reg_id,
                uut.u_matrix.u_mac.mac_reg_row_idx,
                uut.u_matrix.u_mac.mac_reg_beat_idx);
        end
    endtask

    function automatic [8*24-1:0] matrix_insn_name(input [31:0] insn);
        logic [3:0] func4;
        logic [2:0] func3;
        logic [1:0] uop;
        logic [2:0] ctrl;
        logic [1:0] s_size;
        logic [1:0] d_size;
        logic       ls;
        begin
            func4 = insn[31:28];
            uop   = insn[27:26];
            ctrl  = insn[25:23];
            ls    = insn[25];
            func3 = insn[14:12];
            s_size = insn[19:18];
            d_size = insn[11:10];

            matrix_insn_name = "unknown";

            if (insn[6:0] != 7'b0101011) begin
                matrix_insn_name = "non-matrix";
            end else if (func3 == 3'b000 && uop == 2'b00) begin
                unique case (func4)
                    4'b0000: matrix_insn_name = "mrelease";
                    4'b0001: matrix_insn_name = ls ? "msettilek" : "msettileki";
                    4'b0010: matrix_insn_name = ls ? "msettilem" : "msettilemi";
                    4'b0011: matrix_insn_name = ls ? "msettilen" : "msettileni";
                    default: matrix_insn_name = "cfg-unsupported";
                endcase
            end else if (func3 == 3'b000 && uop == 2'b01) begin
                unique case ({func4, ls, d_size})
                    7'b0000_0_00: matrix_insn_name = "mlae8";
                    7'b0000_1_00: matrix_insn_name = "msae8";
                    7'b0001_0_00: matrix_insn_name = "mlbe8";
                    7'b0001_1_00: matrix_insn_name = "msbe8";
                    7'b0010_0_10: matrix_insn_name = "mlce32";
                    7'b0010_1_10: matrix_insn_name = "msce32";
                    default:      matrix_insn_name = "ls-unsupported";
                endcase
            end else if (func3 == 3'b000 && uop == 2'b10) begin
                if (func4 == 4'b0001 && s_size == 2'b00 && d_size == 2'b10) begin
                    unique case (ctrl)
                        3'b000:  matrix_insn_name = "mmaccu.w.b";
                        3'b001:  matrix_insn_name = "mmaccus.w.b";
                        3'b010:  matrix_insn_name = "mmaccsu.w.b";
                        3'b011:  matrix_insn_name = "mmacc.w.b";
                        default: matrix_insn_name = "matmul-unsupported";
                    endcase
                end else begin
                    matrix_insn_name = "matmul-unsupported";
                end
            end else if (func3 == 3'b000 && uop == 2'b11) begin
                unique case (func4)
                    4'b0000: matrix_insn_name = "mzero";
                    4'b0001: matrix_insn_name = "mmov.mm";
                    4'b0010: matrix_insn_name = "mmovw.x.m";
                    4'b0011: matrix_insn_name = ls ? "mmovw.m.x" : "mdupw.m.x";
                    4'b0101: matrix_insn_name = "mrslidedown";
                    4'b0111: matrix_insn_name = "mcslidedown.w";
                    default: matrix_insn_name = "misc-unsupported";
                endcase
            end else if (func3 == 3'b001 && uop == 2'b01) begin
                unique case (func4)
                    4'b0000: matrix_insn_name = (ctrl == 3'b111) ? "madd.w.mm"  : "madd.w.mv";
                    4'b0001: matrix_insn_name = (ctrl == 3'b111) ? "msub.w.mm"  : "msub.w.mv";
                    4'b0010: matrix_insn_name = (ctrl == 3'b111) ? "mmul.w.mm"  : "mmul.w.mv";
                    4'b0100: matrix_insn_name = (ctrl == 3'b111) ? "mmax.w.mm"  : "mmax.w.mv";
                    4'b0101: matrix_insn_name = (ctrl == 3'b111) ? "mumax.w.mm" : "mumax.w.mv";
                    4'b0110: matrix_insn_name = (ctrl == 3'b111) ? "mmin.w.mm"  : "mmin.w.mv";
                    4'b0111: matrix_insn_name = (ctrl == 3'b111) ? "mumin.w.mm" : "mumin.w.mv";
                    4'b1000: matrix_insn_name = (ctrl == 3'b111) ? "msrl.w.mm"  : "msrl.w.mv";
                    4'b1001: matrix_insn_name = (ctrl == 3'b111) ? "msll.w.mm"  : "msll.w.mv";
                    4'b1010: matrix_insn_name = (ctrl == 3'b111) ? "msra.w.mm"  : "msra.w.mv";
                    default: matrix_insn_name = "ew-unsupported";
                endcase
            end else begin
                matrix_insn_name = "matrix-unsupported";
            end
        end
    endfunction

    task automatic print_matrix_start(
        input [8*12-1:0] stage,
        input [31:0] insn,
        input [31:0] rs1_val,
        input [31:0] rs2_val
    );
        logic [3:0] func4;
        logic [2:0] func3;
        logic [1:0] uop;
        logic [2:0] ctrl;
        logic [2:0] ms2;
        logic [2:0] ms1;
        logic [2:0] md;
        logic [1:0] s_size;
        logic [1:0] d_size;
        logic [4:0] rs1;
        logic [4:0] rs2;
        logic [4:0] rd;
        logic       ls;
        begin
            func4  = insn[31:28];
            uop    = insn[27:26];
            ctrl   = insn[25:23];
            ls     = insn[25];
            ms2    = insn[22:20];
            s_size = insn[19:18];
            ms1    = insn[17:15];
            d_size = insn[11:10];
            md     = insn[9:7];
            func3  = insn[14:12];
            rs1    = insn[19:15];
            rs2    = insn[24:20];
            rd     = insn[11:7];

            if (func3 == 3'b000 && uop == 2'b00) begin
                unique case (func4)
                    4'b0001: begin
                        if (ls) begin
                            $display("%s %-16s x%0d=0x%08x at time %0t",
                                stage, matrix_insn_name(insn), rs1, rs1_val, $time);
                        end else begin
                            $display("%s %-16s imm=%0d at time %0t",
                                stage, matrix_insn_name(insn), insn[24:15], $time);
                        end
                    end
                    4'b0010: begin
                        if (ls) begin
                            $display("%s %-16s x%0d=0x%08x at time %0t",
                                stage, matrix_insn_name(insn), rs1, rs1_val, $time);
                        end else begin
                            $display("%s %-16s imm=%0d at time %0t",
                                stage, matrix_insn_name(insn), insn[24:15], $time);
                        end
                    end
                    4'b0011: begin
                        if (ls) begin
                            $display("%s %-16s x%0d=0x%08x at time %0t",
                                stage, matrix_insn_name(insn), rs1, rs1_val, $time);
                        end else begin
                            $display("%s %-16s imm=%0d at time %0t",
                                stage, matrix_insn_name(insn), insn[24:15], $time);
                        end
                    end
                    default: begin
                        $display("%s %-16s insn=0x%08x at time %0t",
                            stage, matrix_insn_name(insn), insn, $time);
                    end
                endcase
            end else if (func3 == 3'b000 && uop == 2'b01) begin
                if (func4 == 4'b0010) begin
                    $display("%s %-16s acc%0d, (x%0d=0x%08x), x%0d=0x%08x at time %0t",
                        stage, matrix_insn_name(insn), md[1:0], rs1, rs1_val, rs2, rs2_val, $time);
                end else begin
                    $display("%s %-16s tr%0d, (x%0d=0x%08x), x%0d=0x%08x at time %0t",
                        stage, matrix_insn_name(insn), md[1:0], rs1, rs1_val, rs2, rs2_val, $time);
                end
            end else if (func3 == 3'b000 && uop == 2'b10) begin
                $display("%s %-16s acc%0d, tr%0d, tr%0d at time %0t",
                    stage, matrix_insn_name(insn), md[1:0], ms1[1:0], ms2[1:0], $time);
            end else if (func3 == 3'b000 && uop == 2'b11) begin
                if (func4 == 4'b0000) begin
                    $display("%s %-16s acc%0d at time %0t",
                        stage, matrix_insn_name(insn), md[1:0], $time);
                end else if (func4 == 4'b0001) begin
                    $display("%s %-16s tr/acc%0d, tr/acc%0d at time %0t",
                        stage, matrix_insn_name(insn), md, ms1, $time);
                end else if (func4 == 4'b0010) begin
                    $display("%s %-16s x%0d, tr/acc%0d at time %0t",
                        stage, matrix_insn_name(insn), rd, ms2, $time);
                end else if (func4 == 4'b0011) begin
                    $display("%s %-16s tr/acc%0d, x%0d=0x%08x at time %0t",
                        stage, matrix_insn_name(insn), md, rs2, rs2_val, $time);
                end else begin
                    $display("%s %-16s tr/acc%0d, tr/acc%0d, ctrl=%0d at time %0t",
                        stage, matrix_insn_name(insn), md, ms1, ctrl, $time);
                end
            end else if (func3 == 3'b001 && uop == 2'b01) begin
                if (ctrl == 3'b111) begin
                    $display("%s %-16s acc%0d, acc%0d, acc%0d at time %0t",
                        stage, matrix_insn_name(insn), md[1:0], ms2[1:0], ms1[1:0], $time);
                end else begin
                    $display("%s %-16s acc%0d, acc%0d, acc%0d[row %0d] at time %0t",
                        stage, matrix_insn_name(insn), md[1:0], ms2[1:0], ms1[1:0], ctrl, $time);
                end
            end else begin
                $display("%s %-16s insn=0x%08x at time %0t",
                    stage, matrix_insn_name(insn), insn, $time);
            end
        end
    endtask

    initial begin
        $dumpfile("picorv32-matrix-coprocessor/sim/tb_soc_top.vcd");
        $dumpvars(0, tb_soc_top);
        errors = 0;
        start_mld_count = 0;
        start_mst_count = 0;
        start_matmul_count = 0;
        scenario_id = 0;
        active_matrix_scenario = 0;
        active_matrix_insn = 32'b0;
        trap_seen = 1'b0;
        scenario_running = 1'b0;
        pause_between_scenarios = PAUSE_BETWEEN_SCENARIOS_DEFAULT || $test$plusargs("PAUSE_SCENARIO");
        trace_cycle = $test$plusargs("TRACE_CYCLE");

        if (trace_cycle) begin
            $display("TRACE_CYCLE enabled: printing PCPI/AXI/DMA/REG/MAC status every clock while a scenario is active.");
        end

        $display("RAM initialized from picorv32-matrix-coprocessor/sim/soc_init.mem");

        // Reset sequence
        repeat (10) @(posedge clk);
        resetn <= 1'b1;

        // Run for a while then stop
        repeat (3000) @(posedge clk);

        $display("CSR mtilem=%0d mtilen=%0d mtilek=%0d", uut.u_matrix.out_mtilem, uut.u_matrix.out_mtilen, uut.u_matrix.out_mtilek);
        $display("TR0 rows (after load):");
        for (i = 0; i < 4; i = i + 1) begin
            $display("tr0[%0d] = %08x %08x %08x %08x", i,
                uut.u_matrix.u_regfile.matrix_regs[0][i][0],
                uut.u_matrix.u_regfile.matrix_regs[0][i][1],
                uut.u_matrix.u_regfile.matrix_regs[0][i][2],
                uut.u_matrix.u_regfile.matrix_regs[0][i][3]);
        end
        $display("TR1 rows (after load):");
        for (i = 0; i < 4; i = i + 1) begin
            $display("tr1[%0d] = %08x %08x %08x %08x", i,
                uut.u_matrix.u_regfile.matrix_regs[1][i][0],
                uut.u_matrix.u_regfile.matrix_regs[1][i][1],
                uut.u_matrix.u_regfile.matrix_regs[1][i][2],
                uut.u_matrix.u_regfile.matrix_regs[1][i][3]);
        end
        $display("ACC0 rows (after matmul):");
        for (i = 0; i < 4; i = i + 1) begin
            $display("acc0[%0d] = %08x %08x %08x %08x", i,
                uut.u_matrix.u_regfile.matrix_regs[4][i][0],
                uut.u_matrix.u_regfile.matrix_regs[4][i][1],
                uut.u_matrix.u_regfile.matrix_regs[4][i][2],
                uut.u_matrix.u_regfile.matrix_regs[4][i][3]);
        end
        $display("C matrix (base 0x600) words:");
        for (i = C_BASE_WORD; i < C_BASE_WORD + 16; i = i + 1) begin
            $display("C[%0d] = 0x%08x", i - C_BASE_WORD, mem_read(i));
        end

        if (mem_read(D_BASE_WORD + 0) !== 32'hDEAD_BE01) begin
            $display("ERROR partial byte store: got 0x%08x expected 0xDEADBE01", mem_read(D_BASE_WORD + 0));
            errors = errors + 1;
        end
        if (mem_read(D_BASE_WORD + 4) !== 32'hCAFE_BABE) begin
            $display("ERROR partial row count: row1 got 0x%08x expected 0xCAFEBABE", mem_read(D_BASE_WORD + 4));
            errors = errors + 1;
        end

        if (start_mld_count != 3) begin
            $display("ERROR start_mld_count=%0d expected 3", start_mld_count);
            errors = errors + 1;
        end
        if (start_mst_count != 2) begin
            $display("ERROR start_mst_count=%0d expected 2", start_mst_count);
            errors = errors + 1;
        end
        if (start_matmul_count != 2) begin
            $display("ERROR start_matmul_count=%0d expected 2", start_matmul_count);
            errors = errors + 1;
        end

        check_c(0,  32'h00000088);
        check_c(1,  32'h000005d8);
        check_c(2,  32'h00000001);
        check_c(3,  32'h00000010);
        check_c(4,  32'h00000188);
        check_c(5,  32'h00000e58);
        check_c(6,  32'h00000011);
        check_c(7,  32'h00000020);
        check_c(8,  32'h00000288);
        check_c(9,  32'h000016d8);
        check_c(10, 32'h00000021);
        check_c(11, 32'h00000030);
        check_c(12, 32'h00000388);
        check_c(13, 32'h00001f58);
        check_c(14, 32'h00000031);
        check_c(15, 32'h00000040);

        if (errors == 0) begin
            $display("PACKED_LITE_TEST_PASS");
        end else begin
            $display("PACKED_LITE_TEST_FAIL errors=%0d", errors);
        end
        $finish;
    end

    always @(posedge clk) begin
        if (resetn && uut.u_matrix.start_cfg) begin
            update_scenario(uut.pcpi_insn);
        end

        if (resetn && (uut.u_matrix.start_cfg || uut.u_matrix.start_mld ||
                       uut.u_matrix.start_mst || uut.u_matrix.start_matmul ||
                       uut.u_matrix.start_misc || uut.u_matrix.start_ew)) begin
            active_matrix_insn = uut.pcpi_insn;
            active_matrix_scenario = scenario_id;
        end

        if (resetn && LOG_PCPI_DONE && uut.pcpi_ready) begin
            $display("PCPI done at time %0t", $time);
        end
        if (resetn && uut.pcpi_ready) begin
            maybe_pause_after_scenario();
        end
        if (resetn && uut.u_matrix.start_cfg) begin
            print_matrix_start("start_cfg", uut.pcpi_insn, uut.u_matrix.pcpi_rs1, uut.u_matrix.pcpi_rs2);
        end
        if (resetn && uut.u_matrix.start_mld) begin
            start_mld_count = start_mld_count + 1;
            print_matrix_start("start_mld", uut.pcpi_insn, uut.u_matrix.pcpi_rs1, uut.u_matrix.pcpi_rs2);
        end
        if (resetn && uut.u_matrix.start_matmul) begin
            start_matmul_count = start_matmul_count + 1;
            print_matrix_start("start_matmul", uut.pcpi_insn, uut.u_matrix.pcpi_rs1, uut.u_matrix.pcpi_rs2);
        end
        if (resetn && uut.u_matrix.start_mst) begin
            start_mst_count = start_mst_count + 1;
            print_matrix_start("start_mst", uut.pcpi_insn, uut.u_matrix.pcpi_rs1, uut.u_matrix.pcpi_rs2);
        end
        if (resetn && uut.u_matrix.start_misc) begin
            print_matrix_start("start_misc", uut.pcpi_insn, uut.u_matrix.pcpi_rs1, uut.u_matrix.pcpi_rs2);
        end
        if (resetn && uut.u_matrix.start_ew) begin
            print_matrix_start("start_ew", uut.pcpi_insn, uut.u_matrix.pcpi_rs1, uut.u_matrix.pcpi_rs2);
        end
        if (resetn && uut.trap && !trap_seen) begin
            trap_seen = 1'b1;
            errors = errors + 1;
            $display("ERROR CPU trap asserted at time %0t", $time);
        end
        if (resetn && LOG_AXI && uut.m_axi_arvalid && uut.m_axi_arready) begin
            $display("AR addr=0x%08x len=%0d", uut.m_axi_araddr, uut.m_axi_arlen);
        end
        if (resetn && LOG_AXI && uut.m_axi_rvalid && uut.m_axi_rready) begin
            $display("R data=0x%08x rlast=%0d", uut.m_axi_rdata, uut.m_axi_rlast);
        end
        if (resetn && LOG_AXI && uut.m_axi_awvalid && uut.m_axi_awready) begin
            $display("AW addr=0x%08x len=%0d", uut.m_axi_awaddr, uut.m_axi_awlen);
        end
        if (resetn && LOG_AXI && uut.m_axi_wvalid && uut.m_axi_wready) begin
            $display("W data=0x%08x wlast=%0d", uut.m_axi_wdata, uut.m_axi_wlast);
        end
        if (resetn && LOG_AXI && uut.m_axi_bvalid && uut.m_axi_bready) begin
            $display("B resp=%0d", uut.m_axi_bresp);
        end
        if (resetn && LOG_REG_WRITE && uut.u_matrix.u_dma.reg_we) begin
            $display("DMA reg_we id=%0d row=%0d beat=%0d data=0x%08x", uut.u_matrix.u_dma.reg_id, uut.u_matrix.u_dma.reg_row_idx, uut.u_matrix.u_dma.reg_beat_idx, uut.u_matrix.u_dma.reg_wdata);
        end
        if (resetn && LOG_REG_WRITE && uut.u_matrix.u_mac.mac_reg_we) begin
            $display("MAC reg_we id=%0d row=%0d beat=%0d data=0x%08x", uut.u_matrix.u_mac.mac_reg_id, uut.u_matrix.u_mac.mac_reg_row_idx, uut.u_matrix.u_mac.mac_reg_beat_idx, uut.u_matrix.u_mac.mac_reg_wdata[31:0]);
        end
        if (resetn && LOG_MAC_STEP && uut.u_matrix.u_mac.state == 3'd2) begin
            $display("MAC step m=%0d n=%0d k=%0d A[row=%0d beat=%0d byte=%0d]=0x%02x B[row=%0d beat=%0d byte=%0d]=0x%02x",
                uut.u_matrix.u_mac.m_idx, uut.u_matrix.u_mac.n_idx, uut.u_matrix.u_mac.k_idx,
                uut.u_matrix.u_mac.read_row_A, uut.u_matrix.u_mac.read_beat_A, uut.u_matrix.u_mac.byte_sel_A, uut.u_matrix.u_mac.a_byte,
                uut.u_matrix.u_mac.read_row_B, uut.u_matrix.u_mac.read_beat_B, uut.u_matrix.u_mac.byte_sel_B, uut.u_matrix.u_mac.b_byte);
        end
        if (resetn && trace_cycle && scenario_running) begin
            print_cycle_trace();
        end
    end
endmodule
`endif

