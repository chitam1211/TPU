# Out-of-context Vivado flow for the CV-X-IF design, with the ports constrained by input/output
# delays (fpga/kv260/ooc_budget.tcl) instead of a registered-I/O wrapper. No bitstream.
# Target: KV260 SOM (xck26-sfvc784-2LV-c).
#
# Design (environment variable KLTN_OOC, set by run_vivado_kv260.ps1 -Ooc <design>):
#   core         rtl/core_if_xif/Core.v with XIF = 1 (the XIF logic is kept; earlier runs used XIF = 0)
#   coproc       rtl/core_matrix_xif/matrix_xif_coproc.sv: matrix_xif_adapter + matrix_core_v2
#                (rtl/matrix_if, with the files of rtl/matrix_if_xif in place of the same names)
#   core_matrix  rtl/core_matrix_xif/core_matrix_xif.sv: core + coproc; CV-X-IF timed for real,
#                only the SoC-side ports have delays (check of the budgets used by core / coproc)
#
# Usage: vivado -mode batch -source implement_ooc_xif.tcl
#          -tclargs <clock period ns> ?<mode full|synth>? ?<report dir>? ?<build dir>? ?<directive>[+retiming]?
# Reports (besides the usual ones):
#   run_summary.txt / post_synth_summary.txt   WNS, Fmax estimate, worst unit, boundary breakdown
#   boundary_ports.csv                         per port: budget, worst slack, arrival/required time
#   boundary_timing.rpt                        worst paths from the inputs and to the outputs
#   ooc_constraints_synth.xdc (build dir)      constraints for synthesis (clock, reset, port delays)
#   ooc_constraints.xdc (build dir)            port delays set again after synthesis, relative to
#                                              the clock at a flip-flop (used for implementation)
# KLTN_OOC_DCP=<post_synth.dcp>: skip synthesis and start from that checkpoint (-FromRun).

set script_dir [file dirname [file normalize [info script]]]
set kltn_root  [file normalize [file join $script_dir ../..]]
source [file join $script_dir ooc_budget.tcl]

set design ""
if {[info exists ::env(KLTN_OOC)]} { set design $::env(KLTN_OOC) }
if {[lsearch -exact {core coproc core_matrix} $design] < 0} {
    error "Set KLTN_OOC to core, coproc or core_matrix (run_vivado_kv260.ps1 -Ooc <design>), got '$design'"
}

set part_name "xck26-sfvc784-2LV-c"
set clock_period_ns 10.000
set mode full
set build_dir  [file join $kltn_root build vivado ooc_$design]
set report_dir [file join $kltn_root reports vivado ooc_$design]
if {[info exists argv] && [llength $argv] > 0} { set clock_period_ns [lindex $argv 0] }
if {[info exists argv] && [llength $argv] > 1} { set mode [lindex $argv 1] }
if {[info exists argv] && [llength $argv] > 2} { set report_dir [file normalize [lindex $argv 2]] }
if {[info exists argv] && [llength $argv] > 3} { set build_dir [file normalize [lindex $argv 3]] }
set synth_opts {}
if {[info exists argv] && [llength $argv] > 4 && [lindex $argv 4] ne ""} {
    set cfg_parts [split [lindex $argv 4] "+"]
    lappend synth_opts -directive [lindex $cfg_parts 0]
    if {[lsearch -exact [lrange $cfg_parts 1 end] retiming] >= 0} { lappend synth_opts -retiming }
}
if {[lsearch -exact {full synth} $mode] < 0} { error "Unknown mode '$mode': use full or synth" }
puts "INFO: Design: $design  mode: $mode  clock: $clock_period_ns ns"

file mkdir $build_dir
file mkdir $report_dir
cd $build_dir
if {[llength [get_parts -quiet $part_name]] == 0} {
    error "Part $part_name is unavailable. Install the Zynq UltraScale+ MPSoC/Kria device files in Vivado."
}

# ------------------------------------------------------------------ sources
proc rtl {args} { return [file join $::kltn_root rtl {*}$args] }

