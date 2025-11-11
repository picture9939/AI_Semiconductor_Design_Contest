// ============================================================================
// state_dependent_plasticity.sv
// 프리와 포스트 스파이크의 순서에 따라 가중치 변화를 정하고, 
// 그 크기를 도파민으로 스케일하는 STDP 모델 
// ============================================================================
module state_dependent_plasticity #(
  parameter int WEIGHT_W = 16
)(
  input  logic clk, rst_n, clk_en,
  input  logic pre_spk_i,
  input  logic post_spk_i,
  input  logic [7:0] dopamine_i,          // 0~255
  output logic signed [WEIGHT_W-1:0] dw_o // 가중치 변화를 출력으로
);
  // LTP (강화)와 LTD (약화)의 기본 크기 
  localparam signed [WEIGHT_W-1:0] ETA_P = 16'sd4; // pre -> post (인과)일 때 + 4 
  localparam signed [WEIGHT_W-1:0] ETA_M = -16'sd3; // post -> post (역인과)일 때 -3 


  // 지난 사이클의 pre/post 스파이크를 저장할 1클럭 지연 플립플롭 
  logic pre_z, post_z;
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin pre_z<=1'b0; post_z<=1'b0; end
    else if(clk_en) begin pre_z<=pre_spk_i; post_z<=post_spk_i; end
    // 이번 pre를 저장 -> 다음 사이클에 사용, 이번 post를 저장 -> 다음 사이클에 사용
  end


  // 이번 사이클 가중치의 부호와 기본 세기를 결정하는 조합 로직 
  logic signed [WEIGHT_W-1:0] base;
  always_comb begin
    // 직전 pre_z=1 그리고 이번 post=1 → pre가 post보다 먼저 → LTP(강화)
    if(pre_z && post_spk_i)      base = ETA_P;

    //직전 post_z=1 그리고 이번 pre=1 → post가 pre보다 먼저 → LTD(약화)
    else if(post_z && pre_spk_i) base = ETA_M;
    else                         base = '0;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) dw_o <= '0;
    else if(clk_en) dw_o <= base * $signed({1'b0,dopamine_i[7:4]});
  end
endmodule
