// ============================================================================
// psum_accum.sv — Partial-Sum Accumulator (fp32 Column Accumulation)
// ============================================================================
// Accumulates attn_tile column outputs across the head_dim depth dimension
// and across SPLIT_FACTOR phases.
//
// CRITICAL (inherited from cim_pkg/psum_accum.sv):
//   - clear takes absolute priority over all enables
//   - All split quarters accumulated together in one clock edge
//     (pre-computed intermediate sums to prevent overwrite)
//
// For Attention:
//   Phase A: accumulates Q×K^T column partial sums over HEAD_DIM=128 depth.
//   Phase B: accumulates P×V column partial sums over TILE_KV*HEAD_DIM.
//
// Adapted from ~/git/xx/hw/rtl/core/psum_accum.sv:
//   - INT32 → fp32 (shortreal-based for simulation, FP IP for synthesis)
//   - TILE_ROWS output → TILE_COLS output (column-major accumulation)
//   - Same SPLIT_FACTOR generate structure
//   - Same clear-priority logic
// ============================================================================

module psum_accum
  import attn_pkg::*;
(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 clear,       // synchronous clear (highest priority)

    // Full accumulation enable (SPLIT_FACTOR=1)
    input  logic                 en,
    input  logic [FP32_W-1:0]    tile_col [TILE_COLS],

    // SPLIT=2: lo/hi halves
    input  logic                 en_lo,
    input  logic                 en_hi,
    input  logic [FP32_W-1:0]    col_lo [TILE_COLS],
    input  logic [FP32_W-1:0]    col_hi [TILE_COLS],

    // SPLIT=4: 4 quarters
    input  logic                 en_q0,
    input  logic                 en_q1,
    input  logic                 en_q2,
    input  logic                 en_q3,
    input  logic [FP32_W-1:0]    col_q0 [TILE_COLS],
    input  logic [FP32_W-1:0]    col_q1 [TILE_COLS],
    input  logic [FP32_W-1:0]    col_q2 [TILE_COLS],
    input  logic [FP32_W-1:0]    col_q3 [TILE_COLS],

    // Accumulated output
    output logic [FP32_W-1:0]    psum [TILE_COLS]
);

  // ==================================================================
  // Pre-computed intermediate sums (inherited from cim_psum_accum.sv)
  // ==================================================================
  // This prevents later enables from overwriting earlier contributions
  // when multiple quarters are committed in the same clock edge.

  shortreal psum_real     [TILE_COLS];
  shortreal col_q0_real   [TILE_COLS];
  shortreal col_q1_real   [TILE_COLS];
  shortreal col_q2_real   [TILE_COLS];
  shortreal col_q3_real   [TILE_COLS];
  shortreal col_lo_real   [TILE_COLS];
  shortreal col_hi_real   [TILE_COLS];
  shortreal tile_col_real [TILE_COLS];

  // Pre-compute all intermediate sums
  shortreal sum_q0   [TILE_COLS];
  shortreal sum_q01  [TILE_COLS];
  shortreal sum_q012 [TILE_COLS];
  shortreal sum_all  [TILE_COLS];
  shortreal sum_lo   [TILE_COLS];
  shortreal sum_both [TILE_COLS];

  genvar gi;
  generate
    for (gi = 0; gi < TILE_COLS; gi++) begin : GEN_PSUM_REAL
      assign psum_real[gi]     = $bitstoshortreal(psum[gi]);
      assign col_q0_real[gi]   = $bitstoshortreal(col_q0[gi]);
      assign col_q1_real[gi]   = $bitstoshortreal(col_q1[gi]);
      assign col_q2_real[gi]   = $bitstoshortreal(col_q2[gi]);
      assign col_q3_real[gi]   = $bitstoshortreal(col_q3[gi]);
      assign col_lo_real[gi]   = $bitstoshortreal(col_lo[gi]);
      assign col_hi_real[gi]   = $bitstoshortreal(col_hi[gi]);
      assign tile_col_real[gi] = $bitstoshortreal(tile_col[gi]);

      assign sum_q0[gi]   = psum_real[gi] + col_q0_real[gi];
      assign sum_q01[gi]  = psum_real[gi] + col_q0_real[gi] + col_q1_real[gi];
      assign sum_q012[gi] = psum_real[gi] + col_q0_real[gi] + col_q1_real[gi] + col_q2_real[gi];
      assign sum_all[gi]  = psum_real[gi] + col_q0_real[gi] + col_q1_real[gi]
                          + col_q2_real[gi] + col_q3_real[gi];
      assign sum_lo[gi]   = psum_real[gi] + col_lo_real[gi];
      assign sum_both[gi] = psum_real[gi] + col_lo_real[gi] + col_hi_real[gi];
    end
  endgenerate

  // ==================================================================
  // Accumulator Register (synchronous, clear-priority)
  // ==================================================================
  // Pattern: exactly the always_ff block from cim_psum_accum.sv,
  // adapted for TILE_COLS (column output) instead of TILE_ROWS.

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < TILE_COLS; i++)
        psum[i] <= 32'd0;
    end else if (clear) begin
      for (int i = 0; i < TILE_COLS; i++)
        psum[i] <= 32'd0;
    end else if (TILE_SPLIT_FACTOR == 4) begin
      // SPLIT=4: all 4 quarters committed together in one clock edge
      if (en_q0 && en_q1 && en_q2 && en_q3) begin
        for (int i = 0; i < TILE_COLS; i++)
          psum[i] <= $shortrealtobits(sum_all[i]);
      end else if (en_q0 && en_q1 && en_q2) begin
        for (int i = 0; i < TILE_COLS; i++)
          psum[i] <= $shortrealtobits(sum_q012[i]);
      end else if (en_q0 && en_q1) begin
        for (int i = 0; i < TILE_COLS; i++)
          psum[i] <= $shortrealtobits(sum_q01[i]);
      end else if (en_q0) begin
        for (int i = 0; i < TILE_COLS; i++)
          psum[i] <= $shortrealtobits(sum_q0[i]);
      end
    end else if (TILE_SPLIT_FACTOR == 2) begin
      // SPLIT=2: lo+hi halves committed together
      if (en_lo && en_hi) begin
        for (int i = 0; i < TILE_COLS; i++)
          psum[i] <= $shortrealtobits(sum_both[i]);
      end else if (en_lo) begin
        for (int i = 0; i < TILE_COLS; i++)
          psum[i] <= $shortrealtobits(sum_lo[i]);
      end else if (en_hi) begin
        for (int i = 0; i < TILE_COLS; i++)
          psum[i] <= $shortrealtobits(psum_real[i] + col_hi_real[i]);
      end
    end else begin
      // SPLIT=1: accumulate full column values
      if (en) begin
        for (int i = 0; i < TILE_COLS; i++)
          psum[i] <= $shortrealtobits(psum_real[i] + tile_col_real[i]);
      end
    end
  end

endmodule
