# Auto-generated SDC
set_units -time ns -capacitance pF
create_clock -name clk -period 10.0 [get_ports clk]
set_clock_uncertainty 0.10 [get_clocks clk]
set in_no_clk [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay  1.0 -clock [get_clocks clk] $in_no_clk
set_output_delay 1.0 -clock [get_clocks clk] [all_outputs]
set_load 0.02 [all_outputs]
