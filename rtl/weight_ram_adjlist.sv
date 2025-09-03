// =============================================================
// weight_ram_adjlist.sv  (SV, Genus-friendly)
// 모든 뉴런 간의 연결 관계와 가중치를 저장하고, 다른 부품들이 요청할 때마다 해당 정보를 빠르고 효율적으로 제공하는 것
// =============================================================
`timescale 1ns/1ps
module weight_ram_adjlist #(
    parameter int N = 64,
    parameter int MAX_FANOUT = 16 // 하나의 뉴런이 가질 수 있는 최대 연결 수 (주소록에 저장 가능한 최대 친구 수)
)(
    input  logic clk, reset,

    // ---- 스트림 읽기 (행 단위) ----
    // a뉴런과 연결된 모든 친구들의 목록과 관계를 순서대로 알려줘
    input  logic                  rd_start, // 신호가 1이되면 목록 읽기 시작
    input  logic [$clog2(N)-1:0]  rd_pre, // '누구의' 주소록을 읽을지를 입력받음 
    output logic                  rd_valid, // 메모리가 보내는 친구 정보가 유효함을 알리는 출력 신호
    output logic [$clog2(N)-1:0]  rd_post, // 찾은 뉴런의 인덱스를 출력 
    output logic  signed [3:0]    rd_weight, // 그 뉴런과의 가중치를 출력
    input  logic                  rd_next, // 외부에서 다음 인덱스를 요청하는 입력 신호
    output logic                  rd_last, // 마지막 뉴런이라고 메모리가 알려주는 출력 신호

    // ---- 임의 읽기 ----
    // a뉴런과 b뉴런의 현재 관계가 어때? 
    input  logic                  rr_en, // 특정 관계를 읽겠다는 요청 신호
    input  logic [$clog2(N)-1:0]  rr_pre, rr_post, // 관계를 알고 싶은 두 뉴런의 주소를 입력받음 
    output logic                  rr_valid, // 메모리의 응답이 유효함을 알리는 출력 신호
    output logic  signed [3:0]    rr_weight, // 현재 그 둘의 관계 (가중치)를 출력
    output logic                  rr_hit, // 맞다 아니라를 알려주는 출력 신호

    // ---- 임의 쓰기 ----
    // a와 b의 관계를 이걸로 새로 저장해줘
    input  logic                  w_en, // 관계를 쓰겠다 (업데이트)는 요청 신호
    input  logic [$clog2(N)-1:0]  w_pre, w_post, // 관계를 업데이트할 두 뉴런의 주소를 입력받음
    input  logic  signed [3:0]    w_data, // 새로 저장할 관계 값을 입력받음 

    // ---- 구성 로더 ---- (초기 설정 및 디버깅용)
    // 맨 처음에 주소록을 이렇게 세팅해줘 
    input  logic                  cfg_en, // 구성 모드를 활성화하는 신호
    input  logic [$clog2(N)-1:0]  cfg_pre, // 주소록을 수정할 뉴런의 주소
    input  logic [$clog2(MAX_FANOUT)-1:0] cfg_slot, // 그 뉴런의 주소록 중 몇 번째 칸을 수정할지 정함
    input  logic [$clog2(N)-1:0]  cfg_dst, // 그 칸에 저장할 뉴런 인덱스
    input  logic  signed [3:0]    cfg_val, // 그 칸에 저장할 가중치
    input  logic                  cfg_deg_wen, // 친구 수를 직접 수정할지 정하는 신호
    input  logic [$clog2(MAX_FANOUT):0] cfg_degree, // 직접 수정할 친구의 수 
    input  logic                  cfg_clr_row // 특정 뉴런의 주소록 전체를 초기화하는 신호
);
    localparam int DW    = $clog2(N); // 뉴런 주소에 필요한 비트 수
    localparam int SLOTW = $clog2(MAX_FANOUT); // 주소록의 칸 (슬록) 주소에 필요한 비트 수 

    // --- 메모리의 실제 저장 공간 (N개의 주소록) ---
    logic [DW-1:0]        dst   [N-1:0][MAX_FANOUT-1:0]; / // dst: '누구와' 연결되어 있는지 (친구의 이름)를 저장하는 2D 배열
    logic signed [3:0]    val   [N-1:0][MAX_FANOUT-1:0]; // val: '얼마나' 강하게 연결되어 있는지 (친구와의 관계)를 저장하는 2D 배열
    logic [SLOTW:0]       degree[N-1:0]; // degree: 각 뉴런이 '몇 명의' 친구를 가지고 있는지 저장하는 1D 배열

    integer i,j;

    // 초기화/쓰기/구성
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i=0;i<N;i++) begin
                degree[i] <= '0;
                for (j=0;j<MAX_FANOUT;j++) begin
                    dst[i][j] <= '0;
                    val[i][j] <= 4'sd0;
                end
            end
        end else begin // 리셋이 아닐 경우,
            if (cfg_en) begin // 구성 모드가 활성화되면,
                dst[cfg_pre][cfg_slot] <= cfg_dst; // 외부에서 지정한 연결 목록 칸에
                val[cfg_pre][cfg_slot] <= cfg_val; // 지정된 연결 대상과 가중치를 직접 씀
            end
            if (cfg_deg_wen) begin // 팬아웃 수 직접 수정이 활성화되면
                degree[cfg_pre] <= cfg_degree; // 외부에서 지정한 값으로 팬 아웃 수를 직접 수정
            end
            if (cfg_clr_row) begin // 주소록 초기화가 활성화되면,
                for (j=0;j<MAX_FANOUT;j++) begin // 지정된 뉴런의 연결 목록을
                    dst[cfg_pre][j] <= '0; // 모두 깨끗하게
                    val[cfg_pre][j] <= 4'sd0; // 지움
                end
                degree[cfg_pre] <= '0; // 팬아웃 수도 0으로 만듦
            end
            if (w_en) begin // 쓰기 요청(w_en)이 들어오면,
                for (j=0;j<MAX_FANOUT;j++) begin // 해당 뉴런(w_pre)의 연결 목록을 처음부터 끝까지 검색해서
                    if (dst[w_pre][j]==w_post) begin // 업데이트할 연결 대상(w_post)를 발견하면
                        val[w_pre][j] <= w_data; // 새로운 가중치(w_data)로 덮어씀
                    end
                end
            end
        end
    end

    // ---- 스트림 읽기 FSM ----
    typedef enum logic [1:0] {S_IDLE, S_OUT} sst_t; // 상태 정의: S_IDLE(대기), S_OUT(출력 중)
    sst_t sst; // 현재 상태를 저장하는 레지스터
    logic [SLOTW-1:0]      k; // 현재 몇 번째 연결을 읽고 있는지 가리키는 포인터
    logic [DW-1:0]         cur_pre; // 현재 읽고 있는 연결 목록의 시작 뉴런

    logic                  rd_valid_q;
    logic [DW-1:0]         rd_post_q;
    logic signed [3:0]     rd_weight_q;

    assign rd_valid  = rd_valid_q;
    assign rd_post   = rd_post_q;
    assign rd_weight = rd_weight_q;

    always_ff @(posedge clk or posedge reset) begin 
        if (reset) begin // 리셋 시, 모든 상태와 신호를 초기화
            sst       <= S_IDLE; // 상태를 '대기'로
            rd_valid_q<= 1'b0; // 유효 신호를 '아니오'로
            rd_last   <= 1'b0; // 마지막 신호를 '아니오'로
            rd_post_q <= '0; // 출력할 연결 대상을 0으로
            rd_weight_q <= 4'sd0;  // 출력할 가중치를 0으로
            k         <= '0; // 포인터를 0으로
            cur_pre   <= '0; // 현재 시작 뉴런을 0으로
        end else begin
            rd_last <= 1'b0; // 매 클록마다 마지막 신호는 일단 '아니오'로 초기화

            case (sst) // 현재 상태에 따라 동작
                S_IDLE: begin // '대기' 상태일 때
                    rd_valid_q <= 1'b0; // 출력은 유효하지 않음
                    if (rd_start) begin // '연결 목록 읽어줘' 요청이 오면
                        cur_pre <= rd_pre; // 누구의 연결 목록을 읽을지 기억하고
                        k       <= '0; // 첫 번째 연결부터 시작(포인터 리셋)
                        sst     <= S_OUT; // '출력 중' 상태로 전환
                    end
                end

                S_OUT: begin // '출력 중' 상태일 때
                    if (k >= degree[cur_pre]) begin // 포인터(k)가 실제 **출력 연결 개수(degree)**를 넘어서면 (모든 연결을 다 읽었다면)
                        if (!rd_valid_q || (rd_valid_q && rd_next)) begin // 현재 출력이 없거나, "다음" 요청이 오면
                            rd_valid_q <= 1'b0; // 출력을 유효하지 않음으로 바꾸고
                            rd_last    <= 1'b1;  // '마지막이야' 신호를 보낸 후
                            sst        <= S_IDLE; // '대기' 상태로 복귀
                        end
                    end else begin // 아직 읽을 연결이 남았다면
                        if (val[cur_pre][k] == 0) begin // 현재 연결의 가중치가 0(연결 없음)이면
                            if (k != MAX_FANOUT-1) k <= k + 1'b1; else k <= k; // 다음 연결로 포인터를 이동 (단, 끝이면 멈춤)
                        end else begin // 가중치가 0이 아닌 유효한 연결이라면
                            if (!rd_valid_q) begin // 아직 현재 연결 정보를 출력하지 않았다면
                                rd_post_q   <= dst[cur_pre][k]; // 연결 대상 뉴런과
                                rd_weight_q <= val[cur_pre][k]; // 가중치를 출력 준비하고
                                rd_valid_q  <= 1'b1; // 출력이 '유효함'을 알림
                            end else if (rd_next) begin // 이미 출력했고, "다음" 요청이 왔다면
                                rd_valid_q  <= 1'b0; // 일단 현재 출력을 '유효하지 않음'으로 바꾸고
                                if (k != MAX_FANOUT-1) k <= k + 1'b1;  // 다음 연결로 포인터를 이동
                            end
                        end
                    end
                end
            endcase
        end
    end

    // ---- 임의 읽기: 1사이클 레이턴시 ----
    integer t;
    logic signed [3:0] rr_w_mux; // 검색된 가중치를 임시 저장할 변수
    logic              rr_hit_c; // 검색 성공 여부를 임시 저장할 변수

    always_comb begin // 조합 논리 (입력이 바뀌면 출력이 즉시 계산됨)
        rr_w_mux = 4'sd0; // 매 순간 임시 변수를 0으로 초기화
        rr_hit_c = 1'b0; // 검색 성공 여부를 '아니오'로 초기화
        if (rr_en) begin // '특정 가중치 알려줘' 요청이 오면
            for (t=0; t<MAX_FANOUT; t=t+1) begin // 해당 뉴런의 연결 목록을 전부 검색
                if (dst[rr_pre][t] == rr_post) begin // 요청한 연결 대상(rr_post)을 찾으면
                    rr_w_mux = val[rr_pre][t]; // 그 연결의 가중치를 임시 변수에 저장
                    rr_hit_c = 1'b1; // '찾았다!'고 표시
                end
            end
        end
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            rr_valid <= 1'b0;
            rr_weight<= 4'sd0;
            rr_hit   <= 1'b0;
        end else begin
            rr_valid <= rr_en;
            rr_weight<= rr_en ? rr_w_mux : 4'sd0;
            rr_hit   <= rr_en ? rr_hit_c : 1'b0;
        end
    end
endmodule
