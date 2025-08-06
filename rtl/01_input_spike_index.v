module spike_generator (
  input wire clk,
  input wire reset,
  input wire [63:0] spike_in,
  input wire [63:0] inhib_flag
);

  reg [9:0] time_step;

  always @(posedge clk or posedge reset) begin
    if (reset) begin
      time_step <= 0;
    end else begin
      time_step <= time_step + 1;
      // 디버깅 출력
      $display("Time: %0t, Spike In = %b, Inhibition Flag = %b", $time, spike_in, inhib_flag);
    end
  end

endmodule
