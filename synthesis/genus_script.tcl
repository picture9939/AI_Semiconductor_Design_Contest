# =============================================================================
# Cadence Genus Synthesis TCL (robust to older builds)
# Project: AI Neuron Top (성현)
# Date   : Fri Oct 31 2025 (KST)
# =============================================================================

# --------------------------
# Project paths
# --------------------------
set proj_root "/home/aiasic25429/counter_design_database_45nm_final"
set rtl_path  [file join $proj_root "rtl"]
set lib_path  [file join $proj_root "lib"]
set sdc_file  [file join $proj_root "constraints" "top.sdc"]

file mkdir [file join $proj_root "reports"]
file mkdir [file join $proj_root "outputs"]
file mkdir [file join $proj_root "fv"]
file mkdir [file join $proj_root "constraints"]

# --------------------------
# Helpers
# --------------------------
proc _try {script} {
  if {[catch {uplevel 1 $script} em]} {
    puts "NOTE: skip '$script' -> $em"
  }
}

proc uniq {lst} {
  set seen {}; set out {}
  foreach x $lst { if {![info exists seen($x)]} { set seen($x) 1; lappend out $x } }
  return $out
}

proc rglob {base pattern {maxdepth 3}} {
  set res {}; set stack [list [list $base 0]]
  while {[llength $stack]} {
    lassign [lindex $stack end] dir depth
    set stack [lrange $stack 0 end-1]
    foreach f [glob -nocomplain -directory $dir $pattern] {
      if {[file isfile $f]} { lappend res $f }
    }
    if {$depth < $maxdepth} {
      foreach d [glob -nocomplain -directory $dir *] {
        if {[file isdirectory $d]} { lappend stack [list $d [expr {$depth+1}]] }
      }
    }
  }
  return $res
}

proc prefer_corner {files} {
  set s [lsearch -all -inline -nocase $files *slow*]
  if {[llength $s]} { return $s }
  set s [lsearch -all -inline -nocase $files *ss*]
  if {[llength $s]} { return $s }
  return $files
}

# --------------------------
# Messaging verbosity (version-safe)
# --------------------------
set_db / .information_level 3
foreach v {false 0 no} { _try "set_db message .truncate $v" }
_try {set_db message .display_limit 100000}
_try {set_db message .buffer_limit  100000}
_try {set_db message .display_width 100000}

# --------------------------
# Search paths
# --------------------------
set_db / .hdl_search_path [list $rtl_path $proj_root]
set_db / .lib_search_path [list $lib_path]

# --------------------------
# Libraries
# --------------------------
set target_library "slow_vdd1v0_basicCells.lib"
set target_lib_full [file join $lib_path $target_library]
set lib_files {}; set db_files {}

if {[file exists $target_lib_full]} {
  set lib_files [list $target_lib_full]
} else {
  set lib_files [rglob $lib_path *.lib 2]
  set db_files  [rglob $lib_path *.db  2]
}

if {[llength $lib_files] > 0} {
  set libs_use [prefer_corner $lib_files]
  puts "INFO: Using Liberty:\n  [join $libs_use \n  ]"
  if {[catch {read_libs -liberty $libs_use} em]} {
    puts "WARN: read_libs -liberty failed -> $em ; fallback to set_db / .library"
    _try {set_db / .library $libs_use}
  }
} elseif {[llength $db_files] > 0} {
  set dbs_use [prefer_corner $db_files]
  puts "INFO: Using DBs:\n  [join $dbs_use \n  ]"
  if {[catch {read_libs -liberty $dbs_use} em2]} {
    puts "WARN: read_libs on .db failed -> $em2 ; fallback to set_db / .library"
    _try {set_db / .library $dbs_use}
  }
} else {
  puts "FATAL: No .lib/.db found in $lib_path"; exit 1
}

puts "DBG lib_cells = [llength [get_db lib_cells]]"
if {[llength [get_db lib_cells]] == 0} { puts "FATAL: No lib cells visible."; exit 1 }

