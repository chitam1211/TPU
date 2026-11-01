# Synthesis + implementation sweep of the RV32IF core (scripts/run_vivado_kv260.ps1 -Mode fullsweep).
# PROJECT mode: the synthesis and implementation strategies are the preconfigured ones of
# Vivado 2022.2 (UG901 "Vivado Preconfigured Strategies", UG904 "Implementation Categories,
# Strategy Descriptions, and Directive Mapping"), applied by Vivado itself instead of being
# re-typed as directives. Every run is a separate Vivado process (launch_runs), so runs do not
# influence each other the way several synth_design calls in one session did.
# Same design and constraint as implement_core_if.tcl: core_timing_wrap, out-of-context,
# xck26-sfvc784-2LV-c, one clock.
#   Stage 1: every synthesis configuration, each followed by the default implementation.
#   Stage 2: the best stage-1 synthesis (routed WNS, then TNS), or the ones named in the plan,
#            with every implementation strategy of the plan.
# Usage: vivado -mode batch -source full_sweep.tcl -tclargs <clock ns> <plan file> <report dir> <build dir>
# Plan file (written by the runner), one entry per line:
#   jobs <n>             parallel runs
#   synth <config>       "<strategy or directive>[+retiming]"; default = Vivado Synthesis Defaults;
#                        a synth_design directive name runs the default strategy with that directive
#   impl <strategy>      implementation strategy; default = Vivado Implementation Defaults
#   base auto|top<n>|<config>   synthesis configuration(s) for stage 2 (auto = top1)
#   resume <sweep.xpr>   continue an earlier sweep project: runs that already completed are kept,
#                        unfinished or failed ones are reset and launched again
# Output in <report dir>: rows.csv, full_sweep_summary.txt, and <synth>__<impl>/ per routed run
# (timing summary, utilization, summary.txt). Project and run folders go to <build dir>/proj.

set script_dir [file dirname [file normalize [info script]]]
set kltn_root  [file normalize [file join $script_dir ../..]]
set rtl_dir    [file join $kltn_root rtl core_if]
set part_name  "xck26-sfvc784-2LV-c"
set top_name   "core_timing_wrap"

if {![info exists argv] || [llength $argv] < 4} {
    error "usage: -tclargs <clock ns> <plan file> <report dir> <build dir>"
}
lassign $argv clock_period_ns plan_path report_dir build_dir
set report_dir [file normalize $report_dir]
set build_dir  [file normalize $build_dir]
file mkdir $report_dir $build_dir
cd $build_dir
source [file join $script_dir write_summary.tcl]

set jobs 2
set synth_cfgs {}
set impl_cfgs {}
set base auto
set resume ""
set f [open $plan_path r]
foreach line [split [read $f] "\n"] {
    set line [string trim $line]
    if {$line eq "" || [string index $line 0] eq "#"} { continue }
    # Split with regexp, not as a Tcl list: list parsing would turn the backslashes of a
    # Windows path into escapes.
    regexp {^(\S+)\s*(.*)$} $line -> key val
    switch -- $key {
        jobs  { set jobs $val }
        synth { lappend synth_cfgs $val }
        impl  { lappend impl_cfgs $val }
        base  { set base $val }
        resume { set resume $val }
        default { error "plan: unknown entry '$line'" }
    }
}
close $f
puts "INFO: [llength $synth_cfgs] synthesis configurations, [llength $impl_cfgs] implementation strategies, base $base, jobs $jobs"

# ---- Project ------------------------------------------------------------------------------
# Vivado 2022.2 runs Tcl 8.5: no lmap or other 8.6 commands in this file.
if {$resume ne ""} {
    puts "INFO: resuming project $resume"
    open_project $resume
} else {
    create_project -force sweep [file join $build_dir proj] -part $part_name
    set rtl_files [lsort [glob -nocomplain [file join $rtl_dir *.v]]]
    add_files -norecurse [concat $rtl_files [list [file join $script_dir core_timing_wrap.v]]]
    set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1]]
    set_property top $top_name [get_filesets sources_1]
    set xdc_path [file join $build_dir clock.xdc]
    set xf [open $xdc_path w]
    puts $xf "create_clock -name sys_clk -period $clock_period_ns \[get_ports clk\]"
    close $xf
    add_files -fileset constrs_1 -norecurse $xdc_path
    update_compile_order -fileset sources_1
}

