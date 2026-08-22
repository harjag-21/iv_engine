# 250 MHz Clock Constraint (4.000 ns period) for AXI4-Stream Wrapper
create_clock -period 4.000 -name aclk -waveform {0.000 2.000} [get_ports aclk]