# --------------------------
# RTL set (latest ‘성현’ 세트)
# --------------------------
set required_files {
  ai_neuron_top_comp_v2.sv
  cortical_neuron_core_tm.sv
  dynamic_synapse_processor_stream_v2.sv
  g_pulse_accumulator.sv
  lfsr32.sv
  motor_decoder_4dir.sv
  network_state_monitor.sv
  physics_integrator_2d.sv
  power_manager.sv
  pressure_sensor_field_3ch.sv
  spike_rate_lp.sv
  state_dependent_plasticity.sv
  synapse_event_fifo.sv
  tof_delay_line.sv
  weight_ram_adjlist.sv
}

set rtl_list {}; set missing {}
foreach f $required_files {
  set p [file join $rtl_path $f]
  if {[file exists $p]} { lappend rtl_list $p } else { lappend missing $f }
}
if {[llength $missing] > 0} { puts "FATAL: Missing RTL:\n  [join $missing \n  ]"; exit 1 }

# --------------------------
# Top & Elaboration
# --------------------------
set my_design "ai_neuron_top_comp_v2"

# Enable filename:row:col tracking for datapath report (must be before elaborate)
_try {set_db / .hdl_track_filename_row_col true}

if {[catch {read_hdl -sv $rtl_list} em_hdl]} { puts "FATAL: read_hdl failed -> $em_hdl"; exit 1 }
if {[catch {elaborate $my_design} em_elab]} { puts "FATAL: elaborate $my_design failed -> $em_elab"; exit 1 }

# --------------------------
# Constraints (default clock if no SDC)
# --------------------------
if {[file exists $sdc_file]} {
  puts "INFO: Reading SDC $sdc_file"
  _try {read_sdc $sdc_file}
} else {
  puts "WARN: SDC not found -> creating default 100MHz clock on 'clk' (if exists)"
  if {[llength [get_db ports clk]]} { _try {create_clock -name clk -period 10 [get_ports clk]} }
  # Optional global limits to keep fanout sane on older builds:
  _try {set_max_fanout 64 [current_design]}
}

# --------------------------
# Control ungrouping & preserve regs/nets
# --------------------------
_try {set_db / .auto_ungroup none}
_try {set_db / .delete_unloaded_insts           false}
_try {set_db / .delete_unloaded_seqs            false}
_try {set_db / .elab_delete_unloaded_insts      false}
_try {set_db / .elab_delete_unloaded_seqs       false}
_try {set_db / .optimize_constant_feedback_seqs false}
_try {set_db / .optimize_merge_flops            false}
_try {set_db / .optimize_merge_latches          false}
_try {set_db / .preserve_unconnected_signals    all}
_try {set_db / .preserve_registers              true}

# --------------------------
# Synthesis
# --------------------------
puts "INFO: syn_generic -effort high"
_try {syn_generic -effort high}
_try {write_hdl -generic > [file join $proj_root outputs netlist_generic.v]}

puts "INFO: syn_map -effort high"
if {[catch {syn_map -effort high} em_map]} { puts "FATAL: syn_map failed -> $em_map"; exit 1 }

# --------------------------
# Reports & Dumps
# --------------------------
set rpt_dir [file join $proj_root reports]
set out_dir [file join $proj_root outputs]

_try {report_qor                                     > [file join $rpt_dir qor.txt]}
_try {report_timing -path_type summary -max_paths 50 > [file join $rpt_dir timing.txt]}
_try {report_area                                   > [file join $rpt_dir area.txt]}
_try {report_power                                  > [file join $rpt_dir power.txt]}
_try {check_design -all                             > [file join $rpt_dir check_design.rpt]}

# Deleted/optimized elements (options vary by version)
_try {report_sequential -deleted                    > [file join $rpt_dir deleted_seqs.rpt]}
_try {report_sequential -optimized                  > [file join $rpt_dir optimized_seqs.rpt]}
_try {report datapath                               > [file join $rpt_dir datapath.rpt]}

# Gate/cell usage & nets
_try {report_gates -inst_info -sort name            > [file join $rpt_dir gate_count_by_cell.txt]}
_try {report_nets -flat                             > [file join $rpt_dir nets_flat.rpt]}

# Mapped outputs (use redirect syntax – required on older builds)
_try {write_hdl -mapped > [file join $out_dir netlist_mapped.v]}
_try {write_sdc $my_design > [file join $out_dir exported_constraints.sdc]}
_try {write_sdf -design $my_design > [file join $out_dir design.sdf]}

puts "INFO: Synthesis & reporting complete for '$my_design'."