set synth_flow [get_property FLOW [get_runs synth_1]]
set impl_flow  [get_property FLOW [get_runs impl_1]]
set synth_strategies [list_property_value STRATEGY [get_runs synth_1]]
set impl_strategies  [list_property_value STRATEGY [get_runs impl_1]]
set synth_directives [list_property_value STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE [get_runs synth_1]]
puts "INFO: flows: $synth_flow / $impl_flow"

proc sanitize {s} { return [regsub -all {[^A-Za-z0-9]+} $s "_"] }

# "<name>[+retiming]" -> {strategy directive retiming}; errors on unknown names before anything runs.
proc parse_synth {cfg} {
    global synth_strategies synth_directives
    set parts [split $cfg "+"]
    set name [lindex $parts 0]
    set retiming [expr {[lsearch -exact [lrange $parts 1 end] retiming] >= 0}]
    if {[string tolower $name] eq "default"} {
        return [list "Vivado Synthesis Defaults" "" $retiming]
    }
    if {[lsearch -exact $synth_strategies $name] >= 0} { return [list $name "" $retiming] }
    if {[lsearch -exact $synth_directives $name] >= 0} {
        return [list "Vivado Synthesis Defaults" $name $retiming]
    }
    error "Unknown synthesis configuration '$cfg'.\nStrategies: [join $synth_strategies {, }]\nDirectives: [join $synth_directives {, }]"
}

proc impl_strategy {name} {
    global impl_strategies
    if {[string tolower $name] eq "default"} { return "Vivado Implementation Defaults" }
    if {[lsearch -exact $impl_strategies $name] >= 0} { return $name }
    error "Unknown implementation strategy '$name'.\nStrategies: [join $impl_strategies {, }]"
}

foreach c $synth_cfgs { parse_synth $c }
foreach c $impl_cfgs { impl_strategy $c }

# synth config -> synth run name
set synth_run [dict create]
set n 0
foreach cfg $synth_cfgs {
    lassign [parse_synth $cfg] strategy directive retiming
    set name [format "s%02d_%s" [incr n] [sanitize $cfg]]
    dict set synth_run $cfg $name
    if {[llength [get_runs -quiet $name]]} { puts "INFO: $name : kept from the earlier sweep"; continue }
    create_run -flow $synth_flow -strategy $strategy -constrset constrs_1 $name
    set r [get_runs $name]
    if {$directive ne ""} { set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE $directive $r }
    # Out-of-context like the non-project flow; -retiming as a plain synth_design option.
    set more [string trim "[get_property {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} $r] -mode out_of_context"]
    if {$retiming} { append more " -retiming" }
    set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value $more -objects $r
    puts "INFO: $name : strategy '$strategy'[expr {$directive ne "" ? ", directive $directive" : ""}], options '$more'"
}

set rows_path [file join $report_dir rows.csv]
set rf [open $rows_path w]
puts $rf "stage,synth,impl,status,WNS_ns,TNS_ns,setup_fail,WHS_ns,THS_ns,hold_fail,Fmax_MHz,LUTs,FFs,CARRY8,DSPs,worst_path_levels,worst_path"
close $rf
set results {}

proc run_ok {r} {
    return [expr {[get_property PROGRESS $r] eq "100%" && ![string match -nocase "*error*" [get_property STATUS $r]]}]
}

# Launch the given runs, wait for all of them; a failed launch or run is reported, not fatal.
proc launch_and_wait {runs} {
    global jobs
    set todo {}
    foreach r $runs {
        if {[run_ok [get_runs $r]]} { puts "INFO: $r already complete"; continue }
        if {[get_property PROGRESS [get_runs $r]] ne "0%"} { reset_run $r }
        lappend todo $r
    }
    if {![llength $todo]} { return }
    puts "INFO: launching [llength $todo] runs, $jobs at a time: [join $todo { }]"
    if {[catch {launch_runs $todo -jobs $jobs} err]} { puts "WARNING: launch_runs: $err" }
    foreach r $runs {
        if {[catch {wait_on_run $r} err]} { puts "WARNING: wait_on_run $r: $err" }
        puts "INFO: [clock format [clock seconds] -format %H:%M:%S] $r: [get_property STATUS [get_runs $r]]"
    }
}

