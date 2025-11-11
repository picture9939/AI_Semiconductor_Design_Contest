// ============================================================================
// tof_delay_line.sv  (Genus-friendly, no variable bit-select, no wide bitwise)
//  - 입력 1clk 펄스를 delay_i 사이클 뒤 1clk로 방출
//  - 카운트다운 슬롯 구조: 각 슬롯이 (active, cnt) 보유
//  - 한 사이클에 입력 1개 처리 가정 (필요시 SLOTS↑)
// ============================================================================
module tof_delay_line #(
  parameter int MAX_DELAY = 256,            // 최대 지연 길이(사이클)
  parameter int SLOTS     = 8               // 동시 보유 가능한 펄스 슬롯 수
)(
  input  logic clk,
  input  logic rst_n,
  input  logic clk_en,

  input  logic in_pulse,                                  // 1-cycle pulse
  input  logic [$clog2(MAX_DELAY)-1:0] delay_i,           // 0..MAX_DELAY-1
  output logic out_pulse                                   // 1-cycle pulse after delay
);

  // 폭 정의
  localparam int WDL   = (MAX_DELAY <= 1) ? 1 : $clog2(MAX_DELAY);
  localparam int SLOTW = (SLOTS     <= 1) ? 1 : $clog2(SLOTS);
  // 비교 간편화를 위한 최대 인덱스 상수(폭 맞춰 선언)
  localparam [SLOTW-1:0] SLOTMAX = (SLOTS > 0) ? (SLOTS-1) : 0;

  // 슬롯 상태 (unpacked array → 합성 친화)
  logic               active_q [0:SLOTS-1];
  logic [WDL-1:0]     cnt_q    [0:SLOTS-1];

  // 라운드로빈 할당 포인터(순차)
  logic [SLOTW-1:0]   alloc_ptr_q;

  // 조합 플래그/인덱스(모듈 상단에 선언)
  logic               any_expire_c;
  logic [SLOTS-1:0]   expire_vec_c;         // 각 슬롯 만료 비트

  logic               found_free_c;
  logic [SLOTW-1:0]   free_idx_c;
  logic [SLOTW-1:0]   probe_c;

  // 루프 인덱스 (모듈 상단 선언)
  integer i, j, k;

  // 만료 판정 (조합) : OR-reduction만 사용, 변수 비트선택/와이드 비트연산 회피
  always_comb begin
    any_expire_c = 1'b0;
    for (i = 0; i < SLOTS; i = i + 1) begin
      // 만료: active & cnt==0
      expire_vec_c[i] = (active_q[i] == 1'b1) && (cnt_q[i] == {WDL{1'b0}});
      if (expire_vec_c[i]) any_expire_c = 1'b0 | 1'b1; // 파서 친화적으로 명시적 할당
    end
  end

  // 빈 슬롯 탐색(조합): alloc_ptr_q부터 라운드로빈
  always_comb begin
    found_free_c = 1'b0;
    free_idx_c   = alloc_ptr_q;
    probe_c      = alloc_ptr_q;

    for (j = 0; j < SLOTS; j = j + 1) begin
      if (found_free_c == 1'b0) begin
        if (active_q[probe_c] == 1'b0) begin
          found_free_c = 1'b1;
          free_idx_c   = probe_c;
        end
        // probe_c = (probe_c + 1) % SLOTS;  (모듈러/슬라이스 없이 wrap)
        if (probe_c == SLOTMAX)
          probe_c = {SLOTW{1'b0}};
        else
          probe_c = probe_c + {{(SLOTW-1){1'b0}},1'b1};
      end
    end
  end

  // 순차 로직
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (k = 0; k < SLOTS; k = k + 1) begin
        active_q[k] <= 1'b0;
        cnt_q[k]    <= {WDL{1'b0}};
      end
      alloc_ptr_q <= {SLOTW{1'b0}};
      out_pulse   <= 1'b0;
    end else if (clk_en) begin
      // 1) 만료 펄스 출력 (OR of all expires)
      out_pulse <= any_expire_c;

      // 2) 각 슬롯 업데이트
      for (k = 0; k < SLOTS; k = k + 1) begin
        if (active_q[k] == 1'b1) begin
          if (cnt_q[k] == {WDL{1'b0}}) begin
            // 방출됨 → 슬롯 비움
            active_q[k] <= 1'b0;
            cnt_q[k]    <= {WDL{1'b0}};
          end else begin
            // 카운트다운
            cnt_q[k] <= cnt_q[k] - {{(WDL-1){1'b0}},1'b1};
          end
        end
      end

      // 3) 신규 입력 할당 (한 사이클 1개 가정)
      if (in_pulse == 1'b1) begin
        if (found_free_c == 1'b1) begin
          active_q[free_idx_c] <= 1'b1;
          cnt_q[free_idx_c]    <= delay_i;   // delay_i 사이클 뒤 방출
          // 다음 탐색을 위해 포인터 1칸 이동
          if (free_idx_c == SLOTMAX)
            alloc_ptr_q <= {SLOTW{1'b0}};
          else
            alloc_ptr_q <= free_idx_c + {{(SLOTW-1){1'b0}},1'b1};
        end
        // 빈 슬롯이 없으면 입력 드롭(필요시 overflow 플래그 추가)
      end
    end
  end

endmodule
