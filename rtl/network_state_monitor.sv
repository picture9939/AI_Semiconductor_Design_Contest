// =============================================================
// network_state_monitor.sv — 생체 스케일 + 견고화(히스테리시스/홀드)
//  * 기존 포트 동일: (N, clk, reset, spike_out -> network_state[1:0])
//  * 파라미터만 필요시 조정하면 됩니다.
// =============================================================
`timescale 1ns/1ps
module network_state_monitor #(
    parameter int N                = 64, // 모니터링할 뉴런의 총 개수

    // --- 시간 스케일 ---
    parameter int F_CLK_HZ         = 1_000_000, // 시스템 클럭 주파수 (Hz 단위)
    parameter int SAMPLE_HZ        = 1_000,     // 네트워크 활동을 샘플링하여 상태를 평가하는 주기 
    parameter int EMA_SHIFT        = 4,         // 지수이동평균(ENZ) 필터의 시정수를 결정하는 시프트 값 
                                                // 감쇠율이 1/2^S 가 되며, S=4는 1/16을 의미
                                                // 값이 클수록 더 부드럽게 (느리게) 변동을 추적

    // --- 발화율 임계(1뉴런 평균 Hz, "상태 UP" 기준값) ---
    // 네트워크 상태가 LOW -> MID 또는 MID -> HIGH로 변경될 때 사용되는 1개 뉴런당 평균 발화율(Hz)
    parameter int R_MED_UP_HZ      = 5,         // LOW에서 MID 상태로 올라가는 기준 발화율 (5 Hz)
    parameter int R_HI_UP_HZ       = 20,        // MID에서 HIGH 상태로 올라가는 기준 발화율 (20 Hz)

    // --- 히스테리시스(1뉴런 평균 Hz, "상태 DOWN" 기준값) ---
    // 상태가 다시 내려갈 떄의 기준값. 상승 기준보다 낮게 설정하여 상태가 경계에서 빠르게 변동하는 것을 방지
    //     예: MID→LOW는 4 Hz, HIGH→MID는 15 Hz (기본: 약 20% 마진)
    parameter int R_MED_DN_HZ      = 4,         // MID에서 LOW 상태로 내려가는 기준 발화율 (4 Hz)
    parameter int R_HI_DN_HZ       = 15,        // HIGH에서 MID 상태로 내려가는 기준 발화율 (15 Hz)


    // --- 최소 유지 시간 ---
    // 상태가 한번 변경되면 최소한 이 시간만큼은 새로운 상태를 유지하도록 하여, 아주 짧은 노이즈성 변동을 무시
    parameter int MIN_HOLD_MS      = 20,        // 상태 변경 간 최소 유지시간(ms)

    // --- 내부 누적 비트폭 ---
    parameter int ACTW             = 12         // 활동 수준(activity_level)을 저장하는 레지스터의 비트 폭. 클수록 정밀도가 높아지나 자원을 더 사용
)(
    input  logic              clk, reset,
    input  logic [N-1:0]      spike_out,
    output logic [1:0]        network_state // 최종 출력: 네트워크 상태 (00: LOW, 01: MID, 10: HIGH)
);
    // ------------------------------
    // 0) 샘플링 tick 생성 (SAMPLE_HZ에 맞춰 1클록 동안 high가 되는 신호)
    // ------------------------------
    // F_CLK_HZ 클록을 분주하여 SAMPLE_HZ 주기의 펄스(tick)를 만듦
    localparam int DIV  = (F_CLK_HZ + SAMPLE_HZ/2) / SAMPLE_HZ; // 나눗셈 반올림을 위해 분자에 절반을 더함
    localparam int DIVW = (DIV <= 1) ? 1 : $clog2(DIV); // 카운터에 필요한 비트 폭을 계산
    logic [DIVW-1:0] divcnt;  // 분주를 위한 카운터 레지스터
    logic tick;               // SAMPLE_HZ 주기로 1클록 동안 '1'이 되는 신호

    // 클록에 동기화되어 카운터를 증가시키고, 목표값에 도달하면 tick을 생성하는 로직
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin // 리셋 시 카운터와 tick을 초기화
            divcnt <= '0; tick <= 1'b0;
        end else begin
            if (DIV <= 1) begin  // 클록 주파수가 샘플링 주기보다 느리거나 같으면 매 클록마다 tick 발생
                tick <= 1'b1; // 
            end else if (divcnt == DIV-1) begin  // 카운터가 목표값에 도달하면
                divcnt <= '0; tick <= 1'b1;  // 카운터를 0으로 리셋하고
            end else begin  // 카운터가 목표값에 도달하지 않았으면 
                divcnt <= divcnt + 1'b1; tick <= 1'b0; // 카운터를 1 증가시키고, tick 신호는 0으로 유지 
            end
        end
    end

    // ------------------------------
    // 1) popcount (이번 샘플링 주기 동안 발생한 총 스파이크 수 계산) 
    // ------------------------------
    // spike_out 벡터에서 '1'의 개수를 셈
    logic [$clog2(N):0] popcount; // 총 스파이크 수를 저장할 변수
    integer ii; // for 루프를 위한 정수 변수

    // 조합 논리로 항상 popcount 값을 계산
    always_comb begin
        popcount = '0; // 계산 전 0으로 초기화
        for (ii=0; ii<N; ii++) popcount += spike_out[ii]; // spike_out의 각 비트를 더함 (Logic 타입은 0 또는 1이므로 합산 가능)
        // ($countones(spike_out))로 바꿔도 되지만 for-loop가 합성 친화적입니다.
    end

    // ------------------------------
    // 2) EMA (지수이동평균) 누적 (tick에서만 갱신, 포화)
    // 스파이크 개수의 변동을 부드럽게 만드는 저역 통과 필터 역할
    //    y <- y - y/2^S + popcount
    // ------------------------------
    logic [ACTW-1:0] activity_level; // 필터링된 활동 수준을 저장하는 레지스터
    logic [ACTW+4:0] acc_next;  // 중간 계산 과정에서의 오버플로우를 방지하기 위해 더 넓은 비트폭을 가진 임시 변수
    localparam int unsigned MAX_VAL = (1<<ACTW)-1; // activity_level이 가질 수 있는 최대값 ((2^ACTW)-1)

    // tick이 발생할 때마다 EMA 값을 갱신하는 레지스터
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            activity_level <= '0; 
        end else if (tick) begin // 샘플링 tick이 발생했을 때만 아래 로직을 수행
        // EMA 계산: 기존 값에서 일부를 감쇠시키고, 새로운 popcount 값을 더함
            acc_next = activity_level - (activity_level >> EMA_SHIFT) + popcount;
             // 포화 로직: 계산 결과가 정의된 최대값을 초과하면 최대값으로 제한(clipping/saturation)
            activity_level <= (acc_next > MAX_VAL) ? MAX_VAL[ACTW-1:0] : acc_next[ACTW-1:0];
        end
    end

    // ------------------------------
    // 3) Hz -> 내부 임계 변환
    //    TH = 2^S * N * r / SAMPLE_HZ   (정수 반올림)
    // 사람이 이해하기 쉬운 단위인 HZ를 하드웨어가 직접 비교할 수 있는 "내부 정수 값"으로 변환하는 과정
    // 사용자가 설정한 Hz 단위의 발화율(r_hz)을 activity_level과 직접 비교할 수 있는 내부 정수 값으로 변환
    // ------------------------------
    localparam int SCALE = (1 << EMA_SHIFT);

    function automatic int conv_hz_to_thr(input int r_hz);
        int thr;
        begin
            // 수식에 따라 계산. (SAMPLE_HZ/2)를 더하는 것은 정수 나눗셈에서 반올림 효과를 주기 위함입니다
            thr = (SCALE * N * r_hz + (SAMPLE_HZ/2)) / SAMPLE_HZ;
            return (thr < 0) ? 0 : thr; // 결과가 음수가 되지 않도록 방지합니다.
        end
    endfunction

    // 위 함수를 사용해 사용자가 설정한 각 Hz 임계값을 내부 정수 임계값으로 변환
    localparam int unsigned TH_MED_UP  = conv_hz_to_thr(R_MED_UP_HZ); // LOW -> MID 상승 임계값
    localparam int unsigned TH_HI_UP   = conv_hz_to_thr(R_HI_UP_HZ);  // MID -> HIGH 상승 임계값
    localparam int unsigned TH_MED_DN  = conv_hz_to_thr(R_MED_DN_HZ); // MID -> LOW 하강 임계값
    localparam int unsigned TH_HI_DN   = conv_hz_to_thr(R_HI_DN_HZ);  // HIGH -> MID 하강 임계값

    // ------------------------------
    // 4) 히스테리시스 + 최소 유지시간
    //    상태는 레지스터(state_q)로 유지, tick 시에만 평가
    // ------------------------------
    // 상태를 나타내기 위한 열거형 (enum) 타입 정의로 가독성을 높임
    typedef enum logic [1:0] {S_LOW=2'b00, S_MID=2'b01, S_HI=2'b10} st_t;
    st_t state_q, state_n; // state_q: 현재 상태(레지스터), state_n: 다음에 될 상태(조합 논리)

    // 최소 유지 시간을 구현하기 위한 카운터 관련 상수 및 변수 정의
    localparam int HOLD_CYC = (MIN_HOLD_MS <= 0) ? 0 : ((SAMPLE_HZ * MIN_HOLD_MS) / 1000); // ms를 샘플링 tick 횟수로 변환
    localparam int HOLDW    = (HOLD_CYC <= 1) ? 1 : $clog2(HOLD_CYC+1); // 유지 시간 카운터(hold_cnt)의 비트 폭 계산
    logic [HOLDW-1:0] hold_cnt; // 현재 상태를 유지한 시간을 세는 카운터

    // 다음 상태 결정(히스테리시스)
    // 현재 상태(state_q)와 활동 수준(activity_level)을 바탕으로 다음 상태(state_n)를 결정
    always_comb begin
        state_n = state_q; // 기본적으로는 현재 상태를 유지
        unique case (state_q) // 현재 상태에 따라 분기
            S_LOW: if (activity_level > TH_MED_UP [ACTW-1:0]) state_n = S_MID; // 현재 상태가 LOW일 때, 활동 수준이 '상승' 임계값을 넘으면 MID로 변경을 시도
            S_MID: begin  
                if      (activity_level > TH_HI_UP [ACTW-1:0]) state_n = S_HI; // 현재 상태가 MID일 때, 활동 수준이 HIGH '상승' 임계값을 넘으면 HIGH로 변경을 시도
                else if (activity_level <= TH_MED_DN[ACTW-1:0]) state_n = S_LOW; // 활동 수준이 LOW '하강' 임계값(히스테리시스)보다 낮아지면 LOW로 변경을 시도
            end
            S_HI:  if (activity_level <= TH_HI_DN[ACTW-1:0])    state_n = S_MID; // 현재 상태가 HIGH일 때, 활동 수준이 MID '하강' 임계값(히스테리시스)보다 낮아지면 MID로 변경을 시도
            default: state_n = S_LOW; // 예외적인 경우(초기화 등) 안전하게 LOW 상태로 설정
        endcase
    end

    // 상태 레지스터와 최소 유지시간을 처리하는 순차 논리
    // 이 블록은 tick마다 state_n을 평가하여 실제 상태(state_q)를 업데이트할지 결정
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin // 리셋 시 상태와 카운터를 초기화
            state_q  <= S_LOW;
            hold_cnt <= '0;
        end else if (tick) begin // 샘플링 tick마다 동작
            if (HOLD_CYC == 0) begin // 최소 유지 시간이 0으로 비활성화된 경우
                state_q <= state_n;   // 즉시 다음 상태로 변경합니다.
            end else begin // 최소 유지 시간이 활성화된 경우
                if (state_n == state_q) begin // 다음 상태가 현재 상태와 같다면 (상태 유지)
                    // 유지 시간 카운터를 증가 (최대값까지만).
                    if (hold_cnt != {HOLDW{1'b1}}) hold_cnt <= hold_cnt + 1'b1;
                end else begin // 다음 상태가 현재 상태와 다르다면 (상태 변경 요청)
                    // 상태 변경 의도 → 홀드 만료됐을 때만 허용
                    if (hold_cnt >= HOLD_CYC[HOLDW-1:0]) begin // 현재 상태를 최소 유지 시간 이상 유지했다면
                        state_q  <= state_n; // 상태 변경을 허용하고
                        hold_cnt <= '0; // 유지 시간 카운터를 리셋
                    end else begin
                        // 아직 최소 유지 시간을 채우지 못했다면
                        state_q  <= state_q;  // 상태 변경을 무시하고 현재 상태를 유지
                        hold_cnt <= hold_cnt + 1'b1; // 유지 시간 카운터는 계속 증가
                    end
                end
            end
        end
    end
    // ------------------------------
    // 5) 최종 출력
    // ------------------------------
    // 최종적으로 결정된 상태(state_q)를 모듈의 출력 포트(network_state)에 연결
    always_comb begin
        network_state = state_q;
    end

endmodule
