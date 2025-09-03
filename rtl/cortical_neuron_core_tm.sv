// ============================================================================
// cortical_neuron_core_tm.sv
// [핵심 기능 요약]
// 1. Izhikevich 뉴런 모델을 하드웨어로 구현합니다. (v, u 두 개의 상태 변수 사용)
// 2. 고정 소수점(Fixed-Point) 방식을 사용해 실수 연산을 정수 연산으로 처리하여 효율을 높입니다.
// 3. 실제 생물학적 뉴런과 유사하게 컨덕턴스(conductance) 기반의 시냅스 모델을 사용합니다.
// 4. 단 하나의 물리적 계산 코어를 사용해 N개의 뉴런을 시간을 나누어(Time-Multiplexing) 처리함으로써
//    하드웨어 면적을 획기적으로 절약합니다.
// 5. 저전력 설계를 위해 클럭 인에이블(en), 불응기, 활동 감지(decay_active) 기능을 포함합니다.

`timescale 1ns/1ps // 시뮬레이션의 시간 단위 (1ns)와 정밀도 (1ps)를 설정

module cortical_neuron_core_tm #(
    // ----------------------------
    // 설계 파라미터 (사용자가 용도에 맞게 튜닝 가능)
    // '#' 뒤에 오는 파라미터들은 모듈을 외부에서 사용할 때 원하는 값으로 변경 가능
    // ----------------------------

    parameter int N      = 64,     // 이 코어 하나가 시뮬레이션할 총 뉴런의 개수
    parameter int Q      = 8,      // 고정소수점의 소수부 비트 수. -> 소수점 계산을 빠르게 하기 위해, 모든 길이를 정수 단위로 환산해서 작업
    parameter int SUM_W  = 16,     // 뉴런의 상태 변수 (v,u,g 등)를 저장할 레지스터의 전체 비트 폭

    // 시냅스 감쇠율: g <- g - g/2^shift  (shift가 클수록 더 빠르게 줄어듦)
    parameter int GEX_DEC_SHIFT = 4,   // 흥분성 g 감쇠(약 6.25%/스텝 = 1/16)
    parameter int GIN_DEC_SHIFT = 3,   // 억제성 g 감쇠(약 12.5%/스텝 = 1/8)

    // 시간 분할로 인해 발생하는 시간 지연을 보정하기 위한 계수
    // 한 뉴런이 다시 계산되기까지 4*N 클럭이 걸리므로, 연속 미분 방정식과 속도를 맞추기 위해 
    // 변화량에 이 값을 곱해준다. 일종의 시간 스템 크기를 조절하는 역할
    // 자신의 상태가 업데이트된 후 다음 업데이트 차례가 돌아오기까지 걸리는 시간
    // 나를 비추지 않는 동안 흘러가버린 시간 
    parameter int TM_FACTOR = 4*N,     // 시간 보정 계수(기본 4클럭 * N개의 뉴런)

    // 이 값이 커질수록 시간 스템이 작아져 더 정밀한 계산이 가능하지만, 변화는 느려짐
    // 갑작스러운 큰 변화량을 줄이기 위해 값을 진정시키는 역할
    parameter int DT_SHIFT  = 3,       // 오일러 적분의 dt 스케일러(≫DT_SHIFT = dt 작아짐)

    // TM_FACTOR과 DT_SHIFT는 디지털이라는 한계 (스톱모션)과 시간 분할이라는 구조적 특성 속에서, 
    // 원래의 연속적인 움직임을 얼마나 정확하고 안정적으로 흉내 낼 것인가를 결정하는 중요한 설정값
    //-----------------
    // 뉴런이 스파이크를 발생시킨 직후, 일정 시간 동안 강제로 휴식하게 하는 '불응기'의 지속 시간
    // 한 뉴런의 계산 주기 (4*N 클럭)를 기준으로 몇 번의 주기를 쉴지 결정함. 과도한 별화를 막음
    //   - 스파이크 직후 REFRAC_CYC 동안 v/u 업데이트 억제 → 과발화/진동 방지.
    parameter int REFRAC_CYC = 1,      // 0이면 비활성, 1~2 권장

    // decay_active 타임아웃:
    // 뉴런 활동 (컨덕턴스가 0이 아닌 상태)이 마지막으로 감지된 후, '아직 활동 중'이라는 신호를 
    // 얼마나 더 유지할지를 결정하는 타임아웃 카운터 초기값. 저전력 제어에 사용됨
    parameter int DECAY_TO   = 64
)(
    // ----------------------------
    // 클록/리셋/클럭-게이트
    // ----------------------------
    input  logic clk,                  // 외부의 클럭 생성기로부터 그 박자 신호 (계속 0과 1을 반복)를 받음
    input  logic reset,                // reset 신호가 들어오면 바로 reset
    input  logic en,                   // 클럭-인에이블 (이 신호가 0이면 clk 박자가 계속 들어와도, 모듈 동작이 멈춰 동적 전력 소모를 줄임)

    // ----------------------------
    // 시냅스 입력 - 외부에서 각 뉴런으로 들어오는 스파이크 정보를 나타냄
    // N개 뉴런 각각에 대한 입력이므로 배열 형태로 선언
    // ----------------------------
    input  logic signed [SUM_W-1:0] g_exc_pulse [N-1:0], // 흥분성 컨덕턴스 펄스
    input  logic signed [SUM_W-1:0] g_inh_pulse [N-1:0], // 억제성 컨덕턴스 펄스

    // ----------------------------
    // N개 뉴런 각각의 스파이크 발생 여부를 나타내는 출력 배열. 스파이크 발생 시 정확히 한 클럭 동안 1이 됨.
    // ----------------------------
    output logic [N-1:0]            spike_out,   // 뉴런별 스파이크 (한 클럭 사이클 동안만 1를 유지하고 바로 0)
    // 만약 신호가 0이면 휴식 상태라 판단하여 코어로 들어가는 클럭 신호를 차단
    output logic                    decay_active // "감쇠 활동 존재" 힌트(전력관리용)
);

    // =========================================================================
    // [유틸 함수] 포화/양수부 추출
    //  - sat_s : 부호 있는 연산 결과가 지정된 비트 폭을 벗어날 때, 최대값 또는 최소값으로 제한하여 오버플로우를 방지
    //  - sat_u : unsigned(≥0) 범위로 클램프. 0 이하면 0, 상한 초과시 all-1.
    //  - pos_part : 음수면 0, 양수면 그대로 반환(컨덕턴스는 음수 금지).
    // =========================================================================
    function automatic signed [SUM_W-1:0] sat_s(input signed [SUM_W+5:0] x);
        localparam signed [SUM_W-1:0] S_MAX =  {1'b0, {(SUM_W-1){1'b1}}}; // 부호 있는 최대값
        localparam signed [SUM_W-1:0] S_MIN =  {1'b1, {(SUM_W-1){1'b0}}}; // 부호 있는 최소값
        if (x > S_MAX) return S_MAX;             // 상한 초과 → 상한으로
        if (x < S_MIN) return S_MIN;             // 하한 미만 → 하한으로
        return x[SUM_W-1:0];                     // 범위 안이면 그대로 반환
    endfunction

    // 부호 없는 값처럼 사용될 결과를 0 이상, 최대값 이하로 제한
    // 컨덕턴스와 같이 음수가 될 수 없는 값에 사용됨 
    // 계산 과정의 사소한 오류로 인해 물리적으로 불가능한 값 (음수 컨덕턴스)이 저장되는 것을 막는 최종 방어선
    function automatic [SUM_W-1:0] sat_u(input signed [SUM_W+5:0] x);
        localparam [SUM_W-1:0] U_MAX = {(SUM_W){1'b1}}; // 부호 없는 최대값 (모든 비트가 1)
        if (x <= 0)    return '0;           // 0 또는 음수면 0으로
        if (x > U_MAX) return U_MAX;        // 상한 초과 → 최대값
        return x[SUM_W-1:0];                // 범위 안이면 그대로 반환
    endfunction


    // 입력된 값에서 양수 부분만 남김. 음수면 0을 반환
    // 시냅스 입력 펄스가 음수일 경우 이를 무시하고 양수 펄스만 컨덕턴스에 더하기 위해 사용됨
    // 흥분성 입력은 뉴런을 흥분시켜야 하는데, 이 입력값으로 음수가 들어온다면, 의도와는 달리 뉴런을 억제하는 효과를 낼 수도 있음
    function automatic [SUM_W-1:0] pos_part(input signed [SUM_W-1:0] s);
        return s[SUM_W-1] ? '0 : s[SUM_W-1:0]; // 최상위 비트(부호)가 1이면 음수 → 0
    endfunction

    // =========================================================================
    // [Izhikevich 파라미터] (Q-format 정렬)
    //  - A=a, B=b, C_BASE=c, D=d 에 해당.
    //  - K140: +140 상수도 Q로 맞춰두면 합산 시 스케일이 일치.
    //  - E_REV_EXC, E_REV_INH: 역전전위(컨덕턴스 모델 핵심).
    // =========================================================================
    localparam signed [SUM_W-1:0] A         = (1<<<Q)/50;   // a=0.02 → Q로 저장
    localparam signed [SUM_W-1:0] B         = (1<<<Q)/5;    // b=0.2
    localparam signed [SUM_W-1:0] C_BASE    = (-65) <<< Q;  // c=-65 mV -> 뉴런 리셋 전위 c = -65mv
    localparam signed [SUM_W-1:0] D         = (  8) <<< Q;  // d=+8 -> 뉴런 리셋 후 u 증가량 d = +8
    localparam signed [SUM_W-1:0] V_PEAK    = ( 30) <<< Q;  // 스파이크 발생을 감지하는 임계 전압 = 30mV
    localparam signed [SUM_W-1:0] E_REV_EXC = (  0) <<< Q;  // 흥분성 시냅스의 역전 전위 (reveral potential)
    localparam signed [SUM_W-1:0] E_REV_INH = (-80) <<< Q;  // 억제성 시냅스의 역전 전위 = -80mV
    localparam signed [SUM_W-1:0] K140      = (140)<<< Q;   // 뉴런 모델 방정식의 상수항 140 

    // [안정 장치] 막전위(v)가 비정상적인 값으로 발산하는 것을 막기 위한 스프트 클램핑 범위
    localparam signed [SUM_W-1:0] V_MIN = (-100) <<< Q;     // v의 최소 허용값
    localparam signed [SUM_W-1:0] V_MAX = (  50) <<< Q;     // v의 최대 허용값

    // =========================================================================
    // 상태 저장을 위한 레지스터 및 메모리 선언
    // N개의 뉴런 각각의 상태를 저장해야 하므로 배열(메모리) 형태로 선언
    // =========================================================================
    logic signed [SUM_W-1:0] v    [N-1:0]; // 막전위 v (Q-format)
    logic signed [SUM_W-1:0] u    [N-1:0]; // 회복변수 u (Q-format)
    logic        [SUM_W-1:0] g_exc[N-1:0]; // 흥분성 컨덕턴스 g_exc (≥0)
    logic        [SUM_W-1:0] g_inh[N-1:0]; // 억제성 컨덕턴스 g_inh (≥0)

    // 불응기 및 활동 감지 카운터의 비트 폭을 파라미터 값에 따라 동적으로 계산
    // $clog2(X)는 X를 표현하는 데 필요한 최소 비트 수를 계산해주는 함수
    localparam int REFRACW = (REFRAC_CYC < 1) ? 1 : $clog2(REFRAC_CYC+1);
    localparam int DECAYW  = (DECAY_TO   < 1) ? 1 : $clog2(DECAY_TO+1);

    logic [REFRACW-1:0] refrac_cnt [N-1:0]; // 뉴런별 불응기 카운터
    logic [DECAYW -1:0] decay_to;           // 전체 코어의 활동을 감지하는 타임아웃 카운터 (전역 변수)

    // =========================================================================
    // [4단계 FSM] 시간분할(Time-Multiplexing)
    //  뉴런 계산 과정을 4단계 (S0~S3)로 나누어 파이프라인으로 처리함. 
    // =========================================================================
    typedef enum logic [1:0] {S0_LOAD, S1_VSQ, S2_CALC, S3_UPDATE} st_t; //FSM의 상태들을 정의
    st_t st;                                 // 현재 FSM 상태를 저장하는 레지스터
    logic [$clog2(N)-1:0] idx;               // 현재 처리 중인 뉴런 인덱스

    // [파이프라인 레지스터] FSM 각 단계의 계산 결과를 다음 단계로 전달하기 위한 임시 저장 공간
    // 합성 툴이 이해하기 쉽도록 always 블록 바깥에 밀 선언합니다. 
    logic signed [SUM_W-1:0] v_r, u_r;       // S0에서 읽어온 v, u 값
    logic        [SUM_W-1:0] gex_r, gin_r;   // S0에서 읽어온 g값
    logic signed [2*SUM_W-1:0] v_sq;         // S1에서 계산된 v^2 (비트 폭이 2배로 넓어짐)
    logic signed [SUM_W-1:0]    Bv;          // S2에서 계산된 b*v 값

    // I_syn (시냅스 전류) 계산을 위한 중간 변수들, 오버플로우 방지를 위해 비트 폭을 넉넉하게 잡는다
    logic signed [2*SUM_W+3:0]  term_exc, term_inh; // 흥분/억제 항
    logic signed [2*SUM_W+4:0]  I_syn_wide;         // 합산(폭 넉넉히)
    logic signed [SUM_W-1:0]    I_syn_q;            // Q로 정규화된 I_syn

    // 0.04*v^2 항 계산을 위한 중간 변수들
    logic signed [2*SUM_W+6:0]  v2_num;     // 41 * v^2
    logic signed [2*SUM_W+5:0]  dv_v2;      // 0.04*v^2 (Q)

    // dv/dt, du/dt 계산을 위한 중간 변수들
    logic signed [2*SUM_W+6:0]  dv_dt_w, du_dt_w;

    // 내부에서 생성되어 다음 클럭에 spike_out으로 나갈 스파이크 펄스 버스
    logic [N-1:0] spike_pulse;

    // S3 단계 (업데이트)에서 사용할 임시 변수들
    logic signed [SUM_W-1:0] v_next, u_next; // 적분 결과를 임시로 담아 클램프 후 저장
    logic signed [SUM_W+5:0] ge_upd, gi_upd; // g 감쇠/누적 중간 합(폭 넉넉하게)

    integer i; // 초기화 루프 등에 사용

    // =========================================================================
    // [순차 로직] 클럭에 동기화되어 상태를 변경하는 메인 로직
    // clk 신호가 상승할 때 (posedge) 또는 reset 신호가 상승할 때마다 내부 코드가 샐행됨
    // =========================================================================
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin // reset 신호가 1이면, 모든 상태를 정해진 초기값으로 되돌림
            // --- 비동기 리셋: 모든 상태 초기화 ---
            for (i=0;i<N;i++) begin
                v[i]         <= C_BASE;             // 막전위 (v)는 안정 상태 (-65mV)로 초기화
                u[i]         <= (B*C_BASE) >>> Q;   // 회복변수 (u)는 v와 평행을 이루는 값 (b*v)으로 초기화
                g_exc[i]     <= '0;                 // 모든 컨덕턴스는 0으로 초기화
                g_inh[i]     <= '0;
                refrac_cnt[i]<= '0;                 // 불응기 카운터도 0으로 초기화
            end
            spike_out   <= '0;                      // 출력 펄스 클리어
            spike_pulse <= '0;                      // 내부 펄스 클리어
            st          <= S0_LOAD;                 // FSM 시작 상태
            idx         <= '0;                      // 첫 번쨰 뉴런 (인덱스 0)부터 처리 시작
            decay_to    <= '0;                      // 활동 감지 카운터도 0으로 초기화
        end else if (en) begin
            // --- en=1일 때만 상태 갱신(=0이면 모든 레지스터 hold → 동적전력 절감) ---
            // (1) 전 사이클에서 만들어진 spike_pulse를 외부로 내보냄
            spike_out   <= spike_pulse;
            // (2) 이번 사이클 계산을 위해 내부 스파이크 펄스 버스를 일단 0으로 초기화
            // 만약 이번 사이클에 스파이크가 발생하면 S3 단계에서 다시 1로 설정
            spike_pulse <= '0;

            // FSM의 현재 상태 (st)에 따라 다른 동작을 수행
            unique case (st)

                // S0: 현재 인덱스(idx)의 뉴런 데이터를 메모리에서 읽어와 파이프라인 레지스터에 저장함
                S0_LOAD: begin
                    v_r   <= v[idx];        // 막전위
                    u_r   <= u[idx];        // 회복변수
                    gex_r <= g_exc[idx];    // 흥분 컨덕턴스
                    gin_r <= g_inh[idx];    // 억제 컨덕턴스
                    st    <= S1_VSQ;        // 다음 클럭에는 S1 상태로 넘어감
                end

                // S1: v^2 계산(멀티플라이 1회) — 다음 단계에서 0.04*v^2 항 계산에 사용
                S1_VSQ: begin
                    v_sq <= v_r * v_r;      // v^2 (Q*Q → 2Q)
                    st   <= S2_CALC;  // 다음 클럭에는 S2 상태로 넘어감
                end

                // S2: dv/dt, du/dt, I_syn 모든 항 계산(병렬/시퀀스 혼합)
                S2_CALC: begin
                    // (a) b*v : u가 수렴해야 할 목표값(=b*v)을 만듦
                    Bv <= (B * v_r) >>> Q;  // (Q*Q)>>Q → Q 유지

                    // (b) I_syn : 컨덕턴스 기반 시냅스 전류
                    //     I_syn = g_exc*(E_exc - v) + g_inh*(E_inh - v)
                    term_exc   <= $signed({1'b0,gex_r}) * (E_REV_EXC - v_r); // 2Q
                    term_inh   <= $signed({1'b0,gin_r}) * (E_REV_INH - v_r); // 2Q
                    I_syn_wide <= term_exc + term_inh; // 2Q 폭 유지(중간 포화 방지)
                    I_syn_q    <= I_syn_wide >>> Q;    // >>>Q 하여 Q 스케일로 맞춤

                    // (c) 0.04*v^2 : 시프트 조합으로 근사 (41/1024 ≈ 0.040039)
                    v2_num  <= (v_sq<<<5) + (v_sq<<<3) + v_sq; // 41*v^2
                    dv_v2   <= v2_num >>> (Q+10);              // /(2^10) & Q 스케일 정렬

                    // (d) dv/dt = 0.04*v^2 + 5*v + 140 - u + I_syn   (모두 Q)
                    dv_dt_w <= dv_v2                     // 0.04*v^2
                               + (v_r<<<2) + v_r         // 5*v = 4*v + v
                               + K140                    // +140
                               - u_r                     // -u
                               + I_syn_q;                // +I_syn

                    // (e) du/dt = a*(b*v - u)   — 회복변수의 느린 동역학
                    du_dt_w <= (A * (Bv - u_r)) >>> Q;  // (Q*Q)>>Q → Q

                    st <= S3_UPDATE;                    // 다음 클럭에는 S3 상태로 넘어감
                end

                // S3: 계산 결과를 바탕으로 스파이크 여부를 판정하고, 뉴런 상태를 업데이트하여 메모리에 다시 씀
                S3_UPDATE: begin
                    // (1) 먼저, 현재 뉴런이 불응기 상태인지 확인
                    if (refrac_cnt[idx] != '0) begin
                        refrac_cnt[idx] <= refrac_cnt[idx] - 1'b1; // 불응기 카운터를 1 감소시키고, 
                        v[idx] <= C_BASE;                          // v는 리셋 전위로 고정
                        u[idx] <= u_r;                             // u는 유지(원하면 완만 복귀도 가능)
                    end else begin
                        // (2) 휴식 중이 아니라면 스파이크 판정: v가 정점(≈30mV) 이상이면 스파이크로 처리
                        if (v_r >= V_PEAK) begin // v가 임계 전압을 넘었으면 스파이크 발생!
                            spike_pulse[idx] <= 1'b1;              // 스파이크 펄스를 1로 설정
                            v[idx]           <= C_BASE;            // v를 리셋 전위로 되돌림
                            u[idx]           <= sat_s(u_r + D);    // u를 d만큼 증가시킴
                            if (REFRAC_CYC != 0)                   // 불응기 기능이 활성화되어 있으면, 
                                refrac_cnt[idx] <= REFRAC_CYC;     // 불응기 카운터를 설정값으로 다시 채움
                        end else begin
                            // 스파이크가 발생하지 않았으면, 오일러 적분법으로 v와 u의 다음 상태를 계산
                            v_next = sat_s(v_r + ((dv_dt_w * TM_FACTOR) >>> DT_SHIFT));
                            //     u_next = u + du/dt * (dt 스케일)
                            u_next = sat_s(u_r + ((du_dt_w * TM_FACTOR) >>> DT_SHIFT));

                            // (4) 계산된 v_next가 비정상적인 범위에 있다면, 지정된 최소/최대값으로 제한함
                            if (v_next < V_MIN)      v[idx] <= V_MIN;
                            else if (v_next > V_MAX) v[idx] <= V_MAX;
                            else                     v[idx] <= v_next;

                            u[idx] <= u_next; // u는 계산된 값을 그대로 저장함
                        end
                    end 

                    // (5) 시냅스 컨덕턴스 (g)를 업데이트함: (자연 감쇠) + (새로운 펄스 입력)
                    // 다음 컨덕턴스 = 현재 컨덕턴스 - 자연 감소량 + 외부 충전량
                    // 컨덕턴스는 신호의 세기를 조절하는 변수. g값이 바로 다음 뉴런에 얼마나 강한 전류를 보낼지를 결정하는 '볼륨 노브' 역할
                    ge_upd = $signed({1'b0,gex_r}) - $signed({1'b0,(gex_r>>GEX_DEC_SHIFT)})
                           + $signed({1'b0, pos_part(g_exc_pulse[idx])});
                    gi_upd = $signed({1'b0,gin_r}) - $signed({1'b0,(gin_r>>GIN_DEC_SHIFT)})
                           + $signed({1'b0, pos_part(g_inh_pulse[idx])});

                    g_exc[idx] <= sat_u(ge_upd);  // 업데이트된 값을 0이상으로 보장하여 저장함
                    g_inh[idx] <= sat_u(gi_upd);

                    // (6) decay_active(활동감지) 타임아웃 카운터를 관리함
                    // 현재 컨덕턴스가 남아있거나 새로운 펄스가 들어오는 등 '활동'이 감지되면, 
                    if ( (gex_r!='0) || (gin_r!='0) ||
                         (g_exc_pulse[idx]!='0) || (g_inh_pulse[idx]!='0) )
                        decay_to <= (DECAY_TO==0) ? '0 : DECAY_TO[DECAYW-1:0]; // 카운터를 초기값으로 리셋
                    // 활동이 없으면 카운터를 1씩 감소시킴
                    else if (decay_to!='0)
                        decay_to <= decay_to - 1'b1;

                    // (7) 다음 클럭의 뉴런을 처리하도록 인덱스를 1 증가시킴
                    if (idx == N-1) begin
                        idx <= '0;
                    end else begin 
                        idx <= idx + 1'b1;
                    end  // 마지막 뉴런이었으면 다시 0번으로 돌아감
                    st  <= S0_LOAD; // FSM 상태를 다시 S0로 되돌려 새로운 뉴런 처리 사이클을 시작함
                end
                default: begin
                    st <= S0_LOAD; // 안전 가드
                end
            endcase
            
        end
        // en==0이면 아무것도 갱신하지 않음(레지스터 유지 → 저전력)
    end

    // 최종 출력: decay_active = (decay_to != 0)
    //   - 전체 g 상태를 매사이클 O(N)으로 OR-리덕션하지 않고,
    //     간단한 타임아웃 카운터로 "활동 잔향"을 표현 → 전력/타이밍 유리.
    assign decay_active = (decay_to!='0);

endmodule