# rtl/core_if_xif/*.v (Core.v and its units; Microprocessor.v is read but not used)
set core_files [lsort [glob [rtl core_if_xif *.v]]]
# Matrix unit: packages first, then the other files of rtl/matrix_if, each replaced by the file
# of the same name in rtl/matrix_if_xif when there is one.
set matrix_files [list [rtl matrix_if fp32_fma_pkg.sv] [rtl matrix_if matrix_cfg_pkg.sv]]
foreach f [lsort [glob [rtl matrix_if *.sv]]] {
    set name [file tail $f]
    if {$name in {fp32_fma_pkg.sv matrix_cfg_pkg.sv}} { continue }
    set xif [rtl matrix_if_xif $name]
    lappend matrix_files [expr {[file exists $xif] ? $xif : $f}]
}
set coproc_files [concat [list [rtl core_if_xif cvxif_pkg.sv]] $matrix_files \
                         [list [rtl core_if_xif matrix_xif_adapter.sv] [rtl core_matrix_xif matrix_xif_coproc.sv]]]

switch $design {
    core        { set files $core_files;   set top_name core;            set generics {-generic XIF=1} }
    coproc      { set files $coproc_files; set top_name matrix_xif_coproc; set generics {} }
    core_matrix { set files [concat $core_files $coproc_files [list [rtl core_matrix_xif core_matrix_xif.sv]]]
                  set top_name core_matrix_xif; set generics {} }
}
set xdc_path [file join $build_dir ooc_constraints_synth.xdc]
ooc_write_xdc $design $clock_period_ns $xdc_path

# KLTN_OOC_DCP (run_vivado_kv260.ps1 -FromRun <run>): reuse the post_synth.dcp of an earlier run of
# the same design instead of synthesizing again (synthesis of core_matrix takes ~35 min).
set from_dcp ""
if {[info exists ::env(KLTN_OOC_DCP)]} { set from_dcp $::env(KLTN_OOC_DCP) }
if {$from_dcp ne ""} {
    if {![file exists $from_dcp]} { error "KLTN_OOC_DCP: no such checkpoint: $from_dcp" }
    puts "INFO: Opening synthesized checkpoint $from_dcp (synthesis skipped)"
    open_checkpoint $from_dcp
    if {[get_property TOP [current_design]] ne $top_name} {
        error "Checkpoint top is [get_property TOP [current_design]], design $design needs $top_name"
    }
    # The checkpoint keeps the clock of its own run: define it again with this run's period
    # (the port delays are set again below in any case).
    create_clock -name sys_clk -period $clock_period_ns [get_ports clk]
    set_false_path -from [get_ports rst]
} else {
    foreach f $files { if {![file exists $f]} { error "Missing source: $f" } }
    puts "INFO: Reading [llength $files] source files, top $top_name $generics"
    read_verilog -sv $files
    read_xdc $xdc_path
    puts "INFO: Constraints for synthesis: $xdc_path"
    puts "INFO: Synthesizing top=$top_name part=$part_name options: $synth_opts"
    synth_design -top $top_name -part $part_name -flatten_hierarchy rebuilt -mode out_of_context {*}$generics {*}$synth_opts
}
set clk_period [get_property PERIOD [get_clocks sys_clk]]
if {abs($clk_period - $clock_period_ns) > 0.0005} {
    error "Clock sys_clk has period $clk_period ns, this run asked for $clock_period_ns ns"
}
puts "INFO: Clock sys_clk period $clk_period ns"

# Out of context the clock has no buffer; tell the placer/timer that it comes from a global
# buffer (the first BUFGCE site of the device), as it will in the SoC.
set bufg_site [lindex [get_sites -quiet -filter {SITE_TYPE == BUFGCE}] 0]
if {$bufg_site eq "" || [catch {set_property HD.CLK_SRC $bufg_site [get_ports clk]} err]} {
    puts "WARNING: HD.CLK_SRC not set (site '$bufg_site'); clock treated as ideal at the port"
} else {
    puts "INFO: HD.CLK_SRC = $bufg_site"
}

