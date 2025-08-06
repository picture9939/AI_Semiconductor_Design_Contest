// 08_weight_rom.v
// ⬢ 64x64 시냅스 가중치 테이블 (고정값)
// ⬢ 조합 논리로 구현된 ROM

module weight_rom (
  input wire [5:0] pre_idx,
  input wire [5:0] post_idx,
  output reg signed [3:0] weight
);

  always @(*) begin
    weight = 4'sd0;  // default

    // 예시: 뉴런 0번 → 출력 0~3 가중치 +3
    if (pre_idx == 6'd0) begin
      case (post_idx)
        6'd0, 6'd1, 6'd2, 6'd3: weight = 4'sd3;
      endcase
    end

    // 억제 예시: 뉴런 1번 → 출력 4~5로 -2
    if (pre_idx == 6'd1) begin
      case (post_idx)
        6'd4, 6'd5: weight = -4'sd2;
      endcase
    end
  end

endmodule
