# =============================================================================
# Vivado 2022.2 project + block design for rv32if_xif_soc (rtl/core_matrix_xif/rv32if_xif_soc.v):
#
#   Zynq UltraScale+ PS --M_AXI_HPM0_FPD (32 bit)--> SmartConnect --+--> rvm/s_axi       (registers)
#                                                                    +--> imem_ctrl/S_AXI --> imem_bram port A
#                                                                    +--> dmem_ctrl/S_AXI --> dmem_bram port A
#   rvm (module reference rv32if_xif_soc): IMEM --> imem_bram port B, DMEM --> dmem_bram port B
#   rvm/irq --> ps/pl_ps_irq0[0] (GIC SPI 121, level high)
#   pl_clk0 clocks everything; pl_resetn0 -> proc_sys_reset -> every aresetn
#
# Address map seen by the PS:
#   0xA000_0000   4 KB  rvm        control registers (docs/soc_xif_ngat_halt.pdf, section 9)
#   0xA001_0000  16 KB  imem_ctrl  IMEM (true dual-port BRAM, port A; the core fetches on port B)
#   0xA002_0000  64 KB  dmem_ctrl  DMEM (true dual-port BRAM, port A; the core loads/stores on port B)
#
# Normally started by scripts/run_vivado_soc_xif.ps1 (scripts/run_vivado_soc_xif.sh from WSL):
#   vivado -mode batch -source build_soc_xif.tcl -tclargs <mhz> <mode> <report_dir> <build_dir> <board> <strategy>
#     mhz         pl_clk0 in MHz (default 100)
#     mode        full: synthesis, implementation, bitstream, .bit/.bin/.hwh/.xsa (default)
#                 impl: synthesis + implementation + reports, no bitstream
#                 bd:   project + block design only (open build_dir/proj/soc.xpr in the GUI)
#     report_dir  soc_summary.txt, address_map.txt, *.rpt (default fpga/soc_xif/build/reports)
#     build_dir   project (proj/) and board files (out/) (default fpga/soc_xif/build)
#     board       kr260 (default) or kv260: board file of the K26 SOM for the PS preset (DDR, UART)
#     strategy    implementation strategy, "default" = Vivado Implementation Defaults
#
# IMEM / DMEM size: imem_kb / dmem_kb below. They set the BRAM controller ranges (and so the
# BRAM depth) and the IMEM_AW / DMEM_AW parameters of rv32if_xif_soc together.
# =============================================================================
set clk_mhz    100
set mode       full
set report_dir ""
set build_dir  ""
set board      kr260
set strategy   default
foreach {i var} {0 clk_mhz 1 mode 2 report_dir 3 build_dir 4 board 5 strategy} {
    if {[llength $argv] > $i && [lindex $argv $i] ne ""} { set $var [lindex $argv $i] }
}
if {$mode ni {full impl bd}} { error "mode must be full, impl or bd, got '$mode'" }
if {$board ni {kr260 kv260}} { error "board must be kr260 or kv260, got '$board'" }

set imem_kb 16
set dmem_kb 64
set base_regs 0xA0000000
set base_imem 0xA0010000
set base_dmem 0xA0020000

set soc_dir   [file normalize [file join [file dirname [info script]] ..]]
set kltn_root [file normalize [file join $soc_dir .. ..]]
if {$build_dir eq ""}  { set build_dir  [file join $soc_dir build] }
if {$report_dir eq ""} { set report_dir [file join $build_dir reports] }
set build_dir  [file normalize $build_dir]
set report_dir [file normalize $report_dir]
set proj_dir   [file join $build_dir proj]
set out_dir    [file join $build_dir out]
set proj_name  soc
set bd_name    system
file mkdir $report_dir $out_dir

proc rtl {args} { return [file join $::kltn_root rtl {*}$args] }
proc log2 {n} { set k 0; while {(1 << $k) < $n} { incr k }; if {(1 << $k) != $n} { error "$n is not a power of 2" }; return $k }
set imem_aw [log2 [expr {$imem_kb * 1024}]]
set dmem_aw [log2 [expr {$dmem_kb * 1024}]]

