# 100.000 MHz Clock Constraint (10.000 ns period) for Artix-7 xc7a200tffg1156-2
create_clock -period 10.000 -name aclk -waveform {0.000 5.000} [get_ports aclk]

# Note for speed-grade -3 parts (xc7a200tffg1156-3), timing closes at 125 MHz (8.000 ns period):
# create_clock -period 8.000 -name aclk -waveform {0.000 4.000} [get_ports aclk]