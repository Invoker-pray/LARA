// ============================================================================
// kv_cache_ram.sv — K/V Cache with 8-bank read organization
// ============================================================================
// Interface contract:
//   - Write:  scalar bf16 stream, linear address = token * HEAD_DIM + dim
//   - Read:   TILE_KV (=64) bf16 values for one dimension across one KV tile
//
// Storage organization:
//   - Tokens are interleaved across 8 banks by token[2:0].
//   - Each bank word stores 8 tokens for the same dim inside one 64-token tile:
//       word = {token+56, token+48, ..., token+8, token}
//   - This matches the docs/code_organization.html "8 banks × 8 tokens/bank"
//     plan and turns one TILE_KV read into 8 bank reads + local unpacking.
//
// Assumption:
//   - rd_token_start is aligned to TILE_KV (=64). This is true for the current
//     attn_core tiling scheme: kv_tile_start = kv_tile_idx * TILE_KV.
// ============================================================================

module kv_cache_ram
  import attn_pkg::*;
  #(parameter bit TOKEN_PARALLEL_READ = 1'b1)
(
    input  logic                       clk,
    input  logic                       rst_n,

    // Write port (streaming load from DDR)
    input  logic                       wr_en,
    input  logic [15:0]                wr_addr,          // token * HEAD_DIM + dim
    input  logic [BF16_W-1:0]          wr_data,

    // Read port (parallel read for attention loop)
    input  logic                       rd_en,
    input  logic [15:0]                rd_token_start,   // expected TILE_KV-aligned
    input  logic [6:0]                 rd_dim,           // head dim index (0..127)
    output logic [BF16_W-1:0]          rd_data [TILE_KV],

    // Vector read port (used by V cache / Phase B)
    input  logic                       rd_vec_en,
    input  logic [15:0]                rd_vec_token_idx,
    input  logic [6:0]                 rd_vec_dim_start, // expected 16-dim aligned
    output logic [BF16_W-1:0]          rd_vec_data [TILE_COLS]
);

  localparam int N_BANKS          = 8;
  localparam int TOKENS_PER_BANK  = TILE_KV / N_BANKS;          // 8
  localparam int WORD_W           = TOKENS_PER_BANK * BF16_W;   // 128 bits
  localparam int TILE_GROUPS      = MAX_SEQ_LEN / TILE_KV;      // 32 groups for 2048/64
  localparam int BANK_DEPTH       = TILE_GROUPS * HEAD_DIM;     // 4096 words / bank
  localparam int DIM_BLOCKS       = HEAD_DIM / TILE_COLS;       // 8

  // bank_mem[bank][group * HEAD_DIM + dim] -> 8 packed bf16 values
  (* ram_style = "ultra" *) logic [WORD_W-1:0] bank_mem [0:N_BANKS-1][0:BANK_DEPTH-1];
  (* ram_style = "ultra" *) logic [TILE_COLS*BF16_W-1:0] vec_mem [0:MAX_SEQ_LEN-1][0:DIM_BLOCKS-1];
  logic [WORD_W-1:0] bank_rd_word [0:N_BANKS-1];
  logic [TILE_COLS*BF16_W-1:0] vec_rd_word;

  // Address decode for scalar write
  logic [15:0] wr_token_idx;
  logic [6:0]  wr_dim_idx;
  logic [2:0]  wr_bank_idx;
  logic [2:0]  wr_slot_idx;
  logic [5:0]  wr_group_idx;
  logic [11:0] wr_word_addr;
  logic [2:0]  wr_dim_blk_idx;
  logic [3:0]  wr_dim_slot_idx;

  assign wr_token_idx = 16'(wr_addr / 16'(HEAD_DIM));
  assign wr_dim_idx   = 7'(wr_addr % 16'(HEAD_DIM));
  assign wr_bank_idx  = wr_token_idx[2:0];
  assign wr_slot_idx  = wr_token_idx[5:3];
  assign wr_group_idx = wr_token_idx[11:6];
  assign wr_word_addr = 12'(wr_group_idx * 16'(HEAD_DIM) + wr_dim_idx);
  assign wr_dim_blk_idx  = wr_dim_idx[6:4];
  assign wr_dim_slot_idx = wr_dim_idx[3:0];

  // Address decode for TILE_KV read
  logic [5:0]  rd_group_idx;
  logic [11:0] rd_word_addr;
  assign rd_group_idx = rd_token_start[11:6];
  assign rd_word_addr = 12'(rd_group_idx * 16'(HEAD_DIM) + rd_dim);

  logic [2:0] rd_vec_dim_blk_idx;
  assign rd_vec_dim_blk_idx = rd_vec_dim_start[6:4];

  integer bi, ti;

  // --------------------------------------------------------------------------
  // Write path: in-place update of one packed slot
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (wr_en) begin
      bank_mem[wr_bank_idx][wr_word_addr][wr_slot_idx*BF16_W +: BF16_W] <= wr_data;
      vec_mem[wr_token_idx][wr_dim_blk_idx][wr_dim_slot_idx*BF16_W +: BF16_W] <= wr_data;
    end
  end

  // --------------------------------------------------------------------------
  // Read path: 8 packed words -> 64 scalar outputs
  // --------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (bi = 0; bi < N_BANKS; bi++) begin
        bank_rd_word[bi] <= '0;
      end
      for (ti = 0; ti < TILE_KV; ti++) begin
        rd_data[ti] <= '0;
      end
      vec_rd_word <= '0;
      for (ti = 0; ti < TILE_COLS; ti++) begin
        rd_vec_data[ti] <= '0;
      end
    end else if (rd_en) begin
      for (bi = 0; bi < N_BANKS; bi++) begin
        bank_rd_word[bi] <= bank_mem[bi][rd_word_addr];
      end
      for (bi = 0; bi < N_BANKS; bi++) begin
        for (ti = 0; ti < TOKENS_PER_BANK; ti++) begin
          rd_data[ti * N_BANKS + bi] <= bank_mem[bi][rd_word_addr][ti*BF16_W +: BF16_W];
        end
      end
    end else if (rd_vec_en) begin
      vec_rd_word <= vec_mem[rd_vec_token_idx][rd_vec_dim_blk_idx];
      for (ti = 0; ti < TILE_COLS; ti++) begin
        rd_vec_data[ti] <= vec_mem[rd_vec_token_idx][rd_vec_dim_blk_idx][ti*BF16_W +: BF16_W];
      end
    end
  end

`ifndef SYNTHESIS
  // Current controller always reads TILE_KV-aligned starts. Keep a loud check
  // so interface misuse is caught in simulation instead of silently misreading.
  always_ff @(posedge clk) begin
    if (rd_en && (rd_token_start[5:0] != 6'd0)) begin
      $error("kv_cache_ram: rd_token_start=%0d must be TILE_KV-aligned (64)", rd_token_start);
    end
    if (rd_vec_en && (rd_vec_dim_start[3:0] != 4'd0)) begin
      $error("kv_cache_ram: rd_vec_dim_start=%0d must be 16-dim aligned", rd_vec_dim_start);
    end
  end
`endif

endmodule
