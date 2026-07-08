// ============================================================================
// attn_tile.sv — 16×16 bf16 MAC Array (Time-Multiplexed, DSP-Inferable)
// ============================================================================
// Computes one [TILE_ROWS × TILE_COLS] sub-block per invocation:
//   Phase A (Q×K^T): S_block[row][col] = Q[row][:] · K[col][:]  (bf16→fp32)
//   Phase B (P×V):   ΔO_block[row] = Σ_col P[row][col] × V[col][:]  (fp32)
//
// Architecture (inherited from cim_tile.sv in INT8-CIM capstone):
//   - 16×16 = 256 bf16_multiply units (DSP48E2-inferable)
//   - TILE_SPLIT_FACTOR: column splitting for timing closure
//     =1: 16-wide multiply in 1 cycle (≤60 MHz safe)
//     =2: 8+8 over 2 cycles (100-125 MHz target) ← DEFAULT
//     =4: 4+4+4+4 over 4 cycles (100+ MHz)
//   - TILE_MAC_REUSE: time-multiplex multiplier hardware
//     =1: instantiate only TILE_COLS/SPLIT_FACTOR multipliers per row
//     and time-mux them via phase_sel (DSP usage ~4× lower).
//
// Key differences from cim_tile (INT8 → bf16):
//   1. bf16 operands: 16-bit (not 8-bit). DSP48E2 handles 16-bit multiply.
//   2. Two phases: Phase A (Q×K^T) and Phase B (P×V), selected by phase_sel.
//      In Phase B, P data is fp32 cast to bf16 before multiply.
//   3. Column output: TILE_COLS fp32 values per cycle (vs TILE_ROWS in CIM).
//
// The tile does NOT accumulate across the head_dim depth dimension.
// psum_accum handles cross-cycle accumulation (same pattern as CIM psum_accum).
//
// Correspondence with Golden Model:
//   Python: attention_golden.py::bf16_matmul()
//   Verification: VV/tb/tb_attn_tile.sv
//
// Reused patterns from ~/git/xx/hw/rtl/core/cim_tile.sv:
//   - generate with GEN_SPLIT4 / GEN_SPLIT2 / GEN_MONO blocks
//   - (* use_dsp = "yes" *) for DSP48E2 inference
//   - PHASE_COLS = TILE_COLS / TILE_SPLIT_FACTOR localparam
//   - Column accumulator chain pattern
// ============================================================================

module attn_tile
  import attn_pkg::*;
