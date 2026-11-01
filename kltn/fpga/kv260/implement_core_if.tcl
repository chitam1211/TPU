# Non-project Vivado flow for the RV32IF core (pipeline + FPU): synthesis, then
# opt/place/phys_opt/route and reports. No bitstream is generated.
# Target: KV260 SOM (xck26-sfvc784-2LV-c), out-of-context.
# Top is core_timing_wrap: `core` with every data port registered, so the
# memory-interface paths are timed (`microprocessor` has no outputs and would
# be optimized away entirely).
# Usage: vivado -mode batch -source implement_core_if.tcl
#          -tclargs <clock period in ns> ?<mode>? ?<report dir>? ?<build dir>? ?<directive>[+retiming]?
# scripts/run_vivado_kv260.ps1 passes a new pair of folders for every run
# (reports/vivado/runs/<time>_<mode>_<clock>ns and build/vivado/runs/<same>), so runs never
# overwrite each other. Without them the old shared folders */vivado/kv260_core_if are used.
# Modes:
#   full     (default) synthesis + implementation, reports after synthesis and after routing
#   synth    synthesis only: post-synthesis reports and a summary with estimated timing
#   netlist  synthesis of `core` itself (no wrapper, same options) and a functional
#            simulation netlist for xsim: <build dir>/netlist/core_funcsim.v
#            (the wrapper would add a cycle to the memory handshake the testbench expects)

set script_dir [file dirname [file normalize [info script]]]
set kltn_root  [file normalize [file join $script_dir ../..]]
set rtl_dir    [file join $kltn_root rtl core_if]
set build_dir  [file join $kltn_root build vivado kv260_core_if]
set report_dir [file join $kltn_root reports vivado kv260_core_if]

set part_name "xck26-sfvc784-2LV-c"
set top_name "core_timing_wrap"
# The only place the clock constraint is defined (a clock.xdc is generated below).
set clock_period_ns 10.000
set mode full
if {[info exists argv] && [llength $argv] > 0} { set clock_period_ns [lindex $argv 0] }
if {[info exists argv] && [llength $argv] > 1} { set mode [lindex $argv 1] }
if {[info exists argv] && [llength $argv] > 2} { set report_dir [file normalize [lindex $argv 2]] }
if {[info exists argv] && [llength $argv] > 3} { set build_dir [file normalize [lindex $argv 3]] }
# Optional 5th argument: synthesis configuration "<directive>[+retiming]" (default: Vivado's default).
set synth_cfg ""
if {[info exists argv] && [llength $argv] > 4} { set synth_cfg [lindex $argv 4] }
set synth_opts {}
if {$synth_cfg ne ""} {
    set cfg_parts [split $synth_cfg "+"]
    lappend synth_opts -directive [lindex $cfg_parts 0]
    if {[lsearch -exact [lrange $cfg_parts 1 end] retiming] >= 0} { lappend synth_opts -retiming }
}
if {[lsearch -exact {full synth netlist} $mode] < 0} {
    error "Unknown mode '$mode': use full, synth or netlist"
}
if {$mode eq "netlist"} { set top_name "core" }
puts "INFO: Mode: $mode"

file mkdir $build_dir
file mkdir $report_dir
cd $build_dir

set available_part [get_parts -quiet $part_name]
if {[llength $available_part] == 0} {
    error "Part $part_name is unavailable. Install the Zynq UltraScale+ MPSoC/Kria device files in Vivado."
}

set rtl_files [lsort [glob -nocomplain [file join $rtl_dir *.v]]]
if {[llength $rtl_files] == 0} {
    error "No Verilog sources found under $rtl_dir"
}

puts "INFO: Reading [llength $rtl_files] RTL files from $rtl_dir"
read_verilog -sv $rtl_files [file join $script_dir core_timing_wrap.v]
# Timing-only constraint. Pin locations and I/O standards are omitted because
# this flow stops after routing and does not generate a bitstream.
set xdc_path [file join $build_dir clock.xdc]
set xdc_file [open $xdc_path w]
puts $xdc_file "create_clock -name sys_clk -period $clock_period_ns \[get_ports clk\]"
close $xdc_file
read_xdc $xdc_path
puts "INFO: Clock constraint: $clock_period_ns ns"

puts "INFO: Synthesizing top=$top_name part=$part_name options: $synth_opts"
synth_design -top $top_name -part $part_name -flatten_hierarchy rebuilt -mode out_of_context {*}$synth_opts

source [file join $script_dir write_summary.tcl]

if {$mode eq "netlist"} {
    # Functional netlist (UNISIM primitives, no delays) for post-synthesis simulation.
    set netlist_dir [file join $build_dir netlist]
    file mkdir $netlist_dir
    write_checkpoint -force [file join $netlist_dir post_synth_core.dcp]
    write_verilog -force -mode funcsim [file join $netlist_dir core_funcsim.v]
    report_utilization -hierarchical -file [file join $report_dir post_synth_core_utilization.rpt]
    puts "INFO: Completed. Netlist: [file join $netlist_dir core_funcsim.v]"
    puts "INFO: Utilization of core alone: [file join $report_dir post_synth_core_utilization.rpt]"
    exit
}

write_checkpoint -force [file join $build_dir post_synth.dcp]
report_utilization -hierarchical -file [file join $report_dir post_synth_utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 -file [file join $report_dir post_synth_timing_summary.rpt]

if {$mode eq "synth"} {
    set summary_path [file join $report_dir post_synth_summary.txt]
    write_run_summary $summary_path "(out-of-context, registered-I/O wrapper around core, no RAMs; POST-SYNTHESIS ESTIMATE, not routed)"
    puts "INFO: Completed (synthesis only). Reports are in $report_dir"
    puts "INFO: Summary: $summary_path"
    exit
}

puts "INFO: Running implementation for routed timing"
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $build_dir post_route.dcp]

report_utilization -hierarchical -file [file join $report_dir post_route_utilization.rpt]
report_timing_summary -delay_type min_max -max_paths 50 -report_unconstrained -file [file join $report_dir post_route_timing_summary.rpt]
report_route_status -file [file join $report_dir post_route_status.rpt]
report_clock_utilization -file [file join $report_dir clock_utilization.rpt]

set summary_path [file join $report_dir run_summary.txt]
write_run_summary $summary_path "(out-of-context, registered-I/O wrapper around core, no RAMs)"

puts "INFO: Completed. Reports are in $report_dir"
puts "INFO: Summary: $summary_path"
exit

