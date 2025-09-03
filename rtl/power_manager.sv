// =============================================================
// power_manager.sv
// 뉴런 코어와 학습(plasticity) 로직의 전원을 켜고 끄는 것을 제어하여
// 시스템의 전력 소모를 최적화하는 모듈
// =============================================================
`timescale 1ns/1ps
module power_manager #( // power_manager이라는 이름의 모듈을 정의
    parameter int N = 64 // 모듈이 관리할 뉴런의 개수 'N'을 파라미터로 정의
) (
    input  logic             clk, reset,
    input  logic [N-1:0]     spike_in,
    input  logic [N-1:0]     spike_out,
    input  logic             decay_active, 
    // 뉴런 내부의 막 전위가 아직 안정 상태로 돌아가지 않고
    // 계속 감쇠 중임을 알리는 신호 (1이면 아직 활동 중)
    output logic             core_en,
    // 뉴런의 핵심 계산 로직을 켤지(1) 말지(0) 결정하는 'Enable' 신호
    output logic             plasticity_en
    // 시냅스 가중치를 조절하는 학습(plasticity) 로직을 켤지(1) 말지(0) 결정하는 'Enable' 신호
);  
    logic tail_active;
    // 입력 스파이크가 멈춘 후에도 뉴런 내부의 활동 (전위 감쇠 등)이 완전히
    // 끝날 때까지 "꼬리"처럼 활성 상태를 유지하기 위한 내부 플래그

    // -----------------------------------------------------------------
    // 'tail_active' 상태 레지스터 로직
    // -----------------------------------------------------------------
    always_ff @(posedge clk or posedge reset) begin
        // 클록의 상승 에지 또는 리셋 신호에 동기화되어 동작하는 순차 회로를 정의
        if (reset) tail_active <= 1'b0;
        else begin
            // '|spike_in'은 N비트 spike_in 벡터의 모든 비트를 OR 연산한 결과
            // 즉, N개의 입력 중 단 하나라도 스파이크가 있으면 '1'이 됨
            if (|spike_in) tail_active <= 1'b1;
            // 외부에서 스파이크 입력이 하나라도 들어오면, tail_active 플래그를 즉시 1로 킴
            // 이는 뉴런이 이제 막 활동을 시작했음을 의미

            else if (!decay_active && !(|spike_out)) tail_active <= 1'b0;
            // 반면, 외부 입력이 없고(!(|spike_in)은 이전 조건에서 암시됨),
            // 뉴런 내부의 전위 감쇠 활동도 모두 끝나고(!decay_active),
            // 뉴런에서 나가는 스파이크 출력도 더 이상 없다면(!(|spike_out)),
            // 이제 뉴런이 완전히 '휴면' 상태에 들어갔다고 판단하고 tail_active 플래그를 0으로 끕니다
        end
    end

    // -----------------------------------------------------------------
    // 최종 Enable 신호 생성 로직
    // -----------------------------------------------------------------
    // core_en 신호는 외부 입력 스파이크가 있거나, 또는 tail_active가 켜져 있을 때 활성화
    // 즉, 외부 입력이 시작되는 순간부터 내부 활동이 완전히 끝날 때까지 뉴런 코어를 계속 켜둠
    assign core_en       = (|spike_in) | tail_active;

    // plasticity_en 신호는 외부 입력 스파이크나 내부 출력 스파이크가 있을 때만 활성화
    // 학습 로직은 실제 스파이크 이벤트(입력 또는 출력)가 발생했을 때만 계산이 필요하기 때문
    assign plasticity_en = (|spike_in) | (|spike_out);
endmodule
