# Out-of-context timing budgets for the CV-X-IF design (fpga/kv260/implement_ooc_xif.tcl).
#
# The SoC (rv32if_xif_soc, not written yet) puts BRAMs and an AXI-Lite register block around
# core_matrix_xif. Out of context those are absent, so every port gets an input or output delay
# that stands for them. The split run (core alone, coprocessor alone) also cuts the CV-X-IF
# signals, which in the full design are timed through both modules in one cycle.
#
# CV-X-IF budget: one number t per signal = the time after the clock edge at which the signal is
# valid at the core/coprocessor boundary. The module that drives it gets set_output_delay T - t
# (it must deliver by t); the module that receives it gets set_input_delay t. Both runs read
# the same table, so their budgets always add up to one cycle. t is a fraction of the period
# ({frac x}) or absolute ns ({abs x}).
#
# Second pass: replace a fraction by the time reported in boundary_ports.csv of the first runs
# (column used_ns: for an output, when it is ready after the clock edge) plus a margin, and run again.
#
# Clock reference. After placement the clock reaches the flip-flops ~2.5 ns after the clock port
# (estimated BUFG + clock tree). A plain set_input_delay is relative to the clock at the port, so
# out of context every input looked 2.5 ns early (hold failing by 2.5 ns, setup too optimistic)
# and every output 2.5 ns late. The router then detoured the input nets to fix hold and wrecked
# setup (first run: WNS -1.4 ns after placement, -5.3 ns after routing). In the SoC the BRAMs and
# the register block hang on the same clock tree, so after synthesis the delays are set again
# with -reference_pin = the clock pin of a flip-flop of the design (ooc_write_port_xdc).

# ---- Environment of core_matrix_xif in the SoC (absolute ns; estimates, edit here) ----------
set OOC_T_BRAM_CO 1.3   ;# BRAM clock-to-out without output register (DS925 T_RCKO_DO; estimate for -2LV)
set OOC_T_BRAM_SU 0.5   ;# BRAM address/data/enable setup + local routing (estimate)
set OOC_T_VALID   0.3   ;# *_mem_valid: a flip-flop in the SoC top (valid <= request)
set OOC_T_HOST    0.5   ;# host / debug ports: AXI-Lite register block

# ---- CV-X-IF: signal  driver  t ----------------------------------------------------------------
# core -> coprocessor
#   issue_valid/instr/id    EX flip-flops + little logic
#   register_rs1/rs2        EX operand forwarding mux (MEM / WB results)
#   commit_valid            issue_valid && issue_ready (issue_ready comes back from the coprocessor)
#   mem_ready, mem_result_valid, result_ready   flip-flops + a gate (mem_result_valid uses data_mem_valid)
#   mem_result_rdata        load_data_in passed through: BRAM clock-to-out + routing
# coprocessor -> core
#   issue_ready             adapter state
#   issue_accept            matrix_dispatch decode of issue_instr (combinational, same cycle)
#   mem_*                   tile load/store unit registers + address arithmetic
#   result_*                matrix_done and the outstanding-result count (uses mem_ready, mem_result_valid)
set OOC_XIF {
    xif_issue_valid       core   {frac 0.25}
    xif_issue_instr       core   {frac 0.25}
    xif_issue_id          core   {frac 0.25}
    xif_register_rs1      core   {frac 0.45}
    xif_register_rs2      core   {frac 0.45}
    xif_register_rs_valid core   {frac 0.10}
    xif_commit_valid      core   {frac 0.40}
    xif_commit_kill       core   {frac 0.10}
    xif_mem_ready         core   {frac 0.25}
    xif_mem_result_valid  core   {frac 0.25}
    xif_mem_result_rdata  core   {abs  1.6}
    xif_result_ready      core   {frac 0.25}
    xif_issue_ready       coproc {frac 0.30}
    xif_issue_accept      coproc {frac 0.55}
    xif_mem_valid         coproc {frac 0.40}
    xif_mem_addr          coproc {frac 0.40}
    xif_mem_we            coproc {frac 0.40}
    xif_mem_be            coproc {frac 0.40}
    xif_mem_wdata         coproc {frac 0.40}
    xif_result_valid      coproc {frac 0.45}
    xif_result_data       coproc {frac 0.45}
    xif_result_we         coproc {frac 0.45}
}

# ---- Port groups of the SoC side ----------------------------------------------------------------
set OOC_MEM_IN_BRAM  {instruction load_data_in}
set OOC_MEM_IN_VALID {instruc_mem_valid data_mem_valid}
set OOC_MEM_OUT      {instruction_mem_request instruction_mem_we_re instruc_mask_singal pc_address
                      data_mem_request data_mem_we_re mask_singal store_data_out alu_out_address load_signal}
set OOC_HOST_IN      {matrix_host_reg_we matrix_host_reg_id matrix_host_reg_row_idx matrix_host_reg_beat_idx
                      matrix_host_reg_wdata matrix_host_read_id matrix_host_read_row matrix_host_read_beat}
set OOC_HOST_OUT     {matrix_host_reg_rdata matrix_debug_mtilem matrix_debug_mtilen matrix_debug_mtilek
                      matrix_busy matrix_done}

proc ooc_t {spec period} {
    lassign $spec kind value
    if {$kind eq "frac"} { return [expr {$value * $period}] }
    return $value
}

