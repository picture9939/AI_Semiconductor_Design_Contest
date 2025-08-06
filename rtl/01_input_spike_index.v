module spike_generator (
  input wire clk,
  input wire reset,
  input wire [63:0] spike_in
);

  reg [3:0] time_step;

  always @(posedge clk or posedge reset) begin
    if (reset) begin
      time_step <= 0;
    end else begin
      time_step <= time_step + 1;
      // 현재 spike 값 출력 (디버깅용)
      $display("Time: %0t, Spike In = %b", $time, spike_in);
    end
  end

endmodule
