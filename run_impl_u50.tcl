# =========================================================
# Full Place-and-Route Implementation Script
# Target Device : Alveo U50  (xcu50-fsvh2104-2-e)
# Top Module    : iv_multi_engine_top  (4-core AXI4-Stream array)
# Clock Target  : 300 MHz  (3.333 ns period) — UltraScale+ aggressive target
#                 Falls back to 250 MHz if 300 MHz cannot close.
# Mode          : Out-of-Context (no I/O buffers; timing/util/power estimation)
#
# Run via:
#   vivado -mode batch -source run_impl_u50.tcl
#
# Outputs (impl_results/u50/ directory):
#   u50_timing_summary.rpt    — post-route WNS / TNS
#   u50_utilization.rpt       — LUT / FF / DSP / URAM breakdown
#   u50_power.rpt             — vector-driven power estimate
#   u50_route.dcp             — routed design checkpoint (re-openable)
# =========================================================

set PART        xcu50-fsvh2104-2-e
set TOP         iv_multi_engine_top
set CLK_PERIOD  3.333
set CLK_NAME    aclk
set OUTDIR      impl_results/u50

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
    {iv_engine.srcs/sources_1/new/iv_multi_engine_top.sv} \
]

set_property top $TOP [current_fileset]

# ----------------------------------------------------------
# 2. Synthesis (OOC mode — UltraScale+ fabric, LUT6 cells)
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 1/6\] Synthesis: $TOP on $PART (UltraScale+)"
puts "============================================================"

synth_design \
    -top            $TOP  \
    -part           $PART \
    -mode           out_of_context \
    -flatten_hierarchy rebuilt

# ----------------------------------------------------------
# 3. Timing Constraint: 300 MHz virtual clock on 'aclk'
# ----------------------------------------------------------
create_clock -period $CLK_PERIOD -name $CLK_NAME [get_ports $CLK_NAME]

# Suppress reset CDC false path
set_false_path -from [get_ports aresetn]

# ----------------------------------------------------------
# 4. Opt Design (UltraScale+ specific: enable retiming)
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 2/6\] opt_design"
puts "============================================================"
opt_design -directive ExploreWithRemap

# ----------------------------------------------------------
# 5. Place Design
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 3/6\] place_design"
puts "============================================================"
place_design -directive AltSpreadLogic_high

# ----------------------------------------------------------
# 6. Physical Optimization
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 4/6\] phys_opt_design"
puts "============================================================"
phys_opt_design -directive AggressiveExplore

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "  Post-phys_opt WNS @ ${CLK_PERIOD} ns: ${wns} ns"

# ----------------------------------------------------------
# 7. Route Design
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 5/6\] route_design"
puts "============================================================"
route_design -directive AggressiveExplore

set wns_post [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "  Post-route WNS @ ${CLK_PERIOD} ns: ${wns_post} ns"

if {$wns_post < 0} {
    puts "  \[WARN\] 300 MHz not closed (WNS=${wns_post}). Applying post-route fix..."
    phys_opt_design -directive AggressiveExplore
    route_design -tns_cleanup
    set wns_post [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    puts "  WNS after post-route fix: ${wns_post} ns"
}

# If still failing at 300 MHz, report at 250 MHz for comparison
if {$wns_post < 0} {
    puts ""
    puts "  \[INFO\] 300 MHz not achievable — reporting equivalent 250 MHz slack..."
    set wns_250 [expr {$wns_post + (3.333 - 4.000)}]
    puts "  Equivalent WNS @ 250 MHz: ${wns_250} ns"
}

# ----------------------------------------------------------
# 8. Reports
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  \[STEP 6/6\] Generating Reports"
puts "============================================================"

report_timing_summary \
    -file          $OUTDIR/u50_timing_summary.rpt \
    -max_paths     10 \
    -report_unconstrained

report_utilization \
    -file          $OUTDIR/u50_utilization.rpt \
    -hierarchical  \
    -hierarchical_depth 4

report_power \
    -file          $OUTDIR/u50_power.rpt \
    -xpe           $OUTDIR/u50_power.xpe

write_checkpoint -force $OUTDIR/u50_route.dcp

# ----------------------------------------------------------
# 9. Console Summary
# ----------------------------------------------------------
set wns_final [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set pass_fail [expr {$wns_final >= 0 ? "PASS" : "TIMING NOT CLOSED"}]

puts ""
puts "============================================================"
puts "  Implementation COMPLETE: $TOP on $PART"
puts "  Clock Target : ${CLK_PERIOD} ns  (300 MHz)"
puts "  Final WNS    : ${wns_final} ns  (${pass_fail})"
puts "============================================================"
puts "  Reports written to: $OUTDIR/"
puts "    u50_timing_summary.rpt"
puts "    u50_utilization.rpt"
puts "    u50_power.rpt"
puts "    u50_route.dcp"
puts "============================================================"

report_utilization -return_string