# Ports of one design with their delay: a list of {port in|out delay_ns note}.
# design: core (Core.v, XIF = 1), coproc (matrix_xif_coproc), core_matrix (core_matrix_xif).
proc ooc_port_delays {design period} {
    global OOC_T_BRAM_CO OOC_T_BRAM_SU OOC_T_VALID OOC_T_HOST OOC_XIF
    global OOC_MEM_IN_BRAM OOC_MEM_IN_VALID OOC_MEM_OUT OOC_HOST_IN OOC_HOST_OUT
    set rows {}
    if {$design in {core core_matrix}} {
        foreach p $OOC_MEM_IN_BRAM  { lappend rows [list $p in  $OOC_T_BRAM_CO "BRAM clock-to-out"] }
        foreach p $OOC_MEM_IN_VALID { lappend rows [list $p in  $OOC_T_VALID   "valid flip-flop"] }
        foreach p $OOC_MEM_OUT      { lappend rows [list $p out $OOC_T_BRAM_SU "BRAM setup"] }
        lappend rows [list halt_hint out $OOC_T_HOST "halt detector"]
    }
    if {$design in {coproc core_matrix}} {
        foreach p $OOC_HOST_IN  { lappend rows [list $p in  $OOC_T_HOST "AXI-Lite register"] }
        foreach p $OOC_HOST_OUT { lappend rows [list $p out $OOC_T_HOST "AXI-Lite register"] }
        lappend rows [list xif_idle out $OOC_T_HOST "halt detector"]
    }
    if {$design in {core coproc}} {
        foreach {sig driver spec} $OOC_XIF {
            set t [ooc_t $spec $period]
            if {$driver eq $design} {
                lappend rows [list $sig out [expr {$period - $t}] [format "XIF, ready at %.3f ns" $t]]
            } else {
                lappend rows [list $sig in $t [format "XIF, arrives at %.3f ns" $t]]
            }
        }
    }
    return $rows
}

# Port delay commands: a list of {comment command}; -max = budget, -min = 0.
# ref_pin: clock pin the delays are relative to (empty = the clock at the port).
proc ooc_delay_cmds {design period {ref_pin ""}} {
    set ref [expr {$ref_pin eq "" ? "" : " -reference_pin \[get_pins {$ref_pin}\]"}]
    set cmds {}
    foreach r [ooc_port_delays $design $period] {
        lassign $r port dir delay note
        set cmd [expr {$dir eq "in" ? "set_input_delay" : "set_output_delay"}]
        set objs "\[get_ports -quiet {$port $port\[*\]}\]"
        lappend cmds "# $port: $note" [format "%s -clock sys_clk%s -max %.3f %s" $cmd $ref $delay $objs]
        lappend cmds "" [format "%s -clock sys_clk%s -min 0.000 %s" $cmd $ref $objs]
    }
    return $cmds
}

# XDC read before synthesis: clock, asynchronous reset, port delays relative to the clock port
# (synthesis has ideal clocks, so the reference does not matter there).
proc ooc_write_xdc {design period path} {
    set f [open $path w]
    puts $f "# Generated by fpga/kv260/ooc_budget.tcl for design '$design', period $period ns (synthesis)"
    puts $f "create_clock -name sys_clk -period $period \[get_ports clk\]"
    puts $f "set_false_path -from \[get_ports rst\]"
    foreach {comment cmd} [ooc_delay_cmds $design $period] {
        if {$comment ne ""} { puts $f $comment }
        puts $f $cmd
    }
    close $f
}

# Port delays again after synthesis, relative to ref_pin (see "Clock reference" above).
# Applies them to the open design and writes them to path. If Vivado refuses -reference_pin,
# falls back to delays at the clock port without hold checks on the ports.
# Returns a line for the run summary.
proc ooc_apply_port_delays {design period path ref_pin} {
    catch {remove_input_delay -quiet [get_ports -quiet -filter {DIRECTION == IN && NAME != clk && NAME != rst}]}
    catch {remove_output_delay -quiet [get_ports -quiet -filter {DIRECTION == OUT}]}
    set errors {}
    if {$ref_pin ne ""} {
        foreach {comment cmd} [ooc_delay_cmds $design $period $ref_pin] {
            if {[catch {eval $cmd} err]} { lappend errors $err; break }
        }
    }
    set f [open $path w]
    puts $f "# Generated by fpga/kv260/ooc_budget.tcl for design '$design', period $period ns (after synthesis)"
    if {$ref_pin ne "" && ![llength $errors]} {
        puts $f "# Delays relative to the clock at $ref_pin"
        foreach {comment cmd} [ooc_delay_cmds $design $period $ref_pin] {
            if {$comment ne ""} { puts $f $comment }
            puts $f $cmd
        }
        close $f
        return "Port delays relative to the clock at $ref_pin (same clock tree as the SoC side)."
    }
    puts "WARNING: -reference_pin not usable ([join $errors]); delays at the clock port, no hold check on ports"
    foreach {comment cmd} [ooc_delay_cmds $design $period] { eval $cmd }
    set_false_path -hold -from [get_ports -filter {DIRECTION == IN && NAME != clk && NAME != rst}]
    set_false_path -hold -to [get_ports -filter {DIRECTION == OUT}]
    puts $f "# FALLBACK: -reference_pin refused ([join $errors]); delays at the clock port"
    foreach {comment cmd} [ooc_delay_cmds $design $period] {
        if {$comment ne ""} { puts $f $comment }
        puts $f $cmd
    }
    puts $f "set_false_path -hold -from \[get_ports -filter {DIRECTION == IN && NAME != clk && NAME != rst}\]"
    puts $f "set_false_path -hold -to \[get_ports -filter {DIRECTION == OUT}\]"
    close $f
    return "FALLBACK: port delays at the clock port (inputs ~clock-tree latency too optimistic, outputs too pessimistic); no hold check on ports."
}
