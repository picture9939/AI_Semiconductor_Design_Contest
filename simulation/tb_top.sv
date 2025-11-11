`timescale 1ns/1ps
`default_nettype none

module tb_top;
  timeunit 1ns; timeprecision 1ps;

  // ------------------------------------------------------------
  // 100 MHz clock
  // ------------------------------------------------------------
  logic clk = 1'b0;
  always #5 clk = ~clk;   // 10 ns period

  // ------------------------------------------------------------
  // Reset: 기본 20사이클 유지, +RESET_CYCLES=N 로 조절 가능
  // ------------------------------------------------------------
  logic rst_n = 1'b0;
  int unsigned RESET_CYCLES = 20;
  initial begin
    void'($value$plusargs("RESET_CYCLES=%d", RESET_CYCLES));
    repeat (RESET_CYCLES) @(posedge clk);
    rst_n = 1'b1;
  end

  // ------------------------------------------------------------
  // 파형 덤프 (VCD)
  // ------------------------------------------------------------
  initial begin
    void'($system("mkdir -p waves"));
    $dumpfile("waves/rtl.vcd");
    $dumpvars(0, tb_top);
  end

  // ------------------------------------------------------------
  // (선택) SAIF 덤프: RTL에선 보통 끔. 필요 시 +define+DUMP_SAIF
  // ------------------------------------------------------------
`ifdef DUMP_SAIF
  initial begin
    $set_gate_level_monitoring("both", "waves/rtl.saif", 1);
    $toggle_start();
  end
  final begin
    $toggle_stop();
    $toggle_report("waves/rtl.saif", 1.0e-9, "tb_top.u_dut");
  end
`endif

  // ------------------------------------------------------------
  // 시뮬 종료 타이머: 기본 200k 사이클, +MAX_CYCLES=N 로 조절
  // ------------------------------------------------------------
  int unsigned MAX_CYCLES = 200000;
  initial begin
    void'($value$plusargs("MAX_CYCLES=%d", MAX_CYCLES));
    repeat (MAX_CYCLES) @(posedge clk);
    $display("[%0t] INFO: MAX_CYCLES reached. Finishing.", $time);
    $finish;
  end

  // ------------------------------------------------------------
  // DUT
  //  - 지금은 필수 포트만 연결(clk, rst_n)
  //  - 추가 포트가 필요해지면 아래에 순차적으로 매핑
  // ------------------------------------------------------------
  ai_neuron_top_comp_v2
  #(
    // 필요시 파라미터 오버라이드
    // .N_NEURON(64)
  )
  u_dut (
    .clk   (clk),
    .rst_n (rst_n)
    // 여기에 필요한 포트만 추가:
    // .ev_valid_i(...),
    // .ev_ready_o(...),
    // .motor_cmd_o(...),
    // ...
  );

endmodule

`default_nettype wire
