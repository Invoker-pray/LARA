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
    output logic                       acc_ready,
    input  logic [clog2_safe(TILE_ROWS)-1:0] acc_row, // row index (0..TILE_ROWS-1)
    input  logic [2:0]                 acc_dim_blk,   // which 16-dim chunk inside HEAD_DIM
    input  logic [FP32_W-1:0]          acc_data [TILE_COLS],  // ΔO row contribution chunk
    input  logic [FP32_W-1:0]          acc_correction,        // correction for acc_row

    // Bank select (0=compute bank0/normalize bank1, 1=swap)
    input  logic                       bank_sel,

    // Normalization control
    input  logic                       normalize,     // pulse: perform O = O_acc / l
    input  logic [4:0]                 active_rows,   // valid rows to emit for this microtile
    input  logic [FP32_W-1:0]          l_state [TILE_ROWS],  // softmax denominators

    // Output stream (to DDR via AXIS)
    input  logic                       o_ready,
    output logic                       o_valid,
    output logic [4:0]                 o_row,
    output logic [6:0]                 o_dim,
    output logic [BF16_W-1:0]          o_data
);

  localparam int CHUNK_W = TILE_COLS * FP32_W;
  localparam int DIM_BLOCKS = HEAD_DIM / TILE_COLS;
  localparam int O_CHUNK_DEPTH = TILE_ROWS * DIM_BLOCKS;
  localparam int O_CHUNK_ADDR_W = clog2_safe(O_CHUNK_DEPTH);
  localparam int CHUNK_BYTE_LANES = CHUNK_W / 8;
  localparam logic [6:0] HEAD_DIM_LAST_U7 = 7'(HEAD_DIM - 1);

`ifndef SYNTHESIS
  localparam shortreal ZERO_SR = 0.0;
  /* verilator lint_off SHORTREAL */
  /* verilator lint_off WIDTHEXPAND */
  /* verilator lint_off WIDTHTRUNC */
  shortreal norm_val, norm_l, norm_result;
  /* verilator lint_on WIDTHTRUNC */
  /* verilator lint_on WIDTHEXPAND */
  /* verilator lint_on SHORTREAL */
`endif

`ifndef USE_XPM_MEMORY
  (* ram_style = "block" *) logic [CHUNK_W-1:0] o_acc0_chunk [0:O_CHUNK_DEPTH-1];
  (* ram_style = "block" *) logic [CHUNK_W-1:0] o_acc1_chunk [0:O_CHUNK_DEPTH-1];
`endif
  logic o_acc0_tag [0:O_CHUNK_DEPTH-1];
  logic o_acc1_tag [0:O_CHUNK_DEPTH-1];
  logic o_acc0_epoch;
  logic o_acc1_epoch;

  logic [clog2_safe(TILE_ROWS)-1:0] acc_row_idx;
  logic [O_CHUNK_ADDR_W-1:0] acc_chunk_addr;
  logic [clog2_safe(TILE_ROWS)-1:0] norm_row_idx;
  logic [2:0] norm_dim_blk_idx;
  logic [3:0] norm_dim_lane_idx;
  logic [O_CHUNK_ADDR_W-1:0] norm_chunk_addr;

  logic        norm_active;
  logic [4:0]  norm_row;
  logic [6:0]  norm_dim;
  logic [4:0]  norm_active_rows;

  logic [FP32_W-1:0] norm_result_bits;
  logic [FP32_W-1:0] norm_pipe_source_bits;
  logic [FP32_W-1:0] norm_pipe_l_bits;
  logic              norm_pipe_valid;
  logic [4:0]        norm_pipe_row;
  logic [6:0]        norm_pipe_dim;

  assign acc_row_idx = acc_row;
  assign acc_chunk_addr = {acc_row, acc_dim_blk};
  assign norm_row_idx = norm_row[clog2_safe(TILE_ROWS)-1:0];
  assign norm_dim_blk_idx = norm_dim[6:4];
  assign norm_dim_lane_idx = norm_dim[3:0];
  assign norm_chunk_addr = {norm_row_idx, norm_dim_blk_idx};

  function automatic logic [CHUNK_W-1:0] chunk_or_zero(
    input logic [CHUNK_W-1:0] stored_word,
    input logic               stored_tag,
    input logic               active_epoch
  );
    begin
      if (stored_tag == active_epoch)
        chunk_or_zero = stored_word;
      else
        chunk_or_zero = '0;
    end
  endfunction

