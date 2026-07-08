// ============================================================================
// attn_pkg.sv — Global Parameter Package (Single Source of Truth)
// ============================================================================
// All configurable parameters for the LARA Attention Accelerator are defined
// here. NO module may define its own `parameter` that shadows a pkg value.
// Hardcoded numeric constants are forbidden — always use pkg names.
//
// Key design decisions:
//   1. TILE_ROWS=16 limited by Softmax parallelism, NOT DSP count.
//      16×32 is the best extension (rows unchanged → Softmax hardware unchanged).
//   2. TILE_SPLIT_FACTOR provides one-click rollback (inherited from CIM design).
//      =1 safe ≤60MHz, =2 target 100-125MHz, =4 aggressive 100+MHz.
//   3. K/V URAM caching eliminates 128× DDR traffic vs no-cache approach.
//      This is the single most important optimization in the entire design.
//   4. MAC array is time-multiplexed between Phase A (Q×K^T) and Phase B (P×V).
//      Using one 16×16 array saves 256 DSPs vs two separate arrays.
//   5. QKV projection is done on the host (ARM). Weights Wq/Wk/Wv/Wo do NOT
//      enter the FPGA data path. FPGA only does Attention computation.
//
// Correspondence with Golden Model:
//   Python: attention_golden.py — ALL constants here must 1:1 match.
//   Verification: VV/tb/ — testbenches import this package.
// ============================================================================

