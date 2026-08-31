# =========================================================
# Full Place-and-Route Implementation Script
# Target Device : Virtex-7 VC707  (xc7vx485tffg1761-2)
# Top Module    : iv_multi_engine_top  (4-core AXI4-Stream array)
# Clock Target  : 250 MHz  (4.000 ns period)
# Mode          : Out-of-Context (no I/O buffers; timing/util/power estimation)
#
# Run via:
#   vivado -mode batch -source run_impl_vc707.tcl
#
# Outputs (impl_results/ directory):
#   vc707_timing_summary.rpt    — post-route WNS / TNS
#   vc707_utilization.rpt       — LUT / FF / DSP / BRAM breakdown
#   vc707_power.rpt             — vector-driven power estimate
#   vc707_route.dcp             — routed design checkpoint (re-openable)
# =========================================================

set PART       xc7vx485tffg1761-2
set TOP        iv_multi_engine_top
set CLK_PERIOD 4.000
set CLK_NAME   aclk
set OUTDIR     impl_results/vc707

# ----------------------------------------------------------
# 0. Create output directory
# ----------------------------------------------------------
file mkdir $OUTDIR

# ----------------------------------------------------------
# 1. Create in-memory project and read all RTL sources
#    Order: leaf modules first (bottom-up dependency order)
# ----------------------------------------------------------
create_project -in_memory -part $PART

read_verilog -sv [list \
    {iv_engine.srcs/sources_1/new/iv_divider_q824.sv}  \
    {iv_engine.srcs/sources_1/new/iv_sqrt_q824.sv}     \
    {iv_engine.srcs/sources_1/new/iv_cordic_pipeline.sv} \
    {iv_engine.srcs/sources_1/new/iv_kn_compensator.sv}  \
    {iv_engine.srcs/sources_1/new/iv_norm_cdf.sv}        \
    {iv_engine.srcs/sources_1/new/iv_bs_datapath.sv}     \
    {iv_engine.srcs/sources_1/new/iv_arbitration_fsm.sv} \
    {iv_engine.srcs/sources_1/new/iv_top.sv}             \
    {iv_engine.srcs/sources_1/new/iv_axis_wrapper.sv}    \
    {iv_engine.srcs/sources_1/new/iv_multi_engine_top.sv} \
]

set_property top $TOP [current_fileset]

# ----------------------------------------------------------
# 2. Synthesis (OOC — no I/O buffers; pure logic estimation)
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
# 3. Timing Constraint: 250 MHz virtual clock on 'aclk'
#    In OOC mode, aclk is treated as a primary input port.
# ----------------------------------------------------------
create_clock -period $CLK_PERIOD -name $CLK_NAME [get_ports $CLK_NAME]

# Suppress reset CDC warnings (aresetn is async reset, by design)
set_false_path -from [get_ports aresetn]

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
# 6. Physical Optimization (standard pass)
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 4/6\] phys_opt_design (standard)"
puts "============================================================"
phys_opt_design

# Check WNS — if still negative, apply aggressive directive
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "  Post-phys_opt WNS: ${wns} ns"

if {$wns < 0} {
    puts "  \[WARN\] WNS < 0 — applying AggressiveExplore directive..."
    phys_opt_design -directive AggressiveExplore
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    puts "  Post-aggressive WNS: ${wns} ns"
}

# ----------------------------------------------------------
# 7. Route Design
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 5/6\] route_design"
puts "============================================================"
route_design

# Post-route physical opt if still negative timing
set wns_post [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "  Post-route WNS: ${wns_post} ns"

if {$wns_post < 0} {
    puts "  \[WARN\] Post-route WNS < 0 — applying post-route phys_opt..."
    phys_opt_design -directive AggressiveExplore
    route_design -tns_cleanup
    set wns_post [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    puts "  Final WNS after post-route fix: ${wns_post} ns"
}

# ----------------------------------------------------------
# 8. Reports
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 6/6\] Generating Reports"
puts "============================================================"

report_timing_summary \
    -file          $OUTDIR/vc707_timing_summary.rpt \
    -max_paths     10 \
    -report_unconstrained

report_utilization \
    -file          $OUTDIR/vc707_utilization.rpt \
    -hierarchical  \
    -hierarchical_depth 4

# Vector-driven power (0.5 activity factor — typical switching estimate)
report_power \
    -file          $OUTDIR/vc707_power.rpt \
    -xpe           $OUTDIR/vc707_power.xpe

# Save routed checkpoint for waveform debug / incremental impl
write_checkpoint -force $OUTDIR/vc707_route.dcp

# ----------------------------------------------------------
# 9. Console Summary
# ----------------------------------------------------------
set wns_final [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set pass_fail [expr {$wns_final >= 0 ? "PASS" : "FAIL — TIMING NOT CLOSED"}]

puts ""
puts "============================================================"
puts "  Implementation COMPLETE: $TOP on $PART"
puts "  Clock Target : ${CLK_PERIOD} ns  (250 MHz)"
puts "  Final WNS    : ${wns_final} ns  (${pass_fail})"
puts "============================================================"
puts "  Reports written to: $OUTDIR/"
puts "    vc707_timing_summary.rpt"
puts "    vc707_utilization.rpt"
puts "    vc707_power.rpt"
puts "    vc707_route.dcp"
puts "============================================================"

# Print inline utilization for quick console review
report_utilization -return_string
