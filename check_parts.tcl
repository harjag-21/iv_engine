set all_families {}
foreach p [get_parts] {
    set fam [get_property FAMILY $p]
    if {[lsearch -exact $all_families $fam] == -1} {
        lappend all_families $fam
    }
}
puts "Installed FPGA Families: $all_families"
puts "Top Artix-7 -3 parts: [lrange [get_parts -filter {FAMILY == artix7 && SPEED == -3}] 0 10]"
exit
