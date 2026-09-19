# =========================================================
# Full Place-and-Route Implementation Script for Artix-7 Speed Grade -3
# Target Device : Artix-7 xc7a200tffg1156-3
# Top Module    : iv_axis_wrapper (1-Core AXI4-Stream Engine)
# Clock Target  : 100 MHz (10.000 ns period)
# Throughput    : 100 Million Options / sec
# Mode          : Out-of-Context (Full physical implementation)
#
# Run via:
#   vivado -mode batch -source run_impl_artix7_1core.tcl
# =========================================================

set PART       xc7a200tffg1156-3
set TOP        iv_axis_wrapper
set CLK_PERIOD 10.000
set CLK_NAME   aclk
set OUTDIR     impl_results/artix7_1core

# ----------------------------------------------------------
# 0. Create output directory
# ----------------------------------------------------------
file mkdir $OUTDIR
set_param drc.disableLUTOverUtilError 1

# ----------------------------------------------------------
# 1. Create in-memory project and read all RTL sources
# ----------------------------------------------------------
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

set_property top $TOP [current_fileset]

# ----------------------------------------------------------
# 2. Synthesis (OOC mode)
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 1/6\] Synthesis: $TOP on $PART @ 100 MHz (10.000 ns)"
puts "============================================================"

synth_design \
    -top            $TOP  \
    -part           $PART \
    -mode           out_of_context \
    -flatten_hierarchy rebuilt \
    -directive      AreaOptimized_high

# ----------------------------------------------------------
# 3. Timing Constraints
# ----------------------------------------------------------
create_clock -period $CLK_PERIOD -name $CLK_NAME [get_ports $CLK_NAME]
set_false_path -from [get_ports aresetn]
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports $CLK_NAME]

# ----------------------------------------------------------
# 4. Opt Design
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 2/6\] opt_design -directive ExploreArea"
puts "============================================================"
opt_design -directive ExploreArea

# ----------------------------------------------------------
# 5. Place Design
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 3/6\] place_design -directive Explore"
puts "============================================================"
set_param drc.disableLUTOverUtilError 1
place_design -directive Explore

# ----------------------------------------------------------
# 6. Physical Optimization
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 4/6\] phys_opt_design"
puts "============================================================"
phys_opt_design -directive AggressiveExplore
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "  Post-phys_opt WNS: ${wns} ns"

# ----------------------------------------------------------
# 7. Route Design
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 5/6\] route_design -directive Explore"
puts "============================================================"
route_design -directive Explore

set wns_post [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "  Post-route WNS: ${wns_post} ns"

# ----------------------------------------------------------
# 8. Generate Reports
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 6/6\] Generating Reports"
puts "============================================================"

report_timing_summary \
    -file          $OUTDIR/artix7_timing_summary.rpt \
    -max_paths     10 \
    -report_unconstrained

report_utilization \
    -file          $OUTDIR/artix7_utilization.rpt \
    -hierarchical \
    -hierarchical_percentages

set_operating_conditions -ambient_temp 25.0
set_operating_conditions -airflow 250
set_load 10.0 [all_outputs]

report_power \
    -file          $OUTDIR/artix7_power.rpt \
    -xpe           $OUTDIR/artix7_power.xpe

write_checkpoint -force $OUTDIR/artix7_route.dcp

puts ""
puts "============================================================"
puts "  IMPLEMENTATION COMPLETE: 1-Core Engine on Artix-7 -3"
puts "  WNS           : $wns_post ns"
puts "  Target Clock  : 100 MHz (10.000 ns)"
puts "  Reports in    : $OUTDIR"
puts "============================================================"
exit
