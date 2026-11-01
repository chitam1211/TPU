# Human-readable timing/utilization digest of the routed design that is currently open.
# Usage: source write_summary.tcl; write_run_summary <file> ?<note>?

proc unit_of {pin} {
    # Skip the wrapper level so units read u_fp_mul, u_decodestage, ...
    regsub {^u_core/} $pin "" pin
    set i [string first "/" $pin]
    if {$i < 0} { return "(core top-level logic)" }
    return [string range $pin 0 [expr {$i - 1}]]
}

proc describe_path {p} {
    return [format "%s -> %s\n      slack %.3f ns, %s logic levels, data path %.3f ns" \
        [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p] \
        [get_property SLACK $p] [get_property LOGIC_LEVELS $p] [get_property DATAPATH_DELAY $p]]
}

# Worst slack of the unique endpoints that fail: {count TNS}.
proc failing_stats {delay} {
    set paths [get_timing_paths -quiet -delay_type $delay -max_paths 20000 -unique_pins -slack_lesser_than 0]
    set tns 0.0
    foreach p $paths { set tns [expr {$tns + [get_property SLACK $p]}] }
    return [list [llength $paths] $tns]
}

proc util_count {util label} {
    if {[regexp "\\|\\s*${label}\\*?\\s*\\|\\s*(\[0-9\]+)\\s*\\|" $util -> n]} { return $n }
    return "n/a"
}

proc write_run_summary {summary_path {note ""}} {
    set setup [lindex [get_timing_paths -delay_type max -max_paths 1] 0]
    set hold  [lindex [get_timing_paths -delay_type min -max_paths 1] 0]
    set wns [get_property SLACK $setup]
    set whs [get_property SLACK $hold]
    lassign [failing_stats max] setup_fail tns
    lassign [failing_stats min] hold_fail ths
    set clk [get_clocks -quiet sys_clk]
    set period [expr {[llength $clk] ? [get_property PERIOD $clk] : 0.0}]

    set f [open $summary_path "w"]
    puts $f "Vivado: [version -short]"
    puts $f "Part: [get_property PART [current_design]]"
    puts $f "Top: [get_property TOP [current_design]]  $note"
    puts $f [format "Target clock: %.3f ns (%.3f MHz)" $period [expr {$period > 0 ? 1000.0 / $period : 0}]]
    puts $f ""
    puts $f "== Setup (max delay, worst corner) =="
    puts $f [format "WNS: %.3f ns   TNS: %.3f ns   failing endpoints: %d" $wns $tns $setup_fail]
    puts $f "Worst path: [describe_path $setup]"
    if {$period > 0 && $period - $wns > 0} {
        puts $f [format "Approximate Fmax: %.1f MHz (from WNS at the target clock; tighten the clock to measure it)" \
            [expr {1000.0 / ($period - $wns)}]]
    }
    puts $f ""
    puts $f "== Hold (min delay, worst corner) =="
    puts $f [format "WHS: %.3f ns   THS: %.3f ns   failing endpoints: %d" $whs $ths $hold_fail]
    puts $f "Worst path: [describe_path $hold]"
    puts $f ""
    puts $f "== Worst setup slack per unit (endpoint hierarchy) =="
    set worst [dict create]
    set count [dict create]
    foreach p [get_timing_paths -quiet -delay_type max -max_paths 20000 -unique_pins] {
        set s [get_property SLACK $p]
        if {![string is double -strict $s]} { continue }
        set u [unit_of [get_property ENDPOINT_PIN $p]]
        if {![dict exists $worst $u] || $s < [dict get $worst $u]} { dict set worst $u $s }
        dict incr count $u
    }
    set rows {}
    dict for {u s} $worst { lappend rows [list $u $s [dict get $count $u]] }
    puts $f [format "%-26s %12s %10s" unit "slack (ns)" endpoints]
    foreach r [lrange [lsort -real -index 1 $rows] 0 11] {
        puts $f [format "%-26s %12.3f %10d" [lindex $r 0] [lindex $r 1] [lindex $r 2]]
    }
    puts $f ""
    puts $f "== Utilization =="
    set util [report_utilization -return_string]
    puts $f "LUTs: [util_count $util {CLB LUTs}]   FFs: [util_count $util {CLB Registers}]   DSPs: [util_count $util {DSPs}]   BRAM tiles: [util_count $util {Block RAM Tile}]"
    puts $f ""
    puts $f "== Not timed =="
    puts $f "Chip port <-> boundary flip-flop: [llength [all_inputs]] inputs (incl. clk/rst) and [llength [all_outputs]] outputs have no input/output delay constraint,"
    puts $f "because the logic outside the core is unknown out-of-context. These hops contain no logic (port -> flop or flop -> port),"
    puts $f "so they do not limit Fmax here; everything behind the boundary flops is timed above."
    close $f
}