# Port delays relative to the clock at a flip-flop of the design (ooc_budget.tcl, "Clock reference"):
# the PC register for the core side, the adapter state for the coprocessor alone.
proc ooc_reference_pin {} {
    foreach pat {u_core/u_fetchstage/u_pc0/address_out_reg[7]/C u_fetchstage/u_pc0/address_out_reg[7]/C
                 u_adapter/FSM_sequential_state_reg[0]/C} {
        set p [get_pins -quiet $pat]
        if {[llength $p]} { return [get_property NAME [lindex $p 0]] }
    }
    set p [lindex [all_registers -clock_pins] 0]
    return [expr {$p eq "" ? "" : [get_property NAME $p]}]
}
set ref_pin [ooc_reference_pin]
set xdc_path [file join $build_dir ooc_constraints.xdc]
set ref_note [ooc_apply_port_delays $design $clock_period_ns $xdc_path $ref_pin]
puts "INFO: $ref_note  Constraints: $xdc_path"

# ------------------------------------------------------------------ reports
source [file join $script_dir write_summary.tcl]

# Units for the per-unit slack table: core units as before, matrix units one level below u_matrix.
proc unit_of {pin} {
    if {[string first "/" $pin] < 0} { return "(output ports)" }
    regsub {/[^/]+$} $pin "" cell   ;# drop the pin name (.../skid_pc_reg[15]/CE -> .../skid_pc_reg[15])
    if {[regexp {^(?:u_coproc/)?u_matrix/([^/]+)/} $cell -> u]} { return "matrix/$u" }
    if {[regexp {^(?:u_coproc/)?u_matrix/} $cell]} { return "matrix (own logic)" }
    if {[regexp {^(?:u_coproc/)?u_adapter/} $cell]} { return "xif adapter" }
    if {[regexp {^u_coproc/} $cell]} { return "coproc (own logic)" }
    set in_core [expr {[regsub {^u_core/} $cell "" cell] || $::design eq "core"}]
    set i [string first "/" $cell]
    if {$i < 0} { return [expr {$in_core ? "core (own logic: skid, XIF, ...)" : "(top level)"}] }
    return [string range $cell 0 [expr {$i - 1}]]
}

proc path_prop {p name} {
    if {[catch {get_property $name $p} v]} { return "" }
    return $v
}

# Worst setup path for each kind of boundary: register->register, input->register,
# register->output, input->output.
proc boundary_breakdown {} {
    set ins  [get_ports -quiet -filter {DIRECTION == IN && NAME != clk && NAME != rst}]
    set outs [get_ports -quiet -filter {DIRECTION == OUT}]
    set regs [all_registers]
    set lines {}
    foreach {label from to} [list "register -> register" $regs $regs "input -> register" $ins $regs \
                                  "register -> output" $regs $outs "input -> output" $ins $outs] {
        if {![llength $from] || ![llength $to]} { lappend lines [format "  %-22s (none)" $label]; continue }
        set p [lindex [get_timing_paths -quiet -delay_type max -max_paths 1 -from $from -to $to] 0]
        if {$p eq ""} { lappend lines [format "  %-22s (no timed path)" $label]; continue }
        lappend lines [format "  %-22s slack %7.3f ns  %s -> %s (%s levels)" $label [get_property SLACK $p] \
            [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p] [get_property LOGIC_LEVELS $p]]
        if {$label eq "register -> register"} { set rr [get_property SLACK $p] }
    }
    # Fmax of the logic alone: the port paths depend on the assumed budgets (ooc_budget.tcl).
    set period [get_property PERIOD [get_clocks sys_clk]]
    if {[info exists rr] && $period - $rr > 0} {
        lappend lines [format "  Approximate Fmax from register -> register only: %.1f MHz" [expr {1000.0 / ($period - $rr)}]]
    }
    return [join $lines "\n"]
}