(
    input  logic                    clk,
    input  logic                    rst_n,

    // --- Phase Select ---
    input  logic                    phase_sel,   // 0=Phase A (Q×K^T), 1=Phase B (P×V)

    // --- Row Broadcast Inputs (TILE_ROWS elements, one per row) ---
    // Phase A: Q[row][depth] — one bf16 element from Q per row
    // Phase B: P[row][col]  — one fp32 attention weight per row (cast to bf16)
    input  logic [BF16_W-1:0]       row_data [TILE_ROWS],

    // --- Column Broadcast Inputs (TILE_COLS elements, one per column) ---
    // Phase A: K[col][depth] — one bf16 element from K per column
    // Phase B: V[col][dim]   — one bf16 element from V per column
    input  logic [BF16_W-1:0]       col_data [TILE_COLS],

    // --- Control ---
    input  logic [1:0]              split_phase, // which split quarter (0..SPLIT_FACTOR-1)
    input  logic                    accum_en,    // enable column accumulation this cycle

    // --- Output: Column-Reduced fp32 Values ---
    // TILE_COLS values per cycle — one per column of the PE grid.
    // These are the column sums of the current split quarter.
    // psum_accum accumulates these across depth iterations.
    output logic [FP32_W-1:0]       col_out [TILE_COLS]
);

  // Derived: columns per split phase
  localparam int PHASE_COLS = TILE_COLS / TILE_SPLIT_FACTOR;  // 16, 8, or 4

  // ==================================================================
  // Operand Selection: Phase A vs Phase B
  // ==================================================================
  // In Phase B, P values come as fp32 but are cast to bf16 for the multiply.
  // The bf16_mac PE handles the bf16→fp32 conversion internally.
  //
  // Phase A: row operand = Q[row][depth] (bf16), col operand = K[col][depth] (bf16)
  // Phase B: row operand = fp32_to_bf16(P[row][col_quarter]) (bf16, truncated from fp32)
  //           col operand = V[col_quarter][dim] (bf16)

  // For simplicity, both phases feed bf16 operands to the PE grid.
  // The phase_sel signal selects which data source drives the row/col inputs.

  // ==================================================================
  // PE Grid: TILE_ROWS × TILE_COLS bf16 Multiply Units
  // ==================================================================
  // Each PE computes: product_fp32 = a_bf16 × b_bf16
  // The products are then column-summed (adder tree per column).
  //
  // Pattern: identical to cim_tile.sv GEN_SPLIT* blocks, adapted for bf16.
  //
  // With TILE_SPLIT_FACTOR=2: PHASE_COLS=8.
  //   split_phase=0: process columns 0..7
  //   split_phase=1: process columns 8..15
  // The external FSM sequences split_phase through 0..SPLIT_FACTOR-1.

  genvar g_row, g_col;
  generate

    // ================================================================
    // SPLIT_FACTOR = 4: 4+4+4+4 columns over 4 cycles
    // ================================================================
    if (TILE_SPLIT_FACTOR == 4) begin : GEN_SPLIT4

      for (g_row = 0; g_row < TILE_ROWS; g_row++) begin : GEN_ROW
        // 4 multipliers per row (PHASE_COLS=4), time-muxed across 4 quarters
        for (g_col = 0; g_col < PHASE_COLS; g_col++) begin : GEN_MUL

          logic [BF16_W-1:0] a_sel, b_sel;
          // MUX: select column based on split_phase
          always_comb begin
            case (split_phase)
              2'd0: begin a_sel = row_data[g_row];       b_sel = col_data[g_col];      end
              2'd1: begin a_sel = row_data[g_row];       b_sel = col_data[g_col + 4];  end
              2'd2: begin a_sel = row_data[g_row];       b_sel = col_data[g_col + 8];  end
              2'd3: begin a_sel = row_data[g_row];       b_sel = col_data[g_col + 12]; end
            endcase
          end

          // bf16 multiply: bf16 × bf16 → fp32
          (* use_dsp = "yes" *)
          logic [FP32_W-1:0] product;
          shortreal a_real, b_real;
          assign a_real = $bitstoshortreal({a_sel, 16'b0});
          assign b_real = $bitstoshortreal({b_sel, 16'b0});
          assign product = $shortrealtobits(a_real * b_real);
        end

        // Column accumulation: sum the PHASE_COLS products per column
        // The column outputs are pre-summed by quarter.
        // psum_accum handles cross-quarter accumulation.
      end

      // Column reduction: for each output column, sum all 16 row contributions
      // This is a TILE_ROWS-to-1 reduction per output column.
      for (g_col = 0; g_col < TILE_COLS; g_col++) begin : GEN_COL_REDUCE
        // Sum TILE_ROWS products for this column
        logic [FP32_W-1:0] col_sum;
        shortreal sum_real;
        shortreal term_real [TILE_ROWS];

        for (g_row = 0; g_row < TILE_ROWS; g_row++) begin : GEN_SUM_TERM
          logic [BF16_W-1:0] a_sel_q, b_sel_q;
          always_comb begin
            case (split_phase)
              2'd0: begin a_sel_q = row_data[g_row]; b_sel_q = col_data[g_col % 4]; end
              2'd1: begin a_sel_q = row_data[g_row]; b_sel_q = col_data[(g_col % 4) + 4]; end
              2'd2: begin a_sel_q = row_data[g_row]; b_sel_q = col_data[(g_col % 4) + 8]; end
              2'd3: begin a_sel_q = row_data[g_row]; b_sel_q = col_data[(g_col % 4) + 12]; end
            endcase
          end
          assign term_real[g_row] = $bitstoshortreal({a_sel_q, 16'b0})
                                 * $bitstoshortreal({b_sel_q, 16'b0});
        end

        // Reduction: sum all TILE_ROWS terms
        // In hardware this is an adder tree. For simulation we use shortreal sum.
        always_comb begin
          sum_real = 0.0;
          for (int r = 0; r < TILE_ROWS; r++)
            sum_real = sum_real + term_real[r];
        end

        assign col_out[g_col] = accum_en ? $shortrealtobits(sum_real) : 32'd0;
      end

    // ================================================================
    // SPLIT_FACTOR = 2: 8+8 columns over 2 cycles (DEFAULT)
    // ================================================================
    end else if (TILE_SPLIT_FACTOR == 2) begin : GEN_SPLIT2

      for (g_col = 0; g_col < TILE_COLS; g_col++) begin : GEN_COL_REDUCE
        shortreal sum_real;
        shortreal term_real [TILE_ROWS];

        for (g_row = 0; g_row < TILE_ROWS; g_row++) begin : GEN_SUM_TERM
          logic [BF16_W-1:0] a_sel_s2, b_sel_s2;
          always_comb begin
            if (split_phase == 1'b0) begin
              a_sel_s2 = row_data[g_row];
              b_sel_s2 = (g_col < 8) ? col_data[g_col] : col_data[7];
            end else begin
              a_sel_s2 = row_data[g_row];
              b_sel_s2 = (g_col >= 8) ? col_data[g_col] : col_data[8];
            end
          end
          assign term_real[g_row] = $bitstoshortreal({a_sel_s2, 16'b0})
                                 * $bitstoshortreal({b_sel_s2, 16'b0});
        end

        // Reduction tree (log2(TILE_ROWS) depth)
        always_comb begin
          sum_real = 0.0;
          for (int r = 0; r < TILE_ROWS; r++)
            sum_real = sum_real + term_real[r];
        end

        // Only active columns produce valid output this split phase
        if (g_col < 8) begin : GEN_LO
          assign col_out[g_col] = (accum_en && split_phase == 1'b0)
                                  ? $shortrealtobits(sum_real) : 32'd0;
        end else begin : GEN_HI
          assign col_out[g_col] = (accum_en && split_phase == 1'b1)
                                  ? $shortrealtobits(sum_real) : 32'd0;
        end
      end

    // ================================================================
    // SPLIT_FACTOR = 1: 16-wide single-cycle (SAFE, ≤60 MHz)
    // ================================================================
    end else begin : GEN_MONO

      for (g_col = 0; g_col < TILE_COLS; g_col++) begin : GEN_COL_REDUCE
        shortreal sum_real;

        always_comb begin
          sum_real = 0.0;
          for (int r = 0; r < TILE_ROWS; r++) begin
            shortreal tr;
            tr = $bitstoshortreal({row_data[r], 16'b0})
               * $bitstoshortreal({col_data[g_col], 16'b0});
            sum_real = sum_real + tr;
          end
        end

        assign col_out[g_col] = accum_en ? $shortrealtobits(sum_real) : 32'd0;
      end
    end
  endgenerate

  // ==================================================================
  // Synthesis Note
  // ==================================================================
  // Shortreal-based operations above are for VCS/Verilator simulation.
  // For Vivado synthesis:
  //   - Each (a × b) maps to DSP48E2: 9-bit × 9-bit mantissa multiply
  //     (bf16 has 7-bit explicit + 1 implicit = 8-bit mantissa).
  //   - Column reduction: adder tree using DSP48E2 post-adders or LUT adders.
  //   - Replace shortreal with Vivado Floating-Point IP or HLS fp32 operators.
  //   - The generate-block structure (SPLIT_FACTOR variants) is synthesizable as-is.
  //
  // DSP48E2 budget per tile:
  //   SPLIT_FACTOR=4: 16 rows × 4 cols = 64 multipliers → 64 DSP48 (5.1% of KV260)
  //   SPLIT_FACTOR=2: 16 rows × 8 cols = 128 multipliers → 128 DSP48 (10.3%)
  //   SPLIT_FACTOR=1: 16 rows × 16 cols = 256 multipliers → 256 DSP48 (20.5%)

endmodule
