set part_name xc7z100ffv900-2
set top_name rv32i_matrix_microprocessor

read_verilog ./rv32i-pipeline-processor/src/adder.v
read_verilog ./rv32i-pipeline-processor/src/alu.v
read_verilog ./rv32i-pipeline-processor/src/branch.v
read_verilog ./rv32i-pipeline-processor/src/control_unit.v
read_verilog ./rv32i-pipeline-processor/src/data_memory_top.v
read_verilog ./rv32i-pipeline-processor/src/Decode.v
read_verilog ./rv32i-pipeline-processor/src/decode_pipe.v
read_verilog ./rv32i-pipeline-processor/src/Execute.v
read_verilog ./rv32i-pipeline-processor/src/execute_pipe.v
read_verilog ./rv32i-pipeline-processor/src/Fetch.v
read_verilog ./rv32i-pipeline-processor/src/fetch_pipe.v
read_verilog ./rv32i-pipeline-processor/src/immediate_gen.v
read_verilog ./rv32i-pipeline-processor/src/instruc_mem_top.v
read_verilog ./rv32i-pipeline-processor/src/memory.v
read_verilog ./rv32i-pipeline-processor/src/memstage_pipe.v
read_verilog ./rv32i-pipeline-processor/src/mux1_2.v
read_verilog ./rv32i-pipeline-processor/src/mux2_4.v
read_verilog ./rv32i-pipeline-processor/src/mux3_8.v
read_verilog ./rv32i-pipeline-processor/src/program_counter.v
read_verilog ./rv32i-pipeline-processor/src/register_file.v
read_verilog ./rv32i-pipeline-processor/src/type_decoder.v
read_verilog ./rv32i-pipeline-processor/src/wrapper_memory.v
read_verilog ./rv32i-pipeline-processor/src/Write_back.v

read_verilog ./rme_rtl/control_decoder.v
read_verilog ./rme_rtl/memory_stage.v
read_verilog ./rme_rtl/core_matrix.v
read_verilog ./rme_rtl/rv32i_matrix_microprocessor.v

read_verilog -sv ./rme_rtl/matrix_core_v2.sv
read_verilog -sv ./rme_rtl/matrix_dispatch.sv
read_verilog -sv ./rme_rtl/matrix_ew.sv
read_verilog -sv ./rme_rtl/matrix_mac_v2.sv
read_verilog -sv ./rme_rtl/matrix_misc.sv
read_verilog -sv ./rme_rtl/matrix_regfile.sv
read_verilog -sv ./rme_rtl/matrix_tile_ls.sv

synth_design -top $top_name -part $part_name

create_clock -period 10.000 -name clk [get_ports clk]

file mkdir reports
report_utilization -file reports/rv32i_matrix_utilization.rpt
report_timing_summary -file reports/rv32i_matrix_timing.rpt
write_checkpoint -force reports/rv32i_matrix_post_synth.dcp
