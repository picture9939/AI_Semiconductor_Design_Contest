// ============================================================================
// synapse_event_fifo.sv
// 생산자 (앞단)에서 들어오는 이벤트를 잠시 저장해주었다가, 소비자 (뒷단)이 준비되면 순서대로 내보냄 
// mem(DEPTH)에 저장
// ============================================================================
module synapse_event_fifo #(
  parameter int W = 32,
  parameter int DEPTH = 16
)(
  input  logic clk, rst_n, clk_en,
  input  logic              in_v,
  output logic              in_r,
  input  logic [W-1:0]      in_d,
  output logic              out_v,
  input  logic              out_r,
  output logic [W-1:0]      out_d
);
  localparam int AW = (DEPTH<=2)?1:$clog2(DEPTH); // 주소 비트폭: depth개를 가리킬 최소 비트 수
  logic [W-1:0] mem[DEPTH]; // 실제 저장소: depth개의 w비트 엔트리
  logic [AW:0]  wptr, rptr; // 쓰기/읽기 포인터
  logic         full, empty;

  assign full  = (wptr[AW]!=rptr[AW]) && (wptr[AW-1:0]==rptr[AW-1:0]);
  // MSB 다르고, 주소 같으면 full
  assign empty = (wptr==rptr);
  // 포인터가 완전히 같으면 empty
  assign in_r  = !full;
  //꽉 차지 않았다면 입력 ready =1 
  assign out_v = !empty;
  // 비어있지 않으면 출력 valid = 1 
  assign out_d = mem[rptr[AW-1:0]];

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) wptr <= '0;
    else if(clk_en && in_v && in_r) begin
      mem[wptr[AW-1:0]] <= in_d; // 현재 쓰기 포인터 위치에 데이터 저장
      wptr <= wptr + 1'b1; // 쓰기 포인터 한 칸 전진 
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) rptr <= '0;
    else if(clk_en && out_v && out_r) rptr <= rptr + 1'b1;
  end
endmodule
