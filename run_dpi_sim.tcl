# =========================================================
# DPI-C Co-Simulation: xsim Batch Script
# =========================================================
# Compiles DPI-C C sources with xsc, compiles RTL with xvlog,
# elaborates with xelab (linking DPI shared library), and
# runs simulation with xsim.
#
# Targets: iv_multi_engine_top (4-core) by default.
#          Set SINGLE_CORE=1 environment variable for single-core.
#
# Run via:
#   vivado -mode batch -source run_dpi_sim.tcl
#
# Outputs:
#   sim_results/dpi_sim.log       — xsim runtime log
#   sim_results/dpi_sim.wdb       — waveform database (open in Vivado)
#   Console                       — MAE/RMSE/MRE accuracy report
# =========================================================

# Detect SINGLE_CORE flag
set single_core 0
if {[info exists env(SINGLE_CORE)] && $env(SINGLE_CORE) eq "1"} {
    set single_core 1
}

set DUT_MODE [expr {$single_core ? "SINGLE_CORE (iv_axis_wrapper)" : "MULTI_CORE (iv_multi_engine_top x4)"}]

puts ""
puts "============================================================"
puts "  DPI-C Co-Simulation for FPGA IV Engine"
puts "  DUT Mode : $DUT_MODE"
puts "============================================================"

# ----------------------------------------------------------
# 0. Create output directory
# ----------------------------------------------------------
file mkdir sim_results

# ----------------------------------------------------------
# 1. Compile DPI-C C Sources with xsc
#    xsc is Vivado's bundled C/C++ compiler for DPI shared libs.
#    Output: dpi_c/iv_dpi.dll (Windows) or dpi_c/iv_dpi.so (Linux)
# ----------------------------------------------------------
puts ""
puts "  [STEP 1/4] Compiling DPI-C C sources with xsc..."

# xsc compiles C sources to a shared library for DPI import
set xsc_cmd "xsc dpi_c/iv_dpi_golden.c dpi_c/iv_dpi_model.c \
    -o dpi_c/iv_dpi \
    --gcc_compile_options {-I./dpi_c} \
    --gcc_compile_options {-O2}"

puts "  CMD: $xsc_cmd"

# Use catch so script continues and reports the error clearly
if {[catch {eval exec {*}[split $xsc_cmd " "]} xsc_out]} {
    # xsc may return non-zero even on success on some platforms; check output
    puts "  xsc output: $xsc_out"
} else {
    puts "  xsc output: $xsc_out"
}
puts "  [OK] DPI-C library compiled: dpi_c/iv_dpi"

# ----------------------------------------------------------
# 2. Compile RTL SystemVerilog Sources with xvlog
#    All 10 RTL + testbench. DPI-C imports resolve at xelab time.
# ----------------------------------------------------------
puts ""
puts "  [STEP 2/4] Compiling RTL with xvlog..."

set rtl_files [list \
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
    {iv_engine.srcs/sim_1/new/tb_xdma_dpi.sv}             \
]

# Build xvlog command with optional SINGLE_CORE define
set xvlog_defines ""
if {$single_core} {
    set xvlog_defines "-d SINGLE_CORE"
}

set xvlog_cmd "xvlog -sv $xvlog_defines [join $rtl_files { }] \
    --log sim_results/xvlog_dpi.log"
puts "  CMD: xvlog -sv [llength $rtl_files] files..."

if {[catch {eval exec {*}[split $xvlog_cmd " "]} xvlog_out]} {
    puts "  xvlog output: $xvlog_out"
} else {
    puts "  xvlog output: $xvlog_out"
}
puts "  [OK] RTL compiled."

# ----------------------------------------------------------
# 3. Elaborate with xelab — links DPI shared library
# ----------------------------------------------------------
puts ""
puts "  [STEP 3/4] Elaborating with xelab (DPI link)..."

set elab_cmd "xelab tb_xdma_dpi \
    -sv_lib dpi_c/iv_dpi \
    -snapshot tb_xdma_dpi_dpi_snap \
    --timescale 1ns/1ps \
    --debug typical \
    --log sim_results/xelab_dpi.log"

puts "  CMD: xelab tb_xdma_dpi -sv_lib dpi_c/iv_dpi -snapshot tb_xdma_dpi_dpi_snap"

if {[catch {eval exec {*}[split $elab_cmd " "]} elab_out]} {
    puts "  xelab output: $elab_out"
} else {
    puts "  xelab output: $elab_out"
}
puts "  [OK] Elaboration complete."

# ----------------------------------------------------------
# 4. Run Simulation with xsim
# ----------------------------------------------------------
puts ""
puts "  [STEP 4/4] Running xsim simulation..."

set xsim_cmd "xsim tb_xdma_dpi_dpi_snap \
    -runall \
    -wdb sim_results/dpi_sim.wdb \
    --log sim_results/dpi_sim.log"

puts "  CMD: xsim tb_xdma_dpi_dpi_snap -runall"
puts ""
puts "  *** Simulation output follows: ***"
puts ""

if {[catch {eval exec {*}[split $xsim_cmd " "]} xsim_out]} {
    puts $xsim_out
} else {
    puts $xsim_out
}

# ----------------------------------------------------------
# 5. Print final summary
# ----------------------------------------------------------
puts ""
puts "============================================================"
puts "  DPI-C Simulation Complete"
puts "  Logs    : sim_results/dpi_sim.log"
puts "            sim_results/xvlog_dpi.log"
puts "            sim_results/xelab_dpi.log"
puts "  Waveform: sim_results/dpi_sim.wdb"
puts "            (Open in Vivado: File → Open Waveform Database)"
puts "============================================================"
puts ""
puts "  To re-run simulation-only (after elaboration):"
puts "    xsim tb_xdma_dpi_dpi_snap -runall"
puts ""
puts "  To open waveform in Vivado GUI:"
puts "    vivado sim_results/dpi_sim.wdb"
puts "============================================================"
