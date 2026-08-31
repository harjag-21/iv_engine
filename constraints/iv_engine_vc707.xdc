# =========================================================
# Xilinx Design Constraints (XDC)
# Board      : Xilinx VC707 Evaluation Board
# Device     : xc7vx485tffg1761-2  (Virtex-7)
# Design Top : iv_multi_engine_top
# Clock      : 200 MHz differential SYSCLK → MMCM → 250 MHz aclk
# =========================================================
# NOTE (OOC Flow):
#   For Out-of-Context Place-and-Route (run_impl_vc707.tcl), the
#   primary clock is created by the script via create_clock on the
#   virtual port 'aclk'. This XDC is used when instantiating
#   iv_multi_engine_top as a sub-module in a full-chip design or
#   XDMA block design that includes the real VC707 differential clock.
# =========================================================

# ----------------------------------------------------------
# Primary Clock: VC707 200 MHz Differential System Clock
# Bank 33 — AD12 (P) / AD11 (N)
# ----------------------------------------------------------
set_property PACKAGE_PIN AD12 [get_ports sys_clk_p]
set_property PACKAGE_PIN AD11 [get_ports sys_clk_n]
set_property IOSTANDARD  LVDS [get_ports sys_clk_p]
set_property IOSTANDARD  LVDS [get_ports sys_clk_n]

# 200 MHz differential input — MMCM inside wrapper converts to 250 MHz
create_clock -period 5.000 -name sys_clk [get_ports sys_clk_p]

# ----------------------------------------------------------
# Derived Clock: 250 MHz aclk from MMCM
# (Uncomment and adjust clk_out1_* path when MMCM is instantiated)
# ----------------------------------------------------------
# create_generated_clock -name aclk \
#     -source [get_pins mmcm_inst/CLKIN1] \
#     -multiply_by 5 -divide_by 4 \
#     [get_pins mmcm_inst/CLKOUT0]

# ----------------------------------------------------------
# Board Reset: VC707 CPU_RESET push-button (SW7)
# Active High → inverted to active-low aresetn in top wrapper
# ----------------------------------------------------------
set_property PACKAGE_PIN AV40 [get_ports cpu_reset]
set_property IOSTANDARD  LVCMOS18 [get_ports cpu_reset]

# Treat reset as false path for timing (async assertion, sync de-assertion by design)
set_false_path -from [get_ports cpu_reset]

# ----------------------------------------------------------
# AXI4-Stream Port Timing Constraints
# Input/Output delay relative to aclk (250 MHz = 4 ns period)
# Assumes external data valid 1.0 ns after aclk rising edge,
# and output must be stable 0.5 ns before next aclk rising edge.
# ----------------------------------------------------------
# Adjust PACKAGE_PIN assignments if connecting to FMC or PMOD connector.

# Input delay: s_axis_tvalid, s_axis_tdata[255:0]
set_input_delay  -clock aclk -max 1.500 [get_ports {s_axis_tvalid s_axis_tdata[*]}]
set_input_delay  -clock aclk -min 0.500 [get_ports {s_axis_tvalid s_axis_tdata[*]}]

# Input delay: m_axis_tready
set_input_delay  -clock aclk -max 1.500 [get_ports m_axis_tready]
set_input_delay  -clock aclk -min 0.500 [get_ports m_axis_tready]

# Output delay: s_axis_tready
set_output_delay -clock aclk -max 1.500 [get_ports s_axis_tready]
set_output_delay -clock aclk -min -0.500 [get_ports s_axis_tready]

# Output delay: m_axis_tvalid, m_axis_tdata[63:0]
set_output_delay -clock aclk -max 1.500 [get_ports {m_axis_tvalid m_axis_tdata[*]}]
set_output_delay -clock aclk -min -0.500 [get_ports {m_axis_tvalid m_axis_tdata[*]}]

# ----------------------------------------------------------
# Bitstream / Configuration Properties (VC707 Board)
# ----------------------------------------------------------
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH  4   [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE    33  [current_design]
set_property CONFIG_MODE                    SPIx4 [current_design]
