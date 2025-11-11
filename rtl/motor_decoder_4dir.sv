// ============================================================================
// motor_decoder_4dir.sv
// 4비트 입력 (ch_fire_i)을 4개의 출력으로 보내는 간단한 디코더
// clk_en이 1일 때만 갱신하고, 0이면 직전 값을 유지 
// ============================================================================
module motor_decoder_4dir(
  input  logic clk, rst_n, clk_en,
  input  logic [3:0] ch_fire_i,    // N,S,E,W
  output logic north_o, south_o, east_o, west_o // 네 방향으로 보낼 제어 신호
);
  // 순차 논리 블록: 클럭 상승엣지 또는 리셋 (하강엣지)에 반응 
  always_ff @(posedge clk or negedge rst_n) begin // rst_n이 0이면 -> 즉시 리셋
    if(!rst_n) begin north_o<=1'b0; south_o<=1'b0; east_o<=1'b0; west_o<=1'b0; end // 0으로 초기화
    else if(clk_en) begin
      north_o <= ch_fire_i[0]; // 입력 비트 0을 북쪽으로 전달 
      south_o <= ch_fire_i[1]; // 입력 비트 1을 남쪽으로 전달 
      east_o  <= ch_fire_i[2]; 
      west_o  <= ch_fire_i[3];
    end
  end
endmodule
