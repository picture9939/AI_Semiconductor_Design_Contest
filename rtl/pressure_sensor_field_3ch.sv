// ============================================================================
// pressure_sensor_field_3ch.sv
// ============================================================================
module pressure_sensor_field_3ch #(
  parameter int PLANE_SIZE_MM = 300,
  parameter int FRAC          = 12,
  parameter int DIST_SHIFT    = 3,
  parameter int TOF_K         = 2,
  parameter int MAX_DELAY     = 256
)(
  input  logic clk, rst_n, clk_en,
  input  logic reseed_i,
  input  logic signed [15:0] pos_mm_x_i,
  input  logic signed [15:0] pos_mm_y_i,
  input  logic [5:0]         mass_g_i,
  output logic [2:0]         spike_o,
  output logic [7:0]         density_o [3],
  output logic [7:0]         dist_bin_o [3]
);

  localparam int HALF = PLANE_SIZE_MM/2;

  logic [31:0] rx, ry;
  lfsr32 ux(.clk(clk), .rst_n(rst_n), .q(rx));
  lfsr32 uy(.clk(clk), .rst_n(rst_n), .q(ry));

  logic signed [15:0] ax[3], ay[3];
  logic reseed_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) reseed_q <= 1'b0;
    else if(clk_en) reseed_q <= reseed_i;
  end

  function automatic signed [15:0] pick_coord(input [31:0] rbits);
    signed [15:0] base;
    begin
      base = (rbits[9:0] % HALF) - (HALF/2);
      return base;
    end
  endfunction

  integer i;
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      for(i=0;i<3;i++) begin ax[i] <= -HALF/2 + i*HALF/2; ay[i] <= -HALF/2 + i*HALF/3; end
    end else if(clk_en && reseed_q) begin
      ax[0] <= pick_coord(rx); ay[0] <= pick_coord(ry);
      ax[1] <= pick_coord({rx[15:0],ry[15:0]});
      ay[1] <= pick_coord({ry[15:0],rx[15:0]});
      ax[2] <= pick_coord({rx[23:8],ry[23:8]});
      ay[2] <= pick_coord({ry[23:8],rx[23:8]});
    end
  end

  logic [7:0]  dist_bin[3];
  logic [7:0]  rate_bin[3];
  logic [7:0]  rnd8;
  assign rnd8 = rx[7:0]^ry[7:0];

  for (genvar k=0;k<3;k++) begin : G_SENS
    logic [15:0] adx, ady;
    logic [16:0] md;
    logic [7:0]  d_bin, rate;

    always_comb begin
      adx = (pos_mm_x_i > ax[k]) ? (pos_mm_x_i - ax[k]) : (ax[k] - pos_mm_x_i);
      ady = (pos_mm_y_i > ay[k]) ? (pos_mm_y_i - ay[k]) : (ay[k] - pos_mm_y_i);
      md  = adx + ady;
      d_bin = md[15:8] >> DIST_SHIFT;
      rate  = ( (mass_g_i[5:0] << 6) >> (1 + (d_bin[5:0])) );
    end

    logic spike_raw;
    always_ff @(posedge clk or negedge rst_n) begin
      if(!rst_n) spike_raw <= 1'b0;
      else if(clk_en)      spike_raw <= (rnd8 < rate);
    end

    localparam int W = $clog2(MAX_DELAY);
    logic [W-1:0] delay;
    always_comb delay = (d_bin * TOF_K);

    tof_delay_line #(.MAX_DELAY(MAX_DELAY)) u_tof (
      .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
      .in_pulse(spike_raw),
      .delay_i(delay),
      .out_pulse(spike_o[k])
    );

    always_ff @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin dist_bin[k] <= '0; rate_bin[k] <= '0; end
      else if(clk_en) begin dist_bin[k] <= d_bin; rate_bin[k] <= rate; end
    end

    assign dist_bin_o[k] = dist_bin[k];
    assign density_o[k]  = rate_bin[k];
  end
endmodule
