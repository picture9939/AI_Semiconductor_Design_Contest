// =============================================================
// ai_neuron_top_comp_v2.sv  (SV, Genus-friendly)
// =============================================================
`timescale 1ns/1ps // 시뮬레이션의 시간 단위 (lns) 및 정밀도 (lps)
module ai_neuron_top_comp_v2 #( // ai_neuron_top_comp_v2.sv 라는 모듈 정의
    parameter int N = 64, //파라미터 N: 네트워크에 포함된 뉴런의 수를 정의, 기본값은 64
    parameter int MAX_FANOUT = 16 // 하나의 뉴런이 가질 수 있는 최대 시냅스 연결 (fan-out) 수를 정의하며, 기본값은 16
)(
    input  logic                 clk,
    input  logic                 reset,
    input  logic [N-1:0]         spike_in,
    input  logic [N-1:0]         inhib_flag,
    input  logic                 neuromod_signal, //신경망의 학습 및 동작에 영향을 주는 신경 조절 신호 (ex 도파민) 입력
    output logic [N-1:0]         spike_out // 뉴런 네트워크의 N개 뉴런이 생성한 스파이크 출력 벡터 
);
    // 네트워크의 전체적인 활동 상태를 모니터링하는 부분
    logic [1:0] network_state;  // 2비트 네트워크 상태 신호 (0: 낮음, 1: 중간, 2: 높음 활동 수준)
    network_state_monitor #(.N(N)) u_state ( // network_state_monitor 모듈을 u_state 라는 이름으로 인스턴스화
        .clk(clk), .reset(reset), .spike_out(spike_out), .network_state(network_state) //u_state 모듈의 포트들을 상위 모듈의 신호에 연결
    ); // u_state 모듈의 포트들을 상위 모듈의 신호에 연결

    // 이벤트 (스파이크) 발생에 따라 필요한 블록만 활성화하여 전력을 관리하는 부분
    logic core_en, plasticity_en; // 각각 뉴런 코어와 가소성 로직을 활성화시키는 enable tlsgh
    logic decay_active; //뉴런의 막 전위가 감쇠 (decay) 중임을 나타내는 신호
    power_manager #(.N(N)) u_pwr ( // power_manager 모듈을 u_pwr 라는 이름으로 인스턴스화
        .clk(clk), .reset(reset), // u_pwr 모듈의 동작에 필요한 입력 신호들을 연결
        .spike_in(spike_in), .spike_out(spike_out), .decay_active(decay_active),
        .core_en(core_en), .plasticity_en(plasticity_en) // u_pwr 모듈이 생성한 코어 및 가소성 enable 신호를 출력받습니다
    );

    // 스파이크 발생 시 관련 시냅스 정보를 스트림처럼 순차적으로 처리하는 부분
    logic signed [15:0] g_exc_pulse [N-1:0]; //각 뉴런에 전달될 흥문성 컨덕턴스 펄스 갑을 저장하는 배열
    logic signed [15:0] g_inh_pulse [N-1:0]; // 각 뉴런에 전달될 억제성 컨덕턴스 펄스 값을 저장하는 배열

    logic rd_start, rd_valid, rd_next, rd_last; // 시냅스 가중치 메모리 스트림 읽기를 위한 제어 신호들. (시작, 유효, 다음 요쳥, 마지막 데이터)
    logic [$clog2(N)-1:0] rd_pre, rd_post; // 메모리에서 읽어올 시냅스의 프리시냅스 (rd_pre) 및 포스트시냅스 (rd_post) 뉴런 인덱스
    logic signed [3:0] rd_weight; // 메모리에서 읽어온 시냅스 가중치 값

    dynamic_synapse_processor_stream #(.N(N), .SUM_W(16), .Q(8)) u_syn ( // 스트림 방식의 동적 시냅스 프로세서 모듈을 u_syn 으로 인스턴스화
        .clk(clk), .reset(reset), .en(core_en), //u_syn 모듈에 클럭, 리셋, 활성화 신호를 연결
        .spike_in(spike_in), .inhib_flag(inhib_flag), // 스파이크 입력과 억제성 플래그를 u_syn 모듈에 전달

        .rd_start(rd_start), .rd_pre(rd_pre), // u_syn이 가중치 메모리에 스트림 읽기 사작과 프리시냅스 인덱스를 요청
        .rd_valid(rd_valid), .rd_post(rd_post), .rd_weight(rd_weight), // 메모리로부터 읽은 데이터 (유효, 포스트시냅스 인덱스, 가중치)를 입력받음
        .rd_last(rd_last), .rd_next(rd_next), // 메모리 읽기 제어 신호 (마지막 데이터, 다음 데이터 요청)를 연결

        .g_exc_pulse(g_exc_pulse), .g_inh_pulse(g_inh_pulse) // 계산된 흥분성/억제성 컨덕턴스 펄스를 뉴런 코어로 전달하기 위해 출력함
    );

    // --- 뉴런: 타임멀티플렉스 Izhikevich ---- 시간 분할 방식으로 다수 뉴련을 처리하는 Izhikevich 모델 기반 뉴런 코어
    cortical_neuron_core_tm #(.N(N), .Q(8), .SUM_W(16)) u_core ( //퍼질 뉴런 코어 모듈을 u_core로 인스턴스화
        .clk(clk), .reset(reset), .en(core_en), // u_core 모듈에 클럭, 리셋, 활성화 신호를 연결
        .g_exc_pulse(g_exc_pulse), .g_inh_pulse(g_inh_pulse), // 시냅스 프로세서에서 계산된 컨덕턴스 펄스 값을 입력받음
        .spike_out(spike_out), .decay_active(decay_active) // 뉴런 연산 결과인 스파이크 출력과 감쇠 활성 상태를 출력
    );

    // --- 필요할 때마다 특정 시냅스 가중치에 접근하는 임의 접금 (Random Access) 방식의 가소성 로직
    logic rr_en, rr_valid; // 임의 읽기 활성화 (rr_en) 및 데이터 유효 (rr_valid) 신호
    logic [$clog2(N)-1:0] rr_pre, rr_post; //임의 읽기를 위한 프리시냅스 및 포스트 시냅스 뉴런 인덱스
    logic signed [3:0] rr_weight; // 임의 읽기를 통해 메모리에서 가져온 시냅스 가중치 값
    logic w_en;  // 가중치 쓰기 활성화 신호
    logic [$clog2(N)-1:0] w_pre_idx, w_post_idx; // 쓰기를 위한 프리시냅스 및 포스트시냅스 뉴런 인덱스
    logic signed [3:0] w_data; // 메모리에 새로 쓸 가중치 데이터

    state_dependent_plasticity #(.N(N), .HIST_W(4)) u_plastic ( //상태 의존적 가소성 모듈을 u_plastic으로 인스턴스화
        .clk(clk), .reset(reset), .en(plasticity_en), // u_plastic 모듈에 클럭, 리셋, 활성화 신호를 연결
        .spike_in(spike_in), .spike_out(spike_out), // 학습 규칙 계산을 위해 스파이크 입력/출력 정보를 연결
        .network_state(network_state), .neuromod_signal(neuromod_signal), // 네트워크 상태와 신경 조절 신호를 학습에 반영하기 위해 연결
        .busy(), .rr_en(rr_en), .rr_pre(rr_pre), .rr_post(rr_post), // u_plastic의 동작 상태와 임의 읽기 요청 신호들을 출력
        .rr_valid(rr_valid), .rr_weight(rr_weight), // 메모리로부터 임의 읽기한 데이터 (유효, 가중치)를 입력받음
        .w_en(w_en), .w_pre_idx(w_pre_idx), .w_post_idx(w_post_idx), .w_data(w_data) // 학습 결과로 계산된 가중치 쓰기 신호 (활성화, 주소, 데이터)를 출력
    );

    // 위 모듈들을 시냅스 가중치 메모리 (RAM)에 연결하는 부분 
    localparam int PREW  = $clog2(N); //로컬 파라미터 PREW: 프리시냅스 주소의 비트 폭을 N에 따라 게산 
    localparam int SLOTW = $clog2(MAX_FANOUT); // 로컬 파라미터 SLOTW: 팬아웃 슬롯 주소의 비트 폭을 MAX_FANOUT에 따라 계산

    wire        cfg_en, cfg_deg_wen, cfg_clr_row; // 메모리 구성용 제어 신호들 (사용 안하므로 wire로 선언)
    wire [PREW-1:0]     cfg_pre,  cfg_dst;
    wire [SLOTW-1:0]    cfg_slot;
    wire signed [3:0]   cfg_val;
    wire [SLOTW:0]      cfg_degree;

    assign cfg_en      = 1'b0;
    assign cfg_deg_wen = 1'b0;
    assign cfg_clr_row = 1'b0;
    assign cfg_pre     = '0;
    assign cfg_slot    = '0;
    assign cfg_dst     = '0;
    assign cfg_val     = '0;
    assign cfg_degree  = '0;

    logic rr_hit; // 임의 읽기 시 요청한 시냅스 연결이 메모리에 존재하는지 여부를 나타냄

    weight_ram_adjlist #(.N(N), .MAX_FANOUT(MAX_FANOUT)) u_wram (
        .clk(clk), .reset(reset),

        // 스트림: synapse processor
        .rd_start(rd_start), .rd_pre(rd_pre),
        .rd_valid(rd_valid), .rd_post(rd_post), .rd_weight(rd_weight),
        .rd_next(rd_next), .rd_last(rd_last),

        // 임의 읽기: plasticity
        .rr_en(rr_en), .rr_pre(rr_pre), .rr_post(rr_post),
        .rr_valid(rr_valid), .rr_weight(rr_weight), .rr_hit(rr_hit),

        // 쓰기: plasticity
        .w_en(w_en), .w_pre(w_pre_idx), .w_post(w_post_idx), .w_data(w_data),

        // 구성 로더 (옵션)
        .cfg_en(cfg_en), .cfg_pre(cfg_pre), .cfg_slot(cfg_slot),
        .cfg_dst(cfg_dst), .cfg_val(cfg_val),
        .cfg_deg_wen(cfg_deg_wen), .cfg_degree(cfg_degree),
        .cfg_clr_row(cfg_clr_row)
    );
endmodule
