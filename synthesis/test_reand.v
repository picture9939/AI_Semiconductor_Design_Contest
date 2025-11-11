// test_read.v
module test_read(output reg out);
  reg [63:0] mem [0:0];
  initial $readmemb("spike_input.txt", mem);
  always @(*) out = mem[0][0]; // 첫 줄의 첫 비트(LSB)를 출력
endmodule