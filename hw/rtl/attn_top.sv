module attn_top
  import attn_pkg::*;
( clk, rst_n, s_axi_awaddr, s_axi_awvalid, s_axi_awready, s_axi_wdata, s_axi_wstrb, s_axi_wvalid, s_axi_wready, s_axi_bresp, s_axi_bvalid, s_axi_bready, s_axi_araddr, s_axi_arvalid, s_axi_arready, s_axi_rdata, s_axi_rresp, s_axi_rvalid, s_axi_rready, s_axis_tdata, s_axis_tvalid, s_axis_tready, s_axis_tlast, m_axis_tdata, m_axis_tvalid, m_axis_tready, m_axis_tlast );
  input logic clk, rst_n;
  input logic [13:0] s_axi_awaddr;
  input logic s_axi_awvalid; output logic s_axi_awready;
  input logic [31:0] s_axi_wdata;
  input logic [3:0] s_axi_wstrb;
  input logic s_axi_wvalid; output logic s_axi_wready;
  output logic [1:0] s_axi_bresp;
  output logic s_axi_bvalid; input logic s_axi_bready;
  input logic [13:0] s_axi_araddr;
  input logic s_axi_arvalid; output logic s_axi_arready;
  output logic [31:0] s_axi_rdata;
  output logic [1:0] s_axi_rresp;
  output logic s_axi_rvalid; input logic s_axi_rready;
  input logic [31:0] s_axis_tdata;
  input logic s_axis_tvalid; output logic s_axis_tready;
  input logic s_axis_tlast;
  output logic [31:0] m_axis_tdata;
  output logic m_axis_tvalid; input logic m_axis_tready;
  output logic m_axis_tlast;
  logic start, done, busy; logic [15:0] seq_len; logic [31:0] cycle_cnt, mac_cycles;
  logic cfg_causal;
  logic [2:0] gqa_group; logic [1:0] q_head;
  logic [1:0] stream_dest_cfg;
  logic [31:0] stream_len_cfg, result_len_cfg;
  logic kv_load_start, kv_load_done, q_load_start, q_load_done, o_write_start, o_write_done;
  logic group_advance;
  logic mac_phase, mac_start, mac_done, softmax_start, softmax_done, kv_tile_first, kv_tile_last;
  localparam int Q_MICROTILES  = TILE_Q / TILE_ROWS;
  localparam int KV_SUBBLOCKS  = TILE_KV / TILE_COLS;
  localparam int DIM_SUBBLOCKS = HEAD_DIM / TILE_COLS;
  localparam int PHASE_COLS    = (TILE_SPLIT_FACTOR <= 1) ? TILE_COLS :
                                 (TILE_COLS / TILE_SPLIT_FACTOR);
  localparam int P_ROW_W            = TILE_COLS * FP32_W;
  localparam int P_STORE_BANK_DEPTH = Q_MICROTILES * KV_SUBBLOCKS;
  localparam logic [31:0] FP32_NEG_INF = 32'hFF80_0000;
  localparam logic [6:0] HEAD_DIM_LAST_U7      = 7'(HEAD_DIM - 1);
  localparam logic [4:0] TILE_ROWS_U5          = 5'(TILE_ROWS);
  localparam logic [4:0] TILE_ROWS_LAST_U5     = 5'(TILE_ROWS - 1);
  localparam logic [4:0] TILE_COLS_U5          = 5'(TILE_COLS);
  localparam logic [3:0] TILE_COLS_LAST_U4     = 4'(TILE_COLS - 1);
  localparam logic [2:0] DIM_SUBBLOCKS_LAST_U3 = 3'(DIM_SUBBLOCKS - 1);
  typedef enum logic [2:0] {
    PA_IDLE     = 3'd0,
    PA_LOAD_CTX = 3'd1,
    PA_RUN      = 3'd2,
    PA_FLUSH    = 3'd3,
    PA_WAIT_P   = 3'd4
  } phasea_state_t;
  typedef enum logic [1:0] {
    PB_IDLE      = 2'd0,
    PB_RUN       = 2'd1,
    PB_UPDATE    = 2'd2,
    PB_DONE      = 2'd3
  } phaseb_state_t;
  logic [6:0] depth_cnt; logic phasea_depth_last;
  logic [1:0] phasea_split_idx, phaseb_split_idx;
  logic phasea_split_last, phaseb_split_last;
  logic phasea_window, phaseb_window, phasea_depth_active;
  phasea_state_t phasea_state;
  phaseb_state_t phaseb_state;
  logic [0:0] phasea_micro_idx, phasea_pending_micro;
  logic [1:0] phasea_kv_blk_idx, phasea_pending_kv_blk;
  logic [3:0] phasea_p_capture_cnt;
  logic phasea_done_all;
  logic [0:0] phaseb_micro_idx;
  logic [1:0] phaseb_kv_blk_idx;
  logic [2:0] phaseb_dim_blk_idx;
  logic [3:0] phaseb_k_idx;
  logic [4:0] phaseb_row_update_idx;
  logic [0:0] phaseb_norm_micro_idx;
  logic phaseb_done_all;
  logic writeback_active, writeback_launch;
  logic [15:0] softmax_q_tile_start, softmax_kv_tile_start;
  logic sm_state_load;
  logic [31:0] sm_state_m_in [TILE_ROWS], sm_state_l_in [TILE_ROWS];
  logic [31:0] sm_m_ctx [Q_MICROTILES][TILE_ROWS];
  logic [31:0] sm_l_ctx [Q_MICROTILES][TILE_ROWS];
  logic [P_ROW_W-1:0] p_store_wr_word [TILE_ROWS];
  logic [P_ROW_W-1:0] p_store_active_word [TILE_ROWS];
  logic [31:0] corr_store [Q_MICROTILES][KV_SUBBLOCKS][TILE_ROWS];
  logic [31:0] obuf_corr_sel;
  logic [31:0] obuf_l_sel [TILE_ROWS];
  logic        obuf_bank_sel_runtime;
  assign phaseb_window = busy && mac_phase && !mac_start && !softmax_start && !kv_load_start && !o_write_start;
  assign phasea_depth_active = (phasea_state == PA_RUN);
  assign phasea_depth_last = (depth_cnt == HEAD_DIM_LAST_U7);
  assign phasea_split_last = (phasea_split_idx == 2'(TILE_SPLIT_FACTOR - 1));
  assign phaseb_split_last = (phaseb_split_idx == 2'(TILE_SPLIT_FACTOR - 1));
  logic axis_valid; logic [15:0] axis_data; logic axis_last; logic [1:0] axis_dest; logic axis_done;
  logic src_valid, src_ready, src_last; logic [15:0] src_data; logic src_done;
  logic buf_sel, o_bank_sel; logic [15:0] q_buf_rd;
  logic [15:0] q_block_rd [TILE_ROWS];
  logic [4:0] q_rd_row; logic [0:0] q_rd_row_start; logic [6:0] q_rd_dim;
  logic [15:0] k_rd [TILE_KV], v_rd [TILE_KV];
  logic k_wr_en, v_wr_en, k_rd_en, v_rd_en;
  logic [15:0] k_wr_addr, v_wr_addr, k_rd_start, v_rd_start;
  logic [6:0] k_rd_dim, v_rd_dim;
  logic [15:0] mac_row [TILE_ROWS], mac_col [TILE_COLS];
  logic [1:0] mac_split; logic mac_clear_accum, mac_accum_en; logic [31:0] mac_col_out [TILE_COLS];
  logic [31:0] mac_block_out [TILE_ROWS][TILE_COLS];
  logic [15:0] q_tile_start, kv_tile_start;
  logic [5:0] active_q_rows;
  logic [6:0] active_kv_cols;
  logic causal_en;
  logic s_valid, p_valid; logic [31:0] s_block [TILE_ROWS][TILE_COLS];
  logic [31:0] p_block [TILE_ROWS][TILE_COLS];
  logic [31:0] m_state [TILE_ROWS], l_state [TILE_ROWS], correction [TILE_ROWS];
  logic psum_en, psum_clear; logic [31:0] psum_in [TILE_COLS], psum_out [TILE_COLS];
  logic obuf_update, obuf_norm; logic [3:0] obuf_row; logic [2:0] obuf_dim_blk; logic [31:0] obuf_data [TILE_COLS];
  logic obuf_valid_raw; logic [4:0] obuf_o_row; logic [6:0] obuf_o_dim;
  logic [15:0] obuf_data_raw;
  logic obuf_clear_bank, obuf_clear_bank_sel;
  logic k_loaded, v_loaded;
  logic [1:0] q_bank_ready;
  logic q_load_bank_sel;
  logic q_load_bank_sel_latched;
  logic q_load_outstanding;
  logic q_same_bank_reload_pending;
  logic q_load_start_d;
  logic kv_load_start_d;
  logic o_write_done_d;
  logic q_compute_bank_sel;
  logic q_ready_bank_sel;
  logic qbuf_wr_en;
  logic v_rd_vec_en;
  logic [15:0] v_rd_vec_token_idx;
  logic [6:0] v_rd_vec_dim_start;
  logic [15:0] v_rd_vec_data [TILE_COLS];
  logic [15:0] k_rd_vec_unused [TILE_COLS];
  logic o_write_done_sticky;
  logic o_write_tile_done;
  logic        start_ready_unused;
  logic        fsm_error_unused;
  logic        perf_valid_unused;
  logic        softmax_block_done_unused;
  logic [31:0] stall_cycles_unused;
  logic [31:0] sink_bytes_received_unused;
  logic [31:0] src_bytes_sent_unused;
  logic        sink_overflow_unused;
  logic        sink_underflow_unused;
  logic        qbuf_bank_ready_unused;
  logic [1:0] q_microtiles_active;
  logic [2:0] kv_subblocks_active;
  logic [0:0] q_microtile_last_idx;
  logic [1:0] kv_subblock_last_idx;
  logic       final_q_tile_active;
  logic       final_head_active;
  logic       final_group_active;
  logic [3:0] phasea_p_capture_target;
  logic [4:0] phasea_softmax_active_rows, phasea_softmax_active_cols;
  logic [4:0] phaseb_active_rows, writeback_active_rows;
  logic [1:0] phaseb_microtile_ready;
  logic [3:0] phaseb_row_update_idx_narrow;
  logic phaseb_prime_now;
  logic [0:0] phaseb_prime_micro_idx;
  logic [1:0] phaseb_prime_kv_blk_idx;
  logic [2:0] phaseb_prime_dim_blk_idx;
  logic writeback_last_sample;
  logic phaseb_row_update_last;
  logic [clog2_safe(P_STORE_BANK_DEPTH)-1:0] p_store_wr_addr;
  logic [clog2_safe(P_STORE_BANK_DEPTH)-1:0] p_store_rd_addr;

  function automatic logic [4:0] active_rows_for_micro(
    input logic [5:0] total_rows,
    input logic [0:0] micro_idx
  );
    logic [5:0] rows_left;
    begin
      if (micro_idx == 1'b0) begin
        rows_left = total_rows;
      end else if (total_rows > 6'(TILE_ROWS)) begin
        rows_left = total_rows - 6'(TILE_ROWS);
      end else begin
        rows_left = 6'd0;
      end

      if (rows_left > 6'(TILE_ROWS))
        active_rows_for_micro = TILE_ROWS_U5;
      else
        active_rows_for_micro = rows_left[4:0];
    end
  endfunction

  function automatic logic [4:0] active_cols_for_kv_subblock(
    input logic [6:0] total_cols,
    input logic [1:0] subblock_idx
  );
    logic [6:0] col_base;
    logic [6:0] cols_left;
    begin
      col_base = {1'b0, subblock_idx, 4'd0};
      if (total_cols <= col_base) begin
        cols_left = 7'd0;
      end else begin
        cols_left = total_cols - col_base;
      end

      if (cols_left > 7'(TILE_COLS))
        active_cols_for_kv_subblock = TILE_COLS_U5;
      else
        active_cols_for_kv_subblock = cols_left[4:0];
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    integer ctxi, ctxj, ctxk, ctxm;
    if (!rst_n) begin
      depth_cnt <= 7'd0;
      phasea_split_idx <= 2'd0;
    end else begin
      if (phasea_state == PA_LOAD_CTX) begin
        depth_cnt <= 7'd0;
        phasea_split_idx <= 2'd0;
      end else if (phasea_depth_active) begin
        if (phasea_split_last) begin
          depth_cnt <= depth_cnt + 7'd1;
          phasea_split_idx <= 2'd0;
        end else begin
          depth_cnt <= depth_cnt;
          phasea_split_idx <= phasea_split_idx + 2'd1;
        end
      end else begin
        depth_cnt <= 7'd0;
        phasea_split_idx <= 2'd0;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    integer ctxi, ctxj, ctxk, ctxm;
    if (!rst_n) begin
      phasea_state <= PA_IDLE;
      phasea_micro_idx <= '0;
      phasea_kv_blk_idx <= '0;
      phasea_pending_micro <= '0;
      phasea_pending_kv_blk <= '0;
      phasea_p_capture_cnt <= 4'd0;
      s_valid <= 1'b0;
      softmax_q_tile_start <= 16'd0;
      softmax_kv_tile_start <= 16'd0;
      for (ctxi = 0; ctxi < TILE_ROWS; ctxi++) begin
        sm_state_m_in[ctxi] <= FP32_NEG_INF;
        sm_state_l_in[ctxi] <= 32'd0;
      end
      for (ctxm = 0; ctxm < Q_MICROTILES; ctxm++) begin
        for (ctxi = 0; ctxi < TILE_ROWS; ctxi++) begin
          sm_m_ctx[ctxm][ctxi] <= FP32_NEG_INF;
          sm_l_ctx[ctxm][ctxi] <= 32'd0;
          for (ctxj = 0; ctxj < KV_SUBBLOCKS; ctxj++) begin
            corr_store[ctxm][ctxj][ctxi] <= 32'd0;
          end
        end
      end
    end else begin
      s_valid <= 1'b0;
      if (!phasea_window) begin
        if (phasea_state == PA_IDLE)
          phasea_p_capture_cnt <= 4'd0;
      end

      case (phasea_state)
        PA_IDLE: begin
          if (phasea_window) begin
            phasea_micro_idx <= 1'd0;
            phasea_kv_blk_idx <= 2'd0;
            phasea_p_capture_cnt <= 4'd0;
            phasea_state <= PA_LOAD_CTX;
          end
        end
        PA_LOAD_CTX: begin
          softmax_q_tile_start <= q_tile_start + {{11{1'b0}}, phasea_micro_idx, 4'd0};
          softmax_kv_tile_start <= kv_tile_start + {{10{1'b0}}, phasea_kv_blk_idx, 4'd0};
          for (ctxi = 0; ctxi < TILE_ROWS; ctxi++) begin
            sm_state_m_in[ctxi] <= sm_m_ctx[phasea_micro_idx][ctxi];
            sm_state_l_in[ctxi] <= sm_l_ctx[phasea_micro_idx][ctxi];
          end
          phasea_state <= PA_RUN;
        end
        PA_RUN: begin
          if (phasea_depth_last && phasea_split_last)
            phasea_state <= PA_FLUSH;
        end
        PA_FLUSH: begin
          s_valid <= 1'b1;
          softmax_q_tile_start <= q_tile_start + {{11{1'b0}}, phasea_micro_idx, 4'd0};
          softmax_kv_tile_start <= kv_tile_start + {{10{1'b0}}, phasea_kv_blk_idx, 4'd0};
          phasea_pending_micro <= phasea_micro_idx;
          phasea_pending_kv_blk <= phasea_kv_blk_idx;
          phasea_state <= PA_WAIT_P;
        end
        PA_WAIT_P: begin
          if (p_valid) begin
            if (phasea_kv_blk_idx == kv_subblock_last_idx) begin
              phasea_kv_blk_idx <= 2'd0;
              if (phasea_micro_idx == q_microtile_last_idx) begin
                phasea_state <= PA_IDLE;
              end else begin
                phasea_micro_idx <= phasea_micro_idx + 1'd1;
                phasea_state <= PA_LOAD_CTX;
              end
            end else begin
              phasea_kv_blk_idx <= phasea_kv_blk_idx + 2'd1;
              phasea_state <= PA_LOAD_CTX;
            end
          end
        end
        default: begin
          phasea_state <= PA_IDLE;
        end
      endcase

      if (p_valid) begin
        phasea_p_capture_cnt <= phasea_p_capture_cnt + 4'd1;
        for (ctxi = 0; ctxi < TILE_ROWS; ctxi++) begin
          sm_m_ctx[phasea_pending_micro][ctxi] <= m_state[ctxi];
          sm_l_ctx[phasea_pending_micro][ctxi] <= l_state[ctxi];
          corr_store[phasea_pending_micro][phasea_pending_kv_blk][ctxi] <= correction[ctxi];
        end
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    integer ctxi, ctxj;
    if (!rst_n) begin
      phaseb_state <= PB_IDLE;
      phaseb_micro_idx <= '0;
      phaseb_kv_blk_idx <= '0;
      phaseb_dim_blk_idx <= '0;
      phaseb_k_idx <= '0;
      phaseb_split_idx <= 2'd0;
      phaseb_row_update_idx <= '0;
      phaseb_norm_micro_idx <= '0;
      writeback_active <= 1'b0;
      writeback_launch <= 1'b0;
      phaseb_microtile_ready <= 2'b00;
    end else begin
      writeback_launch <= 1'b0;

      if (!writeback_active &&
          !o_write_done &&
          phaseb_microtile_ready[phaseb_norm_micro_idx] &&
          ((phaseb_norm_micro_idx != q_microtile_last_idx) || phaseb_done_all || o_write_start)) begin
        writeback_active <= 1'b1;
        writeback_launch <= 1'b1;
      end else if (writeback_active &&
                   writeback_last_sample) begin
        if (phaseb_norm_micro_idx != q_microtile_last_idx) begin
          if (phaseb_microtile_ready[phaseb_norm_micro_idx + 1'd1] &&
              (((phaseb_norm_micro_idx + 1'd1) != q_microtile_last_idx) || phaseb_done_all || o_write_start)) begin
            phaseb_norm_micro_idx <= phaseb_norm_micro_idx + 1'd1;
            writeback_launch <= 1'b1;
          end else begin
            writeback_active <= 1'b0;
            phaseb_norm_micro_idx <= phaseb_norm_micro_idx + 1'd1;
          end
        end else begin
          writeback_active <= 1'b0;
        end
      end

      if (!phaseb_window) begin
        phaseb_state <= PB_IDLE;
        phaseb_split_idx <= 2'd0;
      end else begin
        unique case (phaseb_state)
          PB_IDLE: begin
            phaseb_micro_idx <= 1'd0;
            phaseb_kv_blk_idx <= 2'd0;
            phaseb_dim_blk_idx <= 3'd0;
            phaseb_k_idx <= 4'd0;
            phaseb_split_idx <= 2'd0;
            phaseb_row_update_idx <= 5'd0;
            phaseb_norm_micro_idx <= 1'd0;
            phaseb_microtile_ready <= 2'b00;
            phaseb_state <= PB_RUN;
          end
          PB_RUN: begin
            if (phaseb_split_last) begin
              phaseb_split_idx <= 2'd0;
              if (phaseb_k_idx == TILE_COLS_LAST_U4) begin
                phaseb_row_update_idx <= 5'd0;
                phaseb_state <= PB_UPDATE;
              end else begin
                phaseb_k_idx <= phaseb_k_idx + 4'd1;
              end
            end else begin
              phaseb_split_idx <= phaseb_split_idx + 2'd1;
            end
          end
          PB_UPDATE: begin
            if (phaseb_row_update_last) begin
              phaseb_row_update_idx <= 5'd0;
              if (phaseb_dim_blk_idx == DIM_SUBBLOCKS_LAST_U3) begin
                phaseb_dim_blk_idx <= 3'd0;
                if (phaseb_kv_blk_idx == kv_subblock_last_idx) begin
                  phaseb_microtile_ready[phaseb_micro_idx] <= 1'b1;
                  if (!writeback_active &&
                      !o_write_done &&
                      (phaseb_norm_micro_idx == phaseb_micro_idx)) begin
                    writeback_active <= 1'b1;
                    writeback_launch <= 1'b1;
                  end
                  phaseb_kv_blk_idx <= 2'd0;
                  if (phaseb_micro_idx == q_microtile_last_idx) begin
                    phaseb_state <= PB_DONE;
                  end else begin
                    phaseb_micro_idx <= phaseb_micro_idx + 1'd1;
                    phaseb_k_idx <= 4'd0;
                    phaseb_split_idx <= 2'd0;
                    phaseb_state <= PB_RUN;
                  end
                end else begin
                  phaseb_kv_blk_idx <= phaseb_kv_blk_idx + 2'd1;
                  phaseb_k_idx <= 4'd0;
                  phaseb_split_idx <= 2'd0;
                  phaseb_state <= PB_RUN;
                end
              end else begin
                phaseb_dim_blk_idx <= phaseb_dim_blk_idx + 3'd1;
                phaseb_k_idx <= 4'd0;
                phaseb_split_idx <= 2'd0;
                phaseb_state <= PB_RUN;
              end
            end else begin
              phaseb_row_update_idx <= phaseb_row_update_idx + 5'd1;
            end
          end
          PB_DONE: begin
            phaseb_state <= PB_DONE;
          end
        endcase
      end
    end
  end

  assign q_microtiles_active = (active_q_rows > 6'(TILE_ROWS)) ? 2'd2 : 2'd1;
  assign q_microtile_last_idx = 1'(q_microtiles_active - 2'd1);
  assign kv_subblocks_active = 3'((active_kv_cols + 7'(TILE_COLS) - 7'd1) >> 4);
  assign kv_subblock_last_idx = kv_subblocks_active[1:0] - 2'd1;
  assign phasea_p_capture_target = 4'(q_microtiles_active * kv_subblocks_active);
  assign phasea_done_all = (phasea_p_capture_cnt == phasea_p_capture_target);
  assign phaseb_done_all = (phaseb_state == PB_DONE);
  assign phaseb_row_update_idx_narrow = phaseb_row_update_idx[3:0];
  assign phaseb_row_update_last = (phaseb_active_rows != 5'd0) &&
                                  (phaseb_row_update_idx == phaseb_active_rows - 5'd1);
  assign p_store_wr_addr = {phasea_pending_micro, phasea_pending_kv_blk};
  assign p_store_rd_addr = {phaseb_prime_micro_idx, phaseb_prime_kv_blk_idx};

  always_comb begin
    phasea_softmax_active_rows = active_rows_for_micro(active_q_rows, phasea_micro_idx);
    phaseb_active_rows = active_rows_for_micro(active_q_rows, phaseb_micro_idx);
    writeback_active_rows = active_rows_for_micro(active_q_rows, phaseb_norm_micro_idx);
    phasea_softmax_active_cols = active_cols_for_kv_subblock(active_kv_cols, phasea_kv_blk_idx);

    for (int ri = 0; ri < TILE_ROWS; ri++) begin
      if (!mac_phase)
        mac_row[ri] = (5'(ri) < phasea_softmax_active_rows) ? q_block_rd[ri] : 16'd0;
      else if (5'(ri) < phaseb_active_rows)
        mac_row[ri] = p_store_active_word[ri][phaseb_k_idx*FP32_W + 16 +: 16];
      else
        mac_row[ri] = 16'd0;
    end

    for (int ci = 0; ci < TILE_COLS; ci++) begin
      if (!mac_phase)
        mac_col[ci] = k_rd[phasea_kv_blk_idx * TILE_COLS + ci];
      else
        mac_col[ci] = v_rd_vec_data[ci];
    end

    for (int ri = 0; ri < TILE_ROWS; ri++) begin
      if (writeback_active || o_write_done)
        obuf_l_sel[ri] = sm_l_ctx[phaseb_norm_micro_idx][ri];
      else
        obuf_l_sel[ri] = sm_l_ctx[phaseb_micro_idx][ri];
    end
    if ((phaseb_state == PB_UPDATE) && (phaseb_row_update_idx < phaseb_active_rows))
      obuf_corr_sel = corr_store[phaseb_micro_idx][phaseb_kv_blk_idx][phaseb_row_update_idx_narrow];
    else
      obuf_corr_sel = 32'h3F80_0000;
    for (int di = 0; di < TILE_COLS; di++) begin
      obuf_data[di] = mac_block_out[phaseb_row_update_idx_narrow][di];
    end
    for (int pri = 0; pri < TILE_ROWS; pri++) begin
      for (int pci = 0; pci < TILE_COLS; pci++) begin
        p_store_wr_word[pri][pci*FP32_W +: FP32_W] = p_block[pri][pci];
      end
    end
  end

  always_comb begin
    phaseb_prime_now = 1'b0;
    phaseb_prime_micro_idx = phaseb_micro_idx;
    phaseb_prime_kv_blk_idx = phaseb_kv_blk_idx;
    phaseb_prime_dim_blk_idx = phaseb_dim_blk_idx;

    if (phaseb_state == PB_IDLE) begin
      phaseb_prime_now = 1'b1;
      phaseb_prime_micro_idx = 1'd0;
      phaseb_prime_kv_blk_idx = 2'd0;
      phaseb_prime_dim_blk_idx = 3'd0;
    end else if ((phaseb_state == PB_UPDATE) && phaseb_row_update_last) begin
      if (phaseb_dim_blk_idx == DIM_SUBBLOCKS_LAST_U3) begin
        phaseb_prime_dim_blk_idx = 3'd0;
        if (phaseb_kv_blk_idx == kv_subblock_last_idx) begin
          phaseb_prime_kv_blk_idx = 2'd0;
          if (phaseb_micro_idx != q_microtile_last_idx) begin
            phaseb_prime_now = 1'b1;
            phaseb_prime_micro_idx = phaseb_micro_idx + 1'd1;
          end
        end else begin
          phaseb_prime_now = 1'b1;
          phaseb_prime_kv_blk_idx = phaseb_kv_blk_idx + 2'd1;
        end
      end else begin
        phaseb_prime_now = 1'b1;
        phaseb_prime_dim_blk_idx = phaseb_dim_blk_idx + 3'd1;
      end
    end
  end

  genvar gpstore;
  generate
    for (gpstore = 0; gpstore < TILE_ROWS; gpstore++) begin : GEN_P_STORE
      // The store is only eight words deep. Mapping each 512-bit row to BRAM
      // wastes seven RAMB36 tiles, while the complete store is just 64 Kbit.
      (* ram_style = "distributed" *) logic [P_ROW_W-1:0] p_mem [0:P_STORE_BANK_DEPTH-1];
      always_ff @(posedge clk) begin
        if (p_valid) begin
          p_mem[p_store_wr_addr] <= p_store_wr_word[gpstore];
        end
      end
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          p_store_active_word[gpstore] <= '0;
        end else begin
          if (phaseb_prime_now) begin
            p_store_active_word[gpstore] <= p_mem[p_store_rd_addr];
          end
        end
      end
    end
  endgenerate

  genvar gpi, gslr, gslc;
  generate
    for (gpi=0;gpi<TILE_COLS;gpi++) begin:PI assign psum_in[gpi] = mac_col_out[gpi]; end
    for (gslr=0;gslr<TILE_ROWS;gslr++) for (gslc=0;gslc<TILE_COLS;gslc++) begin:SB
      always_ff @(posedge clk) if((phasea_state == PA_FLUSH) && !mac_phase) s_block[gslr][gslc] <= mac_block_out[gslr][gslc];
    end
  endgenerate
  assign mac_split = (TILE_SPLIT_FACTOR <= 1) ? 2'd2
                                             : (mac_phase ? phaseb_split_idx : phasea_split_idx);
  assign mac_accum_en = phasea_depth_active || (phaseb_state == PB_RUN);
  assign obuf_update = (phaseb_state == PB_UPDATE) && (phaseb_row_update_idx < phaseb_active_rows);
  assign obuf_row = phaseb_row_update_idx_narrow;
  assign obuf_dim_blk = phaseb_dim_blk_idx;
  assign obuf_norm = writeback_launch;
  assign mac_done = mac_phase ? phaseb_done_all : phasea_done_all;
  assign kv_load_done = k_loaded && v_loaded;
  assign q_compute_bank_sel = buf_sel;
  assign phasea_window = busy && !mac_phase && !mac_start && !softmax_start && !kv_load_start && !o_write_start &&
                         !(q_load_start && (q_load_bank_sel == q_compute_bank_sel));
  assign q_load_done = q_load_outstanding ? q_bank_ready[q_load_bank_sel_latched]
                                          : q_bank_ready[q_ready_bank_sel];
  assign o_write_tile_done = writeback_last_sample &&
                             src_ready &&
                             (phaseb_norm_micro_idx == q_microtile_last_idx);
  assign o_write_done = o_write_tile_done || o_write_done_sticky;
  assign softmax_done = softmax_start && phasea_done_all;
  assign sm_state_load = (phasea_state == PA_LOAD_CTX);
  assign psum_en=1'b1; assign psum_clear = kv_tile_first && depth_cnt==7'd0;
  assign obuf_clear_bank = kv_tile_first &&
                           phaseb_prime_now &&
                           (phaseb_prime_kv_blk_idx == 2'd0) &&
                           (phaseb_prime_dim_blk_idx == 3'd0);
  assign obuf_clear_bank_sel = phaseb_prime_micro_idx;
  assign obuf_bank_sel_runtime = (writeback_active || o_write_done)
                               ? ~phaseb_norm_micro_idx
                               : phaseb_micro_idx;
  assign k_wr_en = axis_valid && (axis_dest == STREAM_TO_K_CACHE);
  assign v_wr_en = axis_valid && (axis_dest == STREAM_TO_V_CACHE);
  assign qbuf_wr_en = axis_valid && (axis_dest == STREAM_TO_Q_BUF);
  assign k_rd_en=phasea_depth_active; assign v_rd_en=1'b0;
  assign k_rd_start=kv_tile_start; assign v_rd_start=16'd0;
  assign k_rd_dim=depth_cnt; assign v_rd_dim=depth_cnt;
  assign v_rd_vec_en = phaseb_prime_now ||
                       (phaseb_state == PB_RUN && phaseb_split_last && phaseb_k_idx != TILE_COLS_LAST_U4);
  assign v_rd_vec_token_idx = kv_tile_start +
                              (phaseb_prime_now
                                ? {{10{1'b0}}, phaseb_prime_kv_blk_idx, 4'd0}
                                : ({{10{1'b0}}, phaseb_kv_blk_idx, 4'd0} + {12'd0, phaseb_k_idx + 4'd1}));
  assign v_rd_vec_dim_start = phaseb_prime_now ? {phaseb_prime_dim_blk_idx, 4'd0}
                                               : {phaseb_dim_blk_idx, 4'd0};
  assign q_rd_row={phasea_micro_idx, 4'd0}; assign q_rd_row_start=phasea_micro_idx; assign q_rd_dim=depth_cnt;
  assign mac_clear_accum = !mac_phase ? ((depth_cnt == 7'd0) && (phasea_split_idx == 2'd0))
                                      : ((phaseb_state == PB_RUN) && (phaseb_k_idx == 4'd0) && (phaseb_split_idx == 2'd0));
  assign src_valid = obuf_valid_raw && (obuf_o_row < writeback_active_rows);
  assign final_q_tile_active = ({1'b0, q_tile_start} + {11'd0, active_q_rows}) >= {1'b0, seq_len};
  assign final_head_active = (q_head == 2'(GQA_GROUP_SIZE - 1));
  assign final_group_active = (gqa_group == 3'(N_KV_HEADS - 1));
  assign writeback_last_sample = writeback_active &&
                                 obuf_valid_raw &&
                                 src_ready &&
                                 (writeback_active_rows != 5'd0) &&
                                 (obuf_o_row == writeback_active_rows - 5'd1) &&
                                 (obuf_o_dim == HEAD_DIM_LAST_U7);
  assign src_data = obuf_data_raw;
  assign src_last = (writeback_active_rows != 5'd0) &&
                    final_q_tile_active &&
                    final_head_active &&
                    final_group_active &&
                    (phaseb_norm_micro_idx == q_microtile_last_idx) &&
                    (obuf_o_row == writeback_active_rows - 5'd1) && (obuf_o_dim == HEAD_DIM_LAST_U7);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      k_wr_addr <= 16'd0;
      v_wr_addr <= 16'd0;
      k_loaded  <= 1'b0;
      v_loaded  <= 1'b0;
      q_bank_ready <= 2'b00;
      q_load_bank_sel_latched <= 1'b0;
      q_load_outstanding <= 1'b0;
      q_same_bank_reload_pending <= 1'b0;
      q_load_start_d <= 1'b0;
      kv_load_start_d <= 1'b0;
      o_write_done_d <= 1'b0;
      o_write_done_sticky <= 1'b0;
    end else begin
      if (k_wr_en) k_wr_addr <= k_wr_addr + 16'd1;
      if (v_wr_en) v_wr_addr <= v_wr_addr + 16'd1;

      if (q_load_start && !q_load_start_d) begin
        q_load_bank_sel_latched <= q_load_bank_sel;
        q_bank_ready[q_load_bank_sel] <= 1'b0;
        q_load_outstanding <= 1'b1;
        q_same_bank_reload_pending <= (q_load_bank_sel == q_compute_bank_sel);
      end
      q_load_start_d <= q_load_start;

      if (q_load_outstanding && q_bank_ready[q_load_bank_sel_latched])
        q_load_outstanding <= 1'b0;

      if (kv_load_start && !kv_load_start_d) begin
        k_loaded <= 1'b0;
        v_loaded <= 1'b0;
      end
      kv_load_start_d <= kv_load_start;
      o_write_done_d <= o_write_done;

      if (o_write_tile_done)
        o_write_done_sticky <= 1'b1;

      if (axis_done) begin
        case (axis_dest)
          STREAM_TO_K_CACHE: begin
            k_loaded <= 1'b1;
            k_wr_addr <= 16'd0;
          end
          STREAM_TO_V_CACHE: begin
            v_loaded <= 1'b1;
            v_wr_addr <= 16'd0;
          end
          STREAM_TO_Q_BUF: begin
            q_bank_ready[q_load_bank_sel_latched] <= 1'b1;
          end
          default: begin end
        endcase
      end

      if (start) begin
        k_loaded <= 1'b0;
        v_loaded <= 1'b0;
        q_load_outstanding <= 1'b0;
        q_same_bank_reload_pending <= 1'b0;
        o_write_done_d <= 1'b0;
        o_write_done_sticky <= 1'b0;
      end else if (o_write_start && o_write_done_sticky) begin
        o_write_done_sticky <= 1'b0;
      end

      if (o_write_done && !o_write_done_d &&
          !(q_load_start && (q_load_bank_sel == q_compute_bank_sel)) &&
          !q_same_bank_reload_pending) begin
        q_bank_ready[q_compute_bank_sel] <= 1'b0;
      end

      if (o_write_done && !o_write_done_d)
        q_same_bank_reload_pending <= 1'b0;
    end
  end

  attn_axi_lite_slave u_csr(.clk,.rst_n,.s_axi_awaddr,.s_axi_awvalid,.s_axi_awready,.s_axi_wdata,.s_axi_wstrb,.s_axi_wvalid,.s_axi_wready,.s_axi_bresp,.s_axi_bvalid,.s_axi_bready,.s_axi_araddr,.s_axi_arvalid,.s_axi_arready,.s_axi_rdata,.s_axi_rresp,.s_axi_rvalid,.s_axi_rready,.start,.seq_len,.cfg_causal,.gqa_group,.q_head,.stream_dest(stream_dest_cfg),.stream_len(stream_len_cfg),.result_len(result_len_cfg),.done,.cycle_cnt,.mac_cycles);
  attn_axi_stream_sink u_sink(.clk,.rst_n,.s_axis_tdata,.s_axis_tvalid,.s_axis_tready,.s_axis_tlast,.data_valid(axis_valid),.data_out(axis_data),.data_last(axis_last),.cfg_dest(stream_dest_cfg),.cfg_len(stream_len_cfg),.cfg_burst(4'd0),.dest_sel(axis_dest),.bytes_received(sink_bytes_received_unused),.overflow(sink_overflow_unused),.underflow(sink_underflow_unused),.done(axis_done));
  attn_axi_stream_source u_src(.clk,.rst_n,.data_valid(src_valid),.data_in(src_data),.data_last(src_last),.data_ready(src_ready),.cfg_len(result_len_cfg),.m_axis_tdata,.m_axis_tvalid,.m_axis_tready,.m_axis_tlast,.bytes_sent(src_bytes_sent_unused),.done(src_done));
  attn_core u_fsm(.clk,.rst_n,.start,.start_ready(start_ready_unused),.seq_len,.cfg_q_pos_base(16'd0),.cfg_kv_pos_base(16'd0),.cfg_causal(cfg_causal),.done,.busy,.kv_load_start,.kv_load_done,.q_load_start,.q_load_done,.o_write_start,.o_write_done,.buf_sel(buf_sel),.q_load_bank_sel(q_load_bank_sel),.q_ready_bank_sel(q_ready_bank_sel),.o_bank_sel(o_bank_sel),.group_advance(group_advance),.mac_phase,.mac_start,.mac_done,.softmax_start,.softmax_done,.kv_tile_first,.kv_tile_last,.q_tile_start(q_tile_start),.kv_tile_start(kv_tile_start),.active_q_rows(active_q_rows),.active_kv_cols(active_kv_cols),.causal_en(causal_en),.current_group(gqa_group),.current_head(q_head),.error(fsm_error_unused),.cycle_cnt,.mac_cycles,.stall_cycles(stall_cycles_unused),.perf_valid(perf_valid_unused));
  kv_cache_ram u_kcache(.clk,.rst_n,.wr_en(k_wr_en),.wr_addr(k_wr_addr),.wr_data(axis_data),.rd_en(k_rd_en),.rd_token_start(k_rd_start),.rd_dim(k_rd_dim),.rd_data(k_rd),.rd_vec_en(1'b0),.rd_vec_token_idx(16'd0),.rd_vec_dim_start(7'd0),.rd_vec_data(k_rd_vec_unused));
  kv_cache_ram #(.TOKEN_PARALLEL_READ(1'b0)) u_vcache(.clk,.rst_n,.wr_en(v_wr_en),.wr_addr(v_wr_addr),.wr_data(axis_data),.rd_en(v_rd_en),.rd_token_start(v_rd_start),.rd_dim(v_rd_dim),.rd_data(v_rd),.rd_vec_en(v_rd_vec_en),.rd_vec_token_idx(v_rd_vec_token_idx),.rd_vec_dim_start(v_rd_vec_dim_start),.rd_vec_data(v_rd_vec_data));
  tile_buffer u_qbuf(.clk,.rst_n,.wr_en(qbuf_wr_en),.wr_data(axis_data),.rd_en(phasea_depth_active),.rd_row(q_rd_row),.rd_row_start(q_rd_row_start),.rd_dim(q_rd_dim),.rd_data(q_buf_rd),.rd_block_data(q_block_rd),.wr_bank_sel(q_load_bank_sel),.rd_bank_sel(q_compute_bank_sel),.bank_ready(qbuf_bank_ready_unused));
  attn_tile u_mac(.clk,.rst_n,.phase_sel(mac_phase),.row_data(mac_row),.col_data(mac_col),.split_phase(mac_split),.clear_accum(mac_clear_accum),.accum_en(mac_accum_en),.block_out(mac_block_out),.col_out(mac_col_out));
  softmax_engine u_softmax(.clk,.rst_n,.s_valid,.s_data(s_block),.kv_tile_first,.kv_tile_last,.causal_mask_en(causal_en),.q_tile_start(softmax_q_tile_start),.kv_tile_start(softmax_kv_tile_start),.active_rows(phasea_softmax_active_rows),.active_cols(phasea_softmax_active_cols),.state_load(sm_state_load),.state_m_in(sm_state_m_in),.state_l_in(sm_state_l_in),.m_state,.l_state,.p_valid,.p_data(p_block),.correction,.done(softmax_block_done_unused));
  psum_accum #(.ENABLE_LEGACY_PATHS(1'b0)) u_psum(
    .clk,
    .rst_n,
    .clear(psum_clear),
    .en(psum_en),
    .tile_col(psum_in),
    .en_lo(1'b0),
    .en_hi(1'b0),
    .col_lo('{default:32'd0}),
    .col_hi('{default:32'd0}),
    .en_q0(1'b0),
    .en_q1(1'b0),
    .en_q2(1'b0),
    .en_q3(1'b0),
    .col_q0('{default:32'd0}),
    .col_q1('{default:32'd0}),
    .col_q2('{default:32'd0}),
    .col_q3('{default:32'd0}),
    .psum(psum_out)
  );
  output_buffer u_obuf(.clk,.rst_n,.clear_bank(obuf_clear_bank),.clear_bank_sel(obuf_clear_bank_sel),.acc_update(obuf_update),.acc_row(obuf_row),.acc_dim_blk(obuf_dim_blk),.acc_data(obuf_data),.acc_correction(obuf_corr_sel),.bank_sel(obuf_bank_sel_runtime),.normalize(obuf_norm),.active_rows(writeback_active_rows),.l_state(obuf_l_sel),.o_ready(src_ready),.o_valid(obuf_valid_raw),.o_row(obuf_o_row),.o_dim(obuf_o_dim),.o_data(obuf_data_raw));
endmodule