# Reports of one routed run and one CSV row; returns {stage synth impl status wns tns}.
proc collect {stage cfg impl r} {
    global report_dir rows_path clock_period_ns
    set label "[sanitize $cfg]__[sanitize $impl]"
    set row [list $stage $cfg $impl]
    if {![run_ok [get_runs $r]]} {
        set status "ERROR: [get_property STATUS [get_runs $r]] (see [get_property DIRECTORY [get_runs $r]]/runme.log)"
        set rf [open $rows_path a]
        puts $rf [join [concat $row [list "\"$status\""]] ","]
        close $rf
        return [list $stage $cfg $impl $status "" ""]
    }
    set out [file join $report_dir $label]
    file mkdir $out
    open_run $r -name $r
    report_utilization -hierarchical -file [file join $out post_route_utilization.rpt]
    report_timing_summary -delay_type min_max -max_paths 20 -file [file join $out post_route_timing_summary.rpt]
    write_run_summary [file join $out summary.txt] "(synthesis $cfg, implementation $impl; out-of-context, registered-I/O wrapper)"
    set setup [lindex [get_timing_paths -delay_type max -max_paths 1] 0]
    set hold  [lindex [get_timing_paths -delay_type min -max_paths 1] 0]
    set wns [get_property SLACK $setup]
    lassign [failing_stats max] sfail tns
    lassign [failing_stats min] hfail ths
    set util [report_utilization -return_string]
    set fmax [expr {$clock_period_ns - $wns > 0 ? [format %.1f [expr {1000.0 / ($clock_period_ns - $wns)}]] : ""}]
    set worst "[unit_of [get_property STARTPOINT_PIN $setup]] -> [unit_of [get_property ENDPOINT_PIN $setup]]"
    lappend row ok [format %.3f $wns] [format %.3f $tns] $sfail [format %.3f [get_property SLACK $hold]] \
        [format %.3f $ths] $hfail $fmax [util_count $util {CLB LUTs}] [util_count $util {CLB Registers}] \
        [util_count $util {CARRY8}] [util_count $util {DSPs}] [get_property LOGIC_LEVELS $setup] "\"$worst\""
    set rf [open $rows_path a]
    puts $rf [join $row ","]
    close $rf
    close_design
    puts "INFO: $cfg / $impl : WNS [format %.3f $wns] ns, TNS [format %.3f $tns] ns, Fmax $fmax MHz"
    return [list $stage $cfg $impl ok $wns $tns]
}

# A report that fails for one run must not stop the rest of an overnight sweep.
proc safe_collect {stage cfg impl r} {
    global rows_path
    if {![catch {collect $stage $cfg $impl $r} res]} { return $res }
    puts "WARNING: reports of $r failed: $res"
    catch {close_design}
    set status "ERROR: reports failed: [string map {\" ' \n " "} $res]"
    set rf [open $rows_path a]
    puts $rf "$stage,$cfg,$impl,\"$status\""
    close $rf
    return [list $stage $cfg $impl $status "" ""]
}

# ---- Stage 1: every synthesis configuration + default implementation -----------------------
set t0 [clock seconds]
launch_and_wait [dict values $synth_run]
set stage1 {}
dict for {cfg s} $synth_run {
    if {![run_ok [get_runs $s]]} {
        puts "WARNING: synthesis $cfg failed: [get_property STATUS [get_runs $s]]"
        lappend results [list 1 $cfg default "ERROR: synthesis failed (see [get_property DIRECTORY [get_runs $s]]/runme.log)" "" ""]
        set rf [open $rows_path a]
        puts $rf "1,$cfg,default,\"ERROR: synthesis failed\""
        close $rf
        continue
    }
    set i "${s}_impl_default"
    if {![llength [get_runs -quiet $i]]} {
        create_run -flow $impl_flow -parent_run $s -strategy "Vivado Implementation Defaults" $i
    }
    lappend stage1 [list $cfg $i]
}
set runs {}
foreach x $stage1 { lappend runs [lindex $x 1] }
launch_and_wait $runs
foreach x $stage1 {
    lassign $x cfg i
    lappend results [safe_collect 1 $cfg default $i]
}

