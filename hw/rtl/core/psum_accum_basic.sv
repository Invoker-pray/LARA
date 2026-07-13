module psum_accum_basic
  import attn_pkg::*;
(
    input  logic                 clk, rst_n, clear,
    input  logic                 en,
    input  logic [FP32_W-1:0]    tile_col [TILE_COLS],
    output logic [FP32_W-1:0]    psum [TILE_COLS]
);
  integer ii;

`ifndef SYNTHESIS
  /* verilator lint_off SHORTREAL */
  /* verilator lint_off WIDTHEXPAND */
  /* verilator lint_off WIDTHTRUNC */
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (ii = 0; ii < TILE_COLS; ii++) psum[ii] <= 32'd0;
    end else if (clear) begin
      for (ii = 0; ii < TILE_COLS; ii++) psum[ii] <= 32'd0;
    end else if (en) begin
      for (ii = 0; ii < TILE_COLS; ii++)
        psum[ii] <= $shortrealtobits($bitstoshortreal(psum[ii]) + $bitstoshortreal(tile_col[ii]));
    end
  end
  /* verilator lint_on WIDTHTRUNC */
  /* verilator lint_on WIDTHEXPAND */
  /* verilator lint_on SHORTREAL */
`else
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (ii = 0; ii < TILE_COLS; ii++) psum[ii] <= 32'd0;
    end else if (clear) begin
      for (ii = 0; ii < TILE_COLS; ii++) psum[ii] <= 32'd0;
    end else if (en) begin
      for (ii = 0; ii < TILE_COLS; ii++)
        psum[ii] <= fp32_add(psum[ii], tile_col[ii]);
    end
  end
`endif

endmodule
