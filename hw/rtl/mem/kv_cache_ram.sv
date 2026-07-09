// ============================================================================
// kv_cache_ram.sv — K/V URAM Cache (Behavioral Model)
// ============================================================================
// Stores full K or V matrix for one KV head. Uses behavioral array for
// simulation; Vivado synthesis maps to URAM/BRAM via inference or IP.
//
// Capacity: MAX_SEQ_LEN × HEAD_DIM bf16 = 2048 × 128 × 2B = 512 KB per head.
// Read: TILE_KV elements in parallel per read cycle (TILE_KV=64).
// ============================================================================

module kv_cache_ram
  import attn_pkg::*;
(
    input  logic                       clk,
    input  logic                       rst_n,

    // Write port (streaming load from DDR)
    input  logic                       wr_en,
    input  logic [15:0]                wr_addr,   // = token × HEAD_DIM + dim
    input  logic [BF16_W-1:0]          wr_data,

    // Read port (parallel read for attention loop)
    input  logic                       rd_en,
    input  logic [15:0]                rd_token_start,  // starting token index
    input  logic [6:0]                 rd_dim,          // head dim index (0..127)
    output logic [BF16_W-1:0]          rd_data [TILE_KV]
);

  // ==================================================================
  // Storage Array
  // ==================================================================
  // Behavioral model: simple 2D array.
  // For synthesis: Vivado infers URAM from this pattern or uses IP.

  localparam int TOTAL_ELEMS = MAX_SEQ_LEN * HEAD_DIM;  // 2048 × 128 = 262144

  // Single-port write, multi-port read (TILE_KV parallel reads)
  (* ram_style = "block" *) logic [BF16_W-1:0] mem [0:TOTAL_ELEMS-1];

  // ==================================================================
  // Write Logic
  // ==================================================================
  always_ff @(posedge clk) begin
    if (wr_en)
      mem[wr_addr] <= wr_data;
  end

  // ==================================================================
  // Read Logic (TILE_KV parallel reads)
  // ==================================================================
  integer tk;
  always_ff @(posedge clk) begin
    if (rd_en) begin
      for (tk = 0; tk < TILE_KV; tk++)
        rd_data[tk] <= mem[(rd_token_start + tk[15:0]) * HEAD_DIM + rd_dim];
    end
  end

endmodule
