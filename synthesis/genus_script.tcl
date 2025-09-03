# ===================================================================
# Genus Synthesis Script for "Neuromorphic Core (v2, Competition-Ready)"
# ===================================================================

# --- 0) 사용자 수정 지점 ------------------------------------------------------
# 필요시 최상위(top)를 neuron_top 으로 바꾸면 됨.
set my_design "ai_neuron_top_comp_v2"

# 경로는 본인 환경에 맞게 수정
set rtl_path "/home/aiasic25429/counter_design_database_45nm/rtl"
set lib_path "/home/aiasic25429/counter_design_database_45nm/lib"
set target_library "slow_vdd1v0_basicCells.lib"

# --- 1) 라이브러리 설정 -------------------------------------------------------
set TARGET_LIBS [list "${lib_path}/${target_library}"]
set_db target_library $TARGET_LIBS
set_db link_library   $TARGET_LIBS

# (옵션) 물리 전용 셀 제외(ANTENNA/TAP/FILL/DECAP 등) - 경고 억제 & 사용 금지
set ant_cells [get_lib_cells -regexp {.*(ANTENNA|DECAP|FILL|TAP).*}]
if { [sizeof_collection $ant_cells] > 0 } {
    set_db $ant_cells .dont_use true
}

# --- 2) RTL 파일 목록 ---------------------------------------------------------
# 이번 버전은 SystemVerilog(.sv) 권장. 확장자가 .v 여도 -sv로 읽을 수 있음.
set_db hdl_search_path [list $rtl_path]

set rtl_files [list]
# 순서는 크게 중요치 않지만 가독성을 위해 상위→하위로 나열
lappend rtl_files  \
    "${rtl_path}/ai_neuron_top_comp_v2.sv" \
    "${rtl_path}/cortical_neuron_core_tm.sv" \
    "${rtl_path}/dynamic_synapse_processor_stream.sv" \
    "${rtl_path}/state_dependent_plasticity.sv" \
    "${rtl_path}/network_state_monitor.sv" \
    "${rtl_path}/power_manager.sv" \
    "${rtl_path}/weight_ram_adjlist.sv" \
    "${rtl_path}/neuron_top.sv"

# 파일 존재 여부 점검(디버깅에 도움)
foreach f $rtl_files {
    if {![file exists $f]} {
        puts "WARNING: RTL file not found: $f"
    }
}

# --- 3) 읽기 & 엘라보 ---------------------------------------------------------
# 지난 이슈(파싱/블랙박스) 방지: -sv 사용, 필요시 매크로는 -define에 추가
read_hdl -sv -define {SYNTHESIS} $rtl_files
elaborate $my_design
current_design $my_design

# 빠른 일차 점검
check_design > ./reports/check_design.rpt

# --- 4) 타이밍 제약 -----------------------------------------------------------
# 기본 100MHz(10ns). 필요시 변경
if {![file isdirectory "./reports"]} { file mkdir "./reports" }
if {![file isdirectory "./outputs"]} { file mkdir "./outputs" }

create_clock -name clk -period 10.0 -waveform {0 5} [get_ports clk]
set_clock_uncertainty 0.2 [get_clocks clk]
# 비동기 리셋 비경로
set_false_path -from [get_ports reset]

# 보수적인 IO 타이밍
set_input_delay  2.0 -clock clk [remove_from_collection [all_inputs]  [get_ports {clk reset}]]
set_output_delay 2.0 -clock clk [all_outputs]

# (옵션) 드라이빙/로드 모델이 있으면 활성화
# set_driving_cell -lib_cell INV_X1 [remove_from_collection [all_inputs] [get_ports {clk reset}]]
# set_load 0.05 [all_outputs]

# --- 5) 합성 플로우 -----------------------------------------------------------
syn_generic  -effort high
syn_map      -effort high
syn_opt      -effort high

# --- 6) 리포트 ---------------------------------------------------------------
report_qor               > ./reports/qor_summary.rpt
report_power             > ./reports/power_report.rpt
report_area              > ./reports/area_report.rpt
report_timing -delay max > ./reports/timing_report_max.rpt
report_timing -delay min > ./reports/timing_report_min.rpt
report_constraints -all_violators > ./reports/constraint_violators.rpt

# (옵션) 계층/클럭/팬아웃 확인
report_hierarchy         > ./reports/hierarchy.rpt
report_clocks            > ./reports/clocks.rpt
report_fanout -threshold 50 > ./reports/high_fanout.rpt

# --- 7) 넷리스트/제약 출력 ----------------------------------------------------
write_hdl -mapped > ./outputs/${my_design}_netlist.v
write_sdc         > ./outputs/${my_design}.sdc

# Innovus 연계 산출물(권장)
write_design -innovus -base_name ./outputs/${my_design}_innovus

puts "✅ Synthesis for [get_db design_name] completed successfully."
exit
