set all_families {}
foreach p [get_parts] {
    set fam [get_property FAMILY $p]
    if {[lsearch -exact $all_families $fam] == -1} {
        lappend all_families $fam
    }
}
puts "Installed FPGA Families: $all_families"
puts "200T parts: [get_parts *200t*]"
puts "Kintex parts: [get_parts *7k*]"
puts "UltraScale parts: [get_parts *ku*] [get_parts *vu*] [get_parts *u50*]"
exit
