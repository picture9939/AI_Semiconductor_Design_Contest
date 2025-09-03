// tb_01_input_spike_index.sv
module tb_01_input_spike_index;

  // 1) 타입/폭 정리
  logic clk = 0;
  logic reset = 0;
  logic [63:0] spike_in;          // 64비트
  logic [63:0] inhib_flag = '0;   // 더미면 64'b0 또는 '0

  // spike 파일 메모리
  logic [63:0] spike_mem [0:1023];
  int i;

  // DUT 인스턴스 (DUT 포트 폭이 [63:0]이라고 가정)
  input_spike_index dut (
    .clk       (clk),
    .reset     (reset),
    .spike_in  (spike_in),
    .inhib_flag(inhib_flag)       // 더미면 아예 .inhib_flag('0) 가능
  );

  // 클럭
  always #5 clk = ~clk;

  initial begin
    $dumpfile("wave.vcd");
    $dumpvars(0, tb_01_input_spike_index);

    // 2) concurrent(assign) 제거하고 procedural만 사용
    //    또한 wire 사용 금지 (logic OK)
    $readmemb("tb/spike_input.txt", spike_mem);

    reset = 1; #10; reset = 0;
    spike_in = '0;

    // 3) 64비트 라인들이 들어가게 그대로 할당
    for (i = 0; i < 10; i++) begin
      spike_in = spike_mem[i];
      #10;
    end

    $finish;
  end
endmodule
