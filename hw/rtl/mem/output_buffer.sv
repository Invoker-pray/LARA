// ============================================================================
// output_buffer.sv — Output Accumulator Buffer
// ============================================================================
// Stores running O_acc [TILE_ROWS × HEAD_DIM] fp32. Updated each KV tile.
// On last KV tile: normalizes O = O_acc / l and outputs bf16 O_data.
//
// The O_acc update (O_acc_new = O_acc_old × correction + P×V contribution)
// is brokered by psum_accum, which writes back the updated O_acc here.
// ============================================================================

module output_buffer
  import attn_pkg::*;
(
    input  logic                       clk,
    input  logic                       rst_n,

    // Accumulator update port (from psum_accum)
    // FlashAttention: O_acc_new[i][d] = O_acc_old[i][d] × correction[i] + ΔO[i][d]
    input  logic                       acc_update,
    input  logic [4:0]                 acc_row,       // row index (0..TILE_ROWS-1)
    input  logic [FP32_W-1:0]          acc_data [HEAD_DIM],  // ΔO row contribution (128 fp32)
    input  logic [FP32_W-1:0]          correction [TILE_ROWS],  // from softmax_engine

    // Normalization control
    input  logic                       normalize,     // pulse: perform O = O_acc / l
    input  logic [FP32_W-1:0]          l_state [TILE_ROWS],  // softmax denominators

    // Output stream (to DDR via AXIS)
    output logic                       o_valid,
    output logic [4:0]                 o_row,
    output logic [6:0]                 o_dim,
    output logic [BF16_W-1:0]          o_data
);

  // Storage: TILE_ROWS × HEAD_DIM fp32 = 16 × 128 = 2048 elements
  logic [FP32_W-1:0] o_acc [0:TILE_ROWS-1][0:HEAD_DIM-1];

  // Update accumulator
  integer di, ar;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (ar = 0; ar < TILE_ROWS; ar++)
        for (di = 0; di < HEAD_DIM; di++)
          o_acc[ar][di] <= 32'd0;
    end else if (acc_update) begin
      // FlashAttention: O_new = O_old × correction + ΔO
      for (di = 0; di < HEAD_DIM; di++) begin
        shortreal o_old = $bitstoshortreal(o_acc[acc_row][di]);
        shortreal corr  = $bitstoshortreal(correction[acc_row]);
        shortreal delta = $bitstoshortreal(acc_data[di]);
        o_acc[acc_row][di] <= $shortrealtobits(o_old * corr + delta);
      end
    end
  end

  // Normalize and output (sequential readout)
  logic        norm_active;
  logic [4:0]  norm_row;
  logic [6:0]  norm_dim;
  shortreal    norm_val, norm_l, norm_result;

  // Combinational normalization
  always_comb begin
    norm_val    = $bitstoshortreal(o_acc[norm_row][norm_dim]);
    norm_l      = $bitstoshortreal(l_state[norm_row]);
    if (norm_l != 0.0)
      norm_result = norm_val / norm_l;
    else
      norm_result = 0.0;
  end

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
        o_data  <= $shortrealtobits(norm_result) >> 16;

        if (norm_dim == HEAD_DIM - 1) begin
          norm_dim <= 7'd0;
          if (norm_row == TILE_ROWS - 1) begin
            norm_active <= 1'b0;
            o_valid     <= 1'b0;
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
