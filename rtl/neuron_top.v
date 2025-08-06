// neuron_top.v
// 전체 회로의 Top Module – input generator + crossbar 연결

module neuron_top (
  input wire clk,
  input wire reset,
  output wire signed [15:0] weighted_sum [63:0]  // 결과 출력
);

  wire [63:0] spike_in;
  wire [63:0] inhib_flag;

  // 입력 스파이크 발생기
  input_spike_index stim_gen (
    .clk(clk),
    .reset(reset),
    .spike_in(spike_in),
    .inhib_flag(inhib_flag)
  );

  // Crossbar
  crossbar uut (
    .clk(clk),
    .reset(reset),
    .spike_in(spike_in),
    .inhib_flag(inhib_flag),
    .weighted_sum(weighted_sum)
  );

endmodule
