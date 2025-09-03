// =============================================================
// weight_ram_adjlist.sv  (SV, Genus-friendly)
// =============================================================
`timescale 1ns/1ps
module weight_ram_adjlist #(
    parameter int N = 64,
    parameter int MAX_FANOUT = 16
)(
    input  logic clk, reset,

    // ---- 스트림 읽기 (행 단위) ----
    input  logic                  rd_start,
    input  logic [$clog2(N)-1:0]  rd_pre,
    output logic                  rd_valid,
    output logic [$clog2(N)-1:0]  rd_post,
    output logic  signed [3:0]    rd_weight,
    input  logic                  rd_next,
    output logic                  rd_last,

    // ---- 임의 읽기 ----
    input  logic                  rr_en,
    input  logic [$clog2(N)-1:0]  rr_pre, rr_post,
    output logic                  rr_valid,
    output logic  signed [3:0]    rr_weight,
    output logic                  rr_hit,

    // ---- 임의 쓰기 ----
    input  logic                  w_en,
    input  logic [$clog2(N)-1:0]  w_pre, w_post,
    input  logic  signed [3:0]    w_data,

    // ---- 구성 로더 ----
    input  logic                  cfg_en,
    input  logic [$clog2(N)-1:0]  cfg_pre,
    input  logic [$clog2(MAX_FANOUT)-1:0] cfg_slot,
    input  logic [$clog2(N)-1:0]  cfg_dst,
    input  logic  signed [3:0]    cfg_val,
    input  logic                  cfg_deg_wen,
    input  logic [$clog2(MAX_FANOUT):0] cfg_degree,
    input  logic                  cfg_clr_row
);
    localparam int DW    = $clog2(N);
    localparam int SLOTW = $clog2(MAX_FANOUT);

    logic [DW-1:0]        dst   [N-1:0][MAX_FANOUT-1:0];
    logic signed [3:0]    val   [N-1:0][MAX_FANOUT-1:0];
    logic [SLOTW:0]       degree[N-1:0];

    integer i,j;

    // 초기화/쓰기/구성
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i=0;i<N;i++) begin
                degree[i] <= '0;
                for (j=0;j<MAX_FANOUT;j++) begin
                    dst[i][j] <= '0;
                    val[i][j] <= 4'sd0;
                end
            end
        end else begin
            if (cfg_en) begin
                dst[cfg_pre][cfg_slot] <= cfg_dst;
                val[cfg_pre][cfg_slot] <= cfg_val;
            end
            if (cfg_deg_wen) begin
                degree[cfg_pre] <= cfg_degree;
            end
            if (cfg_clr_row) begin
                for (j=0;j<MAX_FANOUT;j++) begin
                    dst[cfg_pre][j] <= '0;
                    val[cfg_pre][j] <= 4'sd0;
                end
                degree[cfg_pre] <= '0;
            end
            if (w_en) begin
                for (j=0;j<MAX_FANOUT;j++) begin
                    if (dst[w_pre][j]==w_post) begin
                        val[w_pre][j] <= w_data;
                    end
                end
            end
        end
    end

    // ---- 스트림 읽기 FSM ----
    typedef enum logic [1:0] {S_IDLE, S_OUT} sst_t;
    sst_t sst;
    logic [SLOTW-1:0]      k;
    logic [DW-1:0]         cur_pre;

    logic                  rd_valid_q;
    logic [DW-1:0]         rd_post_q;
    logic signed [3:0]     rd_weight_q;

    assign rd_valid  = rd_valid_q;
    assign rd_post   = rd_post_q;
    assign rd_weight = rd_weight_q;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            sst       <= S_IDLE;
            rd_valid_q<= 1'b0;
            rd_last   <= 1'b0;
            rd_post_q <= '0;
            rd_weight_q <= 4'sd0;
            k         <= '0;
            cur_pre   <= '0;
        end else begin
            rd_last <= 1'b0;

            case (sst)
                S_IDLE: begin
                    rd_valid_q <= 1'b0;
                    if (rd_start) begin
                        cur_pre <= rd_pre;
                        k       <= '0;
                        sst     <= S_OUT;
                    end
                end

                S_OUT: begin
                    if (k >= degree[cur_pre]) begin
                        if (!rd_valid_q || (rd_valid_q && rd_next)) begin
                            rd_valid_q <= 1'b0;
                            rd_last    <= 1'b1;
                            sst        <= S_IDLE;
                        end
                    end else begin
                        if (val[cur_pre][k] == 0) begin
                            if (k != MAX_FANOUT-1) k <= k + 1'b1; else k <= k;
                        end else begin
                            if (!rd_valid_q) begin
                                rd_post_q   <= dst[cur_pre][k];
                                rd_weight_q <= val[cur_pre][k];
                                rd_valid_q  <= 1'b1;
                            end else if (rd_next) begin
                                rd_valid_q  <= 1'b0;
                                if (k != MAX_FANOUT-1) k <= k + 1'b1;
                            end
                        end
                    end
                end
            endcase
        end
    end

    // ---- 임의 읽기: 1사이클 레이턴시 ----
    integer t;
    logic signed [3:0] rr_w_mux;
    logic              rr_hit_c;

    always_comb begin
        rr_w_mux = 4'sd0;
        rr_hit_c = 1'b0;
        if (rr_en) begin
            for (t=0; t<MAX_FANOUT; t=t+1) begin
                if (dst[rr_pre][t] == rr_post) begin
                    rr_w_mux = val[rr_pre][t];
                    rr_hit_c = 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            rr_valid <= 1'b0;
            rr_weight<= 4'sd0;
            rr_hit   <= 1'b0;
        end else begin
            rr_valid <= rr_en;
            rr_weight<= rr_en ? rr_w_mux : 4'sd0;
            rr_hit   <= rr_en ? rr_hit_c : 1'b0;
        end
    end
endmodule
