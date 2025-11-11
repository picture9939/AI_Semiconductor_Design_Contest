// ============================================================================
// g_pulse_accumulator.sv
// - 입력 펄스(+/-)를 누적해 value_o에 반영
// - 누적 결과(또는 g-컨덕턴스)를 전류로 변환해 뉴런 상태(v,u 또는 LIF)를 1스텝 갱신
// - 스파이크가 나올 때 spike_o를 1클럭 동안 1로 출력
// ============================================================================

module g_pulse_accumulator #(

  // --------------------------------------------------------------------------
  // 고정소수점/시간 스텝 설정
  // --------------------------------------------------------------------------
  parameter int W = 24,          // 내부 신호/상태의 총 비트수
  parameter int FRAC = 12,       // Q(FRAC) 형식의 소수부 비트수
  parameter int DT_SHIFT = 6,    // 오일러 적분의 시간 간격 ≈ 1/2^DT_SHIFT

  // --------------------------------------------------------------------------
  // 전류 입력 방식 선택(컨덕턴스 모델 vs 단순 스케일)
  // --------------------------------------------------------------------------
  parameter bit ENABLE_G_MODEL = 1'b1, // 1이면 g_exc/g_inh 모델 사용, 0이면 value_o만 사용

  // g-컨덕턴스 모델 파라미터(모두 Q(FRAC) 스케일)
  parameter int  G_LEAK_SHIFT      = 5,           // g ← g - (g >> G_LEAK_SHIFT) : g 감쇠 속도
  parameter logic signed [W-1:0] G_STEP_EXC_Q = 24'sd2048,    // 흥분성 펄스 1개가 g_exc에 더해지는 값
  // 24 -> 비트폭, 's -> singed (부호있음), d -> decimal(10진수), h는 16진, b는 2진, 819 -> 실제 정수 값
  parameter logic signed [W-1:0] G_STEP_INH_Q = 24'sd2048,    // 억제성 펄스 1개가 g_inh에 더해지는 값
  parameter logic signed [W-1:0] E_EXC_Q      = 24'sd122880,  // 흥분성 반전전위(대략 +30.0)
  parameter logic signed [W-1:0] E_INH_Q      = -24'sd266240, // 억제성 반전전위(대략 -65.0)

  // 컨덕턴스 모델을 쓰지 않을 때: value_o → 전류 변환 스케일
  parameter int I_SCALE_SHIFT = 8, // I_q = value_o << I_SCALE_SHIFT

  // 외부 전류/노이즈
  parameter bit ENABLE_NOISE = 1'b0,                   // 1이면 간단 노이즈를 추가
  parameter logic signed [W-1:0] NOISE_AMPL_Q = 24'sd16, // 노이즈 크기(아주 작게 기본값)

  // --------------------------------------------------------------------------
  // 뉴런 모델 선택(Izhikevich 또는 LIF)
  // --------------------------------------------------------------------------
  parameter bit USE_IZHI = 1'b1, // 1이면 Izhikevich, 0이면 LIF

  // Izhikevich 계수(Q(FRAC))
  // v' = 0.04 v^2 + 5 v + 140 - u + I
  // u' = a (b v - u)
  parameter logic signed [W-1:0] K1_Q    = 24'sd164,     // 0.04 * 2^FRAC
  parameter logic signed [W-1:0] K2_Q    = 24'sd20480,   // 5.0  * 2^FRAC
  parameter logic signed [W-1:0] K3_Q    = 24'sd573440,  // 140  * 2^FRAC
  parameter logic signed [W-1:0] A_Q     = 24'sd82,      // 0.02 * 2^FRAC
  parameter logic signed [W-1:0] B_Q     = 24'sd819,     // 0.2  * 2^FRAC
  parameter logic signed [W-1:0] C_Q     = -24'sd266240, // 스파이크 후 v 리셋 값(대략 -65)
  parameter logic signed [W-1:0] D_Q     = 24'sd32768,   // 스파이크 후 u 보정(대략 +8)
  parameter logic signed [W-1:0] VPEAK_Q = 24'sd122880,  // 스파이크 판단용 피크(대략 +30)

  // LIF 계수(USE_IZHI=0일 때 사용)
  parameter int  LIF_LEAK_SHIFT  = 5,                      // v ← v - (v >> LIF_LEAK_SHIFT) + I
  parameter logic signed [W-1:0] V_RESET_Q = 24'sd0,       // 스파이크 후 v 리셋 값
  parameter logic signed [W-1:0] TH_BASE_Q = 24'sd65536,   // 기본 임계(대략 16)
  parameter logic signed [W-1:0] TH_INC_Q  = 24'sd4096,    // 스파이크 시 임계 상승량(대략 1)
  parameter int  TH_DECAY_SHIFT  = 8,                      // 임계가 기본값으로 되돌아가는 속도

  // 공통: 불응기
  parameter int  REFRACT_LEN = 0                           // 스파이크 후 쉬는 사이클 수(0이면 비사용)
)(
  // --------------------------------------------------------------------------
  // 포트
  // --------------------------------------------------------------------------
  input  logic clk, rst_n, clk_en,   // 클럭 / 비동기 로우 리셋 / 클럭 인에이블
  input  logic plus_pulse_i,         // +1로 누적하는 입력 펄스(1클럭)
  input  logic minus_pulse_i,        // -1로 누적하는 입력 펄스(1클럭)
  output logic signed [W-1:0] value_o,// 누적 결과(포화 적용됨)

  input  logic signed [W-1:0] i_ext_i, // 외부에서 주는 연속 전류(Q(FRAC)); 없으면 0 연결
  output logic                spike_o, // 스파이크 발생 시 1클럭 동안 1
  output logic signed [W-1:0] v_o,     // 막전위 모니터링
  output logic signed [W-1:0] u_o,     // Izhikevich의 회복변수(LIF에선 0)
  output logic signed [W-1:0] th_o,    // LIF의 적응 임계(IZHI에서는 참고용)
  output logic signed [W-1:0] g_exc_o, // 흥분성 컨덕턴스 모니터링
  output logic signed [W-1:0] g_inh_o, // 억제성 컨덕턴스 모니터링
  output logic signed [W-1:0] i_syn_o  // 뉴런에 실제로 투입된 전류 I
);

  // ===========================================================================
  // 보조 함수들: 포화 덧셈 / 고정소수점 곱셈 / 포화 좌시프트 / 절댓값
  // ===========================================================================
  function automatic signed [W-1:0] sat_add(input signed [W-1:0] a, b);
    signed [W:0] t; begin
      t = a + b;                                  // 한 비트 넓혀 더해 오버플로 확인
      if (t[W] != t[W-1])                         // 부호 변화면 범위 밖 → 포화
        sat_add = t[W] ? {1'b1,{(W-1){1'b0}}}     // 최소값으로 고정
                       : {1'b0,{(W-1){1'b1}}};    // 최대값으로 고정
      else
        sat_add = t[W-1:0];                       // 정상 범위면 그대로 반환
    end
  endfunction

  function automatic signed [W-1:0] fxp_mul(input signed [W-1:0] x, y);
    logic signed [(2*W)-1:0] wide, sh; begin
      wide = x * y;                               // 정수 곱(2W비트)
      sh   = wide >>> FRAC;                       // 소수부 만큼 산술 시프트 → Q(FRAC)로 정규화
      if (sh[(2*W)-1] != sh[W-1])                 // 상위 확장부가 부호와 다르면 포화
        fxp_mul = sh[(2*W)-1] ? {1'b1,{(W-1){1'b0}}}
                              : {1'b0,{(W-1){1'b1}}};
      else
        fxp_mul = sh[W-1:0];
    end
  endfunction

  function automatic signed [W-1:0] sat_shl(input signed [W-1:0] x, input int s);
    logic signed [(W+8)-1:0] wide; begin
      wide = {{8{x[W-1]}}, x} <<< s;              // 여유비트 붙여 좌시프트(산술)
      if (wide[W+7:W] != {8{wide[W-1]}})          // 잘린 상위비트가 부호와 다르면 포화
        sat_shl = wide[W-1] ? {1'b1,{(W-1){1'b0}}}
                            : {1'b0,{(W-1){1'b1}}};
      else
        sat_shl = wide[W-1:0];
    end
  endfunction

  function automatic signed [W-1:0] abs_s(input signed [W-1:0] s);
    abs_s = s[W-1] ? -s : s;                      // 부호비트를 이용한 절댓값 계산
  endfunction

  // ===========================================================================
  // 펄스 누적기: 같은 사이클에 +와 -가 함께 들어오면 서로 상쇄되도록 구현
  // ===========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      value_o <= '0;                              // 리셋 시 누적값 초기화
    end else if (clk_en) begin
      logic signed [W-1:0] one  = {{(W-1){1'b0}}, 1'b1}; // 정수 1
      logic signed [W-1:0] step = '0;                     // 이번 사이클 변화량
      if (plus_pulse_i)  step = step + one;               // +펄스 반영
      if (minus_pulse_i) step = step - one;               // -펄스 반영
      if (step != '0)    value_o <= sat_add(value_o, step); // 필요 시 포화 덧셈
    end
  end

  // ===========================================================================
  // 전류 구성: g-컨덕턴스 모델 또는 단순 스케일 중 선택
  // ===========================================================================
  logic signed [W-1:0] g_exc, g_inh;     // 컨덕턴스 상태
  logic signed [W-1:0] i_syn;            // 이번 스텝에서 뉴런이 받는 전류
  assign g_exc_o = g_exc;
  assign g_inh_o = g_inh;
  assign i_syn_o = i_syn;

  // 간단 LFSR 노이즈(옵션 사용 시에만 영향)
  logic [15:0] lfsr;
  wire  noise_bit = lfsr[0] ^ lfsr[2] ^ lfsr[3] ^ lfsr[5]; // 피드백 탭(16,14,13,11)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) lfsr <= 16'hACE1;                        // 초기 시드
    else if (clk_en) lfsr <= {lfsr[14:0], noise_bit};    // 한 스텝 진행
  end
  // 노이즈 크기 제한 및 스케일 적용(비활성 시 0)
  wire signed [W-1:0] noise_q = ENABLE_NOISE ? {{(W-16){1'b0}}, lfsr} & NOISE_AMPL_Q : '0;

  // g-컨덕턴스 갱신(활성) 또는 더미 유지(비활성)
  generate
    if (ENABLE_G_MODEL) begin : GEN_GMODEL
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          g_exc <= '0;
          g_inh <= '0;
        end else if (clk_en) begin
          g_exc <= sat_add(g_exc, -(g_exc >>> G_LEAK_SHIFT)); // g_exc 감쇠
          g_inh <= sat_add(g_inh, -(g_inh >>> G_LEAK_SHIFT)); // g_inh 감쇠
          if (plus_pulse_i)  g_exc <= sat_add(g_exc, G_STEP_EXC_Q); // +펄스 → g_exc 증가
          if (minus_pulse_i) g_inh <= sat_add(g_inh, G_STEP_INH_Q); // -펄스 → g_inh 증가
          if (g_exc[W-1]) g_exc <= '0;  // 음수 방지(컨덕턴스는 음수가 될 수 없음)
          if (g_inh[W-1]) g_inh <= '0;
        end
      end
      // 실제 전류 I 계산은 아래 뉴런 업데이트 시점에 v와 함께 수행
    end else begin : GEN_SIMPLE_I
      // 모델 비활성 시에도 레지스터는 유지(합성 시 불필요 제거 방지 용도)
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          g_exc <= '0; g_inh <= '0;
        end else if (clk_en) begin
          g_exc <= g_exc; g_inh <= g_inh; // 값 유지
        end
      end
    end
  endgenerate

  // ===========================================================================
  // 뉴런 상태 및 스파이크 로직
  // ===========================================================================
  logic signed [W-1:0] v, u, th; // v: 막전위, u: 회복변수(IZHI), th: LIF 임계
  logic [15:0]         refr_cnt; // 불응기 카운터
  assign v_o  = v;
  assign u_o  = USE_IZHI ? u : '0;
  assign th_o = th;

  // 메인 상태 업데이트(클럭 동기)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      spike_o  <= 1'b0;
      refr_cnt <= '0;
      v        <= USE_IZHI ? C_Q : V_RESET_Q; // 모델에 맞는 초기 v
      u        <= '0;
      th       <= TH_BASE_Q;                  // LIF 기본 임계
    end else if (clk_en) begin
      spike_o <= 1'b0;                        // 기본값: 스파이크 없음

      // 전류 합성: 컨덕턴스 모델이면 (g*(E - v)) 합, 아니면 value_o 스케일 사용
      logic signed [W-1:0] I_q;
      if (ENABLE_G_MODEL) begin
        logic signed [W-1:0] d_exc = sat_add(E_EXC_Q, -v); // (E_exc - v)
        logic signed [W-1:0] d_inh = sat_add(E_INH_Q, -v); // (E_inh - v)
        logic signed [W-1:0] i_e   = fxp_mul(g_exc, d_exc); // 흥분성 전류
        logic signed [W-1:0] i_i   = fxp_mul(g_inh, d_inh); // 억제성 전류
        I_q = sat_add(sat_add(i_e, i_i), sat_add(i_ext_i, noise_q));
      end else begin
        I_q = sat_add(sat_shl(value_o, I_SCALE_SHIFT), sat_add(i_ext_i, noise_q));
      end

      // 불응기 동작: 카운터가 남아있으면 v를 리셋 값으로 고정
      if (REFRACT_LEN != 0 && refr_cnt != 0) begin
        refr_cnt <= refr_cnt - 1;
        v <= USE_IZHI ? C_Q : V_RESET_Q;
      end else begin
        if (USE_IZHI) begin
          // ---------------- Izhikevich ----------------
          logic signed [W-1:0] vv    = fxp_mul(v, v);                 // v^2
          logic signed [W-1:0] k1vv  = fxp_mul(K1_Q, vv);             // 0.04*v^2
          logic signed [W-1:0] k2v   = fxp_mul(K2_Q, v);              // 5*v
          logic signed [W-1:0] rhs_v = sat_add(sat_add(k1vv, k2v),
                                               sat_add(sat_add(K3_Q, -u), I_q));
          logic signed [W-1:0] dv    = rhs_v >>> DT_SHIFT;            // v 변화량
          logic signed [W-1:0] bv    = fxp_mul(B_Q, v);               // b*v
          logic signed [W-1:0] diff  = sat_add(bv, -u);               // (b*v - u)
          logic signed [W-1:0] aterm = fxp_mul(A_Q, diff);            // a*(b*v - u)
          logic signed [W-1:0] du    = aterm >>> DT_SHIFT;            // u 변화량

          v <= sat_add(v, dv);                                        // v 갱신
          u <= sat_add(u, du);                                        // u 갱신

          if (v >= VPEAK_Q) begin                                     // 피크 도달 → 스파이크
            spike_o  <= 1'b1;
            v        <= C_Q;                                          // v 리셋
            u        <= sat_add(u, D_Q);                              // u 보정
            if (REFRACT_LEN != 0) refr_cnt <= REFRACT_LEN;            // 불응기 시작(옵션)
          end

        end else begin
          // ---------------- LIF ----------------
          v <= sat_add(v, sat_add(-(v >>> LIF_LEAK_SHIFT), I_q));     // 누수 + 입력 적용
          logic signed [W-1:0] dth = sat_add(th, -TH_BASE_Q);         // (th - 기준)
          th <= sat_add(th, -(dth >>> TH_DECAY_SHIFT));                // 기준으로 점진 복귀

          if (v >= th) begin                                          // 임계 도달 → 스파이크
            spike_o <= 1'b1;
            v       <= V_RESET_Q;                                     // v 리셋
            th      <= sat_add(th, TH_INC_Q);                         // 임계 상승(적응)
            if (REFRACT_LEN != 0) refr_cnt <= REFRACT_LEN;            // 불응기 시작(옵션)
          end
          u <= '0;                                                    // LIF에선 u 사용 안 함
        end
      end
    end
  end

endmodule
