module psum_accum
  import attn_pkg::*;
  #(parameter bit ENABLE_LEGACY_PATHS = 1'b1)
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
  logic unused_quad_inputs;

  assign unused_quad_inputs = &(1'b0 + {
      en_q0, en_q1, en_q2, en_q3,
      ^col_q0[0], ^col_q1[0], ^col_q2[0], ^col_q3[0]
    });
generate
if (ENABLE_LEGACY_PATHS) begin : g_full
`ifndef SYNTHESIS
  /* verilator lint_off SHORTREAL */
  /* verilator lint_off WIDTHEXPAND */
  /* verilator lint_off WIDTHTRUNC */
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
  /* verilator lint_on WIDTHTRUNC */
  /* verilator lint_on WIDTHEXPAND */
  /* verilator lint_on SHORTREAL */

`else
  // Synthesis: fp32 accumulator using shared bit-level helpers.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (ii = 0; ii < TILE_COLS; ii++) psum[ii] <= 32'd0;
    end else if (clear) begin
      for (ii = 0; ii < TILE_COLS; ii++) psum[ii] <= 32'd0;
    end else if (en_lo && en_hi) begin
      for (ii = 0; ii < TILE_COLS; ii++) begin
        psum[ii] <= fp32_add(fp32_add(psum[ii], col_lo[ii]), col_hi[ii]);
      end
    end else if (en_lo) begin
      for (ii = 0; ii < TILE_COLS; ii++)
        psum[ii] <= fp32_add(psum[ii], col_lo[ii]);
    end else if (en_hi) begin
      for (ii = 0; ii < TILE_COLS; ii++)
        psum[ii] <= fp32_add(psum[ii], col_hi[ii]);
    end else if (en_q0 || en_q1 || en_q2 || en_q3) begin
      for (ii = 0; ii < TILE_COLS; ii++) begin
        logic [31:0] acc_next;
        acc_next = psum[ii];
        if (en_q0) acc_next = fp32_add(acc_next, col_q0[ii]);
        if (en_q1) acc_next = fp32_add(acc_next, col_q1[ii]);
        if (en_q2) acc_next = fp32_add(acc_next, col_q2[ii]);
        if (en_q3) acc_next = fp32_add(acc_next, col_q3[ii]);
        psum[ii] <= acc_next;
      end
    end else if (en) begin
      for (ii = 0; ii < TILE_COLS; ii++)
        psum[ii] <= fp32_add(psum[ii], tile_col[ii]);
    end
  end
`endif
end else begin : g_basic
  logic unused_legacy_inputs;
  assign unused_legacy_inputs = &(1'b0 + {
      en_lo, en_hi, en_q0, en_q1, en_q2, en_q3,
      ^col_lo[0], ^col_hi[0], ^col_q0[0], ^col_q1[0], ^col_q2[0], ^col_q3[0]
    });
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
end
endgenerate

endmodule
