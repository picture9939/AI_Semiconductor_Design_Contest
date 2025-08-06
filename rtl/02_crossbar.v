module crossbar (
  input wire clk,
  input wire reset,
  input wire [63:0] spike_in,
  input wire [63:0] inhib_flag,
  output reg signed [15:0] weighted_sum [63:0]
);

  integer i, j;
  wire signed [3:0] rom_weight;
  reg signed [3:0] weight;
  reg signed [15:0] temp_sum [63:0];

  reg [5:0] pre_idx, post_idx;

  weight_rom wr (
    .pre_idx(pre_idx),
    .post_idx(post_idx),
    .weight(rom_weight)
  );

  always @(posedge clk or posedge reset) begin
    if (reset) begin
      for (j = 0; j < 64; j = j + 1)
        weighted_sum[j] <= 16'sd0;
    end else begin
      for (j = 0; j < 64; j = j + 1) begin
        temp_sum[j] = 16'sd0;
        for (i = 0; i < 64; i = i + 1) begin
          if (spike_in[i]) begin
            pre_idx = i;
            post_idx = j;
            weight = inhib_flag[i] ? -rom_weight : rom_weight;
            temp_sum[j] = temp_sum[j] + weight;
          end
        end
        weighted_sum[j] <= temp_sum[j];
      end
    end
  end

endmodule
