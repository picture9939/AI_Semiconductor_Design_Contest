// ============================================================================
// physics_integrator_2d.sv
//   - Rolling model: v <- v + a; v <- v - v/2^FRIC_L; pos <- pos + v
//   - a = F * inv_mass (inv_mass: 1..30 g reciprocal LUT, Q20)
//   - 경계: 30cm 정사각형, 목표영역: 지름 1cm
//   - 초기 위치: LFSR 기반 랜덤(-L..+L) mm (비동기리셋 의존 제거)
// ============================================================================
module physics_integrator_2d #(
  parameter int FRAC          = 12, // Q 소수부 비트수 
  parameter int PLANE_SIZE_MM = 300, // 평면 한 변 (300mm = 30cm)
  parameter int GOAL_RAD_MM   = 5, // 목표 원의 반지름(mm): 기본 5mm -> 지름 10mm
  parameter int FRIC_L        = 5 // 마찰 세기: 2^5=32로 감쇠 
)(
  input  logic                       clk,
  input  logic                       rst_n,
  input  logic                       clk_en,
  input  logic signed [23:0]         force_x_q,
  input  logic signed [23:0]         force_y_q,
  input  logic [5:0]                 mass_g,
  output logic signed [15:0]         pos_mm_x_o, // x 위치 출력
  output logic signed [15:0]         pos_mm_y_o, // y 방향 힘 가정
  output logic                       goal_reached_o // 목표 영역 안이면 1 
);
  localparam int HALF_MM = PLANE_SIZE_MM/2; // 경계 반경 (mm): 중심 기준 반절

  function automatic logic [19:0] inv_mass_q20 (input logic [5:0] m);
  // 나눗셈을 피하려고 1/m을 표로 준비해뒀다 -> 곱하고 쉬프트로 끝냄
    case (m)
      6'd1:  inv_mass_q20 = 20'd1048575; // (1<<20)-1 to avoid trunc warn
      6'd2:  inv_mass_q20 = 20'd524288;
      6'd3:  inv_mass_q20 = 20'd349525;
      6'd4:  inv_mass_q20 = 20'd262144;
      6'd5:  inv_mass_q20 = 20'd209715;
      6'd6:  inv_mass_q20 = 20'd174762;
      6'd7:  inv_mass_q20 = 20'd149796;
      6'd8:  inv_mass_q20 = 20'd131072;
      6'd9:  inv_mass_q20 = 20'd116509;
      6'd10: inv_mass_q20 = 20'd104857;
      6'd11: inv_mass_q20 = 20'd95324;
      6'd12: inv_mass_q20 = 20'd87381;
      6'd13: inv_mass_q20 = 20'd80659;
      6'd14: inv_mass_q20 = 20'd74912;
      6'd15: inv_mass_q20 = 20'd69905;
      6'd16: inv_mass_q20 = 20'd65536;
      6'd17: inv_mass_q20 = 20'd61686;
      6'd18: inv_mass_q20 = 20'd58254;
      6'd19: inv_mass_q20 = 20'd55187;
      6'd20: inv_mass_q20 = 20'd52428;
      6'd21: inv_mass_q20 = 20'd49931;
      6'd22: inv_mass_q20 = 20'd47660;
      6'd23: inv_mass_q20 = 20'd45590;
      6'd24: inv_mass_q20 = 20'd43690;
      6'd25: inv_mass_q20 = 20'd41943;
      6'd26: inv_mass_q20 = 20'd40329;
      6'd27: inv_mass_q20 = 20'd38836;
      6'd28: inv_mass_q20 = 20'd37441;
      6'd29: inv_mass_q20 = 20'd36157;
      default: inv_mass_q20 = 20'd34952; // 30
    endcase
  endfunction

  logic [31:0] rnd_x, rnd_y; // 초기 위치를 만들 때 쓸 32비트 난수값 두개 
  // LFSR 난수 발생기 인스턴스: 리셋 후 매 클럭마다 값이 변함
  lfsr32 u_lx (.clk(clk), .rst_n(rst_n), .q(rnd_x)); // x축용 난수 
  lfsr32 u_ly (.clk(clk), .rst_n(rst_n), .q(rnd_y)); // y축용 난수

  // 내부 상태: 속도와 위치 
  // 모터 Q 고정소수점 형식으로 32비트에 저장
  logic signed [31:0] vx_q, vy_q; // 속도 
  logic signed [31:0] px_q, py_q; // 위치
  logic               init_done; // 초기 위치를 한 번 설정했는지 표시 

  function automatic signed [31:0] mm_to_q (input signed [15:0] mm);
    return $signed({mm,{FRAC{1'b0}}});
  endfunction

  // 위치를 경계 안으로 묶어주는 함수 
  function automatic signed [31:0] clamp_q(input signed [31:0] xq, input int half_mm);
    signed [31:0] lim = mm_to_q(half_mm[15:0]);
    if (xq >  lim)      return lim;  // 상한 넘으면 상한으로 
    else if (xq < -lim) return -lim; // 하한 넘으면 하한으로 
    else                return xq; // 범위 안이면 그대로 
  endfunction

  // 가속도 = 힘 x (질량의 역수)를 Q스케일로 계산하는 함수
  function automatic signed [31:0] accel_q(input signed [23:0] f_q, input logic [19:0] invm_q20);
    logic signed [44:0] mul; mul = $signed(f_q) * $signed({1'b0,invm_q20}); return mul >>> 20;
  endfunction

  
  function automatic logic in_goal(input signed [15:0] x_mm, input signed [15:0] y_mm, input int rad_mm);
    logic [31:0] r2, d2; r2 = rad_mm*rad_mm; d2 = $signed(x_mm)*$signed(x_mm) + $signed(y_mm)*$signed(y_mm); return (d2<=r2);
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin vx_q<='0; vy_q<='0; px_q<='0; py_q<='0; init_done<=1'b0; end
    else if(clk_en) begin
      if(!init_done) begin // 아직 초기위치를 정하지 않았다면
        px_q <= mm_to_q( ( $signed({1'b0,rnd_x[9:0]}) % HALF_MM ) - (HALF_MM/2) );
        // rnd_x[9:0]는 0~1023 난수 -> % HALF_MMfh 0 ~ % HALF_MM-1로 줄임 -> - (HALF_MM/2)를 통해 중심 기준 좌우 대칭 범위로 이동
        // 대칭 이동은 평균을 0으로 만들어 '한쪽으로 치우친 시작점' 편향을 없애는 방법
        // mm_to_q로 mm 정수를 Q 형식으로 변환해 저장 
        py_q <= mm_to_q( ( $signed({1'b0,rnd_y[9:0]}) % HALF_MM ) - (HALF_MM/2) );
        init_done <= 1'b1;
        // 이제부터는 초기화 끝. 다음 클럭부터 물리 업데이트로 들어감 
      end else begin
        logic [19:0] invm = inv_mass_q20(mass_g);
        // 질량 M에 대한 1/m 값을 LUT에서 꺼냄
        // 나눗셈 대신 곱셈을 쓰기 위해 미리 준비한 값 
        signed [31:0] ax_q = accel_q(force_x_q, invm);
        //x,y 힘에 방금 꺼낸 invm을 곱해서 a_x, a_y를 만듦
        signed [31:0] ay_q = accel_q(force_y_q, invm);
        vx_q <= (vx_q + ax_q) - (vx_q >>> FRIC_L);
        vy_q <= (vy_q + ay_q) - (vy_q >>> FRIC_L);
        // 가속도로 인해 속도가 늘어남. 
        // 마찰로 속도를 조금 깎음, 산술 시프트를 통해 깎기, 5라면 v/32만큼 깎음
        px_q <= clamp_q(px_q + vx_q, HALF_MM);
        py_q <= clamp_q(py_q + vy_q, HALF_MM);
        // pos <- pos + v: 속도만큼 위치를 옮김 
        // 경계 (+-HALF_MM) 밖으로 나가면 벽에서 멈춘 것처럼 잘라서 안에 두기 
        // 위치 반영은 1클럭 늦게 따라옴. (작은 파이프라인 지연)
      end
    end
  end

  // 내부 Q 위치를 mm 정수로 변환해서 외부로 출력 
  // >>> FRAC: 산술 시프트로 소수부를 걷어냄 (부호 유지)
  assign pos_mm_x_o = px_q >>> FRAC;
  assign pos_mm_y_o = py_q >>> FRAC;

  always_ff @(posedge clk or negedge rst_n) begin // 목표 영역 도달 플래그 업데이트
    if(!rst_n) goal_reached_o <= 1'b0;
    else if(clk_en) goal_reached_o <= in_goal(pos_mm_x_o, pos_mm_y_o, GOAL_RAD_MM); // 원 안이면 1 
  end
endmodule
