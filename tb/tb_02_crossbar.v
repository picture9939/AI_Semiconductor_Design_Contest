// tb_02_crossbar.v
// ⬢ Crossbar 회로 시뮬레이션
// ⬢ Excitatory / Inhibitory spike 테스트

module tb_crossbar;

  reg clk;
  reg reset;
  reg [63:0] spike_in;
  reg [63:0] inhib_flag;
  wire signed [15:0] weighted_sum [63:0];

  crossbar uut (
    .clk(clk),
    .reset(reset),
    .spike_in(spike_in),
    .inhib_flag(inhib_flag),
    .weighted_sum(weighted_sum)
  );

  always #5 clk = ~clk;

  integer k;

  initial begin
    $display("=== Crossbar 테스트 시작 ===");

    clk = 0;
    reset = 1;
    spike_in = 64'd0;
    inhib_flag = 64'd0;

    #10 reset = 0;

    // 테스트 1: 뉴런 0,1이 발화 / 흥분성
    spike_in[0] = 1;
    spike_in[1] = 1;
    inhib_flag[0] = 0;
    inhib_flag[1] = 0;

    #10;

    $display("▶ weighted_sum 결과:");
    for (k = 0; k < 8; k = k + 1)
      $display("weighted_sum[%0d] = %0d", k, weighted_sum[k]);

    // 테스트 2: 뉴런 2번이 억제성으로 발화
    spike_in = 64'd0;
    inhib_flag = 64'd0;
    spike_in[2] = 1;
    inhib_flag[2] = 1;

    #10;

    $display("▶ 억제 spike 결과:");
    for (k = 0; k < 8; k = k + 1)
      $display("weighted_sum[%0d] = %0d", k, weighted_sum[k]);

    $finish;
  end

endmodule
