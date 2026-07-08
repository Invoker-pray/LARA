// ============================================================================
// attn_tile.sv — 16×16 bf16 MAC Array (Pipelined v2.0)
// ============================================================================
// Pipeline (MAC_PIPE_STAGES=2):
//   Stage 1: bf16→fp32 expand + multiply (256 parallel, DSP48E2)
//   Stage 2: Column reduction (16-to-1 adder tree) → registered output
// Timing: ~5ns per stage → ≥200 MHz with MAC_PIPE_STAGES=2
// ============================================================================

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

  // ==================================================================
  // Stage 1: Multiply (combinational)
  // ==================================================================
  shortreal prod [TILE_ROWS][TILE_COLS];
  integer ri, ci;

  always_comb begin
    for (ri = 0; ri < TILE_ROWS; ri++) begin
      for (ci = 0; ci < TILE_COLS; ci++) begin
        shortreal a, b;
        a = $bitstoshortreal({row_data[ri], 16'b0});
        // SPLIT=2: each split_phase activates half the columns
        if (split_phase == 2'd0 && ci < 8)
          b = $bitstoshortreal({col_data[ci], 16'b0});
        else if (split_phase == 2'd1 && ci >= 8)
          b = $bitstoshortreal({col_data[ci], 16'b0});
        else
          b = 0.0;
        prod[ri][ci] = a * b;
      end
    end
  end

  // ==================================================================
  // Pipeline Registers (Stage 1 → Stage 2)
  // ==================================================================
  shortreal prod_r [TILE_ROWS][TILE_COLS];
  logic    accum_en_r;

  generate
    if (MAC_PIPE_STAGES >= 2) begin : GEN_PIPE
      integer r, c;
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          for (r = 0; r < TILE_ROWS; r++)
            for (c = 0; c < TILE_COLS; c++)
              prod_r[r][c] <= 0.0;
          accum_en_r <= 1'b0;
        end else begin
          for (r = 0; r < TILE_ROWS; r++)
            for (c = 0; c < TILE_COLS; c++)
              prod_r[r][c] <= prod[r][c];
          accum_en_r <= accum_en;
        end
      end
    end else begin : GEN_COMB
      integer r, c;
      always_comb begin
        for (r = 0; r < TILE_ROWS; r++)
          for (c = 0; c < TILE_COLS; c++)
            prod_r[r][c] = prod[r][c];
        accum_en_r = accum_en;
      end
    end
  endgenerate

  // ==================================================================
  // Stage 2: Column Reduction (adder tree → registered output)
  // ==================================================================
  integer rr, cc;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (cc = 0; cc < TILE_COLS; cc++)
        col_out[cc] <= 32'd0;
    end else begin
      for (cc = 0; cc < TILE_COLS; cc++) begin
        if (accum_en_r) begin
          shortreal sum;
          sum = 0.0;
          for (rr = 0; rr < TILE_ROWS; rr++)
            sum = sum + prod_r[rr][cc];
          col_out[cc] <= $shortrealtobits(sum);
        end else begin
          col_out[cc] <= 32'd0;
        end
      end
    end
  end

endmodule
