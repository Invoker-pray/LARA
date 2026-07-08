// ============================================================================
// rms_norm.sv — RMS Normalization (Extension, Future Hardware)
// ============================================================================
// REFERENCE ONLY — NOT for synthesis in v1.0.
// RMSNorm is performed on the host (ARM CPU) for the competition.
//
// Computes: y = x / sqrt(mean(x^2) + eps) * gamma
// Where x [4096] bf16, gamma [4096] bf16 (learned scale)
//
// Llama3 uses Pre-Norm: RMSNorm is applied BEFORE attention and BEFORE FFN.
// ============================================================================

module rms_norm
  import attn_pkg::*;
#(
  parameter int DIM       = 4096,    // hidden dimension (Llama3-8B)
  parameter int PIPE_LAT  = 5        // pipeline latency (cycles)
)(
    input  logic               clk,
    input  logic               rst_n,

    // Streaming input: one token's hidden states [DIM] bf16
    input  logic               in_valid,
    input  logic [BF16_W-1:0]  in_data,
    input  logic [11:0]        in_idx,       // dimension index 0..DIM-1
    output logic               in_ready,

    // Gamma weight (learned scale, constant per inference)
    input  logic [BF16_W-1:0]  gamma [DIM],  // pre-loaded from weight file

    // Streaming output
    output logic               out_valid,
    output logic [BF16_W-1:0]  out_data,
    output logic [11:0]        out_idx,

    // Control
    input  logic               start,
    output logic               done
);

  // ==================================================================
  // Algorithm (3-pass implementation)
  // ==================================================================
  // Pass 1: square each element, accumulate sum(x^2) [DIM cycles]
  // Pass 2: compute inv_sqrt = 1/sqrt(sum/DIM + eps) [1 cycle with LUT]
  // Pass 3: normalize each element: x * inv_sqrt * gamma [DIM cycles]
  //
  // Total: 2*DIM + PIPE_LAT cycles per token
  // For L=512: 512 × (8192 + 5) ≈ 4.2M cycles ≈ 42 ms @ 100 MHz
  //
  // Resource:
  //   - 1 fp32 accumulator (for sum of squares)
  //   - 1 inverse sqrt LUT (256 entries × fp32 = 1 KB)
  //   - 2 bf16 multipliers (x * inv_sqrt, result * gamma)
  //
  // Gate count: negligible (< 500 LUTs, 2 DSPs)
  // Latency: ~2×DIM cycles per token
  //
  // Conclusion: RMSNorm is very lightweight (O(dim) with tiny constant).
  // It CAN be implemented in FPGA if needed, but host CPU is simpler for v1.0.
  // For v2.0 with larger models or tighter latency budgets, this module
  // can be synthesized and inserted before the attention datapath.

  assign in_ready  = 1'b1;
  assign out_valid = 1'b0;
  assign out_data  = 16'd0;
  assign out_idx   = 12'd0;
  assign done      = 1'b0;

endmodule
