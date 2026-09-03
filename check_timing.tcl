open_checkpoint impl_results/artix7/artix7_route.dcp

puts "=== Evaluating 200 MHz (5.000 ns) ==="
create_clock -period 5.000 -name aclk [get_ports aclk]
report_timing_summary -max_paths 1 -file impl_results/artix7/timing_200mhz.rpt
set wns200 [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "200 MHz WNS: $wns200 ns"

puts "=== Evaluating 150 MHz (6.666 ns) ==="
create_clock -period 6.666 -name aclk [get_ports aclk]
report_timing_summary -max_paths 1 -file impl_results/artix7/timing_150mhz.rpt
set wns150 [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "150 MHz WNS: $wns150 ns"

puts "=== Evaluating 100 MHz (10.000 ns) ==="
create_clock -period 10.000 -name aclk [get_ports aclk]
report_timing_summary -max_paths 1 -file impl_results/artix7/timing_100mhz.rpt
set wns100 [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "100 MHz WNS: $wns100 ns"

exit