package attn_pkg;

  // ==================================================================
  // 1. Tile Geometry — MAC Array Dimensions
  // ==================================================================
  // The MAC array is an TILE_ROWS × TILE_COLS systolic grid of bf16 MAC PEs.
  // Each PE computes: out_fp32 = a_bf16 × b_bf16 + c_fp32  (fused multiply-add).
  // Rows = Q dimension, Columns = K/V dimension.
  // Row count (16) is the HARD LIMIT: Softmax engine processes 16 rows in
  // parallel. Increasing rows means doubling the Softmax hardware, which
  // becomes the bottleneck before DSP count does (see mac_array_analysis.html).

  parameter int TILE_ROWS   = 16;            // Q-dimension parallelism (Softmax-limited)
  parameter int TILE_COLS   = 16;            // K/V-dimension parallelism
  parameter int TILE_ELEMS  = TILE_ROWS * TILE_COLS;  // = 256 PEs total

  // ==================================================================
  // 2. Pipeline Split — One-Click Rollback Mechanism
  // ==================================================================
  // SPLIT_FACTOR controls how many cycles a single dot-product column takes.
  // Higher = better timing closure, lower throughput per column.
  //
  // SPLIT_FACTOR=1: single-cycle 16-wide multiply → relaxed at ≤60 MHz
  // SPLIT_FACTOR=2: two-cycle 8+8 split → target 100-125 MHz (DEFAULT)
  // SPLIT_FACTOR=4: four-cycle 4+4+4+4 → 100+ MHz with margin
  //
  // Rollback path: set SPLIT_FACTOR=1 → all generate blocks fall back to
  // the safe single-cycle path. No RTL changes needed.

  parameter int  TILE_SPLIT_FACTOR = 2;      // Column split factor {1, 2, 4}
  parameter bit  TILE_MAC_REUSE    = 1'b1;   // Time-multiplex MAC for Phase A+B
  parameter bit  C4_MUL_PIPE       = 1'b0;   // DSP48E2 M-register pipeline stage

  // Pipeline depth parameters (higher = better timing, more latency)
  parameter int  MAC_PIPE_STAGES    = 2;       // MAC array pipeline: {1=comb, 2=reg products+reduction}
  parameter int  SOFTMAX_PIPE_STAGES = 2;      // Softmax pipeline: {2, 3} stages

  // ==================================================================
  // 3. Data Widths — Data Type Bit Widths
  // ==================================================================
  // bf16 format: S[15] | E[14:7] | M[6:0]
  // Value = (-1)^S × 2^(E-127) × 1.M
  // bf16 → fp32: pad lower 16 mantissa bits with zeros (no rounding needed).
  // fp32 → bf16: truncate lower 16 mantissa bits (round-to-nearest-even).

  parameter int BF16_EXP_W   = 8;            // bf16 exponent width (bias=127)
  parameter int BF16_MANT_W  = 7;            // bf16 mantissa width (7-bit explicit + 1 implicit = 8 effective)
  parameter int BF16_W       = 16;           // bf16 total width
  parameter int FP32_W       = 32;           // fp32 (IEEE 754 single precision)
  parameter int PSUM_W       = 32;           // Partial sum accumulator width

  // Derived bit positions (for bit-slice clarity in RTL)
  localparam int BF16_SIGN_POS  = 15;
  localparam int BF16_EXP_HI    = 14;
  localparam int BF16_EXP_LO    = 7;
  localparam int BF16_MANT_HI   = 6;
  localparam int BF16_MANT_LO   = 0;

  // ==================================================================
  // 4. Attention Algorithm Parameters — Llama3.1-8B Specification
  // ==================================================================
  // Model: Llama3-8B / Llama3.1-8B (or models with consistent parameters).
  // GQA (Grouped Query Attention): 32 Q heads / 8 KV heads = 4 Q heads per KV head.
  // Each head has dimension HEAD_DIM=128.
  //
  // Data shapes (per layer):
  //   Q: [L, 4096] = [L, N_Q_HEADS × HEAD_DIM]  — 32 heads × 128 = 4096
  //   K: [L, 1024] = [L, N_KV_HEADS × HEAD_DIM]  —  8 heads × 128 = 1024
  //   V: [L, 1024] = [L, N_KV_HEADS × HEAD_DIM]  —  8 heads × 128 = 1024
  //   O: [L, 4096] = [L, N_Q_HEADS × HEAD_DIM]   — 32 heads × 128 = 4096

  parameter int MAX_SEQ_LEN   = 2048;         // Maximum sequence length supported
  parameter int HEAD_DIM      = 128;          // Attention head dimension (Llama3)
  parameter int N_Q_HEADS     = 32;           // Number of query heads
  parameter int N_KV_HEADS    = 8;            // Number of key/value heads (GQA)
  parameter int GQA_GROUP_SIZE = N_Q_HEADS / N_KV_HEADS;  // = 4 Q heads per KV head

  // ==================================================================
  // 5. Tiling — FlashAttention Block Sizes
  // ==================================================================
  // TILE_Q: number of Q rows processed per outer-loop iteration.
  // TILE_KV: number of K/V rows processed per inner-loop iteration.
  //
  // TILE_Q=32 is chosen to balance:
  //   - Q ping-pong buffer size: 2 × 32 × 128 × 2B = 16 KB (small)
  //   - O accumulator size: 32 × 128 × 4B = 16 KB (fits BRAM)
  // TILE_KV=64 is chosen to:
  //   - Match URAM read granularity (multiple banks read in parallel)
  //   - Keep Softmax m/l state update cost amortized over 64 columns

  parameter int TILE_Q   = 32;               // Q tile size (rows per outer iteration)
  parameter int TILE_KV  = 64;               // K/V tile size (rows per inner iteration)

  // ==================================================================
  // 6. Memory Sizing — Auto-Derived from Above Parameters
  // ==================================================================
  // RULE: no manual numbers. Every depth/width derives from upstream
  // parameters via formulas. This ensures consistency when TILE_Q, etc.
  // are changed.

  // --- Tile counts ---
  parameter int MAX_N_Q_TILES  = (MAX_SEQ_LEN + TILE_Q  - 1) / TILE_Q;   // ceil(L / TILE_Q)
  parameter int MAX_N_KV_TILES = (MAX_SEQ_LEN + TILE_KV - 1) / TILE_KV;  // ceil(L / TILE_KV)

  // --- KV Cache (URAM, per KV head) ---
  // K and V are fully cached in URAM to eliminate DDR re-reads.
  // At L=512: 512 × 128 × 2B = 128 KB per head. K+V = 256 KB per GQA group.
  // For L=2048: 2048 × 128 × 2B = 512 KB per head. K+V = 1 MB per group.
  // 8 GQA groups × 1 MB = 8 MB — DOES NOT FIT in KV260 URAM (2.6 MB).
  // For L>512, the controller must serialize GQA groups (load one group's K/V at a time).
  parameter int KV_CACHE_DEPTH    = MAX_SEQ_LEN;          // Rows per head (= L)
  parameter int KV_CACHE_ELEMS    = HEAD_DIM;             // bf16 elements per row
  parameter int KV_CACHE_DATA_W   = HEAD_DIM * BF16_W;    // = 2048 bits per row (logical)
  parameter int KV_CACHE_BURST    = TILE_KV * HEAD_DIM;   // Max read burst: 64 × 128 = 8192 bf16

  // --- Q Tile Buffer (Ping-Pong, URAM/BRAM) ---
  // Two banks (A/B) for streaming: one receives from DDR while the other
  // feeds the MAC array. Only TILE_Q=32 rows needed → small buffer.
  parameter int Q_BUF_BANKS       = 2;                    // Ping-pong: Bank A + Bank B
  parameter int Q_BUF_DEPTH       = TILE_Q;               // Rows per bank
  parameter int Q_BUF_ELEMS       = HEAD_DIM;             // bf16 elements per row
  parameter int Q_BUF_DATA_W      = HEAD_DIM * BF16_W;    // = 2048 bits per row (logical)

  // --- Output Accumulator (fp32, URAM/BRAM) ---
  // Accumulates O = Σ P × V across KV tiles, maintained in fp32 for precision.
  parameter int O_ACCUM_DEPTH     = TILE_Q;               // Rows of Q tile
  parameter int O_ACCUM_ELEMS     = HEAD_DIM;             // fp32 elements per row
  parameter int O_ACCUM_DATA_W    = HEAD_DIM * FP32_W;    // = 4096 bits per row (logical)

  // --- EXP LUT (for Softmax Engine) ---
  // Input range: [-8.0, 0.0] (after subtracting row max). Values < -8 → exp ≈ 0.
  // LUT stores exp(x) in fp32 format. Depth chosen for < 0.1% error.
  parameter int EXP_LUT_ADDR_W = 10;                       // 1024 entries
  parameter int EXP_LUT_DEPTH  = (1 << EXP_LUT_ADDR_W);    // = 1024
  parameter int EXP_LUT_DATA_W = FP32_W;                   // fp32 output

  // Online Softmax constants
  // sqrt(128) ≈ 11.313708, 1/sqrt(128) ≈ 0.088388
  localparam real   HEAD_DIM_SQRT_REAL = 11.31370849898476;
  localparam real   INV_SQRT_D_REAL    = 0.08838834764831845;
  localparam [31:0] INV_SQRT_D_FP32    = 32'h3DB504F3;       // 1/sqrt(128) in fp32

  // ==================================================================
  // 7. CSR Address Map — AXI4-Lite Control/Status Registers
  // ==================================================================
  // 14-bit address space (16 KB). Organized by function groups.
  // All addresses must be 4-byte aligned (AXI4-Lite requirement).
  parameter int CSR_ADDR_W = 14;

  // --- Control & Status (0x000–0x0FF) ---
  parameter logic [13:0] CSR_CTRL            = 14'h000;  // [0] start, [1] soft_reset, [31:2] reserved
  parameter logic [13:0] CSR_STATUS          = 14'h004;  // [0] busy, [1] done, [2] error, [31:3] reserved
  parameter logic [13:0] CSR_SEQ_LEN         = 14'h008;  // Actual sequence length for this inference (≤ MAX_SEQ_LEN)
  parameter logic [13:0] CSR_Q_TILE_IDX      = 14'h00C;  // Current Q tile index (read-only debug)
  parameter logic [13:0] CSR_KV_TILE_IDX     = 14'h010;  // Current KV tile index (read-only debug)
  parameter logic [13:0] CSR_HEAD_IDX        = 14'h014;  // Current Q head index (0..31), driver sets before start

  // --- Data Stream Control (0x020–0x04F) ---
  parameter logic [13:0] CSR_STREAM_SRC      = 14'h020;  // DDR source address [31:0] for next stream
  parameter logic [13:0] CSR_STREAM_SRC_HI   = 14'h024;  // DDR source address [63:32] (reserved for 64-bit)
  parameter logic [13:0] CSR_STREAM_LEN      = 14'h028;  // Stream length in bytes. Write triggers DMA start.
  parameter logic [13:0] CSR_STREAM_DEST     = 14'h02C;  // Stream destination select: 0=K_CACHE, 1=V_CACHE, 2=Q_BUF

  // --- Result Stream Control (0x050–0x07F) ---
  parameter logic [13:0] CSR_RESULT_DST      = 14'h050;  // DDR destination address [31:0] for results
  parameter logic [13:0] CSR_RESULT_DST_HI   = 14'h054;  // DDR destination address [63:32]
  parameter logic [13:0] CSR_RESULT_LEN      = 14'h058;  // Result length in bytes

  // --- Performance Counters (0x100–0x1FF) ---
  parameter logic [13:0] CSR_PERF_CYCLES     = 14'h100;  // Total cycle count [31:0]
  parameter logic [13:0] CSR_PERF_CYCLES_HI  = 14'h104;  // Total cycle count [63:32]
  parameter logic [13:0] CSR_PERF_STALLS     = 14'h108;  // Stall cycles (waiting for DDR/URAM)
  parameter logic [13:0] CSR_PERF_Q_TILES    = 14'h10C;  // Number of Q tiles processed
  parameter logic [13:0] CSR_PERF_KV_TILES   = 14'h110;  // Number of KV tiles processed

  // ==================================================================
  // 8. FSM State Enum — Attention Controller State Machine
  // ==================================================================
  // Orchestrates the FlashAttention double loop (Q-outer, KV-inner).
  // Detailed dataflow: see docs/dataflow_diagram.html §2.2.
  //
  // Macro-level flow:
  //   IDLE → LOAD_KV → Q_INIT → [KV_READ → QK_DOT → SOFTMAX → AV_DOT]* →
  //   NORMALIZE → WRITE_O → (Q_INIT | DONE)

  typedef enum logic [5:0] {
    ST_IDLE          = 6'd0,   // Waiting for start signal
    ST_LOAD_KV       = 6'd1,   // Load K/V from DDR to URAM (once per head)
    ST_Q_INIT        = 6'd2,   // Load next Q tile, init m=-inf, l=0, O_acc=0
    ST_KV_READ       = 6'd3,   // Read K_tile and V_tile from URAM (inner loop start)
    ST_QK_DOT        = 6'd4,   // Phase A: Q_tile × K_tile^T → S_tile blocks (MAC array)
    ST_SOFTMAX       = 6'd5,   // Online Softmax: 1/√128 scale + mask + exp + m/l/O update
    ST_AV_DOT        = 6'd6,   // Phase B: P_tile × V_tile → ΔO_acc (MAC array, time-muxed)
    ST_NORMALIZE     = 6'd7,   // O = O_acc / l, fp32 → bf16 truncation
    ST_WRITE_O       = 6'd8,   // Write O_tile to DDR via AXIS
    ST_DONE          = 6'd9,   // Assert IRQ, return to IDLE
    ST_ERROR         = 6'd63    // Terminal error state (invalid config, DDR timeout, etc.)
  } attn_state_t;

  // ==================================================================
  // 8a. Stream Destination Select
  // ==================================================================
  typedef enum logic [1:0] {
    STREAM_TO_K_CACHE  = 2'd0,  // DDR → K URAM
    STREAM_TO_V_CACHE  = 2'd1,  // DDR → V URAM
    STREAM_TO_Q_BUF    = 2'd2   // DDR → Q Ping-Pong Buffer
  } stream_dest_t;

  // ==================================================================
  // 9. Helper Functions
  // ==================================================================
  // $clog2 is a Verilog system function that returns ceil(log2(x)).
  // For x ≤ 1, $clog2 returns 0, which can cause 0-width signals.
  // clog2_safe ensures a minimum of 1-bit width for address buses.

  function automatic int clog2_safe(input int val);
    if (val <= 1) return 1;
    else return $clog2(val);
  endfunction

  // Ceiling integer division: ceil(a / b) = (a + b - 1) / b
  function automatic int ceil_div(input int a, input int b);
    return (a + b - 1) / b;
  endfunction

endpackage
