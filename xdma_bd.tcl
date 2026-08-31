# =========================================================
# Vivado IP Integrator Block Design Script
# Design    : iv_engine_xdma
# Purpose   : Wire AMD XDMA v4.1 IP to iv_multi_engine_top
#             for full PCIe DMA streaming integration.
#
# Connections:
#   XDMA m_axis_h2c_tdata[255:0] → iv_multi_engine_top s_axis_tdata[255:0]
#   XDMA m_axis_h2c_tvalid        → iv_multi_engine_top s_axis_tvalid
#   iv_multi_engine_top s_axis_tready → XDMA m_axis_h2c_tready
#
#   iv_multi_engine_top m_axis_tdata[63:0] → (zero-padded to 256b) → XDMA s_axis_c2h_tdata
#   iv_multi_engine_top m_axis_tvalid      → XDMA s_axis_c2h_tvalid
#   XDMA s_axis_c2h_tready                → iv_multi_engine_top m_axis_tready
#
# Run via (within a Vivado project that has RTL sources added):
#   source xdma_bd.tcl
#
# Or from batch mode:
#   vivado -mode batch -source xdma_bd.tcl
#   (Script creates the project automatically if run standalone)
# =========================================================

# ----------------------------------------------------------
# 0. Detect whether we are inside an open project or standalone
# ----------------------------------------------------------
set is_standalone 0
if {[catch {current_project}]} {
    set is_standalone 1
}

