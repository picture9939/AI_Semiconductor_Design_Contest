// =============================================================
// state_dependent_plasticity.sv
// 함께 발화하는 뉴런은 서로 강하게 연결되고, 그렇지 않은 뉴런은 약하게 연결
// 네트워크의 상태와 스파이크 타이밍에 기반하여 시냅스 연결 강도 (가중치)를
// 동적으로 조절 (학습)하는 '상태 의존적 가소성' 모듈 
// =============================================================
`timescale 1ns/1ps
module state_dependent_plasticity #(
    parameter int N = 64, parameter int HIST_W = 4
    // 각 뉴런의 최근 스파이크 발생 시간을 얼마나 오래 기억할지 결정 (4비트 = 16클록)
)(
    // ---- 입력 신호 ----
    input  logic clk, reset, en, // 기본 클록, 리셋, 그리고 power_manager로부터 오는 전체 활성화 신호
    input  logic [N-1:0] spike_in, spike_out,  // 학습 규칙을 적용하기 위한 입력/출력 스파이크 정보
    input  logic [1:0]   network_state, // network_state_monitor로부터 오는 네트워크 전체의 활동 상태 (LOW, MID, HIGH)
    input  logic         neuromod_signal, // 외부에서 주어지는 특별한 '학습 촉진' 신호 (보상 신호, 마치 도파민처럼)
    output logic         busy, // 이 모듈이 현재 학습 과정을 수행 중이라 바쁨을 알리는 신호

    //--- 메모리 임의 읽기 인터페이스 (Random Read I/F) ---
    // 특정 시냅스의 현재 가중치를 '물어보기' 위한 신호들

    output logic                  rr_en, // 읽기 요청 활성화 
    output logic [$clog2(N)-1:0]  rr_pre, rr_post, // 읽고 싶은 시냅스의 시작 (pre)과 끝 (post) 뉴런 주소
    input  logic                  rr_valid, // 메모리에서 보낸 데이터가 유효함을 알리는 신호
    input  logic  signed [3:0]    rr_weight, // 메모리에서 읽어온 현재 가중치 값

    // --- 메모리 쓰기 인터페이스 (Write I/F) ---
    // 학습 결과로 계산된 새로운 가중치를 '저장하기' 위한 신호들

    output logic                  w_en, // 쓰기 요청 활성화
    output logic [$clog2(N)-1:0]  w_pre_idx, w_post_idx, // 새로운 가중치를 쓸 시냅스의 주소
    output logic  signed [3:0]    w_data // 새로 저장할 가중치 데이터
);
    // HIST_W(4)로부터 최대 16밀리초의 순간을 기억 
    // 이 시기가 뇌가 인과관계를 학습하기에 충분히 짧고 의미 있는 시간
    localparam int HIST_D = 1 << HIST_W;

    function automatic logic signed [3:0] sat4s(input logic signed [4:0] x);
    // sat4s라는 이름의 함수를 정의 
    // 5비트 부호 있는 정수 x를 입력받아, 4비트 부호 있는 정수 범위로 값을 제한하여 출력
    // 'automatic'은 이 함수가 재진입 가능(re-entrant)하도록 만들어, 여러 곳에서 동시에 안전하게 호출될 수 있게 함
        if (x >  5'sd7)  return 4'sd7;
        // 만약 입력값 x가 4비트로 표현 가능한 양의 최대값 (+7)보다 크면
        // 더이상 값을 증가시키지 않고 +7로 값을 고정(포화)시켜 반환 
        // 5'sd7은 5비트 부호 있는(signed) 10진수(decimal) 7을 의미

        if (x < -5'sd8)  return -4'sd8;
        // 만약 입력값(x)이 4비트로 표현 가능한 음의 최소값(-8)보다 작으면,
        // 더 이상 감소시키지 않고 -8로 값을 고정시켜 반환
        return x[3:0];
        // 만약 입력값(x)이 -8에서 +7 사이의 범위 안에 있다면,
        // 값의 변화 없이 하위 4비트만 그대로 반환
    endfunction

    logic [HIST_W-1:0] in_hist [N-1:0], out_hist [N-1:0];

// in_hist: N개 뉴런 각각의 '입력(input) 스파이크'가 마지막으로 언제 발생했는지 기록하는 메모장 배열
// out_hist: N개 뉴런 각각의 '출력(output) 스파이크'가 마지막으로 언제 발생했는지 기록하는 메모장 배열


// -----------------------------------------------------------------
// N개의 '활동 타이머'를 자동으로 생성하고 업데이트하는 로직
// -----------------------------------------------------------------
    genvar i; generate for (i=0;i<N;i++) begin : G_H

    // 0부터 N-1까지 반복하면서, 뉴런 하나하나에 대한 개별적인 회로 블록을 생성(복제)
    // : G_H는 이 generate 블록에 'G_H'라는 이름을 붙여주는 것

        always_ff @(posedge clk or posedge reset) begin
            if (reset) begin
                in_hist[i]<=HIST_D-1; out_hist[i]<=HIST_D-1;
            end else if (en) begin
                if (spike_in[i])  in_hist[i]  <= '0; else if (in_hist[i]  < HIST_D-1) in_hist[i]  <= in_hist[i]  + 1'b1;
                // 만약 i번째 뉴런에 입력 스파이크가 방금 발생했다면, 타이머를 0으로 리셋 
                // 스파이크가 없었다면, 타이머 값을 1 증가시킴. (시간이 한 클록만큼 흘렀다는 의미)
                // 단, 타이머가 이미 최대값(15)이라면 더 이상 증가하지 않고 멈춤
                if (spike_out[i]) out_hist[i] <= '0; else if (out_hist[i] < HIST_D-1) out_hist[i] <= out_hist[i] + 1'b1;
                // 똑같이 출력 스파이크 타이머 제어
            end
        end
    end endgenerate

    // -----------------------------------------------------------------
    // 학습 과정을 제어하는 상태 머신(FSM)과 관련 변수 선언
    // -----------------------------------------------------------------
    // 학습 과정의 각 단계를 나타내는 5개의 상태를 정의합니다.
    // IDLE(대기), SCAN_PRE/POST(탐색), READ(읽기), WRITE(쓰기)
    typedef enum logic [2:0] {IDLE, SCAN_PRE, SCAN_POST, READ, WRITE} st_t;
    st_t st; // 현재 FSM이 어떤 상태에 있는지를 저장하는 레지스터


    // --- FSM 내부에서 사용할 변수들 ---
    logic [$clog2(N)-1:0] pre_i, post_j, k_scan; // 뉴런들을 스캔 (탐색)하기 위한 인덱스 변수
    logic is_ltp; // 이번 학습이 연결을 강화(LTP)할지, 약화(LTD)할지 결정하는 플래그
    logic signed [3:0] step; // 가중치를 변경할 양 (+1, -1 등 )
    logic signed [4:0] new_w; // 새로 계산된 계산치 값을 임시로 저장하는 변수

    // 학습 과정의 핵심 제어 로직 (상태 머신)
    always_ff @(posedge clk or posedge reset) begin // 클록에 맞춰 동작하는 FSM의 메인 로직
        if (reset) begin // 리셋 시, 모든 상태와 신호를 깨끗하게 초기화
            st<=IDLE; busy<=1'b0; rr_en<=1'b0; w_en<=1'b0;
            pre_i<='0; post_j<='0; k_scan<='0; step<=4'sd0; new_w<=5'sd0;
            rr_pre<='0; rr_post<='0; w_pre_idx<='0; w_post_idx<='0; w_data<=4'sd0;
        end else if (en) begin // power_manager가 허락할 때만 FSM이 동작
            busy <= (st!=IDLE); // IDLE 상태가 아닐 때 (즉, 무언가 작업을 하고 있을 때)는 항상 busy 신호를 켬
            rr_en<=1'b0; w_en<=1'b0; // 메모리 요청 신호는 매 순간 초기화하고, 필요한 상태에서만 킨다

            case (st)  // 현재 상태(st)에 따라 다른 행동을 합니다.
               // --- 1. 대기 상태 (사건 접수) ---
                IDLE: begin
                    // 만약 입력 스파이크가 발생하면, 'SCAN_PRE' 상태로 넘어가 탐문을 시작
                    if (|spike_in)  begin st<=SCAN_PRE;  pre_i<='0;  k_scan<='0; end
                    // 만약 출력 스파이크가 발생하면, 'SCAN_POST' 상태로 넘어가 다른 방향으로 탐문을 시작함
                    else if (|spike_out) begin st<=SCAN_POST; post_j<='0; k_scan<='0; end
                end
               // --- 2. 탐색 상태 (용의자 탐문) ---
                SCAN_PRE: begin
                    // 입력 스파이크를 기준으로, '누가 영향을 받았나?'를 탐색 (주로 연결 강화 조건)
                    // 만약 pre_i 뉴런이 방금 발화했고, k_scan 뉴런이 그보다 살짝 먼저 발화했다면 (STDP 인과관계 조건 충족)
                    if (spike_in[pre_i] && (out_hist[k_scan]>in_hist[pre_i]) && (out_hist[k_scan]<HIST_D-1)) begin
                        // 이 두 뉴런을 용의선상에 올리고, 이들의 관계 (가중치)를 확인하기 위해 'READ' 상태로 넘어감
                        rr_pre <= pre_i; rr_post <= k_scan; is_ltp<=1'b1; rr_en<=1'b1; st<=READ;
                    end else if (k_scan==N-1) begin // 모든 용의자 (k_scan)를 다 탐문했다면, 
                        // 다음 사건(pre_i)으로 넘어가거나, 모든 사건을 다 봤으면 대기(IDLE)상태로 돌아감
                        k_scan<='0; if (pre_i==N-1) st<=IDLE; else pre_i<=pre_i+1'b1;
                    end else k_scan<=k_scan+1'b1; // 다음 용의자를 탐문
                end
                SCAN_POST: begin 
                    // 출력 스파이크를 기준으로, '누가 영향을 줬나?'를 탐색 (주로 연결 약화 조건)
                    if (spike_out[post_j] && (in_hist[k_scan]>out_hist[post_j]) && (in_hist[k_scan]<HIST_D-1)) begin
                        rr_pre <= k_scan; rr_post <= post_j; is_ltp<=1'b0; rr_en<=1'b1; st<=READ;
                    end else if (k_scan==N-1) begin
                        k_scan<='0; if (post_j==N-1) st<=IDLE; else post_j<=post_j+1'b1;
                    end else k_scan<=k_scan+1'b1;
                end
                // --- 3. 읽기 상태 (증거 확인) ---
                READ: begin
                    if (rr_valid) begin // 메모리에서 유효한 증거(현재 가중치)를 보내주면,
                    // 주변 상황(네트워크 상태)과 특별 지시(신경 조절 신호)를 고려하여 최종 판단을 내림
                        if (neuromod_signal)       step <= 4'sd3; // 특별 지시('보상')가 있으면, 가장 강력하게 관계를 강화합니다.
                        else case (network_state) // 그게 아니라면, 전체적인 분위기에 따라 판단
                            2'b00: step<=4'sd0;   // 분위기가 조용하면(LOW): 관계 변화 없음 (사소한 사건으로 판단)
                            2'b01: step<=4'sd1;   // 분위기가 평범하면(MID): 보통 수준으로 관계를 변화시킴
                            2'b10: step<=-4'sd1;  // 분위기가 과열되면(HIGH): 오히려 관계를 약화시켜 진정시킴 (안정화)
                            default: step<=4'sd0;
                        endcase

                        // 새로운 관계(가중치)를 계산하고, 메모리에 쓸 준비를 함
                        new_w <= is_ltp ? ($signed(rr_weight)+$signed(step)) : ($signed(rr_weight)-$signed(step));
                        w_pre_idx  <= rr_pre;
                        w_post_idx <= rr_post;
                        w_data     <= sat4s(new_w); 
                        if (step!=0) w_en <= 1'b1; // 변화가 있을 때만 쓰기 요청을 함
                        st <= WRITE; // '쓰기' 상태로 넘어감
                    end
                end
                 // --- 4. 쓰기 상태 (결과 반영) ---
                WRITE: begin
                    //  // 메모리에 새로운 관계(가중치)를 기록하라고 요청한 후, 한 박자 쉬어가는 상태
                    st <= IDLE; // 모든 작업이 끝났으므로, 다시 '대기' 상태로 돌아가 다음 사건을 기다림
                end
            endcase
        end
    end
endmodule
