//
// ============================================================================
// Auto-generated at run-time by genus_script.tcl (do not commit if undesired)
// Synth-only wrapper top: ai_neuron_top_for_synth
//   - Uses original submodules with their actual port names (per logs)
//   - Provides observable outputs so Genus won't sweep logic
// ============================================================================
module ai_neuron_top_for_synth #(
  parameter int N_NEURON = 64,
  parameter int WEIGHT_W = 16,
  parameter int ACC_W    = 24
)(
  input  logic                 clk,
  input  logic                 rst_n,
  // observable anchors
  output logic [15:0]          posx_mm_o,
  output logic [15:0]          posy_mm_o,
  output logic [3:0]           motor_fire_o,
  output logic [ACC_W-1:0]     fx_acc_o,
  output logic [ACC_W-1:0]     fy_acc_o
);
  localparam int NEURON_ID_W = (N_NEURON<=2)?1:$clog2(N_NEURON);

  // Physics coupling
  logic signed [ACC_W-1:0] fx_acc, fy_acc;
  logic signed [23:0]      fx_q, fy_q;
  logic signed [15:0]      posx_mm, posy_mm;
  logic [5:0]              mass_g;
  logic                    goal_reached;

  assign mass_g = 6'd10;
  assign fx_q   = $signed(fx_acc);
  assign fy_q   = $signed(fy_acc);

  // physics_integrator_2d ports (from logs):
  //   input clk, rst_n, clk_en,
  //   input force_x_q, force_y_q, input mass_g,
  //   output pos_mm_x_o, pos_mm_y_o, output goal_reached_o
  physics_integrator_2d u_phy(
    .clk(clk), .rst_n(rst_n), .clk_en(1'b1),
    .force_x_q(fx_q),
    .force_y_q(fy_q),
    .mass_g(mass_g),
    .pos_mm_x_o(posx_mm),
    .pos_mm_y_o(posy_mm),
    .goal_reached_o(goal_reached)
  );

  // LFSR: ports are (clk, rst_n, q) per log (width 32)
  logic [31:0] rnd;
  lfsr32 u_lfsr(.clk(clk), .rst_n(rst_n), .q(rnd));

  // Event source for DSP
  logic                   ev_valid;
  logic [NEURON_ID_W-1:0] pre_id;
  assign ev_valid = rnd[0];
  assign pre_id   = rnd[NEURON_ID_W-1:0];

  // dynamic_synapse_processor_stream_v2 ports (from logs):
  //   input clk,rst_n,clk_en
  //   input ev_valid, output ev_ready
  //   input pre_id_i, input pos_x_i,pos_y_i, input mass_u8_i
  //   output syn_out_valid, input syn_out_ready
  //   output syn_dst_id_o, syn_weight_o, syn_addr_o, syn_pre_id_o
  //   input upd_valid_i, output upd_ready_o, input upd_addr_i, upd_dw_i
  logic                          syn_v, syn_r;
  logic [NEURON_ID_W-1:0]        syn_dst;
  logic signed [WEIGHT_W-1:0]    syn_w;

  assign syn_r = 1'b1;

  dynamic_synapse_processor_stream_v2 #(
    .N_NEURON(N_NEURON),
    .NEURON_ID_W(NEURON_ID_W),
    .WEIGHT_W(WEIGHT_W),
    .ACC_W(ACC_W),
    .GRID_W(128),
    .GRID_H(128),
    .TOTAL_SYNAPSES(4096),
    .SYN_ADDR_W(16),
    .DEG_W(12)
  ) u_dsp (
    .clk(clk), .rst_n(rst_n), .clk_en(1'b1),
    .ev_valid(ev_valid), .ev_ready(),        // leave ready open in wrapper
    .pre_id_i(pre_id),
    .pos_x_i(posx_mm),
    .pos_y_i(posy_mm),
    .mass_u8_i({2'b0,mass_g}),
    .syn_out_valid(syn_v),
    .syn_out_ready(syn_r),
    .syn_dst_id_o(syn_dst),
    .syn_weight_o(syn_w),
    .syn_addr_o(), .syn_pre_id_o(),
    .upd_valid_i(1'b0), .upd_ready_o(), .upd_addr_i('0), .upd_dw_i('0)
  );

  // Motor decode & accumulation
  logic [3:0] motor_fire;
  assign motor_fire[0] = syn_v && syn_r && (syn_dst == (N_NEURON-4)); // N
  assign motor_fire[1] = syn_v && syn_r && (syn_dst == (N_NEURON-3)); // S
  assign motor_fire[2] = syn_v && syn_r && (syn_dst == (N_NEURON-2)); // E
  assign motor_fire[3] = syn_v && syn_r && (syn_dst == (N_NEURON-1)); // W

  logic north, south, east, west;
  motor_decoder_4dir u_mdec(
    .clk(clk), .rst_n(rst_n), .clk_en(1'b1),
    .ch_fire_i(motor_fire),
    .north_o(north), .south_o(south), .east_o(east), .west_o(west)
  );

  g_pulse_accumulator #(.W(ACC_W)) u_ax(
    .clk(clk), .rst_n(rst_n), .clk_en(1'b1),
    .plus_pulse_i(east), .minus_pulse_i(west), .value_o(fx_acc)
  );
  g_pulse_accumulator #(.W(ACC_W)) u_ay(
    .clk(clk), .rst_n(rst_n), .clk_en(1'b1),
    .plus_pulse_i(north), .minus_pulse_i(south), .value_o(fy_acc)
  );

  // Observable anchors (prevent sweeping)
  assign posx_mm_o    = posx_mm;
  assign posy_mm_o    = posy_mm;
  assign motor_fire_o = motor_fire;
  assign fx_acc_o     = fx_acc;
  assign fy_acc_o     = fy_acc;

endmodule