# Per port: the worst path through it. For an output, arrival = when the signal is ready at the
# port (the number to put in ooc_budget.tcl on the second pass); for an input, the path delay
# after the port tells how much of the cycle the receiving logic needs.
# used_ns = period - delay - slack: for an output, when it is ready after the clock edge at the
# flip-flops (the t of ooc_budget.tcl); for an input, how long the logic behind the port needs
# (incl. setup). arrival/required are absolute and include the clock-tree latency.
proc boundary_ports {design period csv_path} {
    set f [open $csv_path w]
    puts $f "port,dir,delay_ns,note,worst_slack_ns,used_ns,arrival_ns,required_ns,datapath_ns,levels,other_end"
    foreach r [ooc_port_delays $design $period] {
        lassign $r port dir delay note
        set ports [get_ports -quiet [list $port "$port\[*\]"]]
        if {![llength $ports]} { continue }
        if {$dir eq "in"} {
            set p [lindex [get_timing_paths -quiet -delay_type max -max_paths 1 -from $ports] 0]
        } else {
            set p [lindex [get_timing_paths -quiet -delay_type max -max_paths 1 -to $ports] 0]
        }
        if {$p eq ""} {
            puts $f [format "%s,%s,%.3f,%s,,,,,,,(no timed path)" $port $dir $delay $note]
            continue
        }
        set other [get_property [expr {$dir eq "in" ? "ENDPOINT_PIN" : "STARTPOINT_PIN"}] $p]
        set slack [get_property SLACK $p]
        puts $f [format "%s,%s,%.3f,%s,%.3f,%.3f,%s,%s,%s,%s,%s" $port $dir $delay $note $slack \
            [expr {$period - $delay - $slack}] [path_prop $p ARRIVAL_TIME] [path_prop $p REQUIRED_TIME] \
            [path_prop $p DATAPATH_DELAY] [get_property LOGIC_LEVELS $p] $other]
    }
    close $f
}

proc io_note {design period} {
    set s "== Port delays ($design) ==\n"
    append s "Every port except clk/rst has an input/output delay from fpga/kv260/ooc_budget.tcl, so\n"
    append s "port-to-flop and port-to-port paths are timed against that budget (see ooc_constraints.xdc).\n"
    append s "The XIF budgets scale with the period: the Fmax above is an estimate at this period only.\n"
    append s "$::ref_note\n"
    if {$::from_dcp ne ""} { append s "Synthesis reused from $::from_dcp\n" }
    append s "\n"
    append s "== Worst setup path per boundary kind ==\n"
    append s [boundary_breakdown]
    append s "\n\nPer port: boundary_ports.csv   Paths: boundary_timing.rpt\n"
    return $s
}

proc write_reports {stage design period report_dir} {
    report_utilization -hierarchical -file [file join $report_dir ${stage}_utilization.rpt]
    report_timing_summary -delay_type max -max_paths 30 -file [file join $report_dir ${stage}_timing_summary.rpt]
    set ins  [get_ports -quiet -filter {DIRECTION == IN && NAME != clk && NAME != rst}]
    set outs [get_ports -quiet -filter {DIRECTION == OUT}]
    set rpt [file join $report_dir boundary_timing.rpt]
    report_timing -delay_type max -max_paths 20 -nworst 1 -from $ins -file $rpt
    report_timing -delay_type max -max_paths 20 -nworst 1 -to $outs -file $rpt -append
    boundary_ports $design $period [file join $report_dir boundary_ports.csv]
}

set note "(out-of-context, design $design, port delays from ooc_budget.tcl, no RAMs)"
write_checkpoint -force [file join $build_dir post_synth.dcp]
write_reports post_synth $design $clock_period_ns $report_dir

if {$mode eq "synth"} {
    set summary_path [file join $report_dir post_synth_summary.txt]
    write_run_summary $summary_path "$note POST-SYNTHESIS ESTIMATE, not routed" [io_note $design $clock_period_ns]
    puts "INFO: Completed (synthesis only). Summary: $summary_path"
    exit
}

puts "INFO: Running implementation for routed timing"
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $build_dir post_route.dcp]

write_reports post_route $design $clock_period_ns $report_dir
report_timing_summary -delay_type min_max -max_paths 50 -report_unconstrained \
    -file [file join $report_dir post_route_timing_summary.rpt]
report_route_status -file [file join $report_dir post_route_status.rpt]
report_clock_utilization -file [file join $report_dir clock_utilization.rpt]

set summary_path [file join $report_dir run_summary.txt]
write_run_summary $summary_path $note [io_note $design $clock_period_ns]
puts "INFO: Completed. Summary: $summary_path"
exit
