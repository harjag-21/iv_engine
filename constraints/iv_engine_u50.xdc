# =========================================================
# Xilinx Design Constraints (XDC)
# Board      : Alveo U50 Data Center Accelerator Card
# Device     : xcu50-fsvh2104-2-e  (UltraScale+)
# Design Top : iv_multi_engine_top
# Clock      : PCIe 100 MHz refclk → MMCM → 300 MHz aclk
#              (Alternatively: XDMA IP provides 250 MHz AXI clock directly)
# =========================================================
# NOTE (OOC Flow):
#   For Out-of-Context P&R (run_impl_u50.tcl), the primary clock is
#   created in the script on the virtual port 'aclk'. This XDC applies
#   when integrating into the XDMA block design (xdma_bd.tcl) where
#   the AXI user clock is generated from the XDMA IP's axi_aclk output.
# =========================================================

# ----------------------------------------------------------
# Primary Reference Clock: PCIe Differential 100 MHz
# Bank 227 — PCIe edge fingers
# (Actual pin assignment managed by XDMA IP; listed for reference)
# ----------------------------------------------------------
# set_property PACKAGE_PIN AB6 [get_ports pcie_refclk_p]
# set_property PACKAGE_PIN AB5 [get_ports pcie_refclk_n]

# 100 MHz PCIe reference clock constraint
# create_clock -period 10.000 -name pcie_refclk [get_ports pcie_refclk_p]

# ----------------------------------------------------------
# Derived AXI User Clock: 300 MHz aclk from XDMA axi_aclk
# The XDMA IP generates axi_aclk at configurable frequency.
# Target: 300 MHz for UltraScale+ (3.333 ns period)
# ----------------------------------------------------------
create_clock -period 3.333 -name aclk [get_ports aclk]

# ----------------------------------------------------------
# PCIe Persistence Reset (pcie_perstn)
# Active Low. XDMA IP manages this internally; false path for IV engine.
# ----------------------------------------------------------
set_false_path -from [get_ports aresetn]

# ----------------------------------------------------------
# AXI4-Stream Port Timing Constraints (300 MHz)
# Period = 3.333 ns → tighter I/O budgets vs VC707
# ----------------------------------------------------------
# Input delay: s_axis_tvalid, s_axis_tdata[255:0]
set_input_delay  -clock aclk -max 1.000 [get_ports {s_axis_tvalid s_axis_tdata[*]}]
set_input_delay  -clock aclk -min 0.300 [get_ports {s_axis_tvalid s_axis_tdata[*]}]

# Input delay: m_axis_tready
set_input_delay  -clock aclk -max 1.000 [get_ports m_axis_tready]
set_input_delay  -clock aclk -min 0.300 [get_ports m_axis_tready]

# Output delay: s_axis_tready
set_output_delay -clock aclk -max 1.000 [get_ports s_axis_tready]
set_output_delay -clock aclk -min -0.500 [get_ports s_axis_tready]

# Output delay: m_axis_tvalid, m_axis_tdata[63:0]
set_output_delay -clock aclk -max 1.000 [get_ports {m_axis_tvalid m_axis_tdata[*]}]
set_output_delay -clock aclk -min -0.500 [get_ports {m_axis_tvalid m_axis_tdata[*]}]

# ----------------------------------------------------------
# UltraScale+ Specific: Multi-Die / SLR Constraints (U50 is single SLR)
# The xcu50 has 1 SLR — no Laguna register / SLR crossing needed.
# ----------------------------------------------------------

# ----------------------------------------------------------
# Bitstream / Configuration Properties (Alveo U50)
# Secondary PROM via XDMA shell; these are informational only.
# ----------------------------------------------------------
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
