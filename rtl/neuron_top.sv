// =============================================================
// neuron_top.sv (옵션 래퍼)
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
