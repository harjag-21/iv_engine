# =========================================================
# Vivado Custom IP Packaging Script
# =========================================================
# Packages the IV Hardware Acceleration Engine as a reusable
# Vivado Custom IP core for IP Integrator / Block Designs.
# =========================================================

# 1. Open project if not already open
if {[catch {current_project}]} {
    open_project iv_engine.xpr
}

# 2. Create target IP repository directory
set repo_dir "C:/Users/user/iv_engine/ip_repo"
file mkdir $repo_dir

# 3. Package current project into the IP repository
ipx::package_project -root_dir $repo_dir -vendor iitkgp.ac.in -library hft_acceleration -taxonomy /Financial_Acceleration -import_files -force

# 3. Set IP Core Identification Metadata
set core [ipx::current_core]
set_property name iv_hardware_acceleration_engine $core
set_property display_name "FPGA-Accelerated Implied Volatility Engine" $core
set_property description "Zero-bubble 250 MHz hyperbolic CORDIC & Black-Scholes option Implied Volatility calculation engine with AXI4-Stream interface." $core
set_property version 1.0 $core
set_property vendor_display_name "IIT Kharagpur EECE" $core
set_property company_url "https://www.iitkgp.ac.in" $core

# 4. Save and close IP definition
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::save_core $core

puts "========================================================="
puts "SUCCESS: IP Core packaged at $repo_dir"
puts "========================================================="