# ------------------------------------------------------------------ RTL sources
# Same set as tb/soc_xif/run.sh and fpga/kv260/implement_ooc_xif.tcl (design core_matrix):
# rtl/core_if_xif/*.v without Microprocessor.v, rtl/matrix_if/*.sv with the files of
# rtl/matrix_if_xif in place of the same names, the CV-X-IF adapter and coprocessor,
# core_matrix_xif, halt_detect and the SoC top.
set v_files {}
foreach f [lsort [glob [rtl core_if_xif *.v]]] {
    if {[file tail $f] ne "Microprocessor.v"} { lappend v_files $f }
}
lappend v_files [rtl core_matrix_xif halt_detect.v] [rtl core_matrix_xif rv32if_xif_soc.v]
set sv_files [list [rtl core_if_xif cvxif_pkg.sv]]
foreach f [lsort [glob [rtl matrix_if *.sv]]] {
    set xif [rtl matrix_if_xif [file tail $f]]
    lappend sv_files [expr {[file exists $xif] ? $xif : $f}]
}
lappend sv_files [rtl core_if_xif matrix_xif_adapter.sv] [rtl core_matrix_xif matrix_xif_coproc.sv] \
                 [rtl core_matrix_xif core_matrix_xif.sv]
foreach f [concat $v_files $sv_files] {
    if {![file isfile $f]} { error "Missing RTL source: $f" }
}

# ------------------------------------------------------------------ project
set board_store [file join $::env(XILINX_VIVADO) data xhub boards XilinxBoardStore boards]
if {[file isdirectory $board_store]} { set_param board.repoPaths [list $board_store] }

create_project $proj_name $proj_dir -part xck26-sfvc784-2LV-c -force
set board_part [lindex [lsort -dictionary [get_board_parts -quiet "xilinx.com:${board}_som:part0:*"]] end]
if {$board_part eq ""} {
    error "Board part xilinx.com:${board}_som not found (Vivado 2022.2 ships it in $board_store)"
}
set_property board_part $board_part [current_project]
if {$board eq "kr260"} {
    # Carrier connectors (as fpga/kr260/tcl/build_kr260.tcl); only PL logic is used, so optional.
    if {[catch {
        set_property board_connections {som240_1_connector xilinx.com:kr260_carrier:som240_1_connector:1.0 som240_2_connector xilinx.com:kr260_carrier:som240_2_connector:1.0} [current_project]
    } msg]} { puts "WARNING: KR260 carrier connections not set ($msg); not needed for this design." }
}
set_property target_language Verilog [current_project]
add_files -norecurse $sv_files
set_property file_type SystemVerilog [get_files $sv_files]
add_files -norecurse $v_files
update_compile_order -fileset sources_1

# ------------------------------------------------------------------ block design
proc ipdef {name} {
    set d [lindex [lsort -dictionary [get_ipdefs -all "xilinx.com:ip:${name}:*"]] end]
    if {$d eq ""} { error "IP xilinx.com:ip:$name not found in the catalog" }
    return $d
}
create_bd_design $bd_name

set ps [create_bd_cell -type ip -vlnv [ipdef zynq_ultra_ps_e] ps]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {0} \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $clk_mhz \
    CONFIG.PSU__USE__IRQ0 {1} \
] $ps

set rst [create_bd_cell -type ip -vlnv [ipdef proc_sys_reset] rst_pl]
set sc  [create_bd_cell -type ip -vlnv [ipdef smartconnect] axi_sc]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {3}] $sc

set rvm [create_bd_cell -type module -reference rv32if_xif_soc rvm]
set_property -dict [list CONFIG.IMEM_AW $imem_aw CONFIG.DMEM_AW $dmem_aw] $rvm

