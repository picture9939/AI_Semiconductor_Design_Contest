// ============================================================================
// weight_ram_adjlist.sv  -- 4 fan-out walker to motor neurons
// - 요청(req)을 받으면, 소스 뉴런에서 "마지막 4개 뉴런"으로 향하는 4개 엣지를
//   연속해서 하나씩(out_valid/out_ready 핸드셰이크로) 내보내는 작은 워커.
// - 각 소스 뉴런의 시냅스 주소는 {src_id, idx(2비트)} 형태로 4개가 연속 배치.
// - 가중치는 전역 4슬롯(wbase[0..3])을 사용하고, upd_* 포트로 Δw 누적 갱신 가능.
// ============================================================================

module weight_ram_adjlist #(
  parameter int N_NEURON = 64,                           // 전체 뉴런 수
  parameter int NEURON_ID_W = (N_NEURON<=2)?1:$clog2(N_NEURON), // 뉴런 ID 비트폭(ceil log2)
  parameter int TOTAL_SYNAPSES = 4096,                   // 전체 시냅스 수(주소 공간)
  parameter int SYN_ADDR_W = (TOTAL_SYNAPSES<=2)?1:$clog2(TOTAL_SYNAPSES), // 시냅스 주소 비트폭
  parameter int DEG_W = 12,                              // (현재 미사용) 차수/카운트용 여유 파라미터
  parameter int WEIGHT_W = 16                            // 가중치 비트폭(부호 포함)
)(
  input  logic clk, rst_n, clk_en,                       // 클럭, 비동기 리셋(낮음유효), 클럭 게이트

  // 요청 인터페이스(소스 뉴런 ID 입력)
  input  logic                    req_valid,             // 요청 유효
  output logic                    req_ready,             // 모듈이 요청을 받을 준비 완료
  input  logic [NEURON_ID_W-1:0]  req_src_id,            // 소스 뉴런 ID

  // 출력 스트림(엣지 4개를 순차 전송)
  output logic                    out_valid,             // 출력 유효(워커 바쁨=1)
  input  logic                    out_ready,             // 다운스트림 준비
  output logic [NEURON_ID_W-1:0]  out_dst_id,            // 목적지 뉴런 ID(항상 마지막 4개 중 하나)
  output logic signed [WEIGHT_W-1:0] out_weight,         // 가중치(슬롯별 전역 wbase[idx])
  output logic [SYN_ADDR_W-1:0]   out_addr,              // 시냅스 주소({req_src_id, idx})
  output logic                    out_last,              // 4개 중 마지막 전송 시 1

  // 가중치 업데이트 포트(전역 4슬롯에 Δw 적용)
  input  logic                    upd_valid_i,           // 업데이트 유효
  output logic                    upd_ready_o,           // 항상 수신 가능(1)
  input  logic [SYN_ADDR_W-1:0]   upd_addr_i,            // 하위 2비트로 wbase 슬롯 선택
  input  logic signed [WEIGHT_W-1:0] upd_dw_i            // 더해줄 Δw (부호 있음)
);
  logic        busy;                                     // 워커 동작 중 플래그(=out_valid)
  logic [1:0]  idx;                                      // 0..3: 4개 엣지 중 몇 번째인지
  logic [SYN_ADDR_W-1:0] addr;                           // 현재 내보낼 시냅스 주소

  // 메인 상태/포인터 레지스터
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      busy<=1'b0;                                        // 리셋 시 유휴 상태
      idx<=2'd0;                                         // 인덱스 0부터
      addr<='0;                                          // 주소 0으로 초기화
    end
    else if(clk_en) begin                                // 클럭 게이트 활성일 때만 동작
      if(!busy && req_valid) begin                       // 유휴 상태에서 요청 수락
        busy<=1'b1;                                      // 워커 시작(out_valid=1이 됨)
        idx<=2'd0;                                       // 첫 엣지부터
        addr<={req_src_id,2'b00};                        // 주소는 {src_id, 00}에서 시작
      end
      else if(busy && out_valid && out_ready) begin      // 출력 핸드셰이크 완료 시에만 진행
        idx <= idx + 2'd1;                               // 다음 엣지로
        addr<= addr+1'b1;                                // 주소도 +1(= {src_id, 01} 등)
        if(idx==2'd3) busy<=1'b0;                        // 4번째(3) 전송 끝나면 종료
      end
    end
  end

  assign req_ready = clk_en && !busy;                    // 바쁘지 않을 때만 다음 요청 수락

  assign out_valid = busy;                               // 동작 중이면 항상 유효
  assign out_addr  = addr;                               // 현재 엣지의 주소 내보냄
  assign out_last  = (idx==2'd3) && out_valid && out_ready; // 마지막 엣지 실제 전송 타이밍에 1

  // 목적지 뉴런 계산: 마지막 4개 뉴런(N_NEURON-4 .. N_NEURON-1)
  function automatic [NEURON_ID_W-1:0] motor_id(input [1:0] i);
    motor_id = N_NEURON-4 + i;                           // i=0..3 -> 끝에서 4개
  endfunction

  // 전역 가중치 4슬롯(슬롯별 기본 가중치 저장)
  logic signed [WEIGHT_W-1:0] wbase[4];
  integer k;
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n)
      for(k=0;k<4;k++) wbase[k] <= 16'sd64;              // 리셋 시 전 슬롯을 +64로 초기화
    else if(clk_en && upd_valid_i) begin
      wbase[upd_addr_i[1:0]] <= wbase[upd_addr_i[1:0]] + upd_dw_i; // 슬롯 선택해 Δw 누적
    end
  end
  assign upd_ready_o = 1'b1;                             // 언제든 업데이트 수신 가능

  assign out_dst_id = motor_id(idx);                     // 현재 인덱스에 해당하는 목적지 ID
  assign out_weight = wbase[idx];                        // 해당 슬롯의 가중치
endmodule
