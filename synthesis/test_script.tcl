# test_script.tcl
read_libs ../lib/slow_vdd1v0_basicCells.lib
read_hdl -sv test_read.v
elaborate test_read
syn_map
report_area
exit