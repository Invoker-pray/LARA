// ============================================================================
// qkv_projection.sv — QKV Linear Projection (Extension, Future Hardware)
// ============================================================================
// REFERENCE ONLY — NOT for synthesis in v1.0.
// QKV projection is performed on the host (ARM CPU) for the competition.
//
// Computes: Q = X @ Wq^T, K = X @ Wk^T, V = X @ Wv^T
// Where X [L, 4096] bf16, Wq [4096, 4096], Wk/Wv [4096, 1024]
//
// Computation: ~12.9 GMACs for L=512 — 375× more than attention itself.
// Requires streaming weight data from DDR (Wq alone is 32 MB).
// Only viable on FPGA with external DRAM bandwidth ≥ 10 GB/s and ≥ 2048 DSPs.
//
// Interface contract for v2.0 integration with attn_top data path.
// ============================================================================

module qkv_projection
  import attn_pkg::*;
#(
  parameter int IN_DIM  = 4096,    // Llama3-8B hidden dimension
  parameter int OUT_DIM = 4096,    // Q output dim (= IN_DIM for Q, = HEAD_DIM*N_KV_HEADS = 1024 for K/V)
  parameter int N_DSP   = 256      // DSPs allocated to projection
)(
    input  logic               clk,
    input  logic               rst_n,

    // Streaming input: hidden states X [L, IN_DIM] bf16
    input  logic               x_valid,
    input  logic [BF16_W-1:0]  x_data,
    output logic               x_ready,

    // Streaming weight: W [IN_DIM, OUT_DIM] bf16 (from DDR via AXIS)
    input  logic               w_valid,
    input  logic [BF16_W-1:0]  w_data,
    output logic               w_ready,

    // Streaming output: projected Q/K/V [L, OUT_DIM] bf16
    output logic               out_valid,
    output logic [BF16_W-1:0]  out_data,
    input  logic               out_ready,

    // Control
    input  logic               start,
    input  logic [15:0]        seq_len,
    output logic               done,
    output logic [31:0]        cycle_cnt
);

  // ==================================================================
  // Placeholder — full implementation requires:
  // ==================================================================
  // 1. Weight buffer: BRAM caching weight tiles (OUT_DIM × TILE_SIZE bf16)
  // 2. Input buffer:  BRAM caching X tiles (TILE_SIZE × IN_DIM bf16)
  // 3. MAC array:     N_DSP DSP48E2 units computing partial dot products
  // 4. Accumulator:   fp32 partial sums for each output element
  // 5. FSM:           orchestrates weight streaming, tile computation, output
  //
  // Tile decomposition:
  //   Q = X @ Wq: for each L token, compute 4096 dot products of dim 4096
  //     Each dot product: 4096 MACs → split into tiles
  //     TILE=128: 4096/128 = 32 tiles per output element
  //     Total tiles for Q (L=512): 512 × 32 × 4096/256 ≈ 262K tile ops
  //
  // Resource estimate (N_DSP=256, 200 MHz):
  //   Q: 512 × 4096 × 4096 / (256 × 200M) ≈ 168 ms
  //   K+V: 512 × 1024 × 4096 × 2 / (256 × 200M) ≈ 84 ms
  //   Total: ~252 ms per attention layer (QKV only)
  //
  // Conclusion: Host CPU (ARM Cortex-A53 @ 1.5 GHz, NEON SIMD) can achieve
  // similar or better throughput. QKV projection on FPGA is not justified
  // for the competition constraints. This module is a reference for v2.0
  // targeting larger FPGAs (e.g., Alveo U200 with 6840 DSPs).

  assign x_ready   = 1'b1;
  assign w_ready   = 1'b1;
  assign out_valid = 1'b0;
  assign out_data  = 16'd0;
  assign done      = 1'b0;
  assign cycle_cnt = 32'd0;

endmodule
