// ============================================================================
// ai_neuron_top_comp_v2.sv  (Top)
// 뉴런 네트워크의 상위 구성요소
// 센서 입력 (압력 센서 등)을 받아 시냅스를 거쳐 모터 뉴런으로 신호를 전달하고, 
// 물리적인 '공'의 움직임을 시뮬레이션 함
// ============================================================================
module ai_neuron_top_comp_v2 #(
  // 뉴런 관련 파라미터 정의
  parameter int N_NEURON       = 64, // 전체 뉴런의 수, 네트워크 규모
  parameter int NEURON_ID_W    = (N_NEURON<=2)?1:$clog2(N_NEURON), // 누런 ID 표현에 필요한 비트폭 자동 계산

  // 데이트 폭 설정 (가중치, 축적기, 포텐셜 등)
  parameter int WEIGHT_W       = 16, // 시냅스 가중치 표현 폭
  parameter int ACC_W          = 24, // 누적/합산 (힘 등)에 쓰는 데이터폭
  parameter int POT_W          = 24, // 뉴런 막전위 표현용 
  parameter int TH_W           = 16, // 발화 임계값 표현용

  parameter int SYN_ADDR_W     = 16, // 시냅스 메모리 주소 폭 
  parameter int DEG_W          = 12, // 뉴런당 차수 표현 폭 
  parameter int TOTAL_SYNAPSES = 4096 // 전체 시냅스 개수 
)( 
  input  logic clk, // 시스템 클럭 입력, 모든 순차 로직 기준 시계 
  input  logic rst_n // 비동기 리셋 입력, 초기화 신호
);

  // --------------------------------------------------------------------------
  // Clock enable (activity 기반 게이팅)
  // 클럭 게이팅 블록: 회로가 할 일 없을 때는 멈춰 있게 해서 전력 소모 절감
  // power_managerrk clk_en이라는 스위치를 생성해 1이면 동작, 0이면 정지 
  // --------------------------------------------------------------------------
  logic clk_en; // 하위 모듈에 전달할 클럭 인에이블 신호
  power_manager u_pwr( // 전력/클럭 게이팅 관리 블록 인스턴스 -> 활동 신호를 보고 clk_en 생성
    .clk       (clk), // 입력 클럭 연결 
    .rst_n     (rst_n), // 비동기 리셋 연결
    .clk_en_i  (1'b1),     // 상시 동작 (원하면 상태선으로 교체)
    .activity_i(1'b1),     // 간단히 1로 유지
    .clk_en_o  (clk_en)
  );

  // --------------------------------------------------------------------------
  // Physics (ball)
  // --------------------------------------------------------------------------
  logic signed [23:0] fx_q, fy_q; // 물리 엔진에 줄 x/y 방향 힘 값 
  logic signed [15:0] posx_mm, posy_mm; // 현재 공의 위치 (mm 위치)
  logic               goal_reached; // 목표 도달 여부 플래그 
  logic [5:0]         mass_g; // 질량 (g 단위)

  assign mass_g = 6'd10;   // 1~30g

  physics_integrator_2d u_phy ( // 힘과 질량을 받아 위치를 계산하는 적분기
    .clk(clk), .rst_n(rst_n), .clk_en(clk_en), // 클럭/리셋/게이팅 입력
    .force_x_q(fx_q), .force_y_q(fy_q), .mass_g(mass_g), // 힘과 질량 입력
    .pos_mm_x_o(posx_mm), .pos_mm_y_o(posy_mm), .goal_reached_o(goal_reached) // 출력: 위치/도달상태
  );

  // --------------------------------------------------------------------------
  // 3 pressure sensors (ToF + distance attenuation) 센서 블록 시작
  // --------------------------------------------------------------------------
  logic [2:0] sens_spk; // 3채널 센서 스파이크 (각 1비트)
  logic [7:0] sens_rate [3]; // 센서별 발화율/밀도 (8비트)
  logic [7:0] sens_dist [3]; // 센서별 거리 bin (8비트)

  pressure_sensor_field_3ch u_sens ( // 3채널 입력/거리 기반 센서 모델 
    .clk(clk), .rst_n(rst_n), .clk_en(clk_en), // 기본 제어 신호 
    .reseed_i(1'b0),  // 랜덤 시드 재설정 비활성 
    .pos_mm_x_i(posx_mm), .pos_mm_y_i(posy_mm), .mass_g_i(mass_g), // 공의 상태 입력 (위치/질량)
    .spike_o(sens_spk), .density_o(sens_rate), .dist_bin_o(sens_dist) // 센서 출력 (스파이크/레이트/거리bin)
  );

  // 센서 이벤트 -> pre 시냅스 이벤트
  logic                      ev_valid; // 이벤트 발생 유효 표시 
  logic [NEURON_ID_W-1:0]    pre_id; // 이벤트 발생한 pre 뉴런 ID

  always_ff @(posedge clk or negedge rst_n) begin // 순차 로직: 클럭 상승/리셋 시 동작
    if(!rst_n) begin // 리셋 구간
      ev_valid <= 1'b0; // 리셋 시 이벤트 비유효
      pre_id   <= '0; // 리셋 시 pre ID 초기화 
    end else if(clk_en) begin // 클럭 게이팅이 활성일 때만 갱신
      ev_valid <= |sens_spk; // 센서 3개 중 하나라도 1이면 이벤트 발생 
      unique case (1'b1) // 우선 순위 case: 첫 매칭만 선택
        sens_spk[0]: pre_id <= 'd0; // 센서 0가 스파이크 -> pre 뉴런 ID 0
        sens_spk[1]: pre_id <= 'd1; // 센서 1가 스파이크 -> pre 뉴런 ID 1
        default    : pre_id <= 'd2; //그 외 -> pre 뉴런 ID 2
      endcase
    end
  end

  // 센서 신호를 시냅스 입력 이벤트 형태로 정규화 (누가 발화했는지 ID로 표시)



  // --------------------------------------------------------------------------
  // Synapse walker -> 4 motor neurons (N,S,E,W) 시냅스 처리/워커 블록 
  // --------------------------------------------------------------------------
  logic                          syn_v, syn_r; // 시냅스 출력 스트림 valid/ready 
  logic [NEURON_ID_W-1:0]        syn_dst; // 목적지 뉴런 ID (어느 뉴런으로 보낼지)
  logic signed [WEIGHT_W-1:0]    syn_w; // 시냅스 가중치 (영향 크기)
  logic [SYN_ADDR_W-1:0]         syn_addr; // 시냅스 테이블 주소  
  logic [NEURON_ID_W-1:0]        syn_pre; // 실제 pre 뉴런 ID (학습/기록용 메타)

  dynamic_synapse_processor_stream_v2 #( // 시냅스 테이블을 순회/참조하여 (dst,weight) 생성
  // 한 번의 입력 이벤트가 들어오면, 그 뉴런이 갖고 있는 시냅스를 꺼내서 (목적지, 가중치)를 스트림으로 내보냄
    .N_NEURON(N_NEURON), .NEURON_ID_W(NEURON_ID_W), // 전체 뉴런 수, 네트워크 크기/ID폭 전달
    .WEIGHT_W(WEIGHT_W), .ACC_W(ACC_W), // 데이터 폭 전달
    .GRID_W(128), .GRID_H(128), // 공간 맵 해상도 (거리 감쇠 등 내부용)
    .TOTAL_SYNAPSES(TOTAL_SYNAPSES), .SYN_ADDR_W(SYN_ADDR_W), .DEG_W(DEG_W) // 시냅스/주소/차수
  ) u_dsp (
    .clk(clk), .rst_n(rst_n), .clk_en(clk_en), // 제어, clk_en이 0이면 내부 상태 업데이트를 멈춤
    .ev_valid(ev_valid), .ev_ready(/*unused*/), .pre_id_i(pre_id), // 이번 사이클에 pre 이벤트가 있다는 플래그, 모듈이 새 이벤트를 받을 준비가 됐는지 알리는 신호, 발화한 pre 뉴런 ID
    .pos_x_i(posx_mm), .pos_y_i(posy_mm), .mass_u8_i({2'b0,mass_g}), // 시냅스 가중치를 거리/질량 등으로 가감하려는 목적에서 들어가는 입력
    .syn_out_valid(syn_v), .syn_out_ready(syn_r), // 현재 사이클에 유효한 (dst,weight)한 건 나왔다는 의미, 아래에서 받을 준비가 됐는지
    .syn_dst_id_o(syn_dst), .syn_weight_o(syn_w), // 목적지 뉴런 ID, 가중치 
    .syn_addr_o(syn_addr), .syn_pre_id_o(syn_pre), // 지금 읽고 있는 시냅스 테이블 주소 (디버그/추적용), 이 출력 항목의 원천 pre 뉴런 ID 
    .upd_valid_i(1'b0), .upd_ready_o(), .upd_addr_i('0), .upd_dw_i('0) // 런타임에 시냅스 테이블을 쓰기 (가중치 업데이트) 위한 인터페이스 -> 나중에 STDP나 학습 규칙을 연결하려면 여기로 주소/데이터/valid를 넣어 테이블을 갱신 가능)
  );

  // 모터 채널 지정
  // syn_dst가 마지막 4개 뉴런 중 어디냐에 따라 N/S/E/W 중 하나의 비트가 그 사이클에 1이 됨
  // syn_v && syn_r 조건을 넣은 이유는 핸드셰이크가 성립된 사이클만 유효 펄스로 보내겠다는 것 
  // 보통 dynamic_ 그 쪽은 한 사이클에 (dst,weight) 한 건만 내보내므로, 보통 한 번에 moter_fire은 한 비트만 올라옴 -> 도잇에 여러 방향이 1이 될 일 없음
  // 어떤 사이클에 syn_v=1, sun_dst == N_NEURON-2라면 -> moter_fire[2]=1 (E방향)
  // 그 사이클에 u_mec가 east=1 펄스를 뽑아줌
  // u_ax가 east를 +로 누적 -> fx_acc 증가 
  // fx_q에 반영되어 물리엔진이 오른쪽 힘을 받아 위치가 점점 오른쪽으로 이동 
  // 반대로 syn_dst == NNEURON-1이면 W 방향 -> west=1 -> west 펄스가 들어올수록 fx_acc 감소 -> 왼쪽 힘
  logic [3:0] motor_fire; // 4방향 모터 트리거 비트 묶음 
  assign motor_fire[0] = syn_v && syn_r && (syn_dst == (N_NEURON-4)); // N
  assign motor_fire[1] = syn_v && syn_r && (syn_dst == (N_NEURON-3)); // S
  assign motor_fire[2] = syn_v && syn_r && (syn_dst == (N_NEURON-2)); // E
  assign motor_fire[3] = syn_v && syn_r && (syn_dst == (N_NEURON-1)); // W
  assign syn_r = 1'b1;  // 1로 고정했으므로, 항상 받겠다는 의미 

  // 모터 펄스 -> 방향 펄스
  logic north, south, east, west;
  motor_decoder_4dir u_mdec(
    .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
    .ch_fire_i(motor_fire), // [0]=1 -> north = 1, [1]:S, [2]:E, [3]:W
    .north_o(north), .south_o(south), .east_o(east), .west_o(west)
  );

  logic signed [23:0] fx_acc, fy_acc; 
  // east 펄스가 들어올수록 fx_acc가 커짐 (오른쪽으로 힘), west 펄스가 들어올수록 fx_acc가 작아짐 (왼쪽으로 힘)
  // north 펄스는 fy_acc 증가 (위로 힘), south 펄스는 fy_acc 감소 (아래로 힘)
  g_pulse_accumulator #(.W(24)) u_ax(.clk(clk), .rst_n(rst_n), .clk_en(clk_en),
                                     .plus_pulse_i(east), .minus_pulse_i(west), .value_o(fx_acc));
  g_pulse_accumulator #(.W(24)) u_ay(.clk(clk), .rst_n(rst_n), .clk_en(clk_en),
                                     .plus_pulse_i(north), .minus_pulse_i(south), .value_o(fy_acc));

  // 물리 엔진으로 힘 전달 
  assign fx_q = fx_acc; // x방향 힘: 누산 결과를 그대로 물리엔진 입력으로
  assign fy_q = fy_acc; // y방향 힘: 같은 방식

  // --------------------------------------------------------------------------
  // Network monitor (homeostasis)
  // 네트워크가 얼마나 활발하게 발화하고 있는지를 집게해서 발화율과 보상 같은 상태값을 만들어주는 모니터/홈오스타시스
  // --------------------------------------------------------------------------
  logic [N_NEURON-1:0] spk_bus;// 
  assign spk_bus = {{(N_NEURON-3){1'b0}}, sens_spk};

  logic [15:0] rate_bus [N_NEURON]; // 뉴런 i의 발화율 (활동도) 추정치), 이동평균/누적으로 만들어 단발성 노이즈에 흔들리지 않게 함
  logic [7:0]  dopamine; // 전체 활동이 목표보다 높거나 낮을 때 증가/감소시켜 가중치나 임계값 조절에 쓰임 (홈오스타시스)
  logic [31:0] dbg; // 디버그 상태값 

  network_state_monitor #(.N_NEURON(N_NEURON)) u_mon( 
    .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
    .spike_in(spk_bus), // spike_in은 위에서 만든 spk_bus, 뉴런별 발화 신호 묶음
    .dbg_status(dbg), // 디버그용 상태 출력
    .alpha_u8_i(8'd4),      // 발화율 평활 정도를 정하는 계수 -> 느리게/부드럽게 따라가라
    .rate_bus_o(rate_bus), // 각 뉴런별 발화율 출력
    .dopamine_o(dopamine) // 전체 네트워크 활동에 대한 보상 신호 출력
  );

endmodule
