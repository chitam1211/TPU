# One configuration of the synthesis sweep (scripts/run_vivado_kv260.ps1 -Mode sweep).
# The runner starts a NEW Vivado session for every configuration: several synth_design runs
# in one session influenced each other (a directive run alone gave -0.45 ns, the same directive
# after others in one session gave -5.1 ns), so results are only comparable across sessions.
# Same design and constraint as implement_core_if.tcl (core_timing_wrap, out-of-context,
# xck26-sfvc784-2LV-c, one clock). Timing here is the post-synthesis ESTIMATE (no placement,
# wire delays guessed from fanout); routed timing (mode full) decides Fmax.
# Usage: vivado -mode batch -source synth_sweep.tcl
#          -tclargs <clock ns> <config> ?<sweep report dir>? ?<build dir>?
#   <config>: "<directive>" or "<directive>+retiming". Directives are case-sensitive; Vivado 2022.2
#   accepts (list_property_value STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE): default runtimeoptimized
#   AreaOptimized_high AreaOptimized_medium AlternateRoutability AreaMapLargeShiftRegToBRAM
#   AreaMultThresholdDSP FewerCarryChains PerformanceOptimized LogicCompaction
#   PowerOptimized_high PowerOptimized_medium (the last two are not in help synth_design)
# Writes <sweep report dir>/<config>/ and appends one row to <sweep report dir>/rows.csv.
# The runner gives every sweep its own folder (reports/vivado/runs/<time>_sweep_<clock>ns).

set script_dir [file dirname [file normalize [info script]]]
set kltn_root  [file normalize [file join $script_dir ../..]]
set rtl_dir    [file join $kltn_root rtl core_if]
set build_dir  [file join $kltn_root build vivado kv260_synth_sweep]
set sweep_dir  [file join $kltn_root reports vivado kv260_synth_sweep]
set part_name  "xck26-sfvc784-2LV-c"
set top_name   "core_timing_wrap"

if {![info exists argv] || [llength $argv] < 2} {
    error "usage: -tclargs <clock ns> <directive>\[+retiming\] ?<report dir>? ?<build dir>?"
}
set clock_period_ns [lindex $argv 0]
set cfg [lindex $argv 1]
if {[llength $argv] > 2} { set sweep_dir [file normalize [lindex $argv 2]] }
if {[llength $argv] > 3} { set build_dir [file normalize [lindex $argv 3]] }
set parts [split $cfg "+"]
set directive [lindex $parts 0]
set retiming [expr {[lsearch -exact [lrange $parts 1 end] retiming] >= 0}]
set name [string map {+ _} $cfg]
set out_dir [file join $sweep_dir $name]
file mkdir $build_dir
file mkdir $out_dir
cd $build_dir
source [file join $script_dir write_summary.tcl]

set xdc_path [file join $build_dir clock.xdc]
set xdc_file [open $xdc_path w]
puts $xdc_file "create_clock -name sys_clk -period $clock_period_ns \[get_ports clk\]"
close $xdc_file
read_verilog -sv [lsort [glob -nocomplain [file join $rtl_dir *.v]]] [file join $script_dir core_timing_wrap.v]
read_xdc $xdc_path

puts "INFO: ===== $cfg (directive $directive, retiming [expr {$retiming ? "on" : "off"}]) ====="
set opts [list -top $top_name -part $part_name -flatten_hierarchy rebuilt -mode out_of_context \
          -directive $directive]
if {$retiming} { lappend opts -retiming }
set t0 [clock seconds]
synth_design {*}$opts
set secs [expr {[clock seconds] - $t0}]

report_utilization -hierarchical -file [file join $out_dir post_synth_utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 -file [file join $out_dir post_synth_timing_summary.rpt]
write_run_summary [file join $out_dir summary.txt] \
    "(synth_design -directive $directive[expr {$retiming ? " -retiming" : ""}]; POST-SYNTHESIS ESTIMATE, not routed)"

set worst [lindex [get_timing_paths -delay_type max -max_paths 1] 0]
lassign [failing_stats max] nfail tns
set util [report_utilization -return_string]
set row [list $cfg [format %.3f [get_property SLACK $worst]] [format %.3f $tns] $nfail \
    [util_count $util {CLB LUTs}] [util_count $util {CLB Registers}] [util_count $util {CARRY8}] \
    [util_count $util {DSPs}] [get_property LOGIC_LEVELS $worst] $secs]
set f [open [file join $sweep_dir rows.csv] a]
puts $f [join $row ","]
close $f
puts "INFO: Completed $cfg. Reports: $out_dir"
exit
