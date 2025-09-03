set_db init_lib_search_path ../lib/
set_db init_hdl_search_path ../rtl/
read_libs slow_vdd1v0_basicCells.lib
read_hdl counter.v
elaborate 
read_sdc ../constraints/constraints_top.sdc

set_db dft_scan_style muxed_scan 
set_db dft_prefix dft_
define_shift_enable -name SE -active high -create_port SE
check_dft_rules

set_db syn_generic_effort medium
syn_generic
set_db syn_map_effort medium
syn_map
set_db syn_opt_effort medium
syn_opt

check_dft_rules 
set_db design:counter .dft_min_number_of_scan_chains 1 
define_scan_chain -name top_chain -sdi scan_in -sdo scan_out -create_ports  

connect_scan_chains -auto_create_chains 
syn_opt -incremental

report_scan_chains 
write_dft_atpg -library ../lib/slow_vdd1v0_basiccells.v
write_hdl > outputs/counter_netlist_dft.v
write_sdc > outputs/counter_sdc_dft.sdc
write_sdf -nonegchecks -edges check_edge -timescale ns -recrem split  -setuphold split > outputs/dft_delays.sdf
write_scandef > outputs/counter_scanDEF.scandef


