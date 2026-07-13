module softmax_engine_basic
  import attn_pkg::*;
(
    input  logic                           clk,
    input  logic                           rst_n,
    input  logic                           s_valid,
    input  logic [FP32_W-1:0]              s_data [TILE_ROWS][TILE_COLS],
    input  logic                           kv_tile_first,
    input  logic                           causal_mask_en,
    input  logic [15:0]                    q_tile_start,
    input  logic [15:0]                    kv_tile_start,
    input  logic [4:0]                     active_rows,
    input  logic [4:0]                     active_cols,
    input  logic [FP32_W-1:0]              state_m_in [TILE_ROWS],
    input  logic [FP32_W-1:0]              state_l_in [TILE_ROWS],
    output logic [FP32_W-1:0]              m_state [TILE_ROWS],
    output logic [FP32_W-1:0]              l_state [TILE_ROWS],
    output logic                           p_valid,
    output logic [FP32_W-1:0]              p_data [TILE_ROWS][TILE_COLS],
    output logic [FP32_W-1:0]              correction [TILE_ROWS],
    output logic                           done
);

  localparam int LUT_DEPTH = 1024;
  localparam logic [31:0] FP32_NEG_INF_BITS = 32'hFF80_0000;
  localparam logic [31:0] FP32_ZERO_BITS    = 32'h0000_0000;
  localparam shortreal NEG_INF_SR   = -1.0e30;
  localparam shortreal NEG_EIGHT_SR = -8.0;
  localparam shortreal ZERO_SR      = 0.0;
  localparam shortreal ONE_SR       = 1.0;
  localparam shortreal EIGHT_SR     = 8.0;

  (* rom_style = "block" *) logic [FP32_W-1:0] exp_lut [0:LUT_DEPTH-1];

`ifndef SYNTHESIS
  initial begin
    integer fd;
    integer lut_scan_rc;
    fd = $fopen("data/exp_lut.hex", "r");
    if (fd == 0)
      fd = $fopen("VV/data/exp_lut.hex", "r");
    if (fd != 0) begin
      for (int li = 0; li < LUT_DEPTH; li++)
        lut_scan_rc = $fscanf(fd, "%h", exp_lut[li]);
      $fclose(fd);
    end else begin
      $display("WARNING: exp_lut.hex not found. Expected data/exp_lut.hex or VV/data/exp_lut.hex");
    end
  end
`else
  initial begin
    $readmemh("exp_lut.hex", exp_lut);
  end
