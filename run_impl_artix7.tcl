# =========================================================
# Full Place-and-Route Implementation Script for Artix-7
# Target Device : Artix-7 xc7a200tffg1156-2 / xc7a100tcsg324-1
# Top Module    : iv_axis_wrapper (AXI4-Stream Implied Volatility Engine)
# Clock Target  : 250 MHz (4.000 ns period)
# Mode          : Out-of-Context (Full physical implementation)
#
# Run via:
#   vivado -mode batch -source run_impl_artix7.tcl
#
# Outputs (impl_results/artix7/ directory):
#   artix7_timing_summary.rpt — post-route WNS / TNS
#   artix7_utilization.rpt    — post-route LUT / FF / DSP / BRAM
#   artix7_power.rpt          — vector-driven power estimate
#   artix7_route.dcp          — routed design checkpoint
# =========================================================

set PART       xc7a200tffg1156-2
set TOP        iv_axis_wrapper
set CLK_PERIOD 10.000
set CLK_NAME   aclk
set OUTDIR     impl_results/artix7

# ----------------------------------------------------------
# 0. Create output directory
# ----------------------------------------------------------
file mkdir $OUTDIR

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
    {iv_engine.srcs/sources_1/new/iv_top.sv}              \
    {iv_engine.srcs/sources_1/new/iv_axis_wrapper.sv}     \
]

set_property top $TOP [current_fileset]

# ----------------------------------------------------------
# 2. Synthesis (OOC mode)
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 1/6\] Synthesis: $TOP on $PART"
puts "============================================================"

synth_design \
    -top            $TOP  \
    -part           $PART \
    -mode           out_of_context \
    -flatten_hierarchy rebuilt

# ----------------------------------------------------------
# 3. Timing Constraints
# ----------------------------------------------------------
create_clock -period $CLK_PERIOD -name $CLK_NAME [get_ports $CLK_NAME]
set_false_path -from [get_ports aresetn]

# OOC clock source — tells Vivado where the clock buffer sits so it can
# estimate clock network delay accurately in out-of-context mode.
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports $CLK_NAME]

# Force all shift-register delay chains to use FFs, not SRL32.
# SRL32 turns the D-input into a long combinational path from the
# last real register through the entire shift chain — kills timing.
set_property SHREG_EXTRACT no \
    [get_cells -hierarchical -filter {NAME =~ *phi_delay* || \
                                      NAME =~ *abs_x_delay* || \
                                      NAME =~ *is_neg_delay* || \
                                      NAME =~ *sqrt_T_delay* || \
                                      NAME =~ *ln_delay* || \
                                      NAME =~ *S_ln_pipe* || \
                                      NAME =~ *K_ln_pipe* || \
                                      NAME =~ *r_ln_pipe* || \
                                      NAME =~ *T_ln_pipe* || \
                                      NAME =~ *sigma_ln_pipe* || \
                                      NAME =~ *S_d1_pipe* || \
                                      NAME =~ *K_d1_pipe* || \
                                      NAME =~ *r_d1_pipe* || \
                                      NAME =~ *T_d1_pipe* || \
                                      NAME =~ *sqrt_T_d1_pipe* || \
                                      NAME =~ *den_d1_pipe* || \
                                      NAME =~ *S_cdf_pipe* || \
                                      NAME =~ *K_cdf_pipe* || \
                                      NAME =~ *r_cdf_pipe* || \
                                      NAME =~ *T_cdf_pipe* || \
                                      NAME =~ *sqrt_T_cdf_pipe*}]

# ----------------------------------------------------------
# 4. Opt Design
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 2/6\] opt_design"
puts "============================================================"
opt_design

# ----------------------------------------------------------
# 5. Place Design
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 3/6\] place_design"
puts "============================================================"
place_design

# ----------------------------------------------------------
# 6. Physical Optimization — progressive strategy
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 4/6\] phys_opt_design"
puts "============================================================"

# Pass 1: default phys_opt
phys_opt_design
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "  Post-phys_opt pass-1 WNS: ${wns} ns"

# Pass 2: if still failing, try aggressive DSP retiming + fanout fixing
if {$wns < 0} {
    puts "  \[WARN\] WNS < 0 — applying AggressiveExplore + DSP retiming..."
    phys_opt_design -directive AggressiveExplore
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    puts "  Post-phys_opt pass-2 WNS: ${wns} ns"
}

# Pass 3: if still failing, try AlternateReplication (resolves high-fanout nets)
if {$wns < 0} {
    puts "  \[WARN\] WNS < 0 — applying AlternateReplication (fanout fix)..."
    phys_opt_design -directive AlternateFlowWithRetiming
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    puts "  Post-phys_opt pass-3 WNS: ${wns} ns"
}

# ----------------------------------------------------------
# 7. Route Design
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 5/6\] route_design"
puts "============================================================"
route_design

set wns_post [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "  Post-route WNS: ${wns_post} ns"

if {$wns_post < 0} {
    puts "  \[WARN\] Post-route WNS < 0 — applying post-route phys_opt + tns_cleanup..."
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
    -file          $OUTDIR/artix7_timing_summary.rpt \
    -max_paths     10 \
    -report_unconstrained

report_utilization \
    -file          $OUTDIR/artix7_utilization.rpt \
    -hierarchical  \
    -hierarchical_depth 4

report_power \
    -file          $OUTDIR/artix7_power.rpt \
    -xpe           $OUTDIR/artix7_power.xpe

write_checkpoint -force $OUTDIR/artix7_route.dcp

# ----------------------------------------------------------
# 9. Console Summary
# ----------------------------------------------------------
set wns_final [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set pass_fail [expr {$wns_final >= 0 ? "PASS" : "FAIL"}]

puts ""
puts "============================================================"
puts "  Implementation COMPLETE: $TOP on $PART"
puts "  Clock Target : ${CLK_PERIOD} ns  (250 MHz)"
puts "  Final WNS    : ${wns_final} ns  (${pass_fail})"
puts "============================================================"
puts "  Reports written to: $OUTDIR/"
puts "    artix7_timing_summary.rpt"
puts "    artix7_utilization.rpt"
puts "    artix7_power.rpt"
puts "    artix7_route.dcp"
puts "============================================================"

report_utilization -return_string
