module attn_top (
  input  logic clk,
  input  logic rst_n,

  input  logic [13:0] s_axi_awaddr,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  output logic [1:0]  s_axi_bresp,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,
  input  logic [13:0] s_axi_araddr,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready,

  input  logic [31:0] s_axis_tdata,
  input  logic        s_axis_tvalid,
  output logic        s_axis_tready,
  input  logic        s_axis_tlast,

  output logic [31:0] m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast
);

  import attn_pkg::*;

  logic start, start_ready, done, busy, core_error, cfg_causal;
  logic [7:0] core_error_code;
  logic [15:0] seq_len, cfg_q_pos_base, cfg_kv_pos_base;
  logic [31:0] cycle_cnt, mac_cycles, stream_len, result_len;
  logic [1:0] stream_dest;

  logic kv_load_start, kv_load_done, q_load_start, q_load_done, o_write_start;
  wire  o_write_done;
  logic mac_phase, mac_start, softmax_start, kv_tile_first, kv_tile_last;
  wire  mac_done, softmax_done;
  logic [15:0] q_tile_start, kv_tile_start;
  logic [4:0] active_q_rows;
  logic [6:0] active_kv_cols;

  logic [6:0] depth_cnt;
  logic depth_last;
  assign depth_last = (depth_cnt == HEAD_DIM - 1);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) depth_cnt <= 7'd0;
    else if (!mac_start) depth_cnt <= 7'd0;
    else depth_cnt <= depth_cnt + 7'd1;
  end

  logic axis_valid, axis_last, sink_done, sink_overflow, sink_underflow;
  logic [15:0] axis_data;
  logic [1:0] axis_dest;
  logic [31:0] sink_bytes;
  logic stream_error;
  assign stream_error = sink_overflow || sink_underflow;

  logic k_loaded, v_loaded, q_loaded;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      k_loaded <= 1'b0;
      v_loaded <= 1'b0;
      q_loaded <= 1'b0;
    end else if (sink_done && !stream_error) begin
      unique case (stream_dest)
        STREAM_TO_K_CACHE: k_loaded <= 1'b1;
        STREAM_TO_V_CACHE: v_loaded <= 1'b1;
        STREAM_TO_Q_BUF:   q_loaded <= 1'b1;
        default: ;
      endcase
    end
  end

  assign kv_load_done = k_loaded && v_loaded;
  assign q_load_done  = q_loaded;

  logic src_valid, src_last, src_done;
  logic [15:0] src_data;
  logic [31:0] src_bytes;
  logic [31:0] o_elem_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      o_elem_cnt <= 32'd0;
    end else if (o_write_start) begin
      o_elem_cnt <= 32'd0;
    end else if (src_valid) begin
      o_elem_cnt <= o_elem_cnt + 32'd1;
    end
  end
  assign src_last = src_valid && (((o_elem_cnt + 32'd1) << 1) >= result_len);
  assign o_write_done = src_done;

  logic buf_sel, tile_ready;
  logic [15:0] q_buf_rd;
  logic [4:0] q_rd_row;
  logic [6:0] q_rd_dim;

  logic [15:0] k_rd [TILE_KV], v_rd [TILE_KV];
  logic k_wr_en, v_wr_en, q_wr_en, k_rd_en, v_rd_en;
  logic [15:0] k_wr_addr, v_wr_addr, k_rd_start, v_rd_start;
  logic [6:0] k_rd_dim, v_rd_dim;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      k_wr_addr <= 16'd0;
      v_wr_addr <= 16'd0;
    end else begin
      if (k_wr_en) k_wr_addr <= k_wr_addr + 16'd1;
      if (v_wr_en) v_wr_addr <= v_wr_addr + 16'd1;
      if (sink_done && stream_dest == STREAM_TO_K_CACHE) k_wr_addr <= 16'd0;
      if (sink_done && stream_dest == STREAM_TO_V_CACHE) v_wr_addr <= 16'd0;
    end
  end

  assign k_wr_en = axis_valid && (axis_dest == STREAM_TO_K_CACHE);
  assign v_wr_en = axis_valid && (axis_dest == STREAM_TO_V_CACHE);
  assign q_wr_en = axis_valid && (axis_dest == STREAM_TO_Q_BUF);

  logic [15:0] mac_row [TILE_ROWS], mac_col [TILE_COLS];
  logic [1:0] mac_split;
  logic [31:0] mac_col_out [TILE_COLS];
  logic [15:0] p_latch [TILE_ROWS][TILE_COLS];
  logic s_valid, p_valid;
  logic [31:0] s_block [TILE_ROWS][TILE_COLS];
  logic [31:0] p_block [TILE_ROWS][TILE_COLS];
  logic [31:0] m_state [TILE_ROWS], l_state [TILE_ROWS], correction [TILE_ROWS];
  logic psum_en, psum_clear;
  logic [31:0] psum_in [TILE_COLS], psum_out [TILE_COLS];
  logic [31:0] zero_cols [TILE_COLS];
  logic obuf_update, obuf_norm;
  logic [4:0] obuf_row;
  logic [31:0] obuf_data [HEAD_DIM];

  genvar grm, gcm, gpi, gslr, gslc, goi, glr, glc;
  generate
    for (glr = 0; glr < TILE_ROWS; glr++) begin : P_LATCH_R
      for (glc = 0; glc < TILE_COLS; glc++) begin : P_LATCH_C
        always_ff @(posedge clk) if (p_valid) p_latch[glr][glc] <= p_block[glr][glc][31:16];
      end
    end
    for (grm = 0; grm < TILE_ROWS; grm++) begin : ROW_MUX
      assign mac_row[grm] = (!mac_phase) ? q_buf_rd : p_latch[grm][depth_cnt[3:0]];
    end
    for (gcm = 0; gcm < TILE_COLS; gcm++) begin : COL_MUX
      assign mac_col[gcm] = (!mac_phase) ? k_rd[gcm] : v_rd[gcm];
    end
    for (gpi = 0; gpi < TILE_COLS; gpi++) begin : PSUM_IN
      assign psum_in[gpi] = mac_col_out[gpi];
    end
    for (gslr = 0; gslr < TILE_ROWS; gslr++) begin : S_BLOCK_R
      for (gslc = 0; gslc < TILE_COLS; gslc++) begin : S_BLOCK_C
        always_ff @(posedge clk) if (depth_last && !mac_phase) s_block[gslr][gslc] <= psum_out[gslc];
      end
    end
    for (gpi = 0; gpi < TILE_COLS; gpi++) begin : ZERO_COLS
      assign zero_cols[gpi] = 32'd0;
    end
    for (goi = 0; goi < HEAD_DIM; goi++) begin : OBUF_DATA
      assign obuf_data[goi] = psum_out[goi % TILE_COLS];
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) s_valid <= 1'b0;
    else        s_valid <= (depth_last && !mac_phase);
  end

  assign mac_split   = 2'd0;
  assign obuf_update = depth_last && mac_phase;
  assign obuf_row    = 5'd0;
  assign obuf_norm   = kv_tile_last;
  assign mac_done    = depth_last;
  assign psum_en     = 1'b1;
  assign psum_clear  = kv_tile_first && depth_cnt == 7'd0;

  assign k_rd_en     = mac_start && !mac_phase;
  assign v_rd_en     = mac_start && mac_phase;
  assign k_rd_start  = kv_tile_start;
  assign v_rd_start  = kv_tile_start;
  assign k_rd_dim    = depth_cnt;
  assign v_rd_dim    = depth_cnt;
  assign q_rd_row    = 5'd0;
  assign q_rd_dim    = depth_cnt;
  assign buf_sel     = 1'b0;

  attn_axi_lite_slave u_csr (
    .clk, .rst_n,
    .s_axi_awaddr, .s_axi_awvalid, .s_axi_awready,
    .s_axi_wdata, .s_axi_wstrb, .s_axi_wvalid, .s_axi_wready,
    .s_axi_bresp, .s_axi_bvalid, .s_axi_bready,
    .s_axi_araddr, .s_axi_arvalid, .s_axi_arready,
    .s_axi_rdata, .s_axi_rresp, .s_axi_rvalid, .s_axi_rready,
    .start, .seq_len, .cfg_q_pos_base, .cfg_kv_pos_base, .cfg_causal,
    .stream_dest, .stream_len, .result_len,
    .start_ready, .busy, .done, .core_error, .core_error_code,
    .stream_error, .cycle_cnt, .mac_cycles
  );

  attn_axi_stream_sink u_sink (
    .clk, .rst_n,
    .s_axis_tdata, .s_axis_tvalid, .s_axis_tready, .s_axis_tlast,
    .cfg_dest(stream_dest), .cfg_len(stream_len), .cfg_burst(4'd0),
    .data_valid(axis_valid), .data_out(axis_data), .data_last(axis_last), .dest_sel(axis_dest),
    .bytes_received(sink_bytes), .overflow(sink_overflow), .underflow(sink_underflow), .done(sink_done)
  );

  attn_axi_stream_source u_src (
    .clk, .rst_n,
    .data_valid(src_valid), .data_in(src_data), .data_last(src_last),
    .cfg_len(result_len),
    .m_axis_tdata, .m_axis_tvalid, .m_axis_tready, .m_axis_tlast,
    .bytes_sent(src_bytes), .done(src_done)
  );

  attn_core u_fsm (
    .clk, .rst_n,
    .start, .start_ready,
    .seq_len, .cfg_q_pos_base, .cfg_kv_pos_base, .cfg_causal,
    .done, .busy,
    .kv_load_start, .kv_load_done, .q_load_start, .q_load_done, .o_write_start, .o_write_done,
    .mac_phase, .mac_start, .mac_done,
    .softmax_start, .softmax_done,
    .kv_tile_first, .kv_tile_last,
    .q_tile_start, .kv_tile_start, .active_q_rows, .active_kv_cols,
    .error(core_error), .error_code(core_error_code),
    .cycle_cnt, .mac_cycles
  );

  kv_cache_ram u_kcache (.clk, .rst_n, .wr_en(k_wr_en), .wr_addr(k_wr_addr), .wr_data(axis_data), .rd_en(k_rd_en), .rd_token_start(k_rd_start), .rd_dim(k_rd_dim), .rd_data(k_rd));
  kv_cache_ram u_vcache (.clk, .rst_n, .wr_en(v_wr_en), .wr_addr(v_wr_addr), .wr_data(axis_data), .rd_en(v_rd_en), .rd_token_start(v_rd_start), .rd_dim(v_rd_dim), .rd_data(v_rd));
  tile_buffer u_qbuf (.clk, .rst_n, .wr_en(q_wr_en), .wr_data(axis_data), .rd_en(mac_start && !mac_phase), .rd_row(q_rd_row), .rd_dim(q_rd_dim), .rd_data(q_buf_rd), .buf_sel, .tile_ready);
  attn_tile u_mac (.clk, .rst_n, .phase_sel(mac_phase), .row_data(mac_row), .col_data(mac_col), .split_phase(mac_split), .accum_en(1'b1), .col_out(mac_col_out));
  softmax_engine u_softmax (.clk, .rst_n, .s_valid, .s_data(s_block), .kv_tile_first, .kv_tile_last, .causal_mask_en(cfg_causal), .q_tile_start, .kv_tile_start, .m_state, .l_state, .p_valid, .p_data(p_block), .correction, .done(softmax_done));
  psum_accum u_psum (.clk, .rst_n, .clear(psum_clear), .en(psum_en), .tile_col(psum_in), .en_lo(1'b0), .en_hi(1'b0), .col_lo(zero_cols), .col_hi(zero_cols), .en_q0(1'b0), .en_q1(1'b0), .en_q2(1'b0), .en_q3(1'b0), .col_q0(zero_cols), .col_q1(zero_cols), .col_q2(zero_cols), .col_q3(zero_cols), .psum(psum_out));
  output_buffer u_obuf (.clk, .rst_n, .acc_update(obuf_update), .acc_row(obuf_row), .acc_data(obuf_data), .correction(correction), .normalize(obuf_norm), .l_state(l_state), .o_valid(src_valid), .o_row(), .o_dim(), .o_data(src_data));
  // RoPE is host-side/optional in the Phase-1 full-run control path.

endmodule