# =========================================================
# Out-of-Context Synthesis Script for iv_top (single IV engine core)
# Targets: Artix-7 xc7a200tffg1156-2 @ 100 MHz (10.0 ns)
# Run via: vivado -mode batch -source synth_ooc.tcl
# =========================================================

# Create in-memory project targeting the Artix-7 200T part
create_project -in_memory -part xc7a200tffg1156-2

# Read all RTL SystemVerilog source files (order = bottom-up dependency)
read_verilog -sv [list \
    {iv_engine.srcs/sources_1/new/iv_divider_q824.sv} \
    {iv_engine.srcs/sources_1/new/iv_sqrt_q824.sv} \
    {iv_engine.srcs/sources_1/new/iv_norm_cdf.sv} \
    {iv_engine.srcs/sources_1/new/iv_bs_datapath.sv} \
    {iv_engine.srcs/sources_1/new/iv_cordic_pipeline.sv} \
    {iv_engine.srcs/sources_1/new/iv_kn_compensator.sv} \
    {iv_engine.srcs/sources_1/new/iv_arbitration_fsm.sv} \
    {iv_engine.srcs/sources_1/new/iv_top.sv} \
]

# Set the top-level module
set_property top iv_top [current_fileset]

# Run Out-of-Context synthesis
#   -mode out_of_context : no I/O buffers, pure logic synthesis for IP-like estimation
#   -flatten_hierarchy rebuilt : accurate hierarchical resource breakdown
synth_design \
    -top iv_top \
    -part xc7a200tffg1156-2 \
    -mode out_of_context \
    -flatten_hierarchy rebuilt

# Create a 100 MHz constraint (10.0 ns period) for Artix-7 speed-2
create_clock -period 10.000 -name clk [get_ports clk]

# Generate detailed utilization report (hierarchical breakdown)
report_utilization \
    -file synth_results/utilization_ooc.rpt \
    -hierarchical \
    -hierarchical_depth 3

# Generate timing summary with critical paths
report_timing_summary \
    -file synth_results/timing_summary_ooc.rpt \
    -max_paths 5 \
    -report_unconstrained

# Print console summary
puts ""
puts "============================================================"
puts "  OOC Synthesis Complete: iv_top on xc7a12ticsg325-1L"
puts "============================================================"
report_utilization -return_string
puts "============================================================"
puts "  Full reports: synth_results/utilization_ooc.rpt"
puts "               synth_results/timing_summary_ooc.rpt"
puts "============================================================"