`ifndef SYNTHESIS
  function automatic logic [CHUNK_W-1:0] accumulate_chunk_word(
    input logic [CHUNK_W-1:0] old_word,
    input logic [FP32_W-1:0]  corr_bits,
    input logic [FP32_W-1:0]  delta_word [TILE_COLS]
  );
    /* verilator lint_off WIDTHEXPAND */
    /* verilator lint_off WIDTHTRUNC */
    shortreal corr_sr;
    shortreal old_sr;
    shortreal delta_sr;
    logic [CHUNK_W-1:0] next_word;
    begin
      corr_sr = $bitstoshortreal(corr_bits);
      next_word = old_word;
      for (int lane = 0; lane < TILE_COLS; lane++) begin
        old_sr = $bitstoshortreal(old_word[lane * FP32_W +: FP32_W]);
        delta_sr = $bitstoshortreal(delta_word[lane]);
        next_word[lane * FP32_W +: FP32_W] = $shortrealtobits(old_sr * corr_sr + delta_sr);
      end
      accumulate_chunk_word = next_word;
    end
    /* verilator lint_on WIDTHTRUNC */
    /* verilator lint_on WIDTHEXPAND */
  endfunction

  /* verilator lint_off WIDTHEXPAND */
  /* verilator lint_off WIDTHTRUNC */
  function automatic logic [CHUNK_W-1:0] multiply_chunk_word(
    input logic [CHUNK_W-1:0] old_word,
    input logic [FP32_W-1:0]  corr_bits
  );
    shortreal corr_sr;
    shortreal old_sr;
    logic [CHUNK_W-1:0] product_word;
    begin
      corr_sr = $bitstoshortreal(corr_bits);
      for (int lane = 0; lane < TILE_COLS; lane++) begin
        old_sr = $bitstoshortreal(old_word[lane * FP32_W +: FP32_W]);
        product_word[lane * FP32_W +: FP32_W] = $shortrealtobits(old_sr * corr_sr);
      end
      multiply_chunk_word = product_word;
    end
  endfunction

  function automatic logic [CHUNK_W-1:0] add_chunk_word(
    input logic [CHUNK_W-1:0] product_word,
    input logic [FP32_W-1:0]  delta_word [TILE_COLS]
  );
    shortreal product_sr;
    shortreal delta_sr;
    logic [CHUNK_W-1:0] sum_word;
    begin
      for (int lane = 0; lane < TILE_COLS; lane++) begin
        product_sr = $bitstoshortreal(product_word[lane * FP32_W +: FP32_W]);
        delta_sr = $bitstoshortreal(delta_word[lane]);
        sum_word[lane * FP32_W +: FP32_W] = $shortrealtobits(product_sr + delta_sr);
      end
      add_chunk_word = sum_word;
    end
  endfunction
  /* verilator lint_on WIDTHTRUNC */
  /* verilator lint_on WIDTHEXPAND */

  function automatic logic [FP32_W-1:0] normalize_fp32_bits(
    input logic [FP32_W-1:0] src_bits,
    input logic [FP32_W-1:0] l_bits
  );
    /* verilator lint_off WIDTHEXPAND */
    /* verilator lint_off WIDTHTRUNC */
    begin
      norm_val = $bitstoshortreal(src_bits);
      norm_l = $bitstoshortreal(l_bits);
      if (norm_l != ZERO_SR)
        norm_result = norm_val / norm_l;
      else
        norm_result = ZERO_SR;
      normalize_fp32_bits = $shortrealtobits(norm_result);
    end
    /* verilator lint_on WIDTHTRUNC */
    /* verilator lint_on WIDTHEXPAND */
  endfunction
`else
  localparam int RECIP_LUT_DEPTH = 256;
  (* rom_style = "distributed" *) logic [22:0] recip_mant_lut [0:RECIP_LUT_DEPTH-1];

  initial begin
    $readmemh("recip_lut.hex", recip_mant_lut);
  end

  function automatic logic [FP32_W-1:0] recip_lut_bits(
    input logic [FP32_W-1:0] value_bits
  );
    logic [7:0] exp_value;
    logic [22:0] frac_value;
    logic [7:0] exp_recip;
    begin
      exp_value = value_bits[30:23];
      frac_value = value_bits[22:0];
      if (fp32_is_nan(value_bits)) begin
        recip_lut_bits = 32'h7FC0_0000;
      end else if (fp32_is_zero(value_bits)) begin
        recip_lut_bits = {value_bits[31], 8'hFF, 23'd0};
      end else if (fp32_is_inf(value_bits)) begin
        recip_lut_bits = {value_bits[31], 31'd0};
      end else if (frac_value == 23'd0) begin
        exp_recip = 8'd254 - exp_value;
        recip_lut_bits = {value_bits[31], exp_recip, 23'd0};
      end else begin
        exp_recip = 8'd253 - exp_value;
        recip_lut_bits = {
          value_bits[31], exp_recip, recip_mant_lut[frac_value[22:15]]
        };
      end
    end
  endfunction

  function automatic logic [CHUNK_W-1:0] accumulate_chunk_word(
    input logic [CHUNK_W-1:0] old_word,
    input logic [FP32_W-1:0]  corr_bits,
    input logic [FP32_W-1:0]  delta_word [TILE_COLS]
  );
    logic [CHUNK_W-1:0] next_word;
    begin
      next_word = old_word;
      for (int lane = 0; lane < TILE_COLS; lane++) begin
        next_word[lane * FP32_W +: FP32_W] =
          fp32_add(fp32_mul(old_word[lane * FP32_W +: FP32_W], corr_bits),
                   delta_word[lane]);
      end
      accumulate_chunk_word = next_word;
    end
  endfunction

  function automatic logic [CHUNK_W-1:0] multiply_chunk_word(
    input logic [CHUNK_W-1:0] old_word,
    input logic [FP32_W-1:0]  corr_bits
  );
    logic [CHUNK_W-1:0] product_word;
    begin
      for (int lane = 0; lane < TILE_COLS; lane++) begin
        product_word[lane * FP32_W +: FP32_W] =
          fp32_mul(old_word[lane * FP32_W +: FP32_W], corr_bits);
      end
      multiply_chunk_word = product_word;
    end
  endfunction

  function automatic logic [CHUNK_W-1:0] add_chunk_word(
    input logic [CHUNK_W-1:0] product_word,
    input logic [FP32_W-1:0]  delta_word [TILE_COLS]
  );
    logic [CHUNK_W-1:0] sum_word;
    begin
      for (int lane = 0; lane < TILE_COLS; lane++) begin
        sum_word[lane * FP32_W +: FP32_W] =
          fp32_add(product_word[lane * FP32_W +: FP32_W], delta_word[lane]);
      end
      add_chunk_word = sum_word;
    end
  endfunction

  function automatic logic [FP32_W-1:0] normalize_fp32_bits(
    input logic [FP32_W-1:0] src_bits,
    input logic [FP32_W-1:0] l_bits
  );
    begin
      if (fp32_is_zero(l_bits))
        normalize_fp32_bits = 32'd0;
`ifdef LARA_OUTPUT_BUFFER_EXACT_DIV
      else
        normalize_fp32_bits = fp32_div(src_bits, l_bits);
`else
      else
        normalize_fp32_bits = fp32_mul(src_bits, recip_lut_bits(l_bits));
`endif
    end
  endfunction
`endif

  function automatic logic [CHUNK_BYTE_LANES-1:0] chunk_byte_we(input logic wr_fire);
    begin
      chunk_byte_we = wr_fire ? {CHUNK_BYTE_LANES{1'b1}} : '0;
    end
  endfunction

  integer ar;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      o_acc0_epoch <= 1'b0;
      o_acc1_epoch <= 1'b0;
`ifndef USE_XPM_MEMORY
      for (ar = 0; ar < O_CHUNK_DEPTH; ar++) begin
        o_acc0_tag[ar] <= 1'b0;
        o_acc1_tag[ar] <= 1'b0;
      end
`endif
    end else if (clear_bank) begin
      if (!clear_bank_sel)
        o_acc0_epoch <= ~o_acc0_epoch;
      else
        o_acc1_epoch <= ~o_acc1_epoch;
`ifndef USE_XPM_MEMORY
    end else if (acc_update) begin
      if (!bank_sel)
        o_acc0_tag[acc_chunk_addr] <= o_acc0_epoch;
      else
        o_acc1_tag[acc_chunk_addr] <= o_acc1_epoch;
`endif
    end
  end

`ifdef USE_XPM_MEMORY
  logic [CHUNK_W-1:0] o_acc0_rd_word;
  logic [CHUNK_W-1:0] o_acc1_rd_word;
  logic [CHUNK_BYTE_LANES-1:0] o_acc0_web;
  logic [CHUNK_BYTE_LANES-1:0] o_acc1_web;
  logic                        o_acc0_rd_en;
  logic                        o_acc1_rd_en;
  logic [O_CHUNK_ADDR_W-1:0]   o_acc0_rd_addr;
  logic [O_CHUNK_ADDR_W-1:0]   o_acc1_rd_addr;
  logic                        o_acc0_wr_en;
  logic                        o_acc1_wr_en;
  logic [O_CHUNK_ADDR_W-1:0]   o_acc0_wr_addr;
  logic [O_CHUNK_ADDR_W-1:0]   o_acc1_wr_addr;
  logic [CHUNK_W-1:0]          o_acc0_wr_data;
  logic [CHUNK_W-1:0]          o_acc1_wr_data;

  logic                        acc_mem_pending_valid;
  logic                        acc_mem_pending_bank_sel;
  logic [O_CHUNK_ADDR_W-1:0]   acc_mem_pending_addr;
  logic [FP32_W-1:0]           acc_mem_pending_corr;
  logic [CHUNK_W-1:0]          acc_mem_pending_word;
  logic [CHUNK_W-1:0]          acc_mem_pending_product_word;
  logic [FP32_W-1:0]           acc_mem_pending_data [TILE_COLS];

  logic                        acc_mem_issue_valid;
  logic                        acc_mem_issue_bank_sel;
  logic [O_CHUNK_ADDR_W-1:0]   acc_mem_issue_addr;
  logic [FP32_W-1:0]           acc_mem_issue_corr;
  logic                        acc_mem_issue_use_bypass;
  logic                        acc_mem_issue_bypass_from_pending;
  logic                        acc_mem_issue_bypass_from_return;
  logic [CHUNK_W-1:0]          acc_mem_issue_bypass_word;
  logic [FP32_W-1:0]           acc_mem_issue_data [TILE_COLS];

  logic                        acc_mem_return_valid;
  logic                        acc_mem_return_bank_sel;
  logic [O_CHUNK_ADDR_W-1:0]   acc_mem_return_addr;
  logic [FP32_W-1:0]           acc_mem_return_corr;
  logic [FP32_W-1:0]           acc_mem_return_data [TILE_COLS];
  logic [CHUNK_W-1:0]          acc_mem_return_word;

  logic                        norm_issue_fire;
  logic                        norm_active_now;
  logic [4:0]                  norm_row_now;
  logic [6:0]                  norm_dim_now;
  logic [4:0]                  norm_active_rows_now;
  logic [clog2_safe(TILE_ROWS)-1:0] norm_row_idx_now;
  logic [2:0]                  norm_dim_blk_idx_now;
  logic [3:0]                  norm_dim_lane_idx_now;
  logic [O_CHUNK_ADDR_W-1:0]   norm_chunk_addr_now;
  logic                        norm_issue_bank_sel;
  logic [O_CHUNK_ADDR_W-1:0]   norm_issue_addr;
  logic [4:0]                  norm_issue_row;
  logic [6:0]                  norm_issue_dim;
  logic [3:0]                  norm_issue_lane;
  logic [FP32_W-1:0]           norm_issue_l_bits;

  logic                        norm_mem_pending_valid;
  logic                        norm_mem_pending_bank_sel;
  logic [O_CHUNK_ADDR_W-1:0]   norm_mem_pending_addr;
  logic [4:0]                  norm_mem_pending_row;
  logic [6:0]                  norm_mem_pending_dim;
  logic [3:0]                  norm_mem_pending_lane;
  logic [FP32_W-1:0]           norm_mem_pending_l_bits;
  logic [CHUNK_W-1:0]          norm_mem_pending_word;

  logic                        norm_mem_issue_valid;
  logic                        norm_mem_issue_bank_sel;
  logic [O_CHUNK_ADDR_W-1:0]   norm_mem_issue_addr;
  logic [4:0]                  norm_mem_issue_row;
  logic [6:0]                  norm_mem_issue_dim;
  logic [3:0]                  norm_mem_issue_lane;
  logic [FP32_W-1:0]           norm_mem_issue_l_bits;
  logic                        norm_mem_issue_use_bypass;
  logic [CHUNK_W-1:0]          norm_mem_issue_bypass_word;

  logic                        norm_mem_return_valid;
  logic                        norm_mem_return_bank_sel;
  logic [O_CHUNK_ADDR_W-1:0]   norm_mem_return_addr;
  logic [4:0]                  norm_mem_return_row;
  logic [6:0]                  norm_mem_return_dim;
  logic [3:0]                  norm_mem_return_lane;
  logic [FP32_W-1:0]           norm_mem_return_l_bits;

  logic                        norm_resp_valid;
  logic [FP32_W-1:0]           norm_resp_source_bits;
  logic [FP32_W-1:0]           norm_resp_l_bits;
  logic [4:0]                  norm_resp_row;
  logic [6:0]                  norm_resp_dim;
  logic                        norm_resp_advance;
  logic                        norm_resp_wait_valid;
  logic [O_CHUNK_ADDR_W-1:0]   norm_resp_wait_addr;
  logic                        norm_resp_wait_bank_sel;
  logic [4:0]                  norm_resp_wait_row;
  logic [6:0]                  norm_resp_wait_dim;
  logic [3:0]                  norm_resp_wait_lane;
  logic [FP32_W-1:0]           norm_resp_wait_l_bits;

  logic                        acc_fire;
  logic                        acc_issue_bypass_hit;
  logic                        acc_issue_pending_hit;
  logic                        acc_issue_return_hit;
  logic [CHUNK_W-1:0]          acc_pending_write_word_now;
  logic [CHUNK_W-1:0]          acc_issue_base_word;
  logic [CHUNK_W-1:0]          acc_issue_product_word;
  logic [CHUNK_W-1:0]          acc_mem_return_write_word;
  logic                        norm_issue_pending_hit;
  logic                        norm_issue_return_hit;
  logic                        norm_resp_pending_hit;
  logic                        norm_resp_return_hit;
  logic [CHUNK_W-1:0]          norm_resp_word_now;
  logic [CHUNK_W-1:0]          acc_read_word_now;
  logic [CHUNK_W-1:0]          norm_return_word;
  logic [CHUNK_W-1:0]          acc_issue_resolved_base_word;

  assign norm_active_now = normalize ? (active_rows != 5'd0) : norm_active;
  assign norm_row_now = normalize ? 5'd0 : norm_row;
  assign norm_dim_now = normalize ? 7'd0 : norm_dim;
  assign norm_active_rows_now = normalize ? active_rows : norm_active_rows;
  assign norm_row_idx_now = norm_row_now[clog2_safe(TILE_ROWS)-1:0];
  assign norm_dim_blk_idx_now = norm_dim_now[6:4];
  assign norm_dim_lane_idx_now = norm_dim_now[3:0];
  assign norm_chunk_addr_now = {norm_row_idx_now, norm_dim_blk_idx_now};
  assign norm_issue_bank_sel = ~bank_sel;
  assign norm_issue_addr = norm_chunk_addr_now;
  assign norm_issue_row = norm_row_now;
  assign norm_issue_dim = norm_dim_now;
  assign norm_issue_lane = norm_dim_lane_idx_now;
  assign norm_issue_l_bits = l_state[norm_row_idx_now];
  assign norm_resp_advance = norm_resp_valid && (!norm_pipe_valid || o_ready);
  // Keep the multiply and add in separate registered stages.  Combining them
  // here creates a full 16-lane FP32 multiply+add path in one cycle.
  assign acc_pending_write_word_now = add_chunk_word(
    acc_mem_pending_product_word,
    acc_mem_pending_data
  );
  assign acc_issue_resolved_base_word = acc_mem_issue_bypass_from_pending ? acc_pending_write_word_now :
                                        acc_mem_issue_bypass_from_return  ? acc_mem_return_write_word :
                                                                            acc_read_word_now;
  assign acc_issue_base_word = acc_mem_issue_use_bypass ? acc_mem_issue_bypass_word : acc_read_word_now;
  assign acc_issue_product_word = multiply_chunk_word(
    acc_issue_base_word,
    acc_mem_issue_corr
  );
  assign acc_issue_pending_hit = acc_update &&
                                 acc_mem_pending_valid &&
                                 (bank_sel == acc_mem_pending_bank_sel) &&
                                 (acc_chunk_addr == acc_mem_pending_addr);
  assign acc_issue_return_hit = acc_update &&
                                acc_mem_return_valid &&
                                (bank_sel == acc_mem_return_bank_sel) &&
                                (acc_chunk_addr == acc_mem_return_addr);
  assign acc_issue_bypass_hit = acc_issue_pending_hit || acc_issue_return_hit;
  assign norm_issue_pending_hit = norm_issue_fire &&
                                  acc_mem_pending_valid &&
                                  (norm_issue_bank_sel == acc_mem_pending_bank_sel) &&
                                  (norm_issue_addr == acc_mem_pending_addr);
  assign norm_issue_return_hit = norm_issue_fire &&
                                 acc_mem_return_valid &&
                                 (norm_issue_bank_sel == acc_mem_return_bank_sel) &&
                                 (norm_issue_addr == acc_mem_return_addr);
  assign norm_resp_pending_hit = norm_mem_return_valid &&
                                 acc_mem_pending_valid &&
                                 (norm_mem_return_bank_sel == acc_mem_pending_bank_sel) &&
                                 (norm_mem_return_addr == acc_mem_pending_addr);
  assign norm_resp_return_hit = norm_mem_return_valid &&
                                acc_mem_return_valid &&
                                (norm_mem_return_bank_sel == acc_mem_return_bank_sel) &&
                                (norm_mem_return_addr == acc_mem_return_addr);
  // Avoid feeding the long pending-update path directly into the response
  // capture.  If normalize lands on a chunk that is still pending, wait until
  // that update becomes the committed return on the next cycle.
  assign norm_resp_word_now = norm_resp_return_hit ? acc_mem_return_write_word :
                                                     norm_mem_pending_word;
  assign norm_issue_fire = norm_active_now &&
                           !acc_update &&
                           !acc_mem_issue_valid &&
                           !acc_mem_pending_valid &&
                           !acc_mem_return_valid &&
                           !norm_mem_issue_valid &&
                           !norm_mem_pending_valid &&
                           (!norm_resp_valid || norm_resp_advance) &&
                           !norm_resp_wait_valid;

  always_comb begin
    o_acc0_rd_en = 1'b0;
    o_acc0_rd_addr = '0;
    o_acc1_rd_en = 1'b0;
    o_acc1_rd_addr = '0;

    if (acc_update && !acc_issue_bypass_hit) begin
      if (!bank_sel) begin
        o_acc0_rd_en = 1'b1;
        o_acc0_rd_addr = acc_chunk_addr;
      end else begin
        o_acc1_rd_en = 1'b1;
        o_acc1_rd_addr = acc_chunk_addr;
      end
    end

    if (norm_issue_fire) begin
      if (norm_issue_bank_sel) begin
        o_acc1_rd_en = 1'b1;
        o_acc1_rd_addr = norm_issue_addr;
      end else begin
        o_acc0_rd_en = 1'b1;
        o_acc0_rd_addr = norm_issue_addr;
      end
    end
  end

  // XPM read data corresponds to the address issued in the immediately
  // preceding cycle.  `acc_mem_pending_*` describes the older request that
  // is being retired this cycle, so using it here can apply the returned word
  // to the wrong bank/address once rows or microtiles advance.  Resolve the
  // read with the issue tag, matching the normalization path below.
  assign acc_read_word_now = acc_mem_issue_bank_sel
                           ? chunk_or_zero(o_acc1_rd_word, o_acc1_tag[acc_mem_issue_addr], o_acc1_epoch)
                           : chunk_or_zero(o_acc0_rd_word, o_acc0_tag[acc_mem_issue_addr], o_acc0_epoch);
  // XPM read data corresponds to the address issued in the immediately
  // preceding cycle.  `norm_mem_return_*` is already one pipeline stage
  // older, so using it here mislabels the returned chunk and produces periodic
  // zero lanes in the synthesized/XPM path.
  assign norm_return_word = norm_mem_issue_bank_sel
                          ? chunk_or_zero(o_acc1_rd_word, o_acc1_tag[norm_mem_issue_addr], o_acc1_epoch)
                          : chunk_or_zero(o_acc0_rd_word, o_acc0_tag[norm_mem_issue_addr], o_acc0_epoch);

  assign acc_ready = 1'b1;
  assign o_acc0_wr_en = acc_mem_return_valid && !acc_mem_return_bank_sel;
  assign o_acc1_wr_en = acc_mem_return_valid &&  acc_mem_return_bank_sel;
  assign o_acc0_wr_addr = acc_mem_return_addr;
  assign o_acc1_wr_addr = acc_mem_return_addr;
  assign o_acc0_wr_data = acc_mem_return_write_word;
  assign o_acc1_wr_data = acc_mem_return_write_word;
  assign o_acc0_web = chunk_byte_we(o_acc0_wr_en);
  assign o_acc1_web = chunk_byte_we(o_acc1_wr_en);

  xpm_memory_tdpram #(
    .ADDR_WIDTH_A(O_CHUNK_ADDR_W), .ADDR_WIDTH_B(O_CHUNK_ADDR_W),
    .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(8), .BYTE_WRITE_WIDTH_B(8),
    .CASCADE_HEIGHT(0), .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
    .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
    .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
    .MEMORY_SIZE(O_CHUNK_DEPTH * CHUNK_W), .MESSAGE_CONTROL(0),
    .READ_DATA_WIDTH_A(CHUNK_W), .READ_DATA_WIDTH_B(CHUNK_W),
    .READ_LATENCY_A(1), .READ_LATENCY_B(1),
    .READ_RESET_VALUE_A("0"), .READ_RESET_VALUE_B("0"),
    .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
    .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"),
    .WRITE_DATA_WIDTH_A(CHUNK_W), .WRITE_DATA_WIDTH_B(CHUNK_W),
    .WRITE_MODE_A("no_change"), .WRITE_MODE_B("no_change")
  ) o_acc0_mem (
    .sleep(1'b0),
    .clka(clk), .rsta(1'b0), .ena(o_acc0_rd_en), .regcea(1'b1),
    .wea('0), .addra(o_acc0_rd_addr), .dina('0), .injectsbiterra(1'b0), .injectdbiterra(1'b0), .douta(o_acc0_rd_word), .sbiterra(), .dbiterra(),
    .clkb(clk), .rstb(1'b0), .enb(o_acc0_wr_en), .regceb(1'b1),
    .web(o_acc0_web), .addrb(o_acc0_wr_addr), .dinb(o_acc0_wr_data), .injectsbiterrb(1'b0), .injectdbiterrb(1'b0), .doutb(), .sbiterrb(), .dbiterrb()
  );

  xpm_memory_tdpram #(
    .ADDR_WIDTH_A(O_CHUNK_ADDR_W), .ADDR_WIDTH_B(O_CHUNK_ADDR_W),
    .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(8), .BYTE_WRITE_WIDTH_B(8),
    .CASCADE_HEIGHT(0), .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
    .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
    .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
    .MEMORY_SIZE(O_CHUNK_DEPTH * CHUNK_W), .MESSAGE_CONTROL(0),
    .READ_DATA_WIDTH_A(CHUNK_W), .READ_DATA_WIDTH_B(CHUNK_W),
    .READ_LATENCY_A(1), .READ_LATENCY_B(1),
    .READ_RESET_VALUE_A("0"), .READ_RESET_VALUE_B("0"),
    .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
    .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"),
    .WRITE_DATA_WIDTH_A(CHUNK_W), .WRITE_DATA_WIDTH_B(CHUNK_W),
    .WRITE_MODE_A("no_change"), .WRITE_MODE_B("no_change")
  ) o_acc1_mem (
    .sleep(1'b0),
    .clka(clk), .rsta(1'b0), .ena(o_acc1_rd_en), .regcea(1'b1),
    .wea('0), .addra(o_acc1_rd_addr), .dina('0), .injectsbiterra(1'b0), .injectdbiterra(1'b0), .douta(o_acc1_rd_word), .sbiterra(), .dbiterra(),
    .clkb(clk), .rstb(1'b0), .enb(o_acc1_wr_en), .regceb(1'b1),
    .web(o_acc1_web), .addrb(o_acc1_wr_addr), .dinb(o_acc1_wr_data), .injectsbiterrb(1'b0), .injectdbiterrb(1'b0), .doutb(), .sbiterrb(), .dbiterrb()
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (ar = 0; ar < O_CHUNK_DEPTH; ar++) begin
        o_acc0_tag[ar] <= 1'b0;
        o_acc1_tag[ar] <= 1'b0;
      end
      acc_mem_pending_valid <= 1'b0;
      acc_mem_pending_bank_sel <= 1'b0;
      acc_mem_pending_addr <= '0;
      acc_mem_pending_corr <= 32'd0;
      acc_mem_pending_word <= '0;
      acc_mem_pending_product_word <= '0;
      acc_mem_issue_valid <= 1'b0;
      acc_mem_issue_bank_sel <= 1'b0;
      acc_mem_issue_addr <= '0;
      acc_mem_issue_corr <= 32'd0;
      acc_mem_issue_use_bypass <= 1'b0;
      acc_mem_issue_bypass_from_pending <= 1'b0;
      acc_mem_issue_bypass_from_return <= 1'b0;
      acc_mem_issue_bypass_word <= '0;
      acc_mem_return_valid <= 1'b0;
      acc_mem_return_bank_sel <= 1'b0;
      acc_mem_return_addr <= '0;
      acc_mem_return_corr <= 32'd0;
      acc_mem_return_word <= '0;
      acc_mem_return_write_word <= '0;
      for (int lane = 0; lane < TILE_COLS; lane++) begin
        acc_mem_issue_data[lane] <= 32'd0;
        acc_mem_pending_data[lane] <= 32'd0;
        acc_mem_return_data[lane] <= 32'd0;
      end

      norm_active <= 1'b0;
      norm_row <= 5'd0;
      norm_dim <= 7'd0;
      norm_active_rows <= 5'd0;
      norm_mem_pending_valid <= 1'b0;
      norm_mem_pending_bank_sel <= 1'b0;
      norm_mem_pending_addr <= '0;
      norm_mem_pending_row <= 5'd0;
      norm_mem_pending_dim <= 7'd0;
      norm_mem_pending_lane <= 4'd0;
      norm_mem_pending_l_bits <= 32'd0;
      norm_mem_pending_word <= '0;
      norm_mem_issue_valid <= 1'b0;
      norm_mem_issue_bank_sel <= 1'b0;
      norm_mem_issue_addr <= '0;
      norm_mem_issue_row <= 5'd0;
      norm_mem_issue_dim <= 7'd0;
      norm_mem_issue_lane <= 4'd0;
      norm_mem_issue_l_bits <= 32'd0;
      norm_mem_issue_use_bypass <= 1'b0;
      norm_mem_issue_bypass_word <= '0;
      norm_mem_return_valid <= 1'b0;
      norm_mem_return_bank_sel <= 1'b0;
      norm_mem_return_addr <= '0;
      norm_mem_return_row <= 5'd0;
      norm_mem_return_dim <= 7'd0;
      norm_mem_return_lane <= 4'd0;
      norm_mem_return_l_bits <= 32'd0;
      norm_resp_valid <= 1'b0;
      norm_resp_source_bits <= 32'd0;
      norm_resp_l_bits <= 32'd0;
      norm_resp_row <= 5'd0;
      norm_resp_dim <= 7'd0;
      norm_resp_wait_valid <= 1'b0;
      norm_resp_wait_addr <= '0;
      norm_resp_wait_bank_sel <= 1'b0;
      norm_resp_wait_row <= 5'd0;
      norm_resp_wait_dim <= 7'd0;
      norm_resp_wait_lane <= 4'd0;
      norm_resp_wait_l_bits <= 32'd0;
      norm_pipe_valid <= 1'b0;
      norm_pipe_row <= 5'd0;
      norm_pipe_dim <= 7'd0;
      norm_pipe_source_bits <= 32'd0;
      norm_pipe_l_bits <= 32'd0;
    end else begin
      if (acc_mem_return_valid) begin
        if (!acc_mem_return_bank_sel)
          o_acc0_tag[acc_mem_return_addr] <= o_acc0_epoch;
        else
          o_acc1_tag[acc_mem_return_addr] <= o_acc1_epoch;
      end

      acc_mem_return_valid <= acc_mem_pending_valid;
      acc_mem_return_bank_sel <= acc_mem_pending_bank_sel;
      acc_mem_return_addr <= acc_mem_pending_addr;
      acc_mem_return_corr <= acc_mem_pending_corr;
      acc_mem_return_word <= acc_mem_pending_word;
      acc_mem_return_write_word <= add_chunk_word(
        acc_mem_pending_product_word,
        acc_mem_pending_data
      );
      for (int lane = 0; lane < TILE_COLS; lane++) begin
        acc_mem_return_data[lane] <= acc_mem_pending_data[lane];
      end

      acc_mem_pending_valid <= acc_mem_issue_valid;
      acc_mem_pending_bank_sel <= acc_mem_issue_bank_sel;
      acc_mem_pending_addr <= acc_mem_issue_addr;
      acc_mem_pending_corr <= acc_mem_issue_corr;
      acc_mem_pending_word <= acc_issue_base_word;
      acc_mem_pending_product_word <= acc_issue_product_word;
      for (int lane = 0; lane < TILE_COLS; lane++) begin
        acc_mem_pending_data[lane] <= acc_mem_issue_data[lane];
      end

      acc_mem_issue_valid <= acc_update;
      acc_mem_issue_bank_sel <= bank_sel;
      acc_mem_issue_addr <= acc_chunk_addr;
      acc_mem_issue_corr <= acc_correction;
      acc_mem_issue_use_bypass <= acc_issue_bypass_hit;
      acc_mem_issue_bypass_from_pending <= acc_issue_pending_hit;
      acc_mem_issue_bypass_from_return <= acc_issue_return_hit;
      acc_mem_issue_bypass_word <= acc_issue_pending_hit ? acc_pending_write_word_now : acc_mem_return_write_word;
      for (int lane = 0; lane < TILE_COLS; lane++) begin
        acc_mem_issue_data[lane] <= acc_data[lane];
      end

      if (norm_resp_wait_valid) begin
        if (acc_mem_return_valid &&
            (acc_mem_return_bank_sel == norm_resp_wait_bank_sel) &&
            (acc_mem_return_addr == norm_resp_wait_addr)) begin
          norm_resp_valid <= 1'b1;
          norm_resp_row <= norm_resp_wait_row;
          norm_resp_dim <= norm_resp_wait_dim;
          norm_resp_l_bits <= norm_resp_wait_l_bits;
          norm_resp_source_bits <= acc_mem_return_write_word[norm_resp_wait_lane * FP32_W +: FP32_W];
          norm_resp_wait_valid <= 1'b0;
        end
      end else if (norm_mem_return_valid) begin
        if (norm_resp_pending_hit) begin
          norm_resp_wait_valid <= 1'b1;
          norm_resp_wait_addr <= norm_mem_return_addr;
          norm_resp_wait_bank_sel <= norm_mem_return_bank_sel;
          norm_resp_wait_row <= norm_mem_return_row;
          norm_resp_wait_dim <= norm_mem_return_dim;
          norm_resp_wait_lane <= norm_mem_return_lane;
          norm_resp_wait_l_bits <= norm_mem_return_l_bits;
        end else begin
          norm_resp_valid <= 1'b1;
          norm_resp_row <= norm_mem_return_row;
          norm_resp_dim <= norm_mem_return_dim;
          norm_resp_l_bits <= norm_mem_return_l_bits;
          norm_resp_source_bits <= norm_resp_word_now[norm_mem_return_lane * FP32_W +: FP32_W];
        end
      end else if (norm_resp_valid && o_ready) begin
        norm_resp_valid <= 1'b0;
      end

      norm_mem_return_valid <= norm_mem_pending_valid;
      norm_mem_return_bank_sel <= norm_mem_pending_bank_sel;
      norm_mem_return_addr <= norm_mem_pending_addr;
      norm_mem_return_row <= norm_mem_pending_row;
      norm_mem_return_dim <= norm_mem_pending_dim;
      norm_mem_return_lane <= norm_mem_pending_lane;
      norm_mem_return_l_bits <= norm_mem_pending_l_bits;

      norm_mem_pending_valid <= norm_mem_issue_valid;
      norm_mem_pending_bank_sel <= norm_mem_issue_bank_sel;
      norm_mem_pending_addr <= norm_mem_issue_addr;
      norm_mem_pending_row <= norm_mem_issue_row;
      norm_mem_pending_dim <= norm_mem_issue_dim;
      norm_mem_pending_lane <= norm_mem_issue_lane;
      norm_mem_pending_l_bits <= norm_mem_issue_l_bits;
      norm_mem_pending_word <= norm_mem_issue_use_bypass ? norm_mem_issue_bypass_word : norm_return_word;

      norm_mem_issue_valid <= norm_issue_fire;
      norm_mem_issue_bank_sel <= norm_issue_bank_sel;
      norm_mem_issue_addr <= norm_issue_addr;
      norm_mem_issue_row <= norm_issue_row;
      norm_mem_issue_dim <= norm_issue_dim;
      norm_mem_issue_lane <= norm_issue_lane;
      norm_mem_issue_l_bits <= norm_issue_l_bits;
      norm_mem_issue_use_bypass <= norm_issue_pending_hit || norm_issue_return_hit;
      norm_mem_issue_bypass_word <= norm_issue_pending_hit ? acc_pending_write_word_now : acc_mem_return_write_word;

      if (normalize) begin
        norm_active <= (active_rows != 5'd0);
        norm_row <= 5'd0;
        norm_dim <= 7'd0;
        norm_active_rows <= active_rows;
      end

      if (norm_issue_fire) begin
        if (norm_dim_now == HEAD_DIM_LAST_U7) begin
          norm_dim <= 7'd0;
          if (norm_row_now == norm_active_rows_now - 5'd1) begin
            norm_active <= 1'b0;
          end else begin
            norm_row <= norm_row_now + 5'd1;
          end
        end else begin
          norm_dim <= norm_dim_now + 7'd1;
        end
      end
    end
  end
`else
  logic [CHUNK_W-1:0] norm_chunk_word;

  assign acc_ready = 1'b1;

  always_ff @(posedge clk) begin
    if (acc_update) begin
      if (!bank_sel)
        o_acc0_chunk[acc_chunk_addr] <= accumulate_chunk_word(
          chunk_or_zero(o_acc0_chunk[acc_chunk_addr], o_acc0_tag[acc_chunk_addr], o_acc0_epoch),
          acc_correction,
          acc_data
        );
      else
        o_acc1_chunk[acc_chunk_addr] <= accumulate_chunk_word(
          chunk_or_zero(o_acc1_chunk[acc_chunk_addr], o_acc1_tag[acc_chunk_addr], o_acc1_epoch),
          acc_correction,
          acc_data
        );
    end
  end

  always_comb begin
    if (!bank_sel)
      norm_chunk_word = chunk_or_zero(o_acc1_chunk[norm_chunk_addr], o_acc1_tag[norm_chunk_addr], o_acc1_epoch);
    else
      norm_chunk_word = chunk_or_zero(o_acc0_chunk[norm_chunk_addr], o_acc0_tag[norm_chunk_addr], o_acc0_epoch);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      norm_active <= 1'b0;
      norm_pipe_valid <= 1'b0;
      norm_row <= 5'd0;
      norm_dim <= 7'd0;
      norm_active_rows <= 5'd0;
      norm_pipe_row <= 5'd0;
      norm_pipe_dim <= 7'd0;
      norm_pipe_source_bits <= 32'd0;
      norm_pipe_l_bits <= 32'd0;
    end else begin
      if (normalize) begin
        norm_active <= (active_rows != 5'd0);
        norm_row <= 5'd0;
        norm_dim <= 7'd0;
        norm_active_rows <= active_rows;
      end

      if (!norm_pipe_valid || o_ready) begin
        if (norm_active) begin
          norm_pipe_valid <= 1'b1;
          norm_pipe_row <= norm_row;
          norm_pipe_dim <= norm_dim;
          norm_pipe_source_bits <= norm_chunk_word[norm_dim_lane_idx * FP32_W +: FP32_W];
          norm_pipe_l_bits <= l_state[norm_row_idx];

          if (norm_dim == HEAD_DIM_LAST_U7) begin
            norm_dim <= 7'd0;
            if (norm_row == norm_active_rows - 5'd1)
              norm_active <= 1'b0;
            else
              norm_row <= norm_row + 5'd1;
          end else begin
            norm_dim <= norm_dim + 7'd1;
          end
        end else begin
          norm_pipe_valid <= 1'b0;
        end
      end
    end
  end
`endif

`ifdef USE_XPM_MEMORY
  assign norm_result_bits = normalize_fp32_bits(norm_resp_source_bits, norm_resp_l_bits);
  assign o_valid = norm_resp_valid;
  assign o_row = norm_resp_row;
  assign o_dim = norm_resp_dim;
`else
  assign norm_result_bits = normalize_fp32_bits(norm_pipe_source_bits, norm_pipe_l_bits);
  assign o_valid = norm_pipe_valid;
  assign o_row = norm_pipe_row;
  assign o_dim = norm_pipe_dim;
`endif
  assign o_data = fp32_to_bf16(norm_result_bits);

endmodule