foreach mem {imem dmem} {
    set ctrl [create_bd_cell -type ip -vlnv [ipdef axi_bram_ctrl] ${mem}_ctrl]
    set_property -dict [list CONFIG.PROTOCOL {AXI4} CONFIG.DATA_WIDTH {32} CONFIG.SINGLE_PORT_BRAM {1} \
                             CONFIG.ECC_TYPE {0}] $ctrl
    # True dual-port, BRAM controller mode: byte address, 4 write enables, read latency 1 (no
    # output register), depth from the controller's address range.
    set bram [create_bd_cell -type ip -vlnv [ipdef blk_mem_gen] ${mem}_bram]
    # BRAM controller mode is the IP integrator default; set it anyway (a no-op if it is).
    if {[catch { set_property CONFIG.use_bram_block {BRAM_Controller} $bram } msg]} {
        puts "INFO: use_bram_block not set on ${mem}_bram ($msg)"
    }
    set_property -dict [list CONFIG.Memory_Type {True_Dual_Port_RAM} \
                             CONFIG.Enable_B {Use_ENB_Pin} CONFIG.Use_RSTB_Pin {true} \
                             CONFIG.Port_B_Clock $clk_mhz CONFIG.Port_B_Write_Rate {50} \
                             CONFIG.Port_B_Enable_Rate {100}] $bram
    # Without the safety circuit the reset needs no extra cycles (our core never resets the BRAM).
    catch { set_property CONFIG.EN_SAFETY_CKT {false} $bram }
    connect_bd_intf_net [get_bd_intf_pins ${mem}_ctrl/BRAM_PORTA] [get_bd_intf_pins ${mem}_bram/BRAM_PORTA]
    connect_bd_intf_net [get_bd_intf_pins rvm/[string toupper $mem]] [get_bd_intf_pins ${mem}_bram/BRAM_PORTB]
    set bytes [expr {[set ${mem}_kb] * 1024}]
    if {[catch { set_property CONFIG.MEM_SIZE $bytes [get_bd_intf_pins rvm/[string toupper $mem]] } msg]} {
        puts "INFO: MEM_SIZE not set on rvm/[string toupper $mem] ($msg); the depth check below still applies."
    }
}

connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_FPD] [get_bd_intf_pins axi_sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_sc/M00_AXI]    [get_bd_intf_pins rvm/s_axi]
connect_bd_intf_net [get_bd_intf_pins axi_sc/M01_AXI]    [get_bd_intf_pins imem_ctrl/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_sc/M02_AXI]    [get_bd_intf_pins dmem_ctrl/S_AXI]

connect_bd_net [get_bd_pins ps/pl_clk0] \
    [get_bd_pins ps/maxihpm0_fpd_aclk] [get_bd_pins rst_pl/slowest_sync_clk] [get_bd_pins axi_sc/aclk] \
    [get_bd_pins rvm/s_axi_aclk] [get_bd_pins imem_ctrl/s_axi_aclk] [get_bd_pins dmem_ctrl/s_axi_aclk]
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins rst_pl/ext_reset_in]
connect_bd_net [get_bd_pins rst_pl/peripheral_aresetn] \
    [get_bd_pins axi_sc/aresetn] [get_bd_pins rvm/s_axi_aresetn] \
    [get_bd_pins imem_ctrl/s_axi_aresetn] [get_bd_pins dmem_ctrl/s_axi_aresetn]
connect_bd_net [get_bd_pins rvm/irq] [get_bd_pins ps/pl_ps_irq0]

