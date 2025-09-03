// =============================================================
// dynamic_synapse_processor_stream.sv (Genus-friendly & Low-Power Optimized)
// 스파이크 신호가 발생하면, 연결된 뉴런들의 동적 시냅스 강도를 계산하고, 
// 그 계산된 영향력 (u,x)를 다음 뉴런들에게 1클럭 펄스로 전달하여 신호를 전파
//  - 이벤트 기반 pre 스캔: 스파이크가 발생했을 때만 해당 뉴런의 시냅스 정보를 처리
//  - rd_last로 행 종료: 한 pre 뉴런에 연결된 모든 시냅스 정보 수신 완료를 rd_last로 확인
//  - 펄스 단일 드라이버 방식: 출력 펄스를 하나의 alway 블록에서만 제어하여 합성 안정성을 높임
//  - [OPTIMIZED] 조건부 업데이트로 Clock Gating 유도하여 저전력 구현
// =============================================================
`timescale 1ns/1ps // 시뮬레이션의 시간 단위와 정밀도를 정의

module dynamic_synapse_processor_stream #( // 파라미터를 사용해 재사용성을 높임
    parameter int N = 64, // 처리할 뉴런의 총 개수 
    parameter int SUM_W = 16, // 출력 펄스 및 계산의 비트 폭 
    parameter int Q = 8, // 고정소수점의 소수부 비트 수 (정밀도)
    parameter int WEIGHT_W = 4 // [MODIFIED] 시냅스 가중치의 비트 폭
)(
    input  logic clk, reset, en, // 기본 신호: 클럭, 리셋, 모듈 활성화
    // 입력: N개 뉴런의 스파이크 발생 여부와 억제성 여부 정보
    input  logic [N-1:0] spike_in, inhib_flag,

    // RAM 스트림 I/F: 외부 메모리 (시냅스 정보 저장)와의 통신 규격
    output logic                  rd_start, //스파이크 발생 시, 메모리 읽기를 시작하라는 요청 (1클럭 펄스)
    output logic [$clog2(N)-1:0]  rd_pre, // 정보를 읽어올 pre-synaptic 뉴런의 인덱스
    input  logic                  rd_valid, // 메모리로부터 온 데이터가 유효함을 알리는 신호
    input  logic [$clog2(N)-1:0]  rd_post, // 읽어온 post-synatic 뉴런의 인덱스 
    input  logic  signed [WEIGHT_W-1:0] rd_weight, // 읽어온 시냅스 가중치 (연결 강도)
    input  logic                  rd_last, // 현재 pre 뉴런에 대한 마지막 데이터임을 알리는 신호
    output logic                  rd_next, // 현재 데이터를 처리했으니 다음 데이터를 달라는 요청

    // 시냅스 펄스 (출력: 1사이클 펄스)
    output logic signed [SUM_W-1:0] g_exc_pulse [N-1:0], // N개 뉴런 각각에 전달될 흥분성
    output logic signed [SUM_W-1:0] g_inh_pulse [N-1:0] // N개 뉴런 각각에 전달될 억제성
);
    // --- 동적 시냅스(Tsodyks-Markram 모델) 상태 변수 ---
    logic signed [Q:0] u [N-1:0], x [N-1:0]; // u: 자원 활용률(촉진), x: 사용 가능 자원(억제)

    // 모델 파라미터 상수. localparam은 모듈 내부에서만 사용됩니다.
    localparam signed [Q:0] U_param = ((1<<Q)*15)/100; // u의 증가율 (0.15를 고정소수점으로 표현)
    localparam int TAU_D_SHIFT=7, TAU_F_SHIFT=5; // 감쇠 시정수, 나눗셈을 쉬프트 연산으로 데체하여 효율 증대

    // 유틸리티 함수: Find First Set ---
    // 입력 벡터에서 가장 먼저 1이 나오는 비트의 인덱스를 찾아 반환 (우선순위 인코더)
    function automatic [$clog2(N)-1:0] ffs(input logic [N-1:0] m);
        for (int k=0; k<N; k++) if (m[k]) return k[$clog2(N)-1:0];
        return '0;
    endfunction

    // --- FSM 상태 변수 ---
    logic [N-1:0]               todo; // 외부에서 스파이크 신호가 들어오면, 처리해야 할 모든 뉴런이 목로록이 여기에 통쨰로 복사됨
    logic [$clog2(N)-1:0]       cur; // 적힌 여러 뉴런들 중에서, 지금 당장 처리하고 있는 단 하나의 뉴런 번호를 저장

    // --- u,x 업데이트 (저전력 최적화)
    // govar는 generate for 루프에서만 사용할 수 있는 특별한 정수 변수
    genvar i;
    // i가 0부터 N-1까지 변하면서, 안쪽의 코드를 N번 복제하여 
    // N개의 독립적인 뉴런 상태 업데이트 회로를 만듦.GUX는 이 블록의 이름
    generate for(i=0;i<N;i++) begin: GUX
        // --- [OPTIMIZED] 합성 친화 및 저전력을 위한 변수/로직 ---
        // du, dx: u와 x의 변화량(delta)을 저장할 임시 전선(wire)입니다.
        // u_next, x_next: 다음 클럭에 u와 x가 가져야 할 값을 미리 계산하여 저장하는 임시 전선입니다.
        logic signed [Q:0] du, dx, u_next, x_next;
        //update_en: I번째 뉴런의 상태를 업데이트해야 할 때만 1이 되면 '허락' 신호 - 저전력의 핵심
        logic update_en;

        // Condition: 스파이크가 발생했거나, 뉴런 상태가 휴지 상태(u=0, x=1)가 아닐때만 업데이트
        // Genus가 이 신호를 이용해 Clock Gating 로직을 생성하도록 유도
        assign update_en = spike_in[i] || (u[i] != '0) || (x[i] != (1<<Q));

        // 조합 로직: u, x의 다음 상태값 계산
        // Operand Isolation: spike_in[i]가 0이면 곱셈기 입력이 차단되어 전력 소모 감소
        assign du = -(u[i] >>> TAU_F_SHIFT) + (spike_in[i] ? (U_param * ((1<<Q)-u[i]))>>>Q : '0);
        assign dx = (((1<<Q)-x[i]) >>> TAU_D_SHIFT) - (spike_in[i] ? (u[i]*x[i])>>>Q : '0);
        assign u_next = u[i] + du;
        assign x_next = x[i] + dx;

        always_ff @(posedge clk or posedge reset) begin
            // 만약 리셋 신호가 활성화되면 (가장 높은 우선순위)
            if (reset) begin
                // 레지스터를 0으로 초기화
                u[i] <= '0; x[i] <= 1<<Q;
                // x[i] 레지스터를 1.0을 의미하는 (1<<Q) 값으로 초기화
            end else if (en && update_en) begin 
                // 리셋이 아니고, en과 update_en 신호가 모두 1일 때만 (클럭 상승 시)
                // Saturation Logic: u,x 값이 유효한 범위 [0, 1.0]을 벗어나지 않도록 하는 안전장치
                
                if (u_next < 0) u[i] <= 0;
                // 만약 계산된 u_next 값이 0보다 작으면, 강제로 0을 저장
                else if (u_next > (1<<Q)) u[i] <= (1<<Q);
                // 그렇지 않고, 만약 u_next 값이 1.0 (1<<Q) 보다 크면, 강제로 최대값을 저장
                else u[i] <= u_next;
                // 둘 다 아니라면 (정상 범위라면), 계산된 값이 그대로 저장

                if (x_next < 0) x[i] <= 0;
                // 만약 계산된 x_next 값이 0보다 작으면, 강제로 0을 저장
                else if (x_next > (1<<Q)) x[i] <= (1<<Q);
                // 그렇지 않고, 만약 x_next 값이 1.0 (1<<Q) 보다 크면, 강제로 최대값을 저장
                else x[i] <= x_next;
                // 둘 다 아니라면 (정상 범위라면), 계산된 값이 그대로 저장
            end
        end
    end endgenerate

    // --- 펄스 전담 블록(단일 드라이버)
    // FSM이 이 블록에게 전달하는 '펄스 생성 요청서'에 해당하는 신호들
    logic        p_v;         //  "펄스 생성 요청이 유효한가?" (pulse_valid)
    logic        p_is_inh;   // "억제성(-) 펄스인가?" (pulse_is_inhibitory)
    logic [$clog2(N)-1:0] p_idx; // "몇 번 뉴런에게 전달할 것인가?" (pulse_index)
    logic signed [SUM_W-1:0] p_val; // "펄스의 세기는 얼마인가?" (pulse_value)


    // 플리플롭 (기억소자)을 만드는 순차 로직 블록
    // 클럭 또는 리셋 신호가 0에서 1로 변할 떄만 내부 코드가 실행됨. 
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            // 만약 리셋 신호가 활동화되면, 
            g_exc_pulse <= '{default:'0};
            // 모든 흥분성 펄스 출력 배열을 0으로 초기화
            g_inh_pulse <= '{default:'0};
            // 모든 억제성 펄스 출력을 0으로 초기화


        end else if (en) begin
            // 리셋이 아니고, en 신호가 0일 때 (클럭 상승 시)
            // [펄스 생성의 핵심 1] 기본 동작: 매 클럭마다 모든 출력을 0으로 초기화 (클러어)
            // 이렇게 하면 이전 클럭에 나갔던 펄스 값이 이번 클럭에는 자동으로 사라짐
            g_exc_pulse <= '{default:'0};
            g_inh_pulse <= '{default:'0};
            
            // [펄스 생성의 핵심 2] 이벤트 처리: FSM으로부터 유효한 '펄스 생성 요청'(p_v)이 왔는지 확인
            if (p_v) begin
                // 억제성 펄스 출력 배열의 p_idx번째 위치에만 p_val 값을 써줌
                if (p_is_inh) g_inh_pulse[p_idx] <= p_val;
                // 흥분성 펄스 요청이라면, 흥분성 펄스 출력 배열의 p_idx번째 위치에만 p_val 값을 써줌. 
                else          g_exc_pulse[p_idx] <= p_val;
            end
            // 만약 p_v가 0이라면, if문이 실행되지 않으므로 모든 출력은 위에서 클리어된 0으로 유지됨
        end
    end

    // --- 스트림 FSM (펄스 이벤트 생성 전담)
    // FSM이 사용할 상태(State)들의 이름을 정의합니다. 2비트로 S_IDLE, S_ROW 두 가지 상태를 표현
    typedef enum logic [1:0] {S_IDLE,S_ROW} st_t;
    // FSM의 현재 상태를 기억하는 레지스터입니다. (지금 S_IDLE 상태인가? S_ROW 상태인가?)
    st_t st;

    // FSM 내부에서 계산을 위해 사용할 임시 전선(wire)들입니다
    logic signed [Q:0] eff_cur; // 시냅스 유효 강도 (u*x)를 저장할 변수
    logic signed [SUM_W-1:0] g_val; // 최종 계산된 펄스 값을 저장할 변수

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            todo<='0; cur<='0; st<=S_IDLE; // 할 일 목록 비우기, 현재 작업 초기화, 상태는 S_IDLE(대기)로
            rd_start<=1'b0; rd_next<=1'b0; rd_pre<='0; // 메모리 제어 신호 비활성화 
            p_v<=1'b0; p_is_inh<=1'b0; p_idx<='0; p_val<='0; // 펄스 이벤트 생성 신호 비활성화
        // 리셋이 아니고, en신호가 1일 때 (정상 동작)
        end else if (en) begin
            // rd_start, rd_next, p_v는 필요할 때만 1클럭 동안만 켜지는 '펄스' 신호
            // 따라서 매 클럭 시작 시, ㅇ리단 모두 0으로 꺼주는 것이 기본 동작
            rd_start<=1'b0; rd_next<=1'b0;
            p_v<=1'b0; // 기본 비활성

            // 현재 상태(st)가 무엇인지에 따라 다른 행동을 함
            
            case (st)
                S_IDLE: begin
                 // [S_IDLE 상태]: 스파이크가 발생하기를 기다리는 대기 상태입니다.
                    if (|spike_in) begin 
                        // 만약 spike_in 벡터에 1이 하나라도 있다면 (어딘가에서 스파이크가 발생했다면)
                        todo    <= spike_in; // 전체 스파이크 정보를 '할 일 목록'에 복사
                        cur     <= ffs(spike_in); // 처리할 첫 번재 뉴런을 ffs 함수로 찾아 '현재 작업 (cur)'으로 설정
                        rd_pre  <= ffs(spike_in); // 메모리에 이 뉴런의 정보를 달라고 요청하기 위해 주소를 설정
                        rd_start<= 1'b1;  // 메모리에 읽기 시작 신호를 보냄
                        st      <= S_ROW; // 다음 클럭부터는 S_ROW (처리) 상태로 넘어감
                    end
                end

               //[S_ROW 상태]: 메모리에서 시냅스 정보를 읽어와 처리하는 상태입니다.
                S_ROW: begin
                    // 만약 메모리에서 유효한 데이터가 도착했다면,
                    if (rd_valid) begin
                        // (1) efficacy & 값 계산
                        eff_cur = (u[cur]*x[cur])>>>Q; // 현재 뉴런 (cur)의 u,x 갑스로 동적 강도를 계산
                        g_val   = $signed(rd_weight) * eff_cur; // 여기에 메모리에서 읽은 가중치를 곱해 최종 펄스 값을 만듦

                        // (2) '펄스 생성 요청서' 작성
                        // 이 요청서는 다음 클럭에 '펄스 전담 블록'이 읽어감
                        p_v      <= 1'b1;  // 요청 유효!
                        p_is_inh <= inhib_flag[cur];  // 펄스 종류 (억제성/흥분성)
                        p_idx    <= rd_post;  // 펄스 도착지 주소
                        p_val    <= g_val;    // 펄스 세기
          
                        // (3) 다음 메모리에 다음 데이터 요청 
                        rd_next  <= 1'b1;     // "이 데이터 잘 받았으니, 다음 것 주세요"
                    end

                    // 만약 도착한 데이터가 현재 뉴런에 대한 '마지막' 데이터라면, 
                    if (rd_valid && rd_last) begin
                        todo[cur] <= 1'b0;  // 할 일 목록에서 현재 작업을 지움 

                        // 아직 '할 일 목록'에 다른 일이 남아있다면, 
                        if (|todo) begin
                            cur     <= ffs(todo);  // 다음 작업을 ffs 함수로 찾아 '현재 작업'으로 설정
                            rd_pre  <= ffs(todo);  // 메모리에 다음 작업의 주소를 알려줌 
                            rd_start<= 1'b1;       // 메모리에 새로운 읽기 시작 신호를 보냄
                        // '할 일 목록'이 모두 비었다면, 
                        end else begin
                            st <= S_IDLE;  // 모든 이링 끝났으니 다시 S_IDLE(대기) 상태로 돌아감
                        end
                    end
                end
            endcase
        end
    end
endmodule