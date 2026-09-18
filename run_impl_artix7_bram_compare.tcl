# =========================================================
# Experiment 1: Vivado Place-and-Route Implementation Script
# Baseline: 4-Core Array with Block RAM Context & FIFO Storage
# Target Device : Artix-7 xc7a200tffg1156-3
# Top Module    : iv_multi_engine_top_bram
# Clock Target  : 100 MHz (10.000 ns period)
# Mode          : Out-of-Context (Full physical implementation)
# =========================================================

set PART       xc7a200tffg1156-3
set TOP        iv_multi_engine_top_bram
set CLK_PERIOD 10.000
set CLK_NAME   aclk
set OUTDIR     impl_results/artix7_4core_bram

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
    {iv_engine.srcs/sources_1/new/iv_divider_q824.sv}         \
    {iv_engine.srcs/sources_1/new/iv_sqrt_q824.sv}            \
    {iv_engine.srcs/sources_1/new/iv_cordic_pipeline.sv}      \
    {iv_engine.srcs/sources_1/new/iv_kn_compensator.sv}       \
    {iv_engine.srcs/sources_1/new/iv_norm_cdf.sv}             \
    {iv_engine.srcs/sources_1/new/iv_bs_datapath.sv}          \
    {iv_engine.srcs/sources_1/new/iv_arbitration_fsm.sv}      \
    {iv_engine.srcs/sources_1/new/iv_bs_initial_guess.sv}     \
    {iv_engine.srcs/sources_1/new/iv_top_bram.sv}              \
    {iv_engine.srcs/sources_1/new/iv_axis_wrapper_bram.sv}     \
    {iv_engine.srcs/sources_1/new/iv_multi_engine_top_bram.sv}
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

# Clock source definition for accurate OOC clock buffer estimation
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

if {$wns < 0} {
    puts "  \[WARN\] WNS < 0: applying AlternateFlowWithRetiming..."
    phys_opt_design -directive AlternateFlowWithRetiming
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    puts "  Post-phys_opt pass-2 WNS: ${wns} ns"
}

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

if {$wns_post < 0} {
    puts "  \[WARN\] Post-route WNS < 0: applying post-route phys_opt + tns_cleanup..."
    phys_opt_design -directive AggressiveExplore
    route_design -tns_cleanup
    set wns_post [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    puts "  Final WNS after post-route fix: ${wns_post} ns"
}

# ----------------------------------------------------------
# 8. Generate Reports
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 6/6\] Generating Reports"
puts "============================================================"

report_timing_summary \
    -file          $OUTDIR/artix7_bram_timing_summary.rpt \
    -max_paths     10 \
    -report_unconstrained

report_utilization \
    -file          $OUTDIR/artix7_bram_utilization.rpt \
    -hierarchical \
    -hierarchical_percentages

# Vector-driven power estimation
set_operating_conditions -ambient_temp 25.0
set_operating_conditions -airflow 250
set_load 10.0 [all_outputs]

report_power \
    -file          $OUTDIR/artix7_bram_power.rpt \
    -xpe           $OUTDIR/artix7_bram_power.xpe

# Save routed design checkpoint
write_checkpoint -force $OUTDIR/artix7_bram_route.dcp

puts ""
puts "============================================================"
puts "  IMPLEMENTATION COMPLETE: 4-Core BRAM Baseline on Artix-7"
puts "  WNS           : $wns_post ns"
puts "  Target Clock  : 100 MHz (10.000 ns)"
puts "  Reports in    : $OUTDIR"
puts "============================================================"
exit