`endif

  function automatic shortreal exp_lookup(input shortreal x);
    shortreal x_clamped;
    shortreal idx_float, frac;
    integer idx_lo, idx_hi;
    shortreal v_lo, v_hi;
    begin
      if (x < NEG_EIGHT_SR)      x_clamped = NEG_EIGHT_SR;
      else if (x > ZERO_SR)      x_clamped = ZERO_SR;
      else                       x_clamped = x;
      idx_float = (x_clamped + EIGHT_SR) * shortreal'(LUT_DEPTH - 1) / EIGHT_SR;
      idx_lo = integer'(idx_float);
      idx_hi = idx_lo + 1;
      if (idx_hi >= LUT_DEPTH) idx_hi = LUT_DEPTH - 1;
      frac = idx_float - shortreal'(idx_lo);
      v_lo = $bitstoshortreal(exp_lut[idx_lo]);
      v_hi = $bitstoshortreal(exp_lut[idx_hi]);
      exp_lookup = v_lo + frac * (v_hi - v_lo);
    end
  endfunction

  logic                           s_valid_r;
  logic                           kv_tile_first_r;
  logic                           causal_mask_en_r;
  logic [15:0]                    q_tile_start_r, kv_tile_start_r;
  logic [4:0]                     active_rows_r, active_cols_r;
  logic [FP32_W-1:0]              s_data_r [TILE_ROWS][TILE_COLS];
  logic [FP32_W-1:0]              state_m_in_r [TILE_ROWS];
  logic [FP32_W-1:0]              state_l_in_r [TILE_ROWS];

`ifndef SYNTHESIS
  shortreal sm_m_new_sr [TILE_ROWS];
  shortreal sm_l_new_sr [TILE_ROWS];
  shortreal sm_corr_sr [TILE_ROWS];
  shortreal sm_p_sr [TILE_ROWS][TILE_COLS];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_valid_r        <= 1'b0;
      kv_tile_first_r  <= 1'b0;
      causal_mask_en_r <= 1'b0;
      q_tile_start_r   <= 16'd0;
      kv_tile_start_r  <= 16'd0;
      active_rows_r    <= 5'd0;
      active_cols_r    <= 5'd0;
      for (int ri = 0; ri < TILE_ROWS; ri++) begin
        state_m_in_r[ri] <= FP32_NEG_INF_BITS;
        state_l_in_r[ri] <= FP32_ZERO_BITS;
        for (int ci = 0; ci < TILE_COLS; ci++)
          s_data_r[ri][ci] <= FP32_ZERO_BITS;
      end
    end else begin
      s_valid_r        <= s_valid;
      kv_tile_first_r  <= kv_tile_first;
      causal_mask_en_r <= causal_mask_en;
      q_tile_start_r   <= q_tile_start;
      kv_tile_start_r  <= kv_tile_start;
      active_rows_r    <= active_rows;
      active_cols_r    <= active_cols;
      for (int ri = 0; ri < TILE_ROWS; ri++) begin
        state_m_in_r[ri] <= state_m_in[ri];
        state_l_in_r[ri] <= state_l_in[ri];
        for (int ci = 0; ci < TILE_COLS; ci++)
          s_data_r[ri][ci] <= s_data[ri][ci];
      end
    end
  end

  always_comb begin
    int active_rows_i;
    int active_cols_i;
    active_rows_i = integer'(active_rows_r);
    active_cols_i = integer'(active_cols_r);
    for (int ri = 0; ri < TILE_ROWS; ri++) begin
      shortreal row_max_val;
      shortreal m_old_val;
      shortreal l_old_val;
      shortreal m_new_val;
      shortreal correction_val;
      shortreal row_sum_val;
      logic row_valid;
      row_valid = (ri < active_rows_i);
      row_max_val = NEG_INF_SR;
      m_old_val = kv_tile_first_r ? NEG_INF_SR : $bitstoshortreal(state_m_in_r[ri]);
      l_old_val = kv_tile_first_r ? ZERO_SR    : $bitstoshortreal(state_l_in_r[ri]);
      for (int ci = 0; ci < TILE_COLS; ci++) begin
        shortreal scaled_val;
        logic col_valid;
        logic masked;
        col_valid = (ci < active_cols_i);
        masked = !row_valid || !col_valid;
        scaled_val = NEG_INF_SR;
        if (row_valid && col_valid)
          scaled_val = $bitstoshortreal(s_data_r[ri][ci]) * $bitstoshortreal(INV_SQRT_D_FP32);
        if (row_valid && col_valid && causal_mask_en_r) begin
          if ((q_tile_start_r + 16'(ri)) < (kv_tile_start_r + 16'(ci))) begin
            masked = 1'b1;
            scaled_val = NEG_INF_SR;
          end
        end
        if (scaled_val > row_max_val)
          row_max_val = scaled_val;
        sm_p_sr[ri][ci] = ZERO_SR;
        if (!masked)
          sm_p_sr[ri][ci] = exp_lookup(scaled_val - ((m_old_val > row_max_val) ? m_old_val : row_max_val));
      end

      if (row_valid)
        m_new_val = (m_old_val > row_max_val) ? m_old_val : row_max_val;
      else
        m_new_val = m_old_val;

      if (!row_valid)
        correction_val = ZERO_SR;
      else if (kv_tile_first_r)
        correction_val = ZERO_SR;
      else
        correction_val = exp_lookup(m_old_val - m_new_val);

      row_sum_val = ZERO_SR;
      for (int cj = 0; cj < TILE_COLS; cj++)
        row_sum_val = row_sum_val + sm_p_sr[ri][cj];

      sm_m_new_sr[ri] = m_new_val;
      sm_corr_sr[ri] = correction_val;
      if (!row_valid)
        sm_l_new_sr[ri] = l_old_val;
      else if (kv_tile_first_r)
        sm_l_new_sr[ri] = row_sum_val;
      else
        sm_l_new_sr[ri] = l_old_val * correction_val + row_sum_val;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_valid <= 1'b0;
      done    <= 1'b0;
      for (int ri = 0; ri < TILE_ROWS; ri++) begin
        m_state[ri]    <= FP32_NEG_INF_BITS;
        l_state[ri]    <= FP32_ZERO_BITS;
        correction[ri] <= FP32_ZERO_BITS;
        for (int ci = 0; ci < TILE_COLS; ci++)
          p_data[ri][ci] <= FP32_ZERO_BITS;
      end
    end else begin
      p_valid <= s_valid_r;
      done    <= s_valid_r;
      if (s_valid_r) begin
        for (int ri = 0; ri < TILE_ROWS; ri++) begin
          m_state[ri]    <= $shortrealtobits(sm_m_new_sr[ri]);
          l_state[ri]    <= $shortrealtobits(sm_l_new_sr[ri]);
          correction[ri] <= $shortrealtobits(sm_corr_sr[ri]);
          for (int ci = 0; ci < TILE_COLS; ci++)
            p_data[ri][ci] <= $shortrealtobits(sm_p_sr[ri][ci]);
        end
      end
    end
  end
