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
    if (!rst_n) begin
      for (ii = 0; ii < TILE_COLS; ii++) psum[ii] <= 32'd0;
    end else if (clear) begin
      for (ii = 0; ii < TILE_COLS; ii++) psum[ii] <= 32'd0;
    end else if (en_lo && en_hi) begin
      for (ii = 0; ii < TILE_COLS; ii++) begin
        psum[ii] <= $shortrealtobits($bitstoshortreal(psum[ii]) + $bitstoshortreal(col_lo[ii]) + $bitstoshortreal(col_hi[ii]));
      end
    end else if (en_lo) begin
      for (ii = 0; ii < TILE_COLS; ii++)
        psum[ii] <= $shortrealtobits($bitstoshortreal(psum[ii]) + $bitstoshortreal(col_lo[ii]));
    end else if (en_hi) begin
      for (ii = 0; ii < TILE_COLS; ii++)
        psum[ii] <= $shortrealtobits($bitstoshortreal(psum[ii]) + $bitstoshortreal(col_hi[ii]));
    end else if (en) begin
      for (ii = 0; ii < TILE_COLS; ii++)
        psum[ii] <= $shortrealtobits($bitstoshortreal(psum[ii]) + $bitstoshortreal(tile_col[ii]));
    end
  end
endmodule