if {$is_standalone} {
    puts "  \[INFO\] No open project — creating iv_engine_xdma project..."
    create_project iv_engine_xdma ./iv_engine_xdma_proj -part xcu50-fsvh2104-2-e -force

    # Add all RTL sources to the project
    add_files [list \
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
    set_property file_type {SystemVerilog} [get_files *.sv]
    update_compile_order -fileset sources_1
}

# ----------------------------------------------------------
# 1. Create the Block Design
# ----------------------------------------------------------
set bd_name iv_engine_xdma
create_bd_design $bd_name

# ----------------------------------------------------------
# 2. Instantiate XDMA IP
# ----------------------------------------------------------
puts ""
puts "  \[BD\] Adding XDMA IP..."

# Product Guide: PG195 — Xilinx DMA Subsystem for PCI Express (XDMA)
create_bd_cell -type ip -vlnv xilinx.com:ip:xdma:4.1 xdma_0

# Configure for AXI4-Stream H2C + C2H, PCIe Gen3 x8, 256-bit data width
set_property -dict [list \
    CONFIG.mode_selection              {Basic}        \
    CONFIG.pl_link_cap_max_link_width  {X8}           \
    CONFIG.pl_link_cap_max_link_speed  {8.0_GT/s}     \
    CONFIG.axist_bypass_en             {false}         \
    CONFIG.axi_data_width              {256_bit}       \
    CONFIG.axilite_master_en           {false}         \
    CONFIG.pcie_id_if                  {false}         \
    CONFIG.c_s_axi_num_write           {8}             \
    CONFIG.c_s_axi_num_read            {8}             \
    CONFIG.pf0_device_id               {9038}          \
    CONFIG.pf0_sub_class_interface_menu {Other_memory_controller} \
    CONFIG.xdma_axi_intf_mm            {AXI_Stream}   \
    CONFIG.dsc_bypass_rd               {0000}         \
    CONFIG.dsc_bypass_wr               {0000}         \
    CONFIG.c_gen3_speed_support        {1}             \
] [get_bd_cells xdma_0]

# ----------------------------------------------------------
# 3. Instantiate iv_multi_engine_top as a Module Reference
#    (RTL module, not an IP — Vivado BD supports this natively)
# ----------------------------------------------------------
puts "  \[BD\] Adding iv_multi_engine_top module reference..."

create_bd_cell -type module -reference iv_multi_engine_top iv_engine_0

# ----------------------------------------------------------
# 4. Instantiate AXI4-Stream Data Width Converter
#    iv_multi_engine_top output is 64-bit; XDMA C2H needs 256-bit.
#    The converter zero-pads the 64-bit IV result to 256 bits.
# ----------------------------------------------------------
puts "  \[BD\] Adding AXI4-Stream Data Width Converter (64→256 bit)..."

create_bd_cell -type ip -vlnv xilinx.com:ip:axis_dwidth_converter:1.1 dwidth_conv_c2h_0

set_property -dict [list \
    CONFIG.S_TDATA_NUM_BYTES {8}   \
    CONFIG.M_TDATA_NUM_BYTES {32}  \
    CONFIG.HAS_TLAST         {1}   \
    CONFIG.HAS_TKEEP         {1}   \
] [get_bd_cells dwidth_conv_c2h_0]

# ----------------------------------------------------------
# 5. Instantiate Processor System Reset for aclk domain
# ----------------------------------------------------------
puts "  \[BD\] Adding Processor System Reset..."

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 sys_reset_0

# ----------------------------------------------------------
# 6. Create External Ports
# ----------------------------------------------------------
puts "  \[BD\] Creating external I/O ports..."

# PCIe differential reference clock (100 MHz)
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 pcie_refclk

# PCIe lane interface (x8)
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:pcie_7x_mgt_rtl:1.0 pcie_mgt

# PCIe persistence reset (active low)
create_bd_port -dir I -type rst pcie_perstn
set_property CONFIG.POLARITY ACTIVE_LOW [get_bd_ports pcie_perstn]

# ----------------------------------------------------------
# 7. Connect PCIe Physical Interfaces to XDMA
# ----------------------------------------------------------
puts "  \[BD\] Connecting PCIe physical interfaces..."

connect_bd_intf_net [get_bd_intf_ports pcie_refclk] \
                    [get_bd_intf_pins  xdma_0/pcie_refclk]

connect_bd_intf_net [get_bd_intf_ports pcie_mgt] \
                    [get_bd_intf_pins  xdma_0/pcie_mgt]

connect_bd_net [get_bd_ports pcie_perstn] \
               [get_bd_pins  xdma_0/sys_rst_n]

# ----------------------------------------------------------
# 8. Connect Clocks and Resets
# ----------------------------------------------------------
puts "  \[BD\] Connecting clocks and resets..."

# XDMA generates axi_aclk (user AXI clock) and axi_aresetn
connect_bd_net [get_bd_pins xdma_0/axi_aclk]     [get_bd_pins iv_engine_0/aclk]
connect_bd_net [get_bd_pins xdma_0/axi_aclk]     [get_bd_pins dwidth_conv_c2h_0/aclk]
connect_bd_net [get_bd_pins xdma_0/axi_aclk]     [get_bd_pins sys_reset_0/slowest_sync_clk]

connect_bd_net [get_bd_pins xdma_0/axi_aresetn]  [get_bd_pins iv_engine_0/aresetn]
connect_bd_net [get_bd_pins xdma_0/axi_aresetn]  [get_bd_pins dwidth_conv_c2h_0/aresetn]
connect_bd_net [get_bd_pins xdma_0/axi_aresetn]  [get_bd_pins sys_reset_0/ext_reset_in]

# ----------------------------------------------------------
# 9. Connect H2C (Host-to-Card): XDMA → iv_engine_0
#    XDMA m_axis_h2c[0] is 256-bit — matches iv_multi_engine_top input
# ----------------------------------------------------------
puts "  \[BD\] Connecting H2C data path: XDMA → iv_engine_0..."

connect_bd_intf_net [get_bd_intf_pins xdma_0/M_AXIS_H2C_0] \
                    [get_bd_intf_pins iv_engine_0/S_AXIS]

# ----------------------------------------------------------
# 10. Connect C2H (Card-to-Host): iv_engine_0 → dwidth_conv → XDMA
#     iv_engine_0 output is 64-bit; dwidth_conv pads to 256-bit.
# ----------------------------------------------------------
puts "  \[BD\] Connecting C2H data path: iv_engine_0 → dwidth_conv → XDMA..."

connect_bd_intf_net [get_bd_intf_pins iv_engine_0/M_AXIS] \
                    [get_bd_intf_pins dwidth_conv_c2h_0/S_AXIS]

connect_bd_intf_net [get_bd_intf_pins dwidth_conv_c2h_0/M_AXIS] \
                    [get_bd_intf_pins xdma_0/S_AXIS_C2H_0]

# ----------------------------------------------------------
# 11. Validate & Auto-Assign Addresses
# ----------------------------------------------------------
puts "  [BD] Validating block design..."
validate_bd_design

puts "  [BD] Auto-assigning address map..."
assign_bd_address

# ----------------------------------------------------------
# 12. Generate Block Design Output Products
# ----------------------------------------------------------
puts "  [BD] Generating output products (synthesis files + wrapper)..."
generate_target all [get_files ${bd_name}.bd]

# Create HDL wrapper (auto-manages top-level port names)
make_wrapper -files [get_files ${bd_name}.bd] -top
set bd_wrapper [glob -nocomplain ./iv_engine_xdma_proj/iv_engine_xdma_proj.gen/sources_1/bd/${bd_name}/hdl/${bd_name}_wrapper.v]
if {[llength $bd_wrapper] > 0} {
    add_files -norecurse $bd_wrapper
    set_property top ${bd_name}_wrapper [current_fileset]
    update_compile_order -fileset sources_1
}

# ----------------------------------------------------------
# 13. Save Block Design
# ----------------------------------------------------------
save_bd_design

puts ""
puts "============================================================"
puts "  Block Design '${bd_name}' created successfully!"
puts "  Top Wrapper  : ${bd_name}_wrapper"
puts "  XDMA IP      : xdma_0 (Gen3 x8, 256-bit AXI4-Stream)"
puts "  IV Engine    : iv_engine_0 (iv_multi_engine_top, 4 cores)"
puts "  C2H Width    : 64-bit → 256-bit via axis_dwidth_converter"
puts "============================================================"
puts "  Next: Run synthesis and implementation on ${bd_name}_wrapper"
puts "        or open the block design GUI to inspect connections."
puts "============================================================"
