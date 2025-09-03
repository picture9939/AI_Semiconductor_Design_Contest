// =============================================================
// neuron_top.sv (옵션 래퍼)
// 이 파일은 실제 뉴런 로직을 담고 있는 핵심 모듈(ai_neuron_top_comp_v2)을
// 한번 더 감싸서 포장하는 역할
// 이를 통해 프로젝트의 다른 부분과 연결할 때 인터페이스를 단순화할 수 있다
// =============================================================
`timescale 1ns/1ps
module neuron_top #(
    parameter int N = 64
)(
    input  logic clk, reset,
    input  logic [N-1:0] spike_in, inhib_flag,
    input  logic neuromod_signal,
    output logic [N-1:0] spike_out
);
    ai_neuron_top_comp_v2 #(.N(N)) u_top (.*);
endmodule
