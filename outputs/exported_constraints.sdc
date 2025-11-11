# ####################################################################

#  Created by Genus(TM) Synthesis Solution 23.14-s090_1 on Sun Nov 02 19:31:54 KST 2025

# ####################################################################

set sdc_version 2.0

set_units -capacitance 1000fF
set_units -time 1000ps

# Set the current design
current_design ai_neuron_top_comp_v2

create_clock -name "clk" -period 10.0 -waveform {0.0 5.0} [get_ports clk]
set_false_path -from [get_ports rst_n]
set_clock_gating_check -setup 0.0 
set_max_fanout 16.000 [current_design]
set_dont_touch_network [get_ports rst_n]
set_wire_load_mode "enclosed"
set_clock_uncertainty -setup 0.2 [get_clocks clk]
set_clock_uncertainty -hold 0.2 [get_clocks clk]
