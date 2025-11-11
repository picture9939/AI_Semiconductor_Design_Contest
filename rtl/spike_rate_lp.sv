// ============================================================================
// spike_rate_lp.sv
// y[n] = y[n-1] - (y[n-1]>>alpha_u8[3:0]) + (spike?256:0)
// 스파이크 빈도를 느리게 따라가는 1차 저역통과 필터 
// 스파이크가 들어오면 값을 올려주고, 매 사이클마다 조금씩 새어 내려감
// ============================================================================
module spike_rate_lp(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       clk_en,
  input  logic [7:0] alpha_u8,
  input  logic       spike,
  output logic [15:0] rate_o
);
  localparam int GAIN = 16'd256; // 스파이크 1회당 올려줄 양 (256)
  logic [15:0] ny; // 다음 값을 임시로 담아줄 조합 변수
  always_comb begin
    logic [15:0] leak = rate_o >> alpha_u8[3:0];
     // leak: 현재값의 일부, 오른쪽 시프트로
     // alpha가 클수록 천천히 새어감 (시간상수 업)
    ny = rate_o - leak + (spike ? GAIN : 16'd0);
    // spike가 1이면 256 더해 한 번 튀어올라감, 아니면 0을 더함 
  end

  
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) rate_o <= 16'd0;
    else if(clk_en) rate_o <= ny;
  end
endmodule
