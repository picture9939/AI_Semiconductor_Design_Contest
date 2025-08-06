// 01_input_spike_index_rom.v
// ⬢ 합성 가능, ROM 기반 입력 스파이크 생성기
// ⬢ tb/spike_rom_init.vh / inhib_rom_init.vh를 include하여 고정 ROM 구성

module input_spike_index (
  input wire clk,
  input wire reset,
  output reg [63:0] spike_in,
  output reg [63:0] inhib_flag
);

  reg [9:0] time_step;

  // ROM 선언 (1024 x 64bit)
  reg [63:0] spike_rom [0:1023];
  reg [63:0] inhib_rom [0:1023];

  // 초기값 삽입 (.vh include)
  initial begin
    `include "tb/spike_rom_init.vh"
    `include "tb/inhib_rom_init.vh"
  end

  // 시간 흐름에 따라 step 증가
  always @(posedge clk or posedge reset) begin
    if (reset)
      time_step <= 10'd0;
    else
      time_step <= time_step + 1;
  end

  // ROM 읽기
  always @(posedge clk) begin
    spike_in <= spike_rom[time_step];
    inhib_flag <= inhib_rom[time_step];
  end

endmodule
