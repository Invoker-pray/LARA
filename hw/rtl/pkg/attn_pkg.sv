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

  localparam int TILE_ROWS   = 16;            // Q-dimension parallelism (Softmax-limited)
  localparam int TILE_COLS   = 16;            // K/V-dimension parallelism
  localparam int TILE_ELEMS  = TILE_ROWS * TILE_COLS;  // = 256 PEs total

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

  localparam int  TILE_SPLIT_FACTOR = 2;      // Column split factor {1, 2, 4}
  localparam bit  TILE_MAC_REUSE    = 1'b1;   // Time-multiplex MAC for Phase A+B
  localparam bit  C4_MUL_PIPE       = 1'b1;   // DSP48E2 M-register: 1=registered (≥100MHz), 0=combinational (≤60MHz)

  // Pipeline depth parameters (higher = better timing, more latency)
  localparam int  MAC_PIPE_STAGES    = 2;       // MAC array pipeline: {1=comb, 2=reg products+reduction}
  localparam int  SOFTMAX_PIPE_STAGES = 2;      // Softmax pipeline: {2, 3} stages

  // ==================================================================
  // 3. Data Widths — Data Type Bit Widths
  // ==================================================================
  // bf16 format: S[15] | E[14:7] | M[6:0]
  // Value = (-1)^S × 2^(E-127) × 1.M
  // bf16 → fp32: pad lower 16 mantissa bits with zeros (no rounding needed).
  // fp32 → bf16: truncate lower 16 mantissa bits (round-to-nearest-even).

  localparam int BF16_EXP_W   = 8;            // bf16 exponent width (bias=127)
  localparam int BF16_MANT_W  = 7;            // bf16 mantissa width (7-bit explicit + 1 implicit = 8 effective)
  localparam int BF16_W       = 16;           // bf16 total width
  localparam int FP32_W       = 32;           // fp32 (IEEE 754 single precision)
  localparam int PSUM_W       = 32;           // Partial sum accumulator width

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

  // KV260 full-cache deploy target:
  //   seq_len <= 512 keeps one KV group's K+V footprint within on-chip URAM.
  // Longer contexts require the not-yet-implemented streaming fallback path, so
  // keep the synthesized configuration at 512 for a board-realistic bitstream.
  localparam int MAX_SEQ_LEN   = 512;          // Maximum deployed sequence length
  localparam int HEAD_DIM      = 128;          // Attention head dimension (Llama3)
  localparam int N_Q_HEADS     = 32;           // Number of query heads
  localparam int N_KV_HEADS    = 8;            // Number of key/value heads (GQA)
  localparam int GQA_GROUP_SIZE = N_Q_HEADS / N_KV_HEADS;  // = 4 Q heads per KV head

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

  localparam int TILE_Q   = 32;               // Q tile size (rows per outer iteration)
  localparam int TILE_KV  = 64;               // K/V tile size (rows per inner iteration)

  // ==================================================================
  // 6. Memory Sizing — Auto-Derived from Above Parameters
  // ==================================================================
  // RULE: no manual numbers. Every depth/width derives from upstream
  // parameters via formulas. This ensures consistency when TILE_Q, etc.
  // are changed.

  // --- Tile counts ---
  localparam int MAX_N_Q_TILES  = (MAX_SEQ_LEN + TILE_Q  - 1) / TILE_Q;   // ceil(L / TILE_Q)
  localparam int MAX_N_KV_TILES = (MAX_SEQ_LEN + TILE_KV - 1) / TILE_KV;  // ceil(L / TILE_KV)

  // --- KV Cache (URAM, per KV head) ---
  // K and V are fully cached in URAM to eliminate DDR re-reads.
  // At L=512: 512 × 128 × 2B = 128 KB per head. K+V = 256 KB per GQA group.
  // For L=512: 512 × 128 × 2B = 128 KB per head. K+V = 256 KB per group.
  // 8 GQA groups × 256 KB = 2 MB, which fits the KV260 URAM budget with margin.
  // For L>512, the controller must serialize GQA groups or stream tiles from DDR.
  localparam int KV_CACHE_DEPTH    = MAX_SEQ_LEN;          // Rows per head (= L)
  localparam int KV_CACHE_ELEMS    = HEAD_DIM;             // bf16 elements per row
  localparam int KV_CACHE_DATA_W   = HEAD_DIM * BF16_W;    // = 2048 bits per row (logical)
  localparam int KV_CACHE_BURST    = TILE_KV * HEAD_DIM;   // Max read burst: 64 × 128 = 8192 bf16

  // --- Q Tile Buffer (Ping-Pong, URAM/BRAM) ---
  // Two banks (A/B) for streaming: one receives from DDR while the other
  // feeds the MAC array. Only TILE_Q=32 rows needed → small buffer.
  localparam int Q_BUF_BANKS       = 2;                    // Ping-pong: Bank A + Bank B
  localparam int Q_BUF_DEPTH       = TILE_Q;               // Rows per bank
  localparam int Q_BUF_ELEMS       = HEAD_DIM;             // bf16 elements per row
  localparam int Q_BUF_DATA_W      = HEAD_DIM * BF16_W;    // = 2048 bits per row (logical)

  // --- Output Accumulator (fp32, URAM/BRAM) ---
  // Accumulates O = Σ P × V across KV tiles, maintained in fp32 for precision.
  localparam int O_ACCUM_DEPTH     = TILE_Q;               // Rows of Q tile
  localparam int O_ACCUM_ELEMS     = HEAD_DIM;             // fp32 elements per row
  localparam int O_ACCUM_DATA_W    = HEAD_DIM * FP32_W;    // = 4096 bits per row (logical)

  // --- EXP LUT (for Softmax Engine) ---
  // Input range: [-8.0, 0.0] (after subtracting row max). Values < -8 → exp ≈ 0.
  // LUT stores exp(x) in fp32 format. Depth chosen for < 0.1% error.
  localparam int EXP_LUT_ADDR_W = 10;                       // 1024 entries
  localparam int EXP_LUT_DEPTH  = (1 << EXP_LUT_ADDR_W);    // = 1024
  localparam int EXP_LUT_DATA_W = FP32_W;                   // fp32 output

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
  localparam int CSR_ADDR_W = 14;

  // --- Control & Status (0x000–0x0FF) ---
  localparam logic [13:0] CSR_CTRL            = 14'h000;  // [0] start W1P, [1] clear_status W1P
  localparam logic [13:0] CSR_STATUS          = 14'h004;  // ready/busy/done/error/stream/load-request status
  localparam logic [13:0] CSR_SEQ_LEN         = 14'h008;  // Actual sequence length for this inference (≤ MAX_SEQ_LEN)
  localparam logic [13:0] CSR_Q_POS_BASE      = 14'h00C;  // Absolute Q position base for causal masking
  localparam logic [13:0] CSR_KV_POS_BASE     = 14'h010;  // Absolute K/V position base for causal masking
  localparam logic [13:0] CSR_CFG             = 14'h014;  // [0] causal enable
  localparam logic [13:0] CSR_ERROR_CODE      = 14'h018;  // Sticky error classification
  // [0] KV request, [1] Q request, [2] Q destination bank,
  // [6:4] KV group, [10:8] Q group, [13:12] Q head, [23:16] Q tile.
  localparam logic [13:0] CSR_LOAD_REQ        = 14'h01C;

  // --- Data Stream Control (0x020–0x04F) ---
  localparam logic [13:0] CSR_STREAM_SRC      = 14'h020;  // DDR source address [31:0] for next stream
  localparam logic [13:0] CSR_STREAM_SRC_HI   = 14'h024;  // DDR source address [63:32] (reserved for 64-bit)
  localparam logic [13:0] CSR_STREAM_LEN      = 14'h028;  // Endpoint length in bytes; software starts AXI DMA separately
  localparam logic [13:0] CSR_STREAM_DEST     = 14'h02C;  // Stream destination select: 0=K_CACHE, 1=V_CACHE, 2=Q_BUF

  // --- Result Stream Control (0x050–0x07F) ---
  localparam logic [13:0] CSR_RESULT_DST      = 14'h050;  // DDR destination address [31:0] for results
  localparam logic [13:0] CSR_RESULT_DST_HI   = 14'h054;  // DDR destination address [63:32]
  localparam logic [13:0] CSR_RESULT_LEN      = 14'h058;  // Result length in bytes

  // --- Performance Counters (0x100–0x1FF) ---
  localparam logic [13:0] CSR_PERF_CYCLES     = 14'h100;  // Total cycle count [31:0]
  localparam logic [13:0] CSR_PERF_CYCLES_HI  = 14'h104;  // Total cycle count [63:32]
  localparam logic [13:0] CSR_PERF_MAC_CYCLES = 14'h108;  // MAC-active cycles
  localparam logic [13:0] CSR_PERF_STALLS     = 14'h10C;  // Stall cycles waiting for host/memory

  typedef enum logic [7:0] {
    ERR_NONE        = 8'h00,
    ERR_BAD_CFG     = 8'h01,
    ERR_BUSY_START  = 8'h02,
    ERR_STREAM_LEN  = 8'h10,
    ERR_STREAM_DEST = 8'h11,
    ERR_RESULT_LEN  = 8'h12
  } error_code_t;

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

  // ================================================================
  // 10. fp32 Helper Functions — synthesizable bit-level arithmetic
  // ================================================================
  function automatic logic [31:0] fp32_negate(input logic [31:0] a);
    return {~a[31], a[30:0]};
  endfunction

  function automatic logic fp32_is_zero(input logic [31:0] a);
    return (a[30:0] == 31'd0);
  endfunction

  function automatic logic fp32_is_inf(input logic [31:0] a);
    return (a[30:23] == 8'hFF) && (a[22:0] == 23'd0);
  endfunction

  function automatic logic fp32_is_nan(input logic [31:0] a);
    return (a[30:23] == 8'hFF) && (a[22:0] != 23'd0);
  endfunction

  function automatic logic fp32_gt(input logic [31:0] a, input logic [31:0] b);
    begin
      if (a == b) return 1'b0;
      if (a[31] != b[31]) return b[31];
      if (!a[31]) return (a[30:0] > b[30:0]);
      else        return (a[30:0] < b[30:0]);
    end
  endfunction

  function automatic logic [31:0] fp32_max(input logic [31:0] a, input logic [31:0] b);
    return fp32_gt(a, b) ? a : b;
  endfunction

  function automatic logic [31:0] fp32_add(input logic [31:0] a, input logic [31:0] b);
    logic        sign_a, sign_b, sign_large, sign_res;
    logic [7:0]  exp_a, exp_b, exp_large;
    logic [23:0] mant_a, mant_b;
    logic        a_larger, effective_sub;
    logic [24:0] mant_large, mant_small, mant_small_shifted, mant_sum;
    logic [7:0]  exp_res;
    logic [22:0] frac_res;
    integer      shift;
    integer      lz;
    begin
      if (fp32_is_nan(a) || fp32_is_nan(b)) return 32'h7FC0_0000;
      if (fp32_is_zero(a)) return b;
      if (fp32_is_zero(b)) return a;

      sign_a = a[31]; sign_b = b[31];
      exp_a  = (a[30:23] == 8'd0) ? 8'd1 : a[30:23];
      exp_b  = (b[30:23] == 8'd0) ? 8'd1 : b[30:23];
      mant_a = (a[30:23] == 8'd0) ? {1'b0, a[22:0]} : {1'b1, a[22:0]};
      mant_b = (b[30:23] == 8'd0) ? {1'b0, b[22:0]} : {1'b1, b[22:0]};

      a_larger = (exp_a > exp_b) || ((exp_a == exp_b) && (mant_a >= mant_b));
      exp_large = a_larger ? exp_a : exp_b;
      mant_large = {1'b0, (a_larger ? mant_a : mant_b)};
      mant_small = {1'b0, (a_larger ? mant_b : mant_a)};
      sign_large = a_larger ? sign_a : sign_b;
      effective_sub = sign_a ^ sign_b;

      shift = a_larger ? (integer'(exp_a) - integer'(exp_b))
                       : (integer'(exp_b) - integer'(exp_a));
      mant_small_shifted = (shift >= 25) ? 25'd0 : (mant_small >> shift);
      mant_sum = effective_sub ? (mant_large - mant_small_shifted)
                               : (mant_large + mant_small_shifted);

      if (mant_sum == 25'd0) return 32'd0;

      sign_res = sign_large;
      if (mant_sum[24]) begin
        exp_res = exp_large + 8'd1;
        frac_res = mant_sum[23:1];
      end else begin
        lz = 0;
        while ((lz < 24) && !mant_sum[23-lz]) lz++;
        exp_res = exp_large - lz[7:0];
        frac_res = (mant_sum[22:0] << lz);
      end
      return {sign_res, exp_res, frac_res};
    end
  endfunction

  function automatic logic [31:0] fp32_sub(input logic [31:0] a, input logic [31:0] b);
    return fp32_add(a, fp32_negate(b));
  endfunction

  function automatic logic [31:0] fp32_mul(input logic [31:0] a, input logic [31:0] b);
    logic sign_a, sign_b, sign_p;
    logic [7:0] exp_a, exp_b, exp_p;
    logic [23:0] mant_a, mant_b;
    logic [47:0] mant_prod;
    logic [22:0] frac_p;
    begin
      if (fp32_is_nan(a) || fp32_is_nan(b)) return 32'h7FC0_0000;
      if (fp32_is_zero(a) || fp32_is_zero(b)) return {a[31]^b[31], 31'd0};
      if (fp32_is_inf(a) || fp32_is_inf(b)) return {a[31]^b[31], 8'hFF, 23'd0};

      sign_a = a[31]; sign_b = b[31]; sign_p = sign_a ^ sign_b;
      exp_a  = a[30:23]; exp_b = b[30:23];
      mant_a = {1'b1, a[22:0]};
      mant_b = {1'b1, b[22:0]};
      mant_prod = ({24'd0, mant_a} * {24'd0, mant_b});

      if (mant_prod[47]) begin
        exp_p = exp_a + exp_b - 8'd126;
        frac_p = mant_prod[46:24];
      end else begin
        exp_p = exp_a + exp_b - 8'd127;
        frac_p = mant_prod[45:23];
      end
      return {sign_p, exp_p, frac_p};
    end
  endfunction

  function automatic logic [31:0] bf16_mul_to_fp32(
    input logic [15:0] a_bf16,
    input logic [15:0] b_bf16
  );
    logic        sign_a, sign_b, sign_prod;
    logic [7:0]  exp_a,  exp_b, exp_norm;
    logic [7:0]  mant_a, mant_b;
    logic [15:0] mant_prod;
    logic [8:0]  exp_prod;
    logic        norm_shift;
    logic [6:0]  mant_norm;
    logic        a_zero, b_zero, a_inf, b_inf, a_nan, b_nan;
    begin
      sign_a = a_bf16[15];
      sign_b = b_bf16[15];
      exp_a  = a_bf16[14:7];
      exp_b  = b_bf16[14:7];
      mant_a = {1'b1, a_bf16[6:0]};
      mant_b = {1'b1, b_bf16[6:0]};

      mant_prod = ({8'd0, mant_a} * {8'd0, mant_b});
      sign_prod = sign_a ^ sign_b;
      exp_prod  = {1'b0, exp_a} + {1'b0, exp_b} - 9'd127;

      norm_shift = mant_prod[15];
      exp_norm   = norm_shift ? (exp_prod[7:0] + 8'd1) : exp_prod[7:0];
      mant_norm  = norm_shift ? mant_prod[14:8] : mant_prod[13:7];

      a_zero = (a_bf16[14:7] == 8'd0);
      b_zero = (b_bf16[14:7] == 8'd0);
      a_inf  = (a_bf16[14:7] == 8'hFF) && (a_bf16[6:0] == 7'd0);
      b_inf  = (b_bf16[14:7] == 8'hFF) && (b_bf16[6:0] == 7'd0);
      a_nan  = (a_bf16[14:7] == 8'hFF) && (a_bf16[6:0] != 7'd0);
      b_nan  = (b_bf16[14:7] == 8'hFF) && (b_bf16[6:0] != 7'd0);

      if (a_nan || b_nan)
        return 32'h7FC0_0000;
      else if ((a_inf && b_zero) || (a_zero && b_inf))
        return 32'h7FC0_0000;
      else if (a_inf || b_inf)
        return {sign_prod, 8'hFF, 23'd0};
      else if (a_zero || b_zero)
        return {sign_prod, 8'd0, 23'd0};
      else
        return {sign_prod, exp_norm, mant_norm, 16'd0};
    end
  endfunction

  function automatic logic signed [23:0] fp32_to_q8_15(input logic [31:0] a);
    logic sign_a;
    logic [7:0] exp_a;
    logic [23:0] mant_a;
    logic signed [39:0] tmp;
    integer shift;
    begin
      if (fp32_is_zero(a)) return 24'sd0;
      sign_a = a[31];
      exp_a  = a[30:23];
      mant_a = {1'b1, a[22:0]};
      shift = integer'(exp_a) - 127 - 23 + 15;
      if (shift >= 0) tmp = $signed({15'd0, 1'b0, mant_a}) <<< shift;
      else            tmp = $signed({15'd0, 1'b0, mant_a}) >>> (-shift);
      if (sign_a) tmp = -tmp;
      return tmp[23:0];
    end
  endfunction

  function automatic logic [15:0] fp32_to_bf16(input logic [31:0] a);
    logic round_up;
    logic [15:0] upper;
    begin
      upper = a[31:16];
      round_up = a[15] && (|a[14:0] || upper[0]);
      fp32_to_bf16 = upper + round_up;
    end
  endfunction

  function automatic logic [31:0] fp32_recip(input logic [31:0] a);
    logic [7:0] exp_a, exp_r;
    logic [23:0] mant_a;
    logic [23:0] recip_q23, recip_norm;
    logic [22:0] frac_r;
    logic sign_r;
    logic [46:0] dividend;
    logic [46:0] recip_full;
    begin
      if (fp32_is_nan(a)) return 32'h7FC0_0000;
      if (fp32_is_zero(a)) return {a[31], 8'hFF, 23'd0};
      if (fp32_is_inf(a))  return {a[31], 31'd0};
      sign_r = a[31];
      exp_a  = a[30:23];
      mant_a = {1'b1, a[22:0]};
      dividend = 47'd1 << 46;
      recip_full = dividend / {23'd0, mant_a};
      recip_q23 = recip_full[23:0];
      if (recip_q23[23]) begin
        exp_r = 8'd254 - exp_a;
        recip_norm = recip_q23;
      end else begin
        exp_r = 8'd253 - exp_a;
        recip_norm = recip_q23 << 1;
      end
      frac_r = recip_norm[22:0];
      return {sign_r, exp_r, frac_r};
    end
  endfunction

  function automatic logic [31:0] fp32_div(input logic [31:0] a, input logic [31:0] b);
    return fp32_mul(a, fp32_recip(b));
  endfunction

endpackage
