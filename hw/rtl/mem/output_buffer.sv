// ============================================================================
// output_buffer.sv — Output Accumulator Buffer
// ============================================================================
// Dual-bank O_acc: bank A computes while bank B normalizes+outputs.
// Bank select toggles each Q tile (mirrors tile_buffer ping-pong).
// ============================================================================

module output_buffer
  import attn_pkg::*;
(
    input  logic                       clk,
    input  logic                       rst_n,

    // Explicit bank clear (used at Q-tile / microtile boundaries)
    input  logic                       clear_bank,
    input  logic                       clear_bank_sel,

    // Accumulator update port (from psum_accum)
    // FlashAttention: O_acc_new[i][d] = O_acc_old[i][d] × correction[i] + ΔO[i][d]
    input  logic                       acc_update,
    input  logic [4:0]                 acc_row,       // row index (0..TILE_ROWS-1)
    input  logic [FP32_W-1:0]          acc_data [HEAD_DIM],  // ΔO row contribution (128 fp32)
    input  logic [FP32_W-1:0]          correction [TILE_ROWS],  // from softmax_engine

    // Bank select (0=compute bank0/normalize bank1, 1=swap)
    input  logic                       bank_sel,

    // Normalization control
    input  logic                       normalize,     // pulse: perform O = O_acc / l
    input  logic [FP32_W-1:0]          l_state [TILE_ROWS],  // softmax denominators

    // Output stream (to DDR via AXIS)
    output logic                       o_valid,
    output logic [4:0]                 o_row,
    output logic [6:0]                 o_dim,
    output logic [BF16_W-1:0]          o_data
);

  // Dual-bank O_acc: 2 × TILE_ROWS × HEAD_DIM fp32
  logic [FP32_W-1:0] o_acc0 [0:TILE_ROWS-1][0:HEAD_DIM-1];
  logic [FP32_W-1:0] o_acc1 [0:TILE_ROWS-1][0:HEAD_DIM-1];
  logic [FP32_W-1:0] norm_result_bits;
  logic [FP32_W-1:0] norm_source_bits;
  logic [clog2_safe(TILE_ROWS)-1:0] acc_row_idx;
  logic [clog2_safe(TILE_ROWS)-1:0] norm_row_idx;

  assign acc_row_idx = acc_row[clog2_safe(TILE_ROWS)-1:0];

`ifndef SYNTHESIS
  shortreal    norm_val, norm_l, norm_result;
`endif

  // Update accumulator (write to currently-selected compute bank)
  integer di, ar;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (ar = 0; ar < TILE_ROWS; ar++)
        for (di = 0; di < HEAD_DIM; di++) begin
          o_acc0[ar][di] <= 32'd0;
          o_acc1[ar][di] <= 32'd0;
        end
    end else if (clear_bank) begin
      for (ar = 0; ar < TILE_ROWS; ar++)
        for (di = 0; di < HEAD_DIM; di++) begin
          if (!clear_bank_sel)
            o_acc0[ar][di] <= 32'd0;
          else
            o_acc1[ar][di] <= 32'd0;
        end
`ifndef SYNTHESIS
    end else if (acc_update) begin
      for (di = 0; di < HEAD_DIM; di++) begin
        shortreal o_old, corr, delta;
        corr  = $bitstoshortreal(correction[acc_row]);
        delta = $bitstoshortreal(acc_data[di]);
        if (!bank_sel) begin
          o_old = $bitstoshortreal(o_acc0[acc_row][di]);
          o_acc0[acc_row][di] <= $shortrealtobits(o_old * corr + delta);
        end else begin
          o_old = $bitstoshortreal(o_acc1[acc_row][di]);
          o_acc1[acc_row][di] <= $shortrealtobits(o_old * corr + delta);
        end
      end
    end
`else
    end else if (acc_update) begin
      for (di = 0; di < HEAD_DIM; di++) begin
        if (!bank_sel)
          o_acc0[acc_row_idx][di] <= fp32_add(fp32_mul(o_acc0[acc_row_idx][di], correction[acc_row_idx]), acc_data[di]);
        else
          o_acc1[acc_row_idx][di] <= fp32_add(fp32_mul(o_acc1[acc_row_idx][di], correction[acc_row_idx]), acc_data[di]);
      end
    end
`endif
  end

  // Normalize and output (sequential readout)
  logic        norm_active;
  logic [4:0]  norm_row;
  logic [6:0]  norm_dim;
  assign norm_row_idx = norm_row[clog2_safe(TILE_ROWS)-1:0];

  // Combinational normalization
`ifndef SYNTHESIS
  always_comb begin
    // Normalize from the OTHER bank (not the one being computed)
    if (!bank_sel) begin
      norm_val = $bitstoshortreal(o_acc1[norm_row][norm_dim]);
    end else begin
      norm_val = $bitstoshortreal(o_acc0[norm_row][norm_dim]);
    end
    norm_l      = $bitstoshortreal(l_state[norm_row]);
    if (norm_l != 0.0)
      norm_result = norm_val / norm_l;
    else
      norm_result = 0.0;
  end
  assign norm_result_bits = $shortrealtobits(norm_result);
`else
  always_comb begin
    if (!bank_sel)
      norm_source_bits = o_acc1[norm_row_idx][norm_dim];
    else
      norm_source_bits = o_acc0[norm_row_idx][norm_dim];

    if (fp32_is_zero(l_state[norm_row_idx]))
      norm_result_bits = 32'd0;
    else
      norm_result_bits = fp32_div(norm_source_bits, l_state[norm_row_idx]);
  end
`endif

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      norm_active <= 1'b0;
      norm_row    <= 5'd0;
      norm_dim    <= 7'd0;
      o_valid     <= 1'b0;
      o_row       <= 5'd0;
      o_dim       <= 7'd0;
      o_data      <= 16'd0;
    end else begin
      if (normalize) begin
        norm_active <= 1'b1;
        norm_row    <= 5'd0;
        norm_dim    <= 7'd0;
      end

      if (norm_active) begin
        o_valid <= 1'b1;
        o_row   <= norm_row;
        o_dim   <= norm_dim;
        o_data  <= fp32_to_bf16(norm_result_bits);

        if (norm_dim == 7'(HEAD_DIM - 1)) begin
          norm_dim <= 7'd0;
          if (norm_row == 5'(TILE_ROWS - 1)) begin
            norm_active <= 1'b0;
          end else
            norm_row <= norm_row + 5'd1;
        end else
          norm_dim <= norm_dim + 7'd1;
      end else begin
        o_valid <= 1'b0;
      end
    end
  end
endmodule