# Addresses. The slave segment of each interface (rvm/s_axi/reg0, imem_ctrl/S_AXI/Mem0, ...).
proc map_slave {intf offset range} {
    set seg [get_bd_addr_segs -quiet ${intf}/*]
    if {[llength $seg] != 1} { set seg [get_bd_addr_segs -quiet -of_objects [get_bd_intf_pins $intf]] }
    if {[llength $seg] != 1} { error "No single address segment for $intf (found '$seg'; all: [get_bd_addr_segs])" }
    assign_bd_address -offset $offset -range $range -target_address_space [get_bd_addr_spaces ps/Data] $seg -force
}
map_slave rvm/s_axi       $base_regs 4K
map_slave imem_ctrl/S_AXI $base_imem ${imem_kb}K
map_slave dmem_ctrl/S_AXI $base_dmem ${dmem_kb}K

validate_bd_design

proc prop {name obj} { if {[catch { get_property $name $obj } v]} { return "" }; return $v }

# The BRAMs must be what rv32if_xif_soc expects (tb/soc_xif/bram_tdp_model.v): true dual port,
# 32 bit x (size / 4) words, read latency 1 on both ports (no output register).
set bram_notes {}
foreach mem {imem dmem} {
    set c [get_bd_cells ${mem}_bram]
    set words [expr {[set ${mem}_kb] * 256}]
    set type  [prop CONFIG.Memory_Type $c]
    set depth [prop CONFIG.Write_Depth_A $c]
    set width [prop CONFIG.Write_Width_A $c]
    set rega  [prop CONFIG.Register_PortA_Output_of_Memory_Primitives $c]
    set regb  [prop CONFIG.Register_PortB_Output_of_Memory_Primitives $c]
    set note "${mem}_bram: $type, $depth x $width bit, output register A/B $rega/$regb"
    puts "INFO: $note"
    lappend bram_notes $note
    set bad {}
    if {$type ne "True_Dual_Port_RAM"} { lappend bad "Memory_Type '$type', expected True_Dual_Port_RAM" }
    if {[string is integer -strict $depth] && $depth < $words} { lappend bad "depth $depth words, need $words" }
    if {[string is integer -strict $width] && $width != 32} { lappend bad "width $width bit, need 32" }
    if {[string equal -nocase $rega true] || [string equal -nocase $regb true]} {
        lappend bad "output register on (read latency 2; rv32if_xif_soc needs 1)"
    }
    if {[llength $bad]} { error "${mem}_bram: [join $bad {; }]" }
    if {![string is integer -strict $depth] || $depth != $words} {
        puts "CRITICAL WARNING: ${mem}_bram depth '$depth', expected $words words: check the address editor"
    }
}

set act_mhz [prop CONFIG.PSU__CRL_APB__PL0_REF_CTRL__ACT_FREQMHZ $ps]
set fh [open [file join $report_dir address_map.txt] w]
puts $fh "rv32if_xif_soc block design, board $board_part, pl_clk0 requested $clk_mhz MHz, actual $act_mhz MHz"
puts $fh [format "%-26s %-12s %-10s" segment offset range]
foreach seg [lsort [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps/Data]]] {
    puts $fh [format "%-26s 0x%08X   %s" [get_property NAME $seg] [get_property OFFSET $seg] [get_property RANGE $seg]]
}
puts $fh "irq: rvm/irq -> ps/pl_ps_irq0\[0\] (GIC SPI 121, level high)"
puts $fh "IMEM $imem_kb KB (IMEM_AW $imem_aw), DMEM $dmem_kb KB (DMEM_AW $dmem_aw), BRAM true dual port, read latency 1"
foreach n $bram_notes { puts $fh $n }
close $fh

regenerate_bd_layout
save_bd_design
set bd_file [get_files ${bd_name}.bd]
generate_target all $bd_file
add_files -norecurse [make_wrapper -files $bd_file -top]
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

if {$mode eq "bd"} {
    puts "Project and block design: [file join $proj_dir $proj_name.xpr]"
    puts "Address map: [file join $report_dir address_map.txt]"
    return
}

# ------------------------------------------------------------------ synthesis / implementation
if {$strategy ne "default"} { set_property strategy $strategy [get_runs impl_1] }
set last_step [expr {$mode eq "full" ? "write_bitstream" : "route_design"}]
set t0 [clock seconds]
launch_runs impl_1 -to_step $last_step -jobs 4
wait_on_run impl_1
set minutes [expr {([clock seconds] - $t0) / 60}]
foreach r {synth_1 impl_1} {
    set st [get_property STATUS [get_runs $r]]
    puts "INFO: $r: $st"
    if {![string match "*Complete*" $st] || [string match "*ERROR*" $st]} {
        error "$r failed ($st): see [file join $proj_dir $proj_name.runs $r runme.log]"
    }
}

open_run impl_1
report_timing_summary -max_paths 10 -report_unconstrained -file [file join $report_dir timing_summary.rpt]
report_timing -max_paths 20 -nworst 1 -sort_by group -file [file join $report_dir timing_paths.rpt]
report_utilization -file [file join $report_dir utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 8 -file [file join $report_dir utilization_hier.rpt]
report_clocks -file [file join $report_dir clocks.rpt]

if {$mode eq "full"} {
    set bit_src [file join $proj_dir $proj_name.runs impl_1 ${bd_name}_wrapper.bit]
    file copy -force $bit_src [file join $out_dir rv32if_xif_soc.bit]
    set hwh_src [lindex [glob -nocomplain [file join $proj_dir $proj_name.gen sources_1 bd $bd_name hw_handoff ${bd_name}.hwh]] 0]
    if {$hwh_src ne ""} { file copy -force $hwh_src [file join $out_dir rv32if_xif_soc.hwh] }
    # .bin for fpgautil / xmutil (Kria Ubuntu), .xsa for Vitis (bare-metal)
    write_cfgmem -force -format bin -interface SMAPx32 -disablebitswap \
        -loadbit "up 0x0 [file join $out_dir rv32if_xif_soc.bit]" [file join $out_dir rv32if_xif_soc.bin]
    write_hw_platform -fixed -include_bit -force -file [file join $out_dir rv32if_xif_soc.xsa]
}

# ------------------------------------------------------------------ soc_summary.txt
# Built from the reports; if parsing fails, a short summary with the routed WNS is written instead.
set summary_file [file join $report_dir soc_summary.txt]
if {[catch {

proc path_info {kind} {
    set p [get_timing_paths -max_paths 1 -nworst 1 -$kind]
    if {$p eq ""} { return [list "" "" "" "" ""] }
    return [list [get_property SLACK $p] [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p] \
                 [get_property LOGIC_LEVELS $p] [get_property REQUIREMENT $p]]
}
lassign [path_info setup] wns wstart wend wlevels period
lassign [path_info hold]  whs
# TNS and failing endpoints: the "Design Timing Summary" table (header, dashes, values).
set tns "?"; set fail "?"
set ts_lines [split [report_timing_summary -no_detailed_paths -return_string] "\n"]
set i [lsearch -regexp $ts_lines {^\s*WNS\(ns\)\s+TNS\(ns\)}]
if {$i >= 0} {
    set v [regexp -inline -all {\S+} [lindex $ts_lines [expr {$i + 2}]]]
    if {[llength $v] >= 3} { lassign $v _w tns fail }
}

# Cells of one report table row "| a | b | ... |" -> {a b ...}, trimmed.
# Vivado 2022.2 runs Tcl 8.5: no lmap (8.6), so build the list with foreach.
proc split_row {line} {
    set f {}
    foreach x [lrange [split $line |] 1 end-1] { lappend f [string trim $x] }
    return $f
}

# Utilization rows: | Site Type | Used | Fixed | Prohibited | Available | Util% |
set util [report_utilization -return_string]
proc util_row {text name} {
    foreach line [split $text "\n"] {
        if {![string match "|*" $line]} { continue }
        set f [split_row $line]
        if {[string trimright [lindex $f 0] *] eq $name && [llength $f] >= 6} {
            return [format "%8s / %-7s (%s %%)" [lindex $f 1] [lindex $f 4] [lindex $f 5]]
        }
    }
    return "?"
}

# Hierarchical rows: instance -> {Total LUTs, FFs, RAMB36, RAMB18, DSP Blocks}
set hier [report_utilization -hierarchical -hierarchical_depth 8 -return_string]
set cols {}; set rows [dict create]
foreach line [split $hier "\n"] {
    if {![string match "|*" $line]} { continue }
    set f [split_row $line]
    if {[lindex $f 0] eq "Instance"} { set cols $f; continue }
    if {![llength $cols]} { continue }
    set inst [lindex $f 0]
    if {![dict exists $rows $inst]} { dict set rows $inst $f }
}
proc hier_val {inst col} {
    global cols rows
    set i [lsearch -exact $cols $col]
    if {$i < 0 || ![dict exists $rows $inst]} { return "" }
    return [lindex [dict get $rows $inst] $i]
}

set fh [open [file join $report_dir soc_summary.txt] w]
puts $fh "rv32if_xif_soc on $board_part (xck26-sfvc784-2LV-c), Vivado 2022.2, mode $mode, impl strategy $strategy"
puts $fh "pl_clk0: requested $clk_mhz MHz, actual $act_mhz MHz, timed period $period ns"
puts $fh "run time: $minutes min (synthesis + implementation[expr {$mode eq "full" ? " + bitstream" : ""}])"
puts $fh ""
puts $fh "Timing (routed)"
puts $fh [format "  WNS %s ns   TNS %s ns   failing endpoints %s   WHS %s ns" $wns $tns $fail $whs]
if {$wns ne "" && $period ne ""} {
    puts $fh [format "  approximate Fmax of the whole SoC: %.1f MHz" [expr {1000.0 / ($period - $wns)}]]
}
puts $fh "  worst setup path ($wlevels logic levels):"
puts $fh "    from $wstart"
puts $fh "    to   $wend"
puts $fh "  [expr {$wns ne "" && $wns >= 0 ? "timing met" : "TIMING NOT MET: see timing_paths.rpt; try a lower clock or -Strategy Performance_Explore"}]"
puts $fh ""
puts $fh "Utilization (whole design)"
foreach {label name} {"CLB LUTs" "CLB LUTs" "CLB Registers" "CLB Registers" "Block RAM tiles" "Block RAM Tile" "DSPs" "DSPs"} {
    puts $fh [format "  %-16s %s" $label [util_row $util $name]]
}
puts $fh ""
puts $fh "Per block (utilization_hier.rpt)"
puts $fh [format "  %-34s %9s %9s %7s %7s %5s" block LUTs FFs RAMB36 RAMB18 DSP]
set lut_col [expr {[lsearch -exact $cols "Total LUTs"] >= 0 ? "Total LUTs" : "CLB LUTs"}]
foreach {inst label} {
    rvm        "rvm (rv32if_xif_soc)"
    u_cm       "  core_matrix_xif"
    u_core     "    core (RV32IF + FPU)"
    u_coproc   "    matrix coprocessor"
    u_halt     "  halt_detect"
    imem_ctrl  "imem_ctrl (AXI BRAM Controller)"
    dmem_ctrl  "dmem_ctrl (AXI BRAM Controller)"
    imem_bram  "imem_bram"
    dmem_bram  "dmem_bram"
    axi_sc     "axi_sc (SmartConnect)"
    rst_pl     "rst_pl (proc_sys_reset)"
} {
    if {![dict exists $rows $inst]} { continue }
    puts $fh [format "  %-34s %9s %9s %7s %7s %5s" $label [hier_val $inst $lut_col] [hier_val $inst FFs] \
                [hier_val $inst RAMB36] [hier_val $inst RAMB18] [hier_val $inst "DSP Blocks"]]
}
set glue_lut ""; set glue_ff ""
if {[dict exists $rows rvm] && [dict exists $rows u_cm]} {
    catch {
        set glue_lut [expr {[hier_val rvm $lut_col] - [hier_val u_cm $lut_col]}]
        set glue_ff  [expr {[hier_val rvm FFs] - [hier_val u_cm FFs]}]
    }
}
if {$glue_lut ne ""} {
    puts $fh "  SoC glue = rvm - core_matrix_xif (AXI4-Lite registers, CYCLES/MDONE/EXIT_CODE/watchdog, IRQ, halt):"
    puts $fh "    $glue_lut LUTs, $glue_ff FFs"
}
puts $fh ""
puts $fh "Address map: address_map.txt"
if {$mode eq "full"} {
    puts $fh "Board files: $out_dir"
}
close $fh

} err]} {
    catch { close $fh }
    set p [get_timing_paths -max_paths 1 -nworst 1 -setup]
    set fh [open $summary_file w]
    puts $fh "rv32if_xif_soc on $board_part, mode $mode, pl_clk0 $clk_mhz MHz (actual $act_mhz MHz)"
    puts $fh "WNS [expr {$p eq "" ? "?" : [get_property SLACK $p]}] ns (routed)"
    puts $fh "Summary parsing failed ($err): read timing_summary.rpt and utilization_hier.rpt."
    if {$mode eq "full"} { puts $fh "Board files: $out_dir" }
    close $fh
}

puts ""
set fh [open $summary_file r]; puts [read $fh]; close $fh
