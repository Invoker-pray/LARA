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
  localparam int TILE_GROUPS      = MAX_SEQ_LEN / TILE_KV;
  localparam int BANK_DEPTH       = TILE_GROUPS * HEAD_DIM;     // 1024 words / bank for MAX_SEQ_LEN=512
  localparam int DIM_BLOCKS       = HEAD_DIM / TILE_COLS;       // 8
  localparam int WORD_ADDR_W      = clog2_safe(BANK_DEPTH);
  localparam int TOKEN_ADDR_W     = clog2_safe(MAX_SEQ_LEN);
  localparam int VEC_WORD_W       = TILE_COLS * BF16_W;

  logic [TOKEN_ADDR_W-1:0] wr_token_idx;
  logic [TOKEN_ADDR_W-1:0] wr_token_addr_idx;
  logic [6:0]              wr_dim_idx;
  logic [2:0]              wr_bank_idx;
  logic [2:0]              wr_slot_idx;
  logic [clog2_safe(TILE_GROUPS)-1:0] wr_group_idx;
  logic [WORD_ADDR_W-1:0]  wr_word_addr;
  logic [2:0]              wr_dim_blk_idx;
  logic [3:0]              wr_dim_slot_idx;

  logic [clog2_safe(TILE_GROUPS)-1:0] rd_group_idx;
  logic [WORD_ADDR_W-1:0]  rd_word_addr;

  logic [2:0]              rd_vec_dim_blk_idx;
  logic [TOKEN_ADDR_W-1:0] rd_vec_token_addr_idx;

  integer bi;
  integer ti;

  (* keep = "true" *) logic unused_scalar_read_inputs;
  (* keep = "true" *) logic unused_vector_read_inputs;

  assign wr_token_idx      = wr_addr[15:7];
  assign wr_token_addr_idx = wr_token_idx;
  assign wr_dim_idx        = wr_addr[6:0];
  assign wr_bank_idx       = wr_token_idx[2:0];
  assign wr_slot_idx       = wr_token_idx[5:3];
  assign wr_group_idx      = wr_token_idx[8:6];
  assign wr_word_addr      = {wr_group_idx, wr_dim_idx};
  assign wr_dim_blk_idx    = wr_dim_idx[6:4];
  assign wr_dim_slot_idx   = wr_dim_idx[3:0];

  assign rd_group_idx      = rd_token_start[8:6];
  assign rd_word_addr      = {rd_group_idx, rd_dim};

  assign rd_vec_dim_blk_idx    = rd_vec_dim_start[6:4];
  assign rd_vec_token_addr_idx = rd_vec_token_idx[TOKEN_ADDR_W-1:0];

  assign unused_scalar_read_inputs = &{1'b0, rd_en, |rd_token_start, |rd_dim};
  assign unused_vector_read_inputs = &{1'b0, rd_vec_en, |rd_vec_token_idx, |rd_vec_dim_start};

`ifdef KV_CACHE_USE_XPM
  function automatic logic [WORD_W-1:0] slot_word(
    input logic [2:0]        slot_idx,
    input logic [BF16_W-1:0] data
  );
    logic [WORD_W-1:0] word;
    begin
      word = '0;
      word[slot_idx*BF16_W +: BF16_W] = data;
      slot_word = word;
    end
  endfunction

  function automatic logic [VEC_WORD_W-1:0] vec_slot_word(
    input logic [3:0]        slot_idx,
    input logic [BF16_W-1:0] data
  );
    logic [VEC_WORD_W-1:0] word;
    begin
      word = '0;
      word[slot_idx*BF16_W +: BF16_W] = data;
      vec_slot_word = word;
    end
  endfunction

  function automatic logic [WORD_W/8-1:0] byte_we_for_slot(input logic [2:0] slot_idx);
    logic [WORD_W/8-1:0] we;
    begin
      we = '0;
      we[slot_idx*2 +: 2] = 2'b11;
      byte_we_for_slot = we;
    end
  endfunction

  function automatic logic [VEC_WORD_W/8-1:0] vec_byte_we_for_slot(input logic [3:0] slot_idx);
    logic [VEC_WORD_W/8-1:0] we;
    begin
      we = '0;
      we[slot_idx*2 +: 2] = 2'b11;
      vec_byte_we_for_slot = we;
    end
  endfunction

  generate
    if (TOKEN_PARALLEL_READ) begin : g_token_parallel
      logic [WORD_W-1:0] bank_din;
      logic [WORD_W-1:0] bank_dout0, bank_dout1, bank_dout2, bank_dout3;
      logic [WORD_W-1:0] bank_dout4, bank_dout5, bank_dout6, bank_dout7;
      logic [WORD_W/8-1:0] bank_we0, bank_we1, bank_we2, bank_we3;
      logic [WORD_W/8-1:0] bank_we4, bank_we5, bank_we6, bank_we7;
      logic rd_en_d;

      assign bank_din = slot_word(wr_slot_idx, wr_data);
      assign bank_we0 = (wr_en && (wr_bank_idx == 3'd0)) ? byte_we_for_slot(wr_slot_idx) : '0;
      assign bank_we1 = (wr_en && (wr_bank_idx == 3'd1)) ? byte_we_for_slot(wr_slot_idx) : '0;
      assign bank_we2 = (wr_en && (wr_bank_idx == 3'd2)) ? byte_we_for_slot(wr_slot_idx) : '0;
      assign bank_we3 = (wr_en && (wr_bank_idx == 3'd3)) ? byte_we_for_slot(wr_slot_idx) : '0;
      assign bank_we4 = (wr_en && (wr_bank_idx == 3'd4)) ? byte_we_for_slot(wr_slot_idx) : '0;
      assign bank_we5 = (wr_en && (wr_bank_idx == 3'd5)) ? byte_we_for_slot(wr_slot_idx) : '0;
      assign bank_we6 = (wr_en && (wr_bank_idx == 3'd6)) ? byte_we_for_slot(wr_slot_idx) : '0;
      assign bank_we7 = (wr_en && (wr_bank_idx == 3'd7)) ? byte_we_for_slot(wr_slot_idx) : '0;

`define XPM_TOKEN_BANK(INST, WE_SIG, DOUT_SIG) \
      xpm_memory_sdpram #( \
        .ADDR_WIDTH_A(WORD_ADDR_W), .ADDR_WIDTH_B(WORD_ADDR_W), \
        .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(8), .CASCADE_HEIGHT(0), \
        .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"), \
        .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"), \
        .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("ultra"), \
        .MEMORY_SIZE(BANK_DEPTH * WORD_W), .MESSAGE_CONTROL(0), \
        .READ_DATA_WIDTH_B(WORD_W), .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"), \
        .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0), \
        .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"), \
        .WRITE_DATA_WIDTH_A(WORD_W), .WRITE_MODE_B("read_first") \
      ) INST ( \
        .sleep(1'b0), .clka(clk), .ena(|WE_SIG), .wea(WE_SIG), .addra(wr_word_addr), .dina(bank_din), \
        .injectsbiterra(1'b0), .injectdbiterra(1'b0), .clkb(clk), .rstb(1'b0), .enb(rd_en), \
        .regceb(1'b1), .addrb(rd_word_addr), .doutb(DOUT_SIG), .sbiterrb(), .dbiterrb() \
      );

      `XPM_TOKEN_BANK(bank_mem0, bank_we0, bank_dout0)
      `XPM_TOKEN_BANK(bank_mem1, bank_we1, bank_dout1)
      `XPM_TOKEN_BANK(bank_mem2, bank_we2, bank_dout2)
      `XPM_TOKEN_BANK(bank_mem3, bank_we3, bank_dout3)
      `XPM_TOKEN_BANK(bank_mem4, bank_we4, bank_dout4)
      `XPM_TOKEN_BANK(bank_mem5, bank_we5, bank_dout5)
      `XPM_TOKEN_BANK(bank_mem6, bank_we6, bank_dout6)
      `XPM_TOKEN_BANK(bank_mem7, bank_we7, bank_dout7)
`undef XPM_TOKEN_BANK

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          rd_en_d <= 1'b0;
        end else begin
          rd_en_d <= rd_en;
        end
      end

      always_comb begin
        for (int tok = 0; tok < TILE_KV; tok++) begin
          rd_data[tok] = '0;
        end
        for (int lane = 0; lane < TILE_COLS; lane++) begin
          rd_vec_data[lane] = '0;
        end

        if (rd_en_d) begin
          for (int tok = 0; tok < TOKENS_PER_BANK; tok++) begin
            rd_data[tok * N_BANKS + 0] = bank_dout0[tok*BF16_W +: BF16_W];
            rd_data[tok * N_BANKS + 1] = bank_dout1[tok*BF16_W +: BF16_W];
            rd_data[tok * N_BANKS + 2] = bank_dout2[tok*BF16_W +: BF16_W];
            rd_data[tok * N_BANKS + 3] = bank_dout3[tok*BF16_W +: BF16_W];
            rd_data[tok * N_BANKS + 4] = bank_dout4[tok*BF16_W +: BF16_W];
            rd_data[tok * N_BANKS + 5] = bank_dout5[tok*BF16_W +: BF16_W];
            rd_data[tok * N_BANKS + 6] = bank_dout6[tok*BF16_W +: BF16_W];
            rd_data[tok * N_BANKS + 7] = bank_dout7[tok*BF16_W +: BF16_W];
          end
        end
      end
    end else begin : g_vector_parallel
      logic [VEC_WORD_W-1:0] vec_din;
      logic [VEC_WORD_W-1:0] vec_dout0, vec_dout1, vec_dout2, vec_dout3;
      logic [VEC_WORD_W-1:0] vec_dout4, vec_dout5, vec_dout6, vec_dout7;
      logic [VEC_WORD_W/8-1:0] vec_we0, vec_we1, vec_we2, vec_we3;
      logic [VEC_WORD_W/8-1:0] vec_we4, vec_we5, vec_we6, vec_we7;
      logic [VEC_WORD_W-1:0] vec_selected_word;
      logic [2:0] rd_vec_dim_blk_idx_d;

      assign vec_din = vec_slot_word(wr_dim_slot_idx, wr_data);
      assign vec_we0 = (wr_en && (wr_dim_blk_idx == 3'd0)) ? vec_byte_we_for_slot(wr_dim_slot_idx) : '0;
      assign vec_we1 = (wr_en && (wr_dim_blk_idx == 3'd1)) ? vec_byte_we_for_slot(wr_dim_slot_idx) : '0;
      assign vec_we2 = (wr_en && (wr_dim_blk_idx == 3'd2)) ? vec_byte_we_for_slot(wr_dim_slot_idx) : '0;
      assign vec_we3 = (wr_en && (wr_dim_blk_idx == 3'd3)) ? vec_byte_we_for_slot(wr_dim_slot_idx) : '0;
      assign vec_we4 = (wr_en && (wr_dim_blk_idx == 3'd4)) ? vec_byte_we_for_slot(wr_dim_slot_idx) : '0;
      assign vec_we5 = (wr_en && (wr_dim_blk_idx == 3'd5)) ? vec_byte_we_for_slot(wr_dim_slot_idx) : '0;
      assign vec_we6 = (wr_en && (wr_dim_blk_idx == 3'd6)) ? vec_byte_we_for_slot(wr_dim_slot_idx) : '0;
      assign vec_we7 = (wr_en && (wr_dim_blk_idx == 3'd7)) ? vec_byte_we_for_slot(wr_dim_slot_idx) : '0;

`define XPM_VEC_BANK(INST, WE_SIG, DOUT_SIG) \
      xpm_memory_sdpram #( \
        .ADDR_WIDTH_A(TOKEN_ADDR_W), .ADDR_WIDTH_B(TOKEN_ADDR_W), \
        .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(8), .CASCADE_HEIGHT(0), \
        .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"), \
        .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"), \
        .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("ultra"), \
        .MEMORY_SIZE(MAX_SEQ_LEN * VEC_WORD_W), .MESSAGE_CONTROL(0), \
        .READ_DATA_WIDTH_B(VEC_WORD_W), .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"), \
        .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0), \
        .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"), \
        .WRITE_DATA_WIDTH_A(VEC_WORD_W), .WRITE_MODE_B("read_first") \
      ) INST ( \
        .sleep(1'b0), .clka(clk), .ena(|WE_SIG), .wea(WE_SIG), .addra(wr_token_addr_idx), .dina(vec_din), \
        .injectsbiterra(1'b0), .injectdbiterra(1'b0), .clkb(clk), .rstb(1'b0), .enb(rd_vec_en), \
        .regceb(1'b1), .addrb(rd_vec_token_addr_idx), .doutb(DOUT_SIG), .sbiterrb(), .dbiterrb() \
      );

      `XPM_VEC_BANK(vec_mem0, vec_we0, vec_dout0)
      `XPM_VEC_BANK(vec_mem1, vec_we1, vec_dout1)
      `XPM_VEC_BANK(vec_mem2, vec_we2, vec_dout2)
      `XPM_VEC_BANK(vec_mem3, vec_we3, vec_dout3)
      `XPM_VEC_BANK(vec_mem4, vec_we4, vec_dout4)
      `XPM_VEC_BANK(vec_mem5, vec_we5, vec_dout5)
      `XPM_VEC_BANK(vec_mem6, vec_we6, vec_dout6)
      `XPM_VEC_BANK(vec_mem7, vec_we7, vec_dout7)
`undef XPM_VEC_BANK

      always_comb begin
        vec_selected_word = '0;
        unique case (rd_vec_dim_blk_idx_d)
          3'd0: vec_selected_word = vec_dout0;
          3'd1: vec_selected_word = vec_dout1;
          3'd2: vec_selected_word = vec_dout2;
          3'd3: vec_selected_word = vec_dout3;
          3'd4: vec_selected_word = vec_dout4;
          3'd5: vec_selected_word = vec_dout5;
          3'd6: vec_selected_word = vec_dout6;
          default: vec_selected_word = vec_dout7;
        endcase
      end

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          rd_vec_dim_blk_idx_d <= 3'd0;
        end else begin
          rd_vec_dim_blk_idx_d <= rd_vec_dim_blk_idx;
        end
      end

      always_comb begin
        for (int tok = 0; tok < TILE_KV; tok++) begin
          rd_data[tok] = '0;
        end
        for (int lane = 0; lane < TILE_COLS; lane++) begin
          rd_vec_data[lane] = '0;
        end

        // The controller prefetches V once and consumes it across both MAC
        // split phases. XPM read data retains its last value when enb=0,
        // matching the behavioral memory path; do not clear the vector in
        // the cycles between prefetches.
        for (int lane = 0; lane < TILE_COLS; lane++) begin
          rd_vec_data[lane] = vec_selected_word[lane*BF16_W +: BF16_W];
        end
      end
    end
  endgenerate
`else
  function automatic logic [WORD_W-1:0] update_bank_word(
    input logic [WORD_W-1:0] current_word,
    input logic [2:0]        slot_idx,
    input logic [BF16_W-1:0] data
  );
    logic [WORD_W-1:0] next_word;
    begin
      next_word = current_word;
      next_word[slot_idx*BF16_W +: BF16_W] = data;
      update_bank_word = next_word;
    end
  endfunction

  function automatic logic [VEC_WORD_W-1:0] update_vec_word(
    input logic [VEC_WORD_W-1:0] current_word,
    input logic [3:0]            slot_idx,
    input logic [BF16_W-1:0]     data
  );
    logic [VEC_WORD_W-1:0] next_word;
    begin
      next_word = current_word;
      next_word[slot_idx*BF16_W +: BF16_W] = data;
      update_vec_word = next_word;
    end
  endfunction

  generate
    if (TOKEN_PARALLEL_READ) begin : g_token_parallel_behav
      (* ram_style = "ultra" *) logic [WORD_W-1:0] bank_mem0 [0:BANK_DEPTH-1];
      (* ram_style = "ultra" *) logic [WORD_W-1:0] bank_mem1 [0:BANK_DEPTH-1];
      (* ram_style = "ultra" *) logic [WORD_W-1:0] bank_mem2 [0:BANK_DEPTH-1];
      (* ram_style = "ultra" *) logic [WORD_W-1:0] bank_mem3 [0:BANK_DEPTH-1];
      (* ram_style = "ultra" *) logic [WORD_W-1:0] bank_mem4 [0:BANK_DEPTH-1];
      (* ram_style = "ultra" *) logic [WORD_W-1:0] bank_mem5 [0:BANK_DEPTH-1];
      (* ram_style = "ultra" *) logic [WORD_W-1:0] bank_mem6 [0:BANK_DEPTH-1];
      (* ram_style = "ultra" *) logic [WORD_W-1:0] bank_mem7 [0:BANK_DEPTH-1];

      always_ff @(posedge clk) begin
        if (wr_en) begin
          unique case (wr_bank_idx)
            3'd0: bank_mem0[wr_word_addr] <= update_bank_word(bank_mem0[wr_word_addr], wr_slot_idx, wr_data);
            3'd1: bank_mem1[wr_word_addr] <= update_bank_word(bank_mem1[wr_word_addr], wr_slot_idx, wr_data);
            3'd2: bank_mem2[wr_word_addr] <= update_bank_word(bank_mem2[wr_word_addr], wr_slot_idx, wr_data);
            3'd3: bank_mem3[wr_word_addr] <= update_bank_word(bank_mem3[wr_word_addr], wr_slot_idx, wr_data);
            3'd4: bank_mem4[wr_word_addr] <= update_bank_word(bank_mem4[wr_word_addr], wr_slot_idx, wr_data);
            3'd5: bank_mem5[wr_word_addr] <= update_bank_word(bank_mem5[wr_word_addr], wr_slot_idx, wr_data);
            3'd6: bank_mem6[wr_word_addr] <= update_bank_word(bank_mem6[wr_word_addr], wr_slot_idx, wr_data);
            default: bank_mem7[wr_word_addr] <= update_bank_word(bank_mem7[wr_word_addr], wr_slot_idx, wr_data);
          endcase
        end
      end

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          for (ti = 0; ti < TILE_KV; ti++) begin
            rd_data[ti] <= '0;
          end
          for (ti = 0; ti < TILE_COLS; ti++) begin
            rd_vec_data[ti] <= '0;
          end
        end else if (rd_en) begin
          for (bi = 0; bi < N_BANKS; bi++) begin
            for (ti = 0; ti < TOKENS_PER_BANK; ti++) begin
              unique case (bi)
                0: rd_data[ti * N_BANKS + bi] <= bank_mem0[rd_word_addr][ti*BF16_W +: BF16_W];
                1: rd_data[ti * N_BANKS + bi] <= bank_mem1[rd_word_addr][ti*BF16_W +: BF16_W];
                2: rd_data[ti * N_BANKS + bi] <= bank_mem2[rd_word_addr][ti*BF16_W +: BF16_W];
                3: rd_data[ti * N_BANKS + bi] <= bank_mem3[rd_word_addr][ti*BF16_W +: BF16_W];
                4: rd_data[ti * N_BANKS + bi] <= bank_mem4[rd_word_addr][ti*BF16_W +: BF16_W];
                5: rd_data[ti * N_BANKS + bi] <= bank_mem5[rd_word_addr][ti*BF16_W +: BF16_W];
                6: rd_data[ti * N_BANKS + bi] <= bank_mem6[rd_word_addr][ti*BF16_W +: BF16_W];
                default: rd_data[ti * N_BANKS + bi] <= bank_mem7[rd_word_addr][ti*BF16_W +: BF16_W];
              endcase
            end
          end
        end else if (rd_vec_en) begin
          for (ti = 0; ti < TILE_COLS; ti++) begin
            rd_vec_data[ti] <= '0;
          end
        end
      end
    end else begin : g_vector_parallel_behav
      (* ram_style = "ultra" *) logic [VEC_WORD_W-1:0] vec_mem0 [0:MAX_SEQ_LEN-1];
      (* ram_style = "ultra" *) logic [VEC_WORD_W-1:0] vec_mem1 [0:MAX_SEQ_LEN-1];
      (* ram_style = "ultra" *) logic [VEC_WORD_W-1:0] vec_mem2 [0:MAX_SEQ_LEN-1];
      (* ram_style = "ultra" *) logic [VEC_WORD_W-1:0] vec_mem3 [0:MAX_SEQ_LEN-1];
      (* ram_style = "ultra" *) logic [VEC_WORD_W-1:0] vec_mem4 [0:MAX_SEQ_LEN-1];
      (* ram_style = "ultra" *) logic [VEC_WORD_W-1:0] vec_mem5 [0:MAX_SEQ_LEN-1];
      (* ram_style = "ultra" *) logic [VEC_WORD_W-1:0] vec_mem6 [0:MAX_SEQ_LEN-1];
      (* ram_style = "ultra" *) logic [VEC_WORD_W-1:0] vec_mem7 [0:MAX_SEQ_LEN-1];

      always_ff @(posedge clk) begin
        if (wr_en) begin
          unique case (wr_dim_blk_idx)
            3'd0: vec_mem0[wr_token_addr_idx] <= update_vec_word(vec_mem0[wr_token_addr_idx], wr_dim_slot_idx, wr_data);
            3'd1: vec_mem1[wr_token_addr_idx] <= update_vec_word(vec_mem1[wr_token_addr_idx], wr_dim_slot_idx, wr_data);
            3'd2: vec_mem2[wr_token_addr_idx] <= update_vec_word(vec_mem2[wr_token_addr_idx], wr_dim_slot_idx, wr_data);
            3'd3: vec_mem3[wr_token_addr_idx] <= update_vec_word(vec_mem3[wr_token_addr_idx], wr_dim_slot_idx, wr_data);
            3'd4: vec_mem4[wr_token_addr_idx] <= update_vec_word(vec_mem4[wr_token_addr_idx], wr_dim_slot_idx, wr_data);
            3'd5: vec_mem5[wr_token_addr_idx] <= update_vec_word(vec_mem5[wr_token_addr_idx], wr_dim_slot_idx, wr_data);
            3'd6: vec_mem6[wr_token_addr_idx] <= update_vec_word(vec_mem6[wr_token_addr_idx], wr_dim_slot_idx, wr_data);
            default: vec_mem7[wr_token_addr_idx] <= update_vec_word(vec_mem7[wr_token_addr_idx], wr_dim_slot_idx, wr_data);
          endcase
        end
      end

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          for (ti = 0; ti < TILE_KV; ti++) begin
            rd_data[ti] <= '0;
          end
          for (ti = 0; ti < TILE_COLS; ti++) begin
            rd_vec_data[ti] <= '0;
          end
        end else if (rd_vec_en) begin
          for (ti = 0; ti < TILE_COLS; ti++) begin
            unique case (rd_vec_dim_blk_idx)
              3'd0: rd_vec_data[ti] <= vec_mem0[rd_vec_token_addr_idx][ti*BF16_W +: BF16_W];
              3'd1: rd_vec_data[ti] <= vec_mem1[rd_vec_token_addr_idx][ti*BF16_W +: BF16_W];
              3'd2: rd_vec_data[ti] <= vec_mem2[rd_vec_token_addr_idx][ti*BF16_W +: BF16_W];
              3'd3: rd_vec_data[ti] <= vec_mem3[rd_vec_token_addr_idx][ti*BF16_W +: BF16_W];
              3'd4: rd_vec_data[ti] <= vec_mem4[rd_vec_token_addr_idx][ti*BF16_W +: BF16_W];
              3'd5: rd_vec_data[ti] <= vec_mem5[rd_vec_token_addr_idx][ti*BF16_W +: BF16_W];
              3'd6: rd_vec_data[ti] <= vec_mem6[rd_vec_token_addr_idx][ti*BF16_W +: BF16_W];
              default: rd_vec_data[ti] <= vec_mem7[rd_vec_token_addr_idx][ti*BF16_W +: BF16_W];
            endcase
          end
        end else if (rd_en) begin
          for (ti = 0; ti < TILE_KV; ti++) begin
            rd_data[ti] <= '0;
          end
        end
      end
    end
  endgenerate
`endif

`ifndef SYNTHESIS
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
