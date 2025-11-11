// ============================================================================
// cortical_neuron_core_tm.sv  -- LIF + STP + adaptive threshold
// LIF (누수 적분) + STP (단기가소성: 촉진/억제) + 적응 임계치 + 도파민 보정
// 입력 전류 i_syn이 들어옴 (양수 = 흥분성, 음수 = 억제성)
// STP 상태 (촉진 facil_q, 억제 depr_q)를 감쇠시키고 필요한 만큼 더함.
// 막전위 v_q를 '이전값 - 누수 + 입력 + 촉진 - 억제'로 업데이트 
// 임계치 th_q를 '이전값 - 감쇠 + (발화시 증가)'로 업데이트
// 도파민으로 임계치를 낮춰 (th_eff) 더 발화하기 쉽게/어렵게 조절 
// v_q 상위 비트와 th_eff를 비교해 발화 결정
// ============================================================================
module cortical_neuron_core_tm #( // 모듈 선언 + 파라미터화 시작 
  parameter int POT_W = 24, // 막전위 v 비트폭 (고정소수점/정수 폭)
  parameter int TH_W  = 16, // 임게치 th 비트폭
  parameter int WEIGHT_W = 16 // 시냅스 입력 i_syn 비트폭
)(
  input  logic clk, rst_n, clk_en, // 클럭, 비동기 리셋, 클럭 인에이블
  input  logic signed [WEIGHT_W-1:0] i_syn, // 시냅스 입력 전류 (가중치)
  input  logic [7:0] dopamine_i, //도파민 (0~255) 입력, 임계치 보정용, 클수록 발화 쉬움
  output logic spike_o // 이번 클럭에 스파이크? (1이면 발화)
);
  // STP (단기사소성)용 상태: 촉진/억제의 '잔상'을 저장 
  logic [15:0] facil_q, depr_q; // 현재 값 (기억)
  logic [15:0] facil_d, depr_d; // 다음 값 (계산)

  // 촉진/억제 값 "계산" (저장은 아래 always_ff에서)
  always_comb begin
    // 촉진: 시간이 지나면 조금 줄이고 (x의 16으로 나눈 값만큼 줄임), 입력이 +면 +32만큼 올림
    // 매 사이클하다 facil_q를 16으로 나눈 값을 정수 시프트하고, i_syn이 양수 또는 0이면 +32 (부호비트0), i_syn이 음수면 0을 더함
    facil_d = facil_q - (facil_q>>4) + (i_syn[WEIGHT_W-1]?16'd0:16'd32); // i_syn[WEIGHT_W-1는 부호 비트라서 0이면 비음수 (0포험), 1이면 음수로 해석
    // 억제: 시간이 지나면 조금 줄이고, 스파이크가 나가면 +64만큼 올림
    // 촉진은 _32, 억제는 64로 설정해 스파이크 직후 억제 효과가 더 강하게 먹도록 설계함
    depr_d  = depr_q  - (depr_q >>4) + (spike_o ? 16'd64 : 16'd0); // (조건 ? 값1 : 값2) -> 16비트 십진수 54, 16비트 0 
  end

  // 촉진/억제 값 "저장" (계산은 위에서)
  always_ff @(posedge clk or negedge rst_n) begin  // clk_en =1이고 클럭이 진행될때마다 facil_q는 1/16씩 줄어듬
    if(!rst_n) begin facil_q<=16'd0; depr_q<=16'd0; end // 리셋 시 0으로 초기화
    else if(clk_en) begin facil_q<=facil_d; depr_q<=depr_d; end // 켜져 있을 때만 새 값으로 갱신, 위에서 계산한 감쇠 (조건수 +32)를 적용
  end

  // 막전위/임계치 상태 저장용 레지스터
  logic signed [POT_W-1:0] v_q, v_d; // 막전위 현재값/다음값
  logic [TH_W-1:0]         th_q, th_d; // 임계치 현재값/다음값
  always_comb begin // 막전위/임계치 다음값 계산
    // 누수항: 막전위의 1/8 값을 누수로 뺌 (시프트 연산)
    logic signed [POT_W-1:0] leak = v_q >>> 3;
    logic signed [POT_W-1:0] gain = {{(POT_W-WEIGHT_W){i_syn[WEIGHT_W-1]}}, i_syn}; // i_syn[WEIGHT_W-1]을 (POT_W-WEIGHT_W)번 반복.
    // i_syn의 부호비트를 위쪽 빈 칸에 복사해서, 음수/양수의 의미를 보존한 채로 비트폭을 POT_W로 확장
    // {x,b}, 비트를 좌 -> 우 순서로 이어붙임 
    // 서로 다른 비트폭을 더하려면 폭을 맞춰야 하므로, 같은 값을 더 넓은 폭으로 확장하는 작업이 필요
    v_d = v_q - leak + gain + (facil_q[15:8]) - (depr_q[15:8]);
    // 다음 막전위 = 이전 막전위 - 누수 + 시냅스입력 + 촉진(상위 8비트) - 억제(상위 8비트)
    // 다음 임계치 = 이전 임계치 - 1/32 감쇠 + (발화시 +32)
    // 평소에는 조금씩 내려가고, 발화 순간에는 잠깐 높아져 "연속 발화"를 막음
    th_d = th_q - (th_q>>5) + (spike_o ? 16'd32 : 16'd0);
  end

  // 막전위/임계치 값 저장
  always_ff @(posedge clk or negedge rst_n) begin // 클럭 상승엣지 또는 리셋 시
    if(!rst_n) begin v_q <= '0; th_q <= 16'd2048; end // 리셋 시 막전위 0, 임계치 2048로 초기화
    else if(clk_en) begin v_q <= v_d; th_q <= th_d; end // 클럭 인에이블이 켜져 있을 때만 갱신, 계산한 다음값으로 업데이트
  end

 // 발화 결정: 도파민으로 임계치 보정 후, 막전위 상위 비트와 비교
  wire [TH_W-1:0] th_eff = th_q - {dopamine_i,8'd0}; 
  // 도파민 반영된 임계치 = 현재 임계치 - (도파민 값 * 256)
  // 도파민이 1 늘때마다 임게치가 256만큼 내려감 
  // 도파민이 클수록 임계치가 낮아져 발화가 쉬워짐
  // {,} -> 이어붙이기, 도파민 뒤에 8비트 0을 붙여서 16비트로 변환 -> 8비트 왼쪽으로 민 것과 동일 (x256)
  always_ff @(posedge clk or negedge rst_n) begin 
    if(!rst_n) spike_o <= 1'b0; // 리셋 시 즉시 스파이크 출력을 0으로 초기화 
    else if(clk_en)    spike_o <= (v_q[POT_W-1: POT_W-TH_W] >= $signed(th_eff));

    // v_q의 상위 TH_W 비트 (막전위 상위 비트)와 도파민 보정된 임계치 th_eff를 비교
    // 상위 비트만 잘라 임게치와 동일한 비트폭으로 만든 뒤 비교하는 이유 임계치와 동일한 비트폭으로 맞추기 위해서
    // 막전위 상위 비트가 임계치 이상이면 spike_o를 1로 설정 (발화)
    // $signed() -> 값을 signed 타입으로 해석 
  end
endmodule
