// ============================================================================
// dynamic_synapse_processor_stream_v2.sv
// - 거리 기반 감쇠 policy + 인터페이스 유지
// ============================================================================
module dynamic_synapse_processor_stream_v2 #(
  parameter int N_NEURON      = 64, // 전체 뉴런 수 
  parameter int NEURON_ID_W   = (N_NEURON<=2)?1:$clog2(N_NEURON), // 누런 ID 표현에 필요한 비트폭 자동 계산
  parameter int WEIGHT_W      = 16, // 시냅스 가중치 비트폭 (부호형)
  parameter int ACC_W         = 24, // 누산기 비트폭 
  parameter int GRID_W        = 128, // 그리드 폭 (x축)
  parameter int GRID_H        = 128, // 그리드 높이 (y축)
  parameter int DELAY_BITS    = 3, // 지연 버퍼 비트폭
  parameter int DELAY_SCALE_LOG2 = 2, // 지연 스케일링 (거리 제곱)
  parameter int TOTAL_SYNAPSES = 4096, // 전체 시냅스 수 (adjlist RAM 크기)
  parameter int SYN_ADDR_W     = (TOTAL_SYNAPSES<=2)?1:$clog2(TOTAL_SYNAPSES), // 시냅스 메모리 주소 폭
  parameter int DEG_W          = 12, // 뉴런당 차수 표현 폭
  parameter bit ACCUMULATE_ON_COLLISION = 1'b1 // 충돌 시 누산 모드 설정
)(
  input  logic                      clk, // 시스템 클럭
  input  logic                      rst_n, // 비동기 리셋
  input  logic                      clk_en, //  클럭 인에이블

  input  logic                      ev_valid, // 이벤트 유효 플래그
  output logic                      ev_ready, // 이벤트 준비 플래그
  input  logic [NEURON_ID_W-1:0]    pre_id_i, // 발화한 pre 뉴런 ID

  input  logic signed [15:0]        pos_x_i, // 발화한 뉴런의 x 위치
  input  logic signed [15:0]        pos_y_i, // 발화한 뉴런의 y 위치
  input  logic [7:0]                mass_u8_i, // 발화한 뉴런의 질량/규모 (0~255): 감쇠 스케일링용

  output logic                      syn_out_valid, // 시냅스 스트림 유효 플래그
  input  logic                      syn_out_ready, // 시냅스 스트림 준비 플래그
  output logic [NEURON_ID_W-1:0]    syn_dst_id_o, // 시냅스 목적지 뉴런 ID
  output logic signed [WEIGHT_W-1:0]syn_weight_o, // 시냅스 가중치
  output logic [SYN_ADDR_W-1:0]     syn_addr_o, // 시냅스 테이블 주소
  output logic [NEURON_ID_W-1:0]    syn_pre_id_o, // 시냅스 원천(pre) 뉴런 ID

  input  logic                      upd_valid_i, // 가중치 업데이트 요청 플래그
  output logic                      upd_ready_o, // 가중치 업데이트 준비 플래그
  input  logic [SYN_ADDR_W-1:0]     upd_addr_i, // 가중치 업데이트 주소
  input  logic signed [WEIGHT_W-1:0]upd_dw_i // 가중치 업데이트 델타 값
);
  // walker signals
  logic                  out_last_int; // 시냅스 워커가 마지막 시냅스 출력을 내보냈음을 알리는 플래그
  logic                  ram_out_valid, ram_out_ready; // 시냅스 워커 출력 유효/준비 플래그
  logic [NEURON_ID_W-1:0]ram_dst_id; // 시냅스 워커 출력 목적지 뉴런 ID
  logic signed [WEIGHT_W-1:0] ram_weight; // 시냅스 워커 출력 가중치
  logic [SYN_ADDR_W-1:0] ram_addr; // 시냅스 워커 출력 주소

  // request latch
  // 요청 래치 영역: 입력 이벤트 (pre_id_i)를 받아 처리 중임을 표시
  logic req_busy; // 현재 요청 처리 중 플래그 (1이면 바쁨)
  logic [NEURON_ID_W-1:0] pre_lat;  // 처리 중인 pre 뉴런 ID를 보관

  always_ff @(posedge clk or negedge rst_n) begin // 순차 로직: 클럭 상승/리셋 시 동작
    if (!rst_n) req_busy <= 1'b0; // 리셋 시 바쁨 플래그 클리어
    else if (clk_en) begin // 클럭 게이팅이 활성일 때만 갱신
      if (!req_busy && ev_valid) begin pre_lat <= pre_id_i; req_busy <= 1'b1; end // 새 이벤트가 들어오면 pre ID를 래치(레지스터에 보관)하고 바쁨 플래그 설정
      else
      if (req_busy && ram_out_valid && ram_out_ready && out_last_int) req_busy <= 1'b0; // 현재 pre의 인접리스트를 끝 (out_last)까지 내보내면 busy 종료
    end
  end
  assign ev_ready = clk_en && !req_busy; // 바쁘지 않을 때만 (그리고 clk_en일 때) 새 이벤트를 받을 준비

  // walker
  // pre_last를 입력으로 해당 pre의 모든 시냅스를 순서대로 토해내는 블록
  weight_ram_adjlist #( 
    .N_NEURON(N_NEURON), .NEURON_ID_W(NEURON_ID_W), // 뉴런 수/ ID 폭
    .TOTAL_SYNAPSES(TOTAL_SYNAPSES), .SYN_ADDR_W(SYN_ADDR_W), // 시냅스 수/주소 폭
    .DEG_W(DEG_W), .WEIGHT_W(WEIGHT_W) // 차수 폭, 가중치 폭
  ) u_adj ( 
    .clk(clk), .rst_n(rst_n), .clk_en(clk_en), // 클럭/리셋/클럭 enable
    .req_valid(req_busy), .req_ready(/*unused*/), .req_src_id(pre_lat), // 요청 유효/준비 플래그, 요청한 pre 뉴런 ID
    .out_valid(ram_out_valid), .out_ready(ram_out_ready), //walker 출력 유효/준비 플래그
    .out_dst_id(ram_dst_id), .out_weight(ram_weight), // walker 출력 목적지 뉴런 ID, 가중치
    .out_addr(ram_addr), .out_last(out_last_int), // walker 출력 주소, 마지막 시냅스 플래그
    .upd_valid_i(upd_valid_i), .upd_ready_o(upd_ready_o), // 가중치 업데이트 유효/준비 플래그
    .upd_addr_i(upd_addr_i), .upd_dw_i(upd_dw_i) // 가중치 업데이트 주소, 델타 값
  );

  // 거리 기반 감쇠 정책 함수: 맨해튼 거리로 감쇠, mass로 스케일링
  function automatic signed [WEIGHT_W-1:0] policy_weight( //자동합수: 입력 가중치에 정책을 적용해 반환
    input signed [WEIGHT_W-1:0] w_in, // 원래 가중치
    input signed [15:0] px, py, input [7:0] m8 // 위치(x,y), 질량 (0~255)
  );
    signed [15:0] ax, ay; // 16비트 부호형 변수 -> px, py 절대값 저장용
    signed [16:0] manh; // 맨해튼 거리 계산 
    signed [WEIGHT_W-1:0] att; // 최종 감쇠된 가중치. 이 값이 함수 반환값이 됨
    begin
      ax = (px<0)? -px : px; // 절댓값 계산 -> 음수면 부호 반전, 아니면 결과는 그대로 
      ay = (py<0)? -py : py; // 절댓값 계산 -> 음수면 부호 반전, 아니면 결과는 그대로
      manh = ax + ay;                            // 절댓값으로 더하기 
      att = (w_in * $signed({1'b0,m8})) >>> (3 + manh[8:6]); 
      // 입력 가중치 w_in에 질량 m8 (여기선 1+8=9비트)을 곱해 스케일을 키운 뒤, 
      // 맨해튼 거리 manh의 상위 비트에 3을 더한 만큼 산술 우시프트함
      // 거리 클수록 더 많이 감쇠시키되 부호는 그대로 유지해 att에 넣기 
      // 질량이 클수록 전체 세기가 커지고, 거리가 멀수록 더 나눠져 작아짐 
      policy_weight = att;
      // 계산한 감쇠 가중치를 함수 반환값으로 설정
    end
  endfunction

 // walker가 뱉은 것들을 그대로 (패스스루) 내보내고, 가중치만 policy로 한 번 계산해서 출력으로 넘김
  assign syn_out_valid = ram_out_valid;
  assign ram_out_ready = syn_out_ready;
  assign syn_dst_id_o  = ram_dst_id;
  assign syn_weight_o  = policy_weight(ram_weight, pos_x_i, pos_y_i, mass_u8_i);
  // walker의 원본 가중치에 위치/질량 정책을 적용해 감쇠된 가중치를 만들어 출력
  assign syn_addr_o    = ram_addr;
  assign syn_pre_id_o  = pre_lat;
endmodule
