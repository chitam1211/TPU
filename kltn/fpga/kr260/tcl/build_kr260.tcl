# =============================================================================
# Tao project Vivado 2022.2 cho KR260: Zynq MPSoC PS + rv32if_matrix_axi (AXI4-Lite)
# roi chay synth / impl / bitstream, xuat XSA (Vitis), .bit/.hwh (PYNQ), .bin (fpgautil).
#
#   vivado -mode batch -source tcl/build_kr260.tcl                   (100 MHz)
#   vivado -mode batch -source tcl/build_kr260.tcl -tclargs 50       (50 MHz)
#   vivado -mode batch -source tcl/build_kr260.tcl -tclargs 100 bd   (chi tao project + BD)
#
# Dia chi: M_AXI_HPM0_FPD -> rv32if_matrix_axi tai 0xA000_0000, 16 KB. irq -> pl_ps_irq0[0].
# =============================================================================
set clk_mhz 100
set stop_after ""
if {[llength $argv] >= 1} { set clk_mhz [lindex $argv 0] }
if {[llength $argv] >= 2} { set stop_after [lindex $argv 1] }

set kr260_dir  [file normalize [file join [file dirname [info script]] ..]]
set kltn_root  [file normalize [file join $kr260_dir .. ..]]
set cpu_dir    [file join $kltn_root rtl core_if]
set rtl_dir    [file join $kltn_root rtl matrix_if]
set proj_dir   [file join $kr260_dir build vivado]
set out_dir    [file join $kr260_dir build out]
set proj_name  kr260_rv32if_matrix
set bd_name    system

# Board file KR260 (Vivado 2022.2 cai trong data/xhub/boards)
set board_store [file join $::env(XILINX_VIVADO) data xhub boards XilinxBoardStore boards]
if {[file isdirectory $board_store]} {
    set_param board.repoPaths [list $board_store]
}

# ---------------- Nguon RTL ----------------
set scalar_sources {
    adder.v alu.v branch.v control_unit.v control_decoder.v
    data_memory_top.v Decode.v decode_pipe.v Execute.v execute_pipe.v
    Fetch.v fetch_pipe.v immediate_gen.v instruc_mem_top.v memory.v
    memory_stage.v memstage_pipe.v mux1_2.v mux2_4.v mux3_8.v
    program_counter.v register_file.v type_decoder.v wrapper_memory.v
    Write_back.v fp_register_file.v fp_decode.v fp_csr.v fp_misc.v
    fp32_addsub.v fp32_mul.v fp32_divsqrt.v fp32_fma.v
    fp32_convert.v fp32_compare.v
}
set matrix_sources {
    matrix_cfg_pkg.sv fp32_fma_pkg.sv
    matrix_dispatch.sv matrix_ew.sv matrix_ew_fp.sv
    matrix_mac_int.sv matrix_mac_fp.sv matrix_misc.sv
    matrix_regfile.sv matrix_tile_ls.sv matrix_core_v2.sv
}
set v_files {}
set sv_files {}
foreach f $scalar_sources { lappend v_files [file join $cpu_dir $f] }
lappend v_files [file join $rtl_dir core_matrix.v]
lappend v_files [file join $kr260_dir rtl rv32if_matrix_soc.v]
lappend v_files [file join $kr260_dir rtl rv32if_matrix_axi.v]
foreach f $matrix_sources { lappend sv_files [file join $rtl_dir $f] }
foreach f [concat $v_files $sv_files] {
    if {![file isfile $f]} { error "Missing RTL source: $f" }
}

# ---------------- Project ----------------
create_project $proj_name $proj_dir -part xck26-sfvc784-2LV-c -force
set_property board_part xilinx.com:kr260_som:part0:1.1 [current_project]
if {[catch {
    set_property board_connections {som240_1_connector xilinx.com:kr260_carrier:som240_1_connector:1.0 som240_2_connector xilinx.com:kr260_carrier:som240_2_connector:1.0} [current_project]
} msg]} {
    puts "WARNING: khong gan duoc carrier KR260 ($msg). Thiet ke chi dung PL nen van build duoc."
}
set_property target_language Verilog [current_project]

add_files -norecurse $sv_files
set_property file_type SystemVerilog [get_files $sv_files]
add_files -norecurse $v_files
update_compile_order -fileset sources_1

# ---------------- Block design ----------------
create_bd_design $bd_name

set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e ps]
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

set rvm [create_bd_cell -type module -reference rv32if_matrix_axi rvm]

apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master {/ps/pl_clk0 (} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/ps/M_AXI_HPM0_FPD} Slave {/rvm/s_axi} ddr_seg {Auto} \
    intc_ip {New AXI SmartConnect} master_apm {0}] [get_bd_intf_pins rvm/s_axi]

# maxihpm0_fpd_aclk co the chua duoc noi neu automation khong lam
if {[llength [get_bd_nets -of_objects [get_bd_pins ps/maxihpm0_fpd_aclk]]] == 0} {
    connect_bd_net [get_bd_pins ps/pl_clk0] [get_bd_pins ps/maxihpm0_fpd_aclk]
}
connect_bd_net [get_bd_pins rvm/irq] [get_bd_pins ps/pl_ps_irq0]

assign_bd_address
set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps/Data] -filter {NAME =~ *rvm*}]
set_property offset 0xA0000000 $seg
set_property range 16K $seg

validate_bd_design
regenerate_bd_layout
save_bd_design

set bd_file [get_files ${bd_name}.bd]
generate_target all $bd_file
set wrapper [make_wrapper -files $bd_file -top]
add_files -norecurse $wrapper
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

if {$stop_after eq "bd"} {
    puts "Project + BD da tao: $proj_dir"
    return
}

# ---------------- Synth / impl / bitstream ----------------
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property strategy Performance_Explore [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "impl_1 that bai: xem $proj_dir/$proj_name.runs/impl_1/runme.log"
}

open_run impl_1
file mkdir $out_dir
report_timing_summary -file [file join $out_dir timing_summary.rpt]
report_utilization    -file [file join $out_dir utilization.rpt]
report_utilization -hierarchical -file [file join $out_dir utilization_hier.rpt]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "WNS = $wns ns @ $clk_mhz MHz"

set bit_src [file join $proj_dir $proj_name.runs impl_1 ${bd_name}_wrapper.bit]
set hwh_src [lindex [glob -nocomplain [file join $proj_dir $proj_name.gen sources_1 bd $bd_name hw_handoff ${bd_name}.hwh]] 0]
file copy -force $bit_src [file join $out_dir rv32if_matrix.bit]
if {$hwh_src ne ""} { file copy -force $hwh_src [file join $out_dir rv32if_matrix.hwh] }

# .bin cho fpgautil / xmutil (Kria Ubuntu)
write_cfgmem -force -format bin -interface SMAPx32 -disablebitswap \
    -loadbit "up 0x0 [file join $out_dir rv32if_matrix.bit]" [file join $out_dir rv32if_matrix.bin]

# XSA cho Vitis (bare-metal)
write_hw_platform -fixed -include_bit -force -file [file join $out_dir rv32if_matrix.xsa]

set fh [open [file join $out_dir build_info.txt] w]
puts $fh "clock_mhz $clk_mhz"
puts $fh "wns_ns    $wns"
puts $fh "base_addr 0xA0000000 (16 KB)"
puts $fh "built     [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
close $fh
puts "Xong. File trong $out_dir"
