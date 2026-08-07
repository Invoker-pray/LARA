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
    input  logic [TILE_SPLIT_INDEX_W-1:0] split_phase,
    input  logic                    clear_accum,
    input  logic                    accum_en,
    output logic [FP32_W-1:0]       block_out [TILE_ROWS][TILE_COLS],
    output logic [FP32_W-1:0]       block_out_capture [TILE_ROWS][TILE_COLS],
    output logic [FP32_W-1:0]       block_out_registered [TILE_ROWS][TILE_COLS],
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
        if ((TILE_SPLIT_FACTOR <= 1) ||
            ((ci >= (split_phase * ACTIVE_COLS_PER_SPLIT)) &&
             (ci < ((split_phase + 1) * ACTIVE_COLS_PER_SPLIT))))
          b = $bitstoshortreal({col_data[ci], 16'b0});
        else
          b = shortreal'(0.0);
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
        for (cc = 0; cc < TILE_COLS; cc++) begin
          block_acc[rr][cc] <= shortreal'(0.0);
          block_out_capture[rr][cc] <= 32'd0;
          block_out_registered[rr][cc] <= 32'd0;
        end
    end else begin
      for (rr = 0; rr < TILE_ROWS; rr++)
        for (cc = 0; cc < TILE_COLS; cc++) begin
          block_acc[rr][cc] <= block_next[rr][cc];
          block_out_capture[rr][cc] <= $shortrealtobits(block_acc[rr][cc]);
          block_out_registered[rr][cc] <= $shortrealtobits(block_acc[rr][cc]);
        end
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
  logic [31:0] acc_base_r [TILE_ROWS][PHASE_COLS];
  logic [31:0] block_acc_bits [TILE_ROWS][TILE_COLS];
  logic [31:0] active_sum_bits [TILE_ROWS][PHASE_COLS];
  logic [31:0] col_reduce [PHASE_COLS];
  // Keep a local copy of the phase/control bits for each MAC row.  The
  // original single registers drove every reduction and accumulator bit,
  // creating a very high-fanout route from the MAC control plane to the
  // output buffer.  These copies update on the same edge, so the module's
  // visible latency and arithmetic contract are unchanged.
  (* keep = "true" *) logic [TILE_SPLIT_INDEX_W-1:0] split_phase_row_r [TILE_ROWS];
  (* keep = "true" *) logic       clear_accum_row_r [TILE_ROWS];
  (* keep = "true" *) logic       accum_en_row_r    [TILE_ROWS];

  generate
    for (sr = 0; sr < TILE_ROWS; sr++) begin : SYN_ROW
      for (sc = 0; sc < PHASE_COLS; sc++) begin : SYN_PE
        if (TILE_SPLIT_FACTOR <= 1) begin : GEN_MONO
          assign pe_prod[sr][sc] = bf16_mul_to_fp32(row_data[sr], col_data[sc]);
        end else begin : GEN_SPLIT
          wire [COL_IDX_W-1:0] col_idx =
              COL_IDX_W'((split_phase * PHASE_COLS) + sc);
          assign pe_prod[sr][sc] = bf16_mul_to_fp32(row_data[sr], col_data[col_idx]);
        end
      end
    end
  endgenerate

  always_comb begin
    int rr, cc, pc, phase_base;
    logic [31:0] acc_sum;

    if (TILE_SPLIT_FACTOR <= 1)
      phase_base = 0;
    else
      phase_base = split_phase_row_r[0] * PHASE_COLS;

    // One physical adder per active PE.  The selected accumulator slice is
    // registered in the prior stage so the fp32_add feedback path no longer
    // includes the split-select mux and wide block_acc_bits fanout.
    for (rr = 0; rr < TILE_ROWS; rr++) begin
      for (pc = 0; pc < PHASE_COLS; pc++) begin
        active_sum_bits[rr][pc] = accum_en_row_r[rr]
                                ? fp32_add(acc_base_r[rr][pc], pe_prod_r[rr][pc])
                                : acc_base_r[rr][pc];
      end
    end

    for (cc = 0; cc < PHASE_COLS; cc++) begin
      acc_sum = accum_en_row_r[0] ? pe_prod_r[0][cc] : 32'd0;
      for (rr = 1; rr < TILE_ROWS; rr++) begin
        acc_sum = fp32_add(acc_sum,
                           accum_en_row_r[rr] ? pe_prod_r[rr][cc] : 32'd0);
      end
      col_reduce[cc] = acc_sum;
    end

    for (cc = 0; cc < TILE_COLS; cc++) begin
      col_out[cc] = 32'd0;
      if ((cc >= phase_base) && (cc < (phase_base + PHASE_COLS)))
        col_out[cc] = col_reduce[cc - phase_base];
    end

    for (rr = 0; rr < TILE_ROWS; rr++) begin
      for (cc = 0; cc < TILE_COLS; cc++) begin
        // Expose the current transaction without adding an externally visible
        // cycle: pe_prod_r/control_r are the registered input stage, while
        // block_acc_bits holds the completed previous transaction.
        if (TILE_SPLIT_FACTOR <= 1) begin
          if (cc < PHASE_COLS)
            block_out[rr][cc] = active_sum_bits[rr][cc];
          else if (clear_accum_row_r[rr])
            block_out[rr][cc] = 32'd0;
          else
            block_out[rr][cc] = block_acc_bits[rr][cc];
        end else if ((cc >= (split_phase_row_r[rr] * PHASE_COLS)) &&
                     (cc < ((split_phase_row_r[rr] * PHASE_COLS) + PHASE_COLS))) begin
          block_out[rr][cc] = active_sum_bits[rr][cc -
                              (split_phase_row_r[rr] * PHASE_COLS)];
        end else if (clear_accum_row_r[rr]) begin
          block_out[rr][cc] = 32'd0;
        end else begin
          block_out[rr][cc] = block_acc_bits[rr][cc];
        end
      end
    end
  end

  integer pr, pc;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (pr = 0; pr < TILE_ROWS; pr = pr + 1) begin
        split_phase_row_r[pr] <= '0;
        clear_accum_row_r[pr] <= 1'b0;
        accum_en_row_r[pr]    <= 1'b0;
      end
      for (pr = 0; pr < TILE_ROWS; pr = pr + 1)
        for (pc = 0; pc < PHASE_COLS; pc = pc + 1) begin
          pe_prod_r[pr][pc] <= 32'd0;
          acc_base_r[pr][pc] <= 32'd0;
        end
    end else begin
      for (pr = 0; pr < TILE_ROWS; pr = pr + 1) begin
        split_phase_row_r[pr] <= split_phase;
        clear_accum_row_r[pr] <= clear_accum;
        accum_en_row_r[pr]    <= accum_en;
      end
      for (pr = 0; pr < TILE_ROWS; pr = pr + 1)
        for (pc = 0; pc < PHASE_COLS; pc = pc + 1) begin
          pe_prod_r[pr][pc] <= pe_prod[pr][pc];
          // The global block_acc_bits clear commits on the following edge.
          // Hold acc_base at zero for one extra cycle so split1 does not
          // sample the pre-clear accumulator image while split0 is clearing.
          if (clear_accum || clear_accum_row_r[pr]) begin
            acc_base_r[pr][pc] <= 32'd0;
          end else if (TILE_SPLIT_FACTOR <= 1) begin
            acc_base_r[pr][pc] <= block_acc_bits[pr][pc];
          end else begin
            acc_base_r[pr][pc] <= block_acc_bits[pr][pc +
                                  (split_phase * PHASE_COLS)];
          end
        end
    end
  end

  integer ar, ac;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (ar = 0; ar < TILE_ROWS; ar++)
        for (ac = 0; ac < TILE_COLS; ac++)
          block_acc_bits[ar][ac] <= 32'd0;
      for (ar = 0; ar < TILE_ROWS; ar++)
        for (ac = 0; ac < TILE_COLS; ac++)
          block_out_capture[ar][ac] <= 32'd0;
      for (ar = 0; ar < TILE_ROWS; ar++)
        for (ac = 0; ac < TILE_COLS; ac++)
          block_out_registered[ar][ac] <= 32'd0;
    end else begin
      if (clear_accum_row_r[0]) begin
        for (ar = 0; ar < TILE_ROWS; ar++)
          for (ac = 0; ac < TILE_COLS; ac++)
            block_acc_bits[ar][ac] <= 32'd0;
      end

      if (accum_en_row_r[0]) begin
        for (ar = 0; ar < TILE_ROWS; ar++) begin
          for (ac = 0; ac < PHASE_COLS; ac++) begin
            if (TILE_SPLIT_FACTOR <= 1) begin
              block_acc_bits[ar][ac] <= active_sum_bits[ar][ac];
            end else begin
              block_acc_bits[ar][ac +
                (split_phase_row_r[ar] * PHASE_COLS)] <= active_sum_bits[ar][ac];
            end
          end
        end
      end

      // PB_CAPTURE provides the cycle needed for the final split to commit
      // before Phase B consumes the completed block.
      for (ar = 0; ar < TILE_ROWS; ar++)
        for (ac = 0; ac < TILE_COLS; ac++)
          block_out_capture[ar][ac] <= block_out[ar][ac];
      for (ar = 0; ar < TILE_ROWS; ar++)
        for (ac = 0; ac < TILE_COLS; ac++)
          block_out_registered[ar][ac] <= block_acc_bits[ar][ac];
    end
  end
`endif // SYNTHESIS

endmodule
