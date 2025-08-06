// tb/tb_01_input_spike_index.v
module tb_spike_generator();

  logic clk = 0;
  logic reset = 0;
  logic [63:0] spike_in;

  // spike 데이터를 저장할 배열
  reg [63:0] spike_data [0:1023]; // 최대 1024 timestep

  integer i;

  // DUT 연결
  spike_generator uut (
    .clk(clk),
    .reset(reset),
    .spike_in(spike_in)
  );

  // 클럭 생성: 10ns 주기
  always #5 clk = ~clk;

  initial begin
    $dumpfile("wave.vcd");
    $dumpvars(0, tb_spike_generator);

    // spike 파일 읽기 (2진수 포맷)
    $readmemb("tb/spike_input.txt", spike_data);

    // 초기화
    reset = 1; #10; reset = 0;

    // spike 입력
    for (i = 0; i < 10; i = i + 1) begin
      spike_in = spike_data[i];
      #10;
    end

    $finish;
  end

endmodule