`else
  logic [31:0] sm_m_new [TILE_ROWS];
  logic [31:0] sm_l_new [TILE_ROWS];
  logic [31:0] sm_corr [TILE_ROWS];
  logic [31:0] sm_p [TILE_ROWS][TILE_COLS];
  logic [31:0] sm_scaled [TILE_ROWS][TILE_COLS];
  logic        sm_masked [TILE_ROWS][TILE_COLS];

  function automatic logic [31:0] exp_lookup_bits(input logic [31:0] x);
    logic signed [23:0] x_q;
    integer idx_num;
    integer idx;
    begin
      x_q = fp32_to_q8_15(x);
      if (x_q < -24'sd262144) x_q = -24'sd262144;
      else if (x_q > 24'sd0)  x_q = 24'sd0;
      idx_num = integer'(x_q) + 262144;
      idx = (idx_num * (LUT_DEPTH - 1)) >>> 18;
      if (idx < 0) idx = 0;
      else if (idx >= LUT_DEPTH) idx = LUT_DEPTH - 1;
      exp_lookup_bits = exp_lut[idx];
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_valid_r        <= 1'b0;
      kv_tile_first_r  <= 1'b0;
      causal_mask_en_r <= 1'b0;
      q_tile_start_r   <= 16'd0;
      kv_tile_start_r  <= 16'd0;
      active_rows_r    <= 5'd0;
      active_cols_r    <= 5'd0;
      for (int ri = 0; ri < TILE_ROWS; ri++) begin
        state_m_in_r[ri] <= FP32_NEG_INF_BITS;
        state_l_in_r[ri] <= FP32_ZERO_BITS;
        for (int ci = 0; ci < TILE_COLS; ci++)
          s_data_r[ri][ci] <= FP32_ZERO_BITS;
      end
    end else begin
      s_valid_r        <= s_valid;
      kv_tile_first_r  <= kv_tile_first;
      causal_mask_en_r <= causal_mask_en;
      q_tile_start_r   <= q_tile_start;
      kv_tile_start_r  <= kv_tile_start;
      active_rows_r    <= active_rows;
      active_cols_r    <= active_cols;
      for (int ri = 0; ri < TILE_ROWS; ri++) begin
        state_m_in_r[ri] <= state_m_in[ri];
        state_l_in_r[ri] <= state_l_in[ri];
        for (int ci = 0; ci < TILE_COLS; ci++)
          s_data_r[ri][ci] <= s_data[ri][ci];
      end
    end
  end

  always_comb begin
    for (int ri = 0; ri < TILE_ROWS; ri++) begin
      logic [31:0] row_max_val;
      logic [31:0] m_old_val;
      logic [31:0] l_old_val;
      logic [31:0] row_sum_val;
      logic        row_valid;

      sm_m_new[ri] = FP32_NEG_INF_BITS;
      sm_l_new[ri] = FP32_ZERO_BITS;
      sm_corr[ri] = FP32_ZERO_BITS;
      row_max_val = FP32_NEG_INF_BITS;
      row_valid = (ri < integer'(active_rows_r));

      for (int ci = 0; ci < TILE_COLS; ci++) begin
        logic col_valid;
        logic masked;
        integer q_pos;
        integer kv_pos;
        col_valid = (ci < integer'(active_cols_r));
        masked = !row_valid || !col_valid;
        sm_scaled[ri][ci] = FP32_NEG_INF_BITS;
        if (row_valid && col_valid)
          sm_scaled[ri][ci] = fp32_mul(s_data_r[ri][ci], INV_SQRT_D_FP32);
        if (row_valid && col_valid && causal_mask_en_r) begin
          q_pos = integer'(q_tile_start_r) + ri;
          kv_pos = integer'(kv_tile_start_r) + ci;
          if (q_pos < kv_pos) begin
            masked = 1'b1;
            sm_scaled[ri][ci] = FP32_NEG_INF_BITS;
          end
        end
        sm_masked[ri][ci] = masked;
        row_max_val = fp32_max(row_max_val, sm_scaled[ri][ci]);
      end

      m_old_val = kv_tile_first_r ? FP32_NEG_INF_BITS : state_m_in_r[ri];
      l_old_val = kv_tile_first_r ? FP32_ZERO_BITS    : state_l_in_r[ri];

      if (row_valid) begin
        sm_m_new[ri] = fp32_max(m_old_val, row_max_val);
        if (kv_tile_first_r)
          sm_corr[ri] = FP32_ZERO_BITS;
        else
          sm_corr[ri] = exp_lookup_bits(fp32_sub(m_old_val, sm_m_new[ri]));
      end else begin
        sm_m_new[ri] = m_old_val;
      end

      row_sum_val = FP32_ZERO_BITS;
      for (int ci = 0; ci < TILE_COLS; ci++) begin
        logic [31:0] shifted_val;
        shifted_val = fp32_sub(sm_scaled[ri][ci], sm_m_new[ri]);
        sm_p[ri][ci] = FP32_ZERO_BITS;
        if (!sm_masked[ri][ci])
          sm_p[ri][ci] = exp_lookup_bits(shifted_val);
        row_sum_val = fp32_add(row_sum_val, sm_p[ri][ci]);
      end

      if (!row_valid)
        sm_l_new[ri] = l_old_val;
      else if (kv_tile_first_r)
        sm_l_new[ri] = row_sum_val;
      else
        sm_l_new[ri] = fp32_add(fp32_mul(l_old_val, sm_corr[ri]), row_sum_val);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_valid <= 1'b0;
      done    <= 1'b0;
      for (int ri = 0; ri < TILE_ROWS; ri++) begin
        m_state[ri]    <= FP32_NEG_INF_BITS;
        l_state[ri]    <= FP32_ZERO_BITS;
        correction[ri] <= FP32_ZERO_BITS;
        for (int ci = 0; ci < TILE_COLS; ci++)
          p_data[ri][ci] <= FP32_ZERO_BITS;
      end
    end else begin
      p_valid <= s_valid_r;
      done    <= s_valid_r;
      if (s_valid_r) begin
        for (int ri = 0; ri < TILE_ROWS; ri++) begin
          m_state[ri]    <= sm_m_new[ri];
          l_state[ri]    <= sm_l_new[ri];
          correction[ri] <= sm_corr[ri];
          for (int ci = 0; ci < TILE_COLS; ci++)
            p_data[ri][ci] <= sm_p[ri][ci];
        end
      end
    end
  end
`endif

endmodule
