# =========================================================
# Out-of-Context Synthesis Script for Core Scaling Analysis (1-Core & 2-Core)
# =========================================================

set PART xc7a200tffg1156-3

# ---------------------------------------------------------
# 1. Synthesize 1-Core
# ---------------------------------------------------------
puts "============================================================"
puts "  SYNTHESIZING 1-CORE ENGINE"
puts "============================================================"
create_project -in_memory -part $PART
read_verilog -sv [list \
    {iv_engine.srcs/sources_1/new/iv_divider_q824.sv}    \
    {iv_engine.srcs/sources_1/new/iv_sqrt_q824.sv}        \
    {iv_engine.srcs/sources_1/new/iv_cordic_pipeline.sv}  \
    {iv_engine.srcs/sources_1/new/iv_kn_compensator.sv}   \
    {iv_engine.srcs/sources_1/new/iv_norm_cdf.sv}         \
    {iv_engine.srcs/sources_1/new/iv_bs_datapath.sv}      \
    {iv_engine.srcs/sources_1/new/iv_arbitration_fsm.sv}  \
    {iv_engine.srcs/sources_1/new/iv_bs_initial_guess.sv} \
    {iv_engine.srcs/sources_1/new/iv_top.sv}              \
    {iv_engine.srcs/sources_1/new/iv_axis_wrapper.sv}
]
set_property top iv_axis_wrapper [current_fileset]
synth_design -top iv_axis_wrapper -part $PART -mode out_of_context -flatten_hierarchy rebuilt -directive AreaOptimized_high
create_clock -period 10.000 -name aclk [get_ports aclk]
file mkdir impl_results/artix7_1core_synth
report_utilization -file impl_results/artix7_1core_synth/synth_utilization.rpt -hierarchical
report_timing_summary -file impl_results/artix7_1core_synth/synth_timing.rpt -max_paths 5
close_project

# ---------------------------------------------------------
# 2. Synthesize 2-Core
# ---------------------------------------------------------
puts "============================================================"
puts "  SYNTHESIZING 2-CORE ENGINE ARRAY"
puts "============================================================"
create_project -in_memory -part $PART
read_verilog -sv [list \
    {iv_engine.srcs/sources_1/new/iv_divider_q824.sv}    \
    {iv_engine.srcs/sources_1/new/iv_sqrt_q824.sv}        \
    {iv_engine.srcs/sources_1/new/iv_cordic_pipeline.sv}  \
    {iv_engine.srcs/sources_1/new/iv_kn_compensator.sv}   \
    {iv_engine.srcs/sources_1/new/iv_norm_cdf.sv}         \
    {iv_engine.srcs/sources_1/new/iv_bs_datapath.sv}      \
    {iv_engine.srcs/sources_1/new/iv_arbitration_fsm.sv}  \
    {iv_engine.srcs/sources_1/new/iv_bs_initial_guess.sv} \
    {iv_engine.srcs/sources_1/new/iv_top.sv}              \
    {iv_engine.srcs/sources_1/new/iv_axis_wrapper.sv}     \
    {iv_engine.srcs/sources_1/new/iv_multi_engine_top.sv} \
    {iv_engine.srcs/sources_1/new/iv_dual_core_top.sv}
]
set_property top iv_dual_core_top [current_fileset]
synth_design -top iv_dual_core_top -part $PART -mode out_of_context -flatten_hierarchy rebuilt -directive AreaOptimized_high
create_clock -period 10.000 -name aclk [get_ports aclk]
file mkdir impl_results/artix7_2core_synth
report_utilization -file impl_results/artix7_2core_synth/synth_utilization.rpt -hierarchical
report_timing_summary -file impl_results/artix7_2core_synth/synth_timing.rpt -max_paths 5
close_project

puts "SYNTHESIS SCALING COMPLETE"
exit
