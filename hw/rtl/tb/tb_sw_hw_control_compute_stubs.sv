// Test-only stubs for sw_hw_control top-level control simulations.
// These avoid Icarus shortreal system-function limitations in compute blocks.

module attn_tile
  import attn_pkg::*;
(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    phase_sel,
    input  logic [BF16_W-1:0]       row_data [TILE_ROWS],
    input  logic [BF16_W-1:0]       col_data [TILE_COLS],
    input  logic [1:0]              split_phase,
    input  logic                    accum_en,
    output logic [FP32_W-1:0]       col_out [TILE_COLS]
);
  integer ii;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (ii = 0; ii < TILE_COLS; ii++) col_out[ii] <= 32'd0;
    end else begin
      for (ii = 0; ii < TILE_COLS; ii++) col_out[ii] <= {16'd0, col_data[ii]};
    end
  end
endmodule

module softmax_engine
  import attn_pkg::*;
(
    input  logic                           clk,
    input  logic                           rst_n,
    input  logic                           s_valid,
    input  logic [FP32_W-1:0]              s_data [TILE_ROWS][TILE_COLS],
    input  logic                           kv_tile_first,
    input  logic                           kv_tile_last,
    input  logic                           causal_mask_en,
    input  logic [15:0]                    q_tile_start,
    input  logic [15:0]                    kv_tile_start,
    output logic [FP32_W-1:0]              m_state [TILE_ROWS],
    output logic [FP32_W-1:0]              l_state [TILE_ROWS],
    output logic                           p_valid,
    output logic [FP32_W-1:0]              p_data [TILE_ROWS][TILE_COLS],
    output logic [FP32_W-1:0]              correction [TILE_ROWS],
    output logic                           done
);
  integer rr, cc;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_valid <= 1'b0;
      done <= 1'b0;
      for (rr = 0; rr < TILE_ROWS; rr++) begin
        m_state[rr] <= 32'd0;
        l_state[rr] <= 32'h3f800000;
        correction[rr] <= 32'h3f800000;
        for (cc = 0; cc < TILE_COLS; cc++) p_data[rr][cc] <= 32'd0;
      end
    end else begin
      p_valid <= s_valid;
      done <= s_valid && kv_tile_last;
    end
  end
endmodule

module psum_accum
  import attn_pkg::*;
(
    input  logic                 clk, rst_n, clear,
    input  logic                 en,
    input  logic [FP32_W-1:0]    tile_col [TILE_COLS],
    input  logic                 en_lo, en_hi,
    input  logic [FP32_W-1:0]    col_lo [TILE_COLS],
    input  logic [FP32_W-1:0]    col_hi [TILE_COLS],
    input  logic                 en_q0, en_q1, en_q2, en_q3,
    input  logic [FP32_W-1:0]    col_q0 [TILE_COLS],
    input  logic [FP32_W-1:0]    col_q1 [TILE_COLS],
    input  logic [FP32_W-1:0]    col_q2 [TILE_COLS],
    input  logic [FP32_W-1:0]    col_q3 [TILE_COLS],
    output logic [FP32_W-1:0]    psum [TILE_COLS]
);
  integer ii;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || clear) begin
      for (ii = 0; ii < TILE_COLS; ii++) psum[ii] <= 32'd0;
    end else if (en) begin
      for (ii = 0; ii < TILE_COLS; ii++) psum[ii] <= tile_col[ii];
    end
  end
endmodule

module output_buffer
  import attn_pkg::*;
(
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       acc_update,
    input  logic [4:0]                 acc_row,
    input  logic [FP32_W-1:0]          acc_data [HEAD_DIM],
    input  logic [FP32_W-1:0]          correction [TILE_ROWS],
    input  logic                       normalize,
    input  logic [FP32_W-1:0]          l_state [TILE_ROWS],
    output logic                       o_valid,
    output logic [4:0]                 o_row,
    output logic [6:0]                 o_dim,
    output logic [BF16_W-1:0]          o_data
);
  logic active;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active <= 1'b0;
      o_valid <= 1'b0;
      o_row <= 5'd0;
      o_dim <= 7'd0;
      o_data <= 16'd0;
    end else begin
      if (normalize) begin
        active <= 1'b1;
        o_row <= 5'd0;
        o_dim <= 7'd0;
      end
      if (active) begin
        o_valid <= 1'b1;
        o_data <= {8'hA5, o_dim};
        if (o_dim == 7'd3) begin
          active <= 1'b0;
          o_dim <= 7'd0;
        end else begin
          o_dim <= o_dim + 7'd1;
        end
      end else begin
        o_valid <= 1'b0;
      end
    end
  end
endmodule