# ---- Stage 2: base synthesis configuration(s) x implementation strategies ------------------
set ranked [lsort -decreasing -real -index 4 [lsort -decreasing -real -index 5 \
    [lsearch -all -inline -index 3 $results ok]]]
if {$base eq "auto"} { set base top1 }
if {[regexp {^top([0-9]+)$} $base -> k]} {
    set bases {}
    foreach x [lrange $ranked 0 [expr {$k - 1}]] { lappend bases [lindex $x 1] }
} else {
    set bases [regexp -all -inline {[^,\s]+} $base]
}
puts "INFO: stage 2 synthesis base: [join $bases {, }]"
set stage2 {}
foreach cfg $bases {
    if {![dict exists $synth_run $cfg]} { puts "WARNING: base '$cfg' is not a stage-1 configuration, skipped"; continue }
    set s [dict get $synth_run $cfg]
    if {![run_ok [get_runs $s]]} { continue }
    foreach impl $impl_cfgs {
        set strategy [impl_strategy $impl]
        if {$strategy eq "Vivado Implementation Defaults"} { continue }  ;# done in stage 1
        set i "${s}_impl_[sanitize $impl]"
        if {![llength [get_runs -quiet $i]]} {
            create_run -flow $impl_flow -parent_run $s -strategy $strategy $i
        }
        lappend stage2 [list $cfg $impl $i]
    }
}
set runs {}
foreach x $stage2 { lappend runs [lindex $x 2] }
launch_and_wait $runs
foreach x $stage2 {
    lassign $x cfg impl i
    lappend results [safe_collect 2 $cfg $impl $i]
}

# ---- Summary ---------------------------------------------------------------------------------
set mins [expr {([clock seconds] - $t0) / 60}]
set sf [open [file join $report_dir full_sweep_summary.txt] w]
puts $sf "Synthesis + implementation sweep: $top_name, $part_name, clock $clock_period_ns ns, Vivado [version -short]"
puts $sf "Project mode, preconfigured strategies (UG901 / UG904). Routed timing. $mins min, $jobs parallel runs."
puts $sf "Stage 1: each synthesis configuration + Vivado Implementation Defaults."
puts $sf "Stage 2: synthesis [join $bases {, }] + each implementation strategy."
set fmt "%-5s %-34s %-36s %8s %10s %10s"
foreach stage {1 2} {
    puts $sf ""
    puts $sf "== Stage $stage (best routed WNS first) =="
    puts $sf [format $fmt stage synthesis implementation "WNS(ns)" "TNS(ns)" "Fmax(MHz)"]
    set ok [lsearch -all -inline -index 3 [lsearch -all -inline -index 0 $results $stage] ok]
    foreach r [lsort -decreasing -real -index 4 $ok] {
        lassign $r st cfg impl status wns tns
        set fmax [expr {$clock_period_ns - $wns > 0 ? [format %.1f [expr {1000.0 / ($clock_period_ns - $wns)}]] : "-"}]
        puts $sf [format $fmt $st $cfg $impl [format %.3f $wns] [format %.3f $tns] $fmax]
    }
    foreach r [lsearch -all -inline -index 0 $results $stage] {
        if {[lindex $r 3] ne "ok"} { puts $sf [format "%-5s %-34s %-36s %s" {*}[lrange $r 0 3]] }
    }
}
puts $sf ""
puts $sf "Every column (failing endpoints, hold, LUT/FF/CARRY8/DSP, worst path): rows.csv"
puts $sf "Per-run reports: $report_dir/<synthesis>__<implementation>/"
close $sf
puts "INFO: Completed in $mins min. Summary: [file join $report_dir full_sweep_summary.txt]"
exit
