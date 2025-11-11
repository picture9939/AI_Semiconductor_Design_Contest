// ============================================================================
// network_state_monitor.sv
// 각 뉴런의 스파이크를 저역통과해서 평균을 구하고, 
// 평균이 목표치보다 낮/높으면 도파민 출력을 두 레벨로 조절함
// 디버깅용으로 평균값을 dbg_status로도 내보냄
// ============================================================================
module network_state_monitor #( 
  parameter int N_NEURON = 64 // 뉴런 개수 (인스턴스 수)
)(
  input  logic                clk,
  input  logic                rst_n,
  input  logic                clk_en,

  input  logic [N_NEURON-1:0] spike_in,

  output logic [31:0]         dbg_status,

  input  logic [7:0]          alpha_u8_i,
  output logic [15:0]         rate_bus_o [N_NEURON],
  output logic [7:0]          dopamine_o
);
  genvar i;
  generate
    // N_NEURON 개수만큼 레이트 추정기 (spike_rate_ls) 인스턴스 생성
    for (i=0;i<N_NEURON;i++) begin : G_RATE // 블록 이름 (G_RATE[i]이 생겨 디버깅 편함)
      spike_rate_lp u_lp ( // 각 뉴런의 스파이크를 저역통과 -> 레이트 추정
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .alpha_u8(alpha_u8_i), // 필터 계수, 클수록 반응 빠름, 작을수록매끈
        .spike(spike_in[i]), // i번째 뉴런의 스파이크 입력 
        .rate_o(rate_bus_o[i]) // i번째 뉴런의 레이트 출력
      );
    end
  endgenerate

  localparam [15:0] TARGET = 16'd4096; // 목표 평균 레이트 
  logic [31:0] acc_rate_q, mean_q; // 레지스터형 (클럭 도메인에 고정) 누적/평균
  logic [31:0] acc_rate_d, mean_d; // 조합논리형 누적/평균
  integer k;

  // 조합 논리: 모든 뉴런의 레이트 (acc_rate_d)를 더해 평균 (mean_d) 계산
  always_comb begin
    acc_rate_d = 32'd0; // 누적합 초기화 (32비트: 오버플로 여유)
    for (k=0;k<N_NEURON;k++) acc_rate_d = acc_rate_d + rate_bus_o[k]; // 각 뉴런 레이트 (16비트)를 전부 더함
    // 평균 = 합/개수. 0으로 나눔 방지 
    mean_d = (N_NEURON!=0) ? (acc_rate_d / N_NEURON) : 32'd0;
    // 뉴런 수(N_NEURON)가 2의 거듭제곱이면, 평균을 구할 때 나눗셈 (/) 대신 비트 시프트 (>>)로 바꿔 쓰면 하드웨어 비용이 크게 줄어듬
    // /64는 >>6과 같음, 나눗셈 연산자는 합성 시 비싼 디바이더가 생기지만, 고정 폭 시프트는 거의 배선 수준 (아주 싸고 빠름)
  end


  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      acc_rate_q<=32'd0; mean_q<=32'd0; dopamine_o<=8'd0; dbg_status<=32'd0; // 전부 초기화
    end else if(clk_en) begin
      acc_rate_q<=acc_rate_d; mean_q<=mean_d; dbg_status<=mean_d;
      // 계산한 합/평균을 레지스터에 고정, 평균을 그대로 dbg_status로 내보냄
      dopamine_o <= (mean_d < TARGET) ? 8'd192 : 8'd32; // homeostasis
      // 평균이 목표보다 낮으면 도파민 높게 (192) -> 네트워크 흥분성 유도 
      // 평균이 목표 이상이면 도파민 낮게 (32) -> 네트워크 흥분성 저하
    end
  end
endmodule
