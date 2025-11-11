# ===== top.sdc =====
create_clock -name clk -period 10.0 [get_ports clk]     ;# 100MHz
set_clock_uncertainty 0.2 [get_clocks clk]

# 비동기 리셋 네트워크는 타이밍 제외 + 버퍼 보호
set_false_path -from [get_ports rst_n]
set_dont_touch_network [get_ports rst_n]

# I/O 타이밍 여유 (보수적으로 2ns)
set in_ex   [remove_from_collection [all_inputs]  [get_ports {clk rst_n}]]
set out_all [all_outputs]
set_input_delay  2.0 -clock clk $in_ex
set_output_delay 2.0 -clock clk $out_all

# DRC 목표치(과도/팬아웃)
set_max_transition 0.20 $out_all
set_max_fanout     16   [current_design]
