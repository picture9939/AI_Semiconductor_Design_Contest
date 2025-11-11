// ============================================================================
// power_manager.sv  (ports aligned to log: clk_en_i, activity_i)
// ============================================================================
module power_manager(
  input  logic clk,
  input  logic rst_n,
  input  logic clk_en_i,     // 외부 enable
  input  logic activity_i,   // 최근 활동 감지 (간단히 AND)
  output logic clk_en_o
);
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) clk_en_o <= 1'b0;
    else       clk_en_o <= clk_en_i & activity_i;
  end
endmodule
