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
    input  logic                    clear_accum,
    input  logic                    accum_en,
    output logic [FP32_W-1:0]       block_out [TILE_ROWS][TILE_COLS],
    output logic [FP32_W-1:0]       col_out [TILE_COLS]
);

  localparam int ACTIVE_COLS_PER_SPLIT = TILE_COLS / TILE_SPLIT_FACTOR;
  localparam int PHASE_COLS = (TILE_SPLIT_FACTOR <= 1) ? TILE_COLS :
                              (TILE_COLS / TILE_SPLIT_FACTOR);
  localparam int COL_IDX_W = clog2_safe(TILE_COLS);
  (* keep = "true" *) logic unused_phase_sel;

  assign unused_phase_sel = &{1'b0, phase_sel};

  // ==================================================================
  // Stage 1: Multiply (combinational)
  // ==================================================================
`ifndef SYNTHESIS
  /* verilator lint_off SHORTREAL */
  /* verilator lint_off WIDTHEXPAND */
  /* verilator lint_off WIDTHTRUNC */
  shortreal prod [TILE_ROWS][TILE_COLS];
  shortreal block_acc [TILE_ROWS][TILE_COLS];
  shortreal block_next [TILE_ROWS][TILE_COLS];

  always_comb begin
    int ri, ci;
    for (ri = 0; ri < TILE_ROWS; ri++) begin
      for (ci = 0; ci < TILE_COLS; ci++) begin
        shortreal a, b;
        a = $bitstoshortreal({row_data[ri], 16'b0});
        if (split_phase == 2'd0)
          b = (ci < ACTIVE_COLS_PER_SPLIT) ? $bitstoshortreal({col_data[ci], 16'b0}) : shortreal'(0.0);
        else if (split_phase == 2'd1)
          b = (ci >= ACTIVE_COLS_PER_SPLIT) ? $bitstoshortreal({col_data[ci], 16'b0}) : shortreal'(0.0);
        else
          b = $bitstoshortreal({col_data[ci], 16'b0});
        prod[ri][ci] = a * b;
      end
    end
  end

  // ==================================================================
  // Pipeline Registers (Stage 1 → Stage 2)
  // ==================================================================
  shortreal prod_r [TILE_ROWS][TILE_COLS];
  logic    accum_en_r, clear_accum_r;

  generate
    if (MAC_PIPE_STAGES >= 2) begin : GEN_PIPE
      integer r, c;
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          for (r = 0; r < TILE_ROWS; r++)
            for (c = 0; c < TILE_COLS; c++)
              prod_r[r][c] <= shortreal'(0.0);
          accum_en_r <= 1'b0;
          clear_accum_r <= 1'b0;
        end else begin
          for (r = 0; r < TILE_ROWS; r++)
            for (c = 0; c < TILE_COLS; c++)
              prod_r[r][c] <= prod[r][c];
          accum_en_r <= accum_en;
          clear_accum_r <= clear_accum;
        end
      end
    end else begin : GEN_COMB
      integer r, c;
      always_comb begin
        for (r = 0; r < TILE_ROWS; r++)
          for (c = 0; c < TILE_COLS; c++)
            prod_r[r][c] = prod[r][c];
        accum_en_r = accum_en;
        clear_accum_r = clear_accum;
      end
    end
  endgenerate

  always_comb begin
    int ri, ci;
    for (ri = 0; ri < TILE_ROWS; ri++) begin
      for (ci = 0; ci < TILE_COLS; ci++) begin
        block_next[ri][ci] = clear_accum_r ? shortreal'(0.0) : block_acc[ri][ci];
        if (accum_en_r)
          block_next[ri][ci] = block_next[ri][ci] + prod_r[ri][ci];
      end
    end
  end

  // ==================================================================
  // Stage 2: Column Reduction (adder tree → registered output)
  // ==================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    int rr, cc;
    if (!rst_n) begin
      for (rr = 0; rr < TILE_ROWS; rr++)
        for (cc = 0; cc < TILE_COLS; cc++)
          block_acc[rr][cc] <= shortreal'(0.0);
    end else begin
      for (rr = 0; rr < TILE_ROWS; rr++)
        for (cc = 0; cc < TILE_COLS; cc++)
          block_acc[rr][cc] <= block_next[rr][cc];
    end
  end

  always_comb begin
    int rr, cc;
    for (rr = 0; rr < TILE_ROWS; rr++)
      for (cc = 0; cc < TILE_COLS; cc++)
        block_out[rr][cc] = $shortrealtobits(block_acc[rr][cc]);

    for (cc = 0; cc < TILE_COLS; cc++) begin
      if (accum_en_r) begin
        col_out[cc] = $shortrealtobits(
          ((prod_r[0][cc] + prod_r[1][cc]) + (prod_r[2][cc] + (prod_r[3][cc]))) +
          ((prod_r[4][cc] + prod_r[5][cc]) + (prod_r[6][cc] + (prod_r[7][cc]))) +
          ((prod_r[8][cc] + prod_r[9][cc]) + (prod_r[10][cc] + (prod_r[11][cc]))) +
          ((prod_r[12][cc] + prod_r[13][cc]) + (prod_r[14][cc] + (prod_r[15][cc])))
        );
      end else begin
        col_out[cc] = 32'd0;
      end
    end
  end

  /* verilator lint_on WIDTHTRUNC */
  /* verilator lint_on WIDTHEXPAND */
  /* verilator lint_on SHORTREAL */

`else
  // Synthesis: implement TILE_SPLIT_FACTOR as a physical column shrink.
  // For SPLIT_FACTOR=2 the tile only instantiates 8 columns of multipliers
  // and updates either cols [0:7] or cols [8:15] per cycle.
  genvar sr, sc;
  logic [31:0] pe_prod [TILE_ROWS][PHASE_COLS];
  logic [31:0] pe_prod_r [TILE_ROWS][PHASE_COLS];
  logic [31:0] block_acc_bits [TILE_ROWS][TILE_COLS];
  logic [31:0] active_sum_bits [TILE_ROWS][PHASE_COLS];
  logic [31:0] col_reduce [PHASE_COLS];
  logic [1:0]  split_phase_r;
  logic        clear_accum_r;
  logic        accum_en_r;

  generate
    for (sr = 0; sr < TILE_ROWS; sr++) begin : SYN_ROW
      for (sc = 0; sc < PHASE_COLS; sc++) begin : SYN_PE
        if (TILE_SPLIT_FACTOR <= 1) begin : GEN_MONO
          assign pe_prod[sr][sc] = bf16_mul_to_fp32(row_data[sr], col_data[sc]);
        end else begin : GEN_SPLIT
          wire [COL_IDX_W-1:0] col_idx = (split_phase == 2'd1)
                                           ? COL_IDX_W'(sc + PHASE_COLS)
                                           : COL_IDX_W'(sc);
          assign pe_prod[sr][sc] = bf16_mul_to_fp32(row_data[sr], col_data[col_idx]);
        end
      end
    end
  endgenerate

  always_comb begin
    int rr, cc, pc;
    int phase_offset;
    logic [31:0] acc_base;
    logic [31:0] acc_sum;

    phase_offset = 0;
    phase_offset = 0;
    if ((TILE_SPLIT_FACTOR > 1) && (split_phase_r == 2'd1))
      phase_offset = PHASE_COLS;

    // One physical adder per active PE. The split phase selects which half of
    // the 16-column accumulator state is read and written.
    for (rr = 0; rr < TILE_ROWS; rr++) begin
      for (pc = 0; pc < PHASE_COLS; pc++) begin
        acc_base = clear_accum_r ? 32'd0 : block_acc_bits[rr][pc + phase_offset];
        active_sum_bits[rr][pc] = accum_en_r
                                ? fp32_add(acc_base, pe_prod_r[rr][pc])
                                : acc_base;
      end
    end

    for (cc = 0; cc < PHASE_COLS; cc++) begin
      acc_sum = accum_en_r ? pe_prod_r[0][cc] : 32'd0;
      for (rr = 1; rr < TILE_ROWS; rr++) begin
        acc_sum = fp32_add(acc_sum, accum_en_r ? pe_prod_r[rr][cc] : 32'd0);
      end
      col_reduce[cc] = acc_sum;
    end

    for (cc = 0; cc < TILE_COLS; cc++) begin
      col_out[cc] = 32'd0;
      if (TILE_SPLIT_FACTOR <= 1) begin
        if (cc < PHASE_COLS)
          col_out[cc] = col_reduce[cc];
      end else if ((split_phase_r == 2'd0) && (cc < PHASE_COLS)) begin
        col_out[cc] = col_reduce[cc];
      end else if ((split_phase_r == 2'd1) && (cc >= PHASE_COLS) && (cc < (2 * PHASE_COLS))) begin
        col_out[cc] = col_reduce[cc - PHASE_COLS];
      end
    end

    for (rr = 0; rr < TILE_ROWS; rr++) begin
      for (cc = 0; cc < TILE_COLS; cc++) begin
        // Expose the current transaction without adding an externally visible
        // cycle: pe_prod_r/control_r are the registered input stage, while
        // block_acc_bits holds the completed previous transaction.
        if (cc < PHASE_COLS && TILE_SPLIT_FACTOR <= 1)
          block_out[rr][cc] = active_sum_bits[rr][cc];
        else if ((split_phase_r == 2'd0) && (cc < PHASE_COLS))
          block_out[rr][cc] = active_sum_bits[rr][cc];
        else if ((split_phase_r == 2'd1) && (cc >= PHASE_COLS) && (cc < 2 * PHASE_COLS))
          block_out[rr][cc] = active_sum_bits[rr][cc - PHASE_COLS];
        else if (clear_accum_r)
          block_out[rr][cc] = 32'd0;
        else
          block_out[rr][cc] = block_acc_bits[rr][cc];
      end
    end
  end

  integer pr, pc;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      split_phase_r <= 2'd0;
      clear_accum_r <= 1'b0;
      accum_en_r    <= 1'b0;
      for (pr = 0; pr < TILE_ROWS; pr = pr + 1)
        for (pc = 0; pc < PHASE_COLS; pc = pc + 1)
          pe_prod_r[pr][pc] <= 32'd0;
    end else begin
      split_phase_r <= split_phase;
      clear_accum_r <= clear_accum;
      accum_en_r    <= accum_en;
      for (pr = 0; pr < TILE_ROWS; pr = pr + 1)
        for (pc = 0; pc < PHASE_COLS; pc = pc + 1)
          pe_prod_r[pr][pc] <= pe_prod[pr][pc];
    end
  end

  integer ar, ac;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (ar = 0; ar < TILE_ROWS; ar++)
        for (ac = 0; ac < TILE_COLS; ac++)
          block_acc_bits[ar][ac] <= 32'd0;
    end else begin
      if (clear_accum_r) begin
        for (ar = 0; ar < TILE_ROWS; ar++)
          for (ac = 0; ac < TILE_COLS; ac++)
            block_acc_bits[ar][ac] <= 32'd0;
      end

      if (accum_en_r) begin
        for (ar = 0; ar < TILE_ROWS; ar++) begin
          for (ac = 0; ac < PHASE_COLS; ac++) begin
            if ((TILE_SPLIT_FACTOR <= 1) || (split_phase_r == 2'd0))
              block_acc_bits[ar][ac] <= active_sum_bits[ar][ac];
            else if (split_phase_r == 2'd1)
              block_acc_bits[ar][ac + PHASE_COLS] <= active_sum_bits[ar][ac];
          end
        end
      end
    end
  end
`endif // SYNTHESIS

endmodule
