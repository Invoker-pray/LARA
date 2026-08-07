`timescale 1ns/1ps

// Board-matrix case reproducer.  The testbench reads the same raw BF16
// tensors as board_matrix.py, services every K/V and Q load request, and
// compares the complete output stream against expected_o.
module tb_attn_top_board_case;
  import attn_pkg::*;

`ifdef BOARD_CASE_TEST_SEQ
  localparam int TEST_SEQ = `BOARD_CASE_TEST_SEQ;
`else
  localparam int TEST_SEQ = 128;
`endif
  localparam int Q_WORDS = N_Q_HEADS * TEST_SEQ * HEAD_DIM;
  localparam int KV_WORDS = N_KV_HEADS * TEST_SEQ * HEAD_DIM;
  localparam int OUTPUT_WORDS = N_Q_HEADS * TEST_SEQ * HEAD_DIM;
  localparam int Q_TILE_WORDS = TILE_Q * HEAD_DIM;
  localparam int Q_BEATS = Q_TILE_WORDS / 2;
  localparam int KV_BEATS = (TEST_SEQ * HEAD_DIM) / 2;
  localparam int OUTPUT_BEATS = OUTPUT_WORDS / 2;

  logic clk, rst_n;
  logic [13:0] s_axi_awaddr, s_axi_araddr;
  logic s_axi_awvalid, s_axi_wvalid, s_axi_bready, s_axi_arvalid, s_axi_rready;
  logic [31:0] s_axi_wdata, s_axi_rdata;
  logic [3:0] s_axi_wstrb;
  logic s_axi_awready, s_axi_wready, s_axi_bvalid, s_axi_arready, s_axi_rvalid;
  logic [1:0] s_axi_bresp, s_axi_rresp;
  logic [31:0] s_axis_tdata, m_axis_tdata;
  logic s_axis_tvalid, s_axis_tready, s_axis_tlast;
  logic m_axis_tvalid, m_axis_tready, m_axis_tlast;

  logic [15:0] q_mem [0:Q_WORDS-1];
  logic [15:0] k_mem [0:KV_WORDS-1];
  logic [15:0] v_mem [0:KV_WORDS-1];
  logic [15:0] expected_mem [0:OUTPUT_WORDS-1];

  integer errors;
  integer output_beats;
  integer k_v_requests;
  integer q_requests;
  integer first_error_beat;
  integer softmax_debug_dumps;
  integer phasea_debug_cycles;
  integer phaseb_debug_events;
  integer phaseb_prev_state;
  integer phaseb_prev_micro;
  integer phaseb_prev_kv;
  integer phaseb_prev_dim;
  integer phaseb_prev_k;
  integer row1_debug_events;
  logic [31:0] first_got;
  logic [31:0] first_expected;
  string case_dir;
  string actual_path;
  integer actual_fd;

  localparam logic [13:0] CSR_CTRL         = 14'h000;
  localparam logic [13:0] CSR_SEQ_LEN      = 14'h008;
  localparam logic [13:0] CSR_Q_POS_BASE   = 14'h00c;
  localparam logic [13:0] CSR_KV_POS_BASE  = 14'h010;
  localparam logic [13:0] CSR_CFG          = 14'h014;
  localparam logic [13:0] CSR_STREAM_LEN   = 14'h028;
  localparam logic [13:0] CSR_STREAM_DEST  = 14'h02c;
  localparam logic [13:0] CSR_RESULT_LEN   = 14'h058;
  localparam logic [13:0] CSR_PERF_CYCLES  = 14'h100;
  localparam logic [13:0] CSR_PERF_MAC     = 14'h108;
  localparam logic [13:0] CSR_PERF_STALLS  = 14'h10c;

  localparam logic [1:0] STREAM_TO_K_CACHE = 2'd0;
  localparam logic [1:0] STREAM_TO_V_CACHE = 2'd1;
  localparam logic [1:0] STREAM_TO_Q_BUF   = 2'd2;

  attn_top dut (
    .clk, .rst_n,
    .s_axi_awaddr, .s_axi_awvalid, .s_axi_awready,
    .s_axi_wdata, .s_axi_wstrb, .s_axi_wvalid, .s_axi_wready,
    .s_axi_bresp, .s_axi_bvalid, .s_axi_bready,
    .s_axi_araddr, .s_axi_arvalid, .s_axi_arready,
    .s_axi_rdata, .s_axi_rresp, .s_axi_rvalid, .s_axi_rready,
    .s_axis_tdata, .s_axis_tvalid, .s_axis_tready, .s_axis_tlast,
    .m_axis_tdata, .m_axis_tvalid, .m_axis_tready, .m_axis_tlast
  );

  always #5 clk = ~clk;
  assign m_axis_tready = 1'b1;

  task automatic axi_write(input logic [13:0] addr, input logic [31:0] value);
    begin
      @(negedge clk);
      s_axi_awaddr = addr;
      s_axi_wdata = value;
      s_axi_wstrb = 4'hf;
      s_axi_awvalid = 1'b1;
      s_axi_wvalid = 1'b1;
      s_axi_bready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      s_axi_awvalid = 1'b0;
      s_axi_wvalid = 1'b0;
      wait (s_axi_bvalid);
      @(posedge clk);
      @(negedge clk);
      s_axi_bready = 1'b0;
    end
  endtask

  task automatic axi_read(
    input logic [13:0] addr,
    output logic [31:0] value
  );
    begin
      @(negedge clk);
      s_axi_araddr = addr;
      s_axi_arvalid = 1'b1;
      s_axi_rready = 1'b1;
      do @(posedge clk); while (!s_axi_arready);
      @(negedge clk);
      s_axi_arvalid = 1'b0;
      wait (s_axi_rvalid);
      value = s_axi_rdata;
      @(posedge clk);
      @(negedge clk);
      s_axi_rready = 1'b0;
    end
  endtask

  task automatic send_mem(
    input logic [1:0] dest,
    input integer kind,
    input integer base_word,
    input integer word_count
  );
    integer beat;
    logic [15:0] lo_word;
    logic [15:0] hi_word;
    begin
      axi_write(CSR_STREAM_DEST, {30'd0, dest});
      axi_write(CSR_STREAM_LEN, (word_count * 2));
      for (beat = 0; beat < (word_count / 2); beat = beat + 1) begin
        if (kind == 0) begin
          lo_word = q_mem[base_word + 2 * beat];
          hi_word = q_mem[base_word + 2 * beat + 1];
        end else if (kind == 1) begin
          lo_word = k_mem[base_word + 2 * beat];
          hi_word = k_mem[base_word + 2 * beat + 1];
        end else if (kind == 2) begin
          lo_word = v_mem[base_word + 2 * beat];
          hi_word = v_mem[base_word + 2 * beat + 1];
        end else begin
          lo_word = 16'd0;
          hi_word = 16'd0;
        end
        @(negedge clk);
        s_axis_tdata = {hi_word, lo_word};
        s_axis_tlast = (beat == (word_count / 2) - 1);
        s_axis_tvalid = 1'b1;
        do @(posedge clk); while (!s_axis_tready);
        @(negedge clk);
        s_axis_tvalid = 1'b0;
        s_axis_tlast = 1'b0;
      end
      while (!dut.axis_done)
        @(posedge clk);
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic service_kv_request(input integer group);
    begin
      k_v_requests = k_v_requests + 1;
      send_mem(STREAM_TO_K_CACHE, 1, group * TEST_SEQ * HEAD_DIM,
               TEST_SEQ * HEAD_DIM);
      send_mem(STREAM_TO_V_CACHE, 2, group * TEST_SEQ * HEAD_DIM,
               TEST_SEQ * HEAD_DIM);
    end
  endtask

  task automatic service_q_request(
    input integer group,
    input integer head,
    input integer tile
  );
    begin
      q_requests = q_requests + 1;
      if ($test$plusargs("LEGACY_DEBUG"))
        $display("QREQ #%0d group=%0d head=%0d tile=%0d bank=%0d q_tile_idx=%0d kv_tile_idx=%0d state=%0d",
                 q_requests, group, head, tile, dut.q_req_bank_r,
                 dut.current_q_tile, dut.current_kv_tile, dut.u_fsm.state);
      send_mem(
        STREAM_TO_Q_BUF,
        0,
        ((group * GQA_GROUP_SIZE + head) * TEST_SEQ * HEAD_DIM) +
          (tile * TILE_Q * HEAD_DIM),
        Q_TILE_WORDS
      );
    end
  endtask

  always @(posedge clk) begin
    integer out_word;
    logic [31:0] expected_beat;
    if (rst_n && $test$plusargs("LEGACY_DEBUG") &&
        (phasea_debug_cycles < 12) && dut.phasea_depth_active) begin
      phasea_debug_cycles = phasea_debug_cycles + 1;
      $display("PHASEA_DEBUG n=%0d state=%0d depth=%0d split=%0d qrd=%h krd=%h qin=%h kin=%h macout=%h",
               phasea_debug_cycles, dut.phasea_state, dut.depth_cnt,
               dut.phasea_split_idx, dut.q_block_rd[0], dut.k_rd[0],
               dut.mac_row[0], dut.mac_col[0], dut.mac_block_out[0][0]);
    end
    if (rst_n && $test$plusargs("LEGACY_DEBUG") &&
        ((dut.phasea_state == 3'd3) || (dut.phasea_state == 3'd4))) begin
      $display("PHASEA_FLUSH_DEBUG state=%0d phaseb_sel=%0d mac_en=%0d clear=%0d macout=%h acc=%h s0=%h",
               dut.phasea_state, dut.phaseb_datapath_select, dut.mac_accum_en,
               dut.mac_clear_accum, dut.mac_block_out[0][0],
               dut.u_mac.block_acc_bits[0][0], dut.s_block[0][0]);
    end
    if (rst_n && $test$plusargs("LEGACY_DEBUG") &&
        dut.p_valid && (softmax_debug_dumps < 1) &&
        (dut.gqa_group == 3'd0) && (dut.q_head == 2'd0) &&
        (dut.current_q_tile == 8'd0)) begin
      softmax_debug_dumps = softmax_debug_dumps + 1;
      $display("SOFTMAX_DEBUG row0_s=%h,%h,%h,%h row1_s=%h,%h,%h,%h",
               dut.s_block[0][0], dut.s_block[0][1], dut.s_block[0][2], dut.s_block[0][3],
               dut.s_block[1][0], dut.s_block[1][1], dut.s_block[1][2], dut.s_block[1][3]);
      $display("SOFTMAX_DEBUG row2_s=%h,%h,%h,%h row2_p=%h,%h,%h,%h row2_m=%h row2_l=%h",
               dut.s_block[2][0], dut.s_block[2][1], dut.s_block[2][2], dut.s_block[2][3],
               dut.p_block[2][0], dut.p_block[2][1], dut.p_block[2][2], dut.p_block[2][3],
               dut.m_state[2], dut.l_state[2]);
      $display("SOFTMAX_DEBUG row0_p=%h,%h,%h,%h row1_p=%h,%h,%h,%h",
               dut.p_block[0][0], dut.p_block[0][1], dut.p_block[0][2], dut.p_block[0][3],
               dut.p_block[1][0], dut.p_block[1][1], dut.p_block[1][2], dut.p_block[1][3]);
      $display("SOFTMAX_DEBUG row0_m=%h row0_l=%h row0_corr=%h row1_m=%h row1_l=%h row1_corr=%h",
               dut.m_state[0], dut.l_state[0], dut.correction[0],
               dut.m_state[1], dut.l_state[1], dut.correction[1]);
      $display("SOFTMAX_DEBUG synth_shift=%h synth_p_pipe=%h synth_p11=%h synth_l11=%h",
               dut.u_softmax.sm_shifted_pipe, dut.u_softmax.sm_p_pipe,
               dut.u_softmax.sm_p[1][1], dut.u_softmax.sm_row_sum[1]);
      $display("SOFTMAX_DEBUG synth_s11=%h synth_scaled11=%h synth_mnew1=%h",
               dut.u_softmax.s_data_r[1][1], dut.u_softmax.sm_scaled[1][1],
               dut.u_softmax.sm_m_new[1]);
    end
    if (rst_n && m_axis_tvalid && m_axis_tready) begin
      out_word = output_beats * 2;
      expected_beat = {expected_mem[out_word + 1], expected_mem[out_word]};
      if (actual_fd != 0) begin
        $fdisplay(actual_fd, "%04h", m_axis_tdata[15:0]);
        $fdisplay(actual_fd, "%04h", m_axis_tdata[31:16]);
      end
      if ($test$plusargs("LEGACY_DEBUG") &&
          (output_beats < 512) && ((output_beats % 64) == 0)) begin
        $display("BEAT_BOUNDARY beat=%0d got=%h expected=%h group=%0d head=%0d qtile=%0d micro=%0d norm_micro=%0d obuf_row=%0d obuf_dim=%0d",
                 output_beats, m_axis_tdata, expected_beat, dut.gqa_group,
                 dut.q_head, dut.current_q_tile, dut.phaseb_micro_idx,
                 dut.phaseb_norm_micro_idx, dut.obuf_o_row, dut.obuf_o_dim);
      end
      if (m_axis_tdata !== expected_beat) begin
        errors = errors + 1;
        if ($test$plusargs("FIRST_DEBUG") && (output_beats < 4)) begin
          $display("FIRST_DEBUG beat=%0d got=%h expected=%h norm_src=%h norm_l=%h norm_result=%h resp_valid=%0d resp_row=%0d resp_dim=%0d pipe_src=%h pipe_l=%h norm_bank=%0d norm_addr=%0d norm_issue_valid=%0d norm_issue_bank=%0d norm_issue_addr=%0d norm_mem_return_valid=%0d norm_mem_return_bank=%0d norm_mem_return_addr=%0d norm_mem_return_lane=%0d",
                   output_beats, m_axis_tdata, expected_beat,
                   dut.u_obuf.norm_resp_source_bits,
                   dut.u_obuf.norm_resp_l_bits,
                   dut.u_obuf.norm_result_bits,
                   dut.u_obuf.norm_resp_valid,
                   dut.u_obuf.norm_resp_row,
                   dut.u_obuf.norm_resp_dim,
                   dut.u_obuf.norm_pipe_source_bits,
                   dut.u_obuf.norm_pipe_l_bits,
                   dut.obuf_bank_sel_runtime,
                   dut.u_obuf.norm_chunk_addr,
                   dut.u_obuf.norm_mem_issue_valid,
                   dut.u_obuf.norm_mem_issue_bank_sel,
                   dut.u_obuf.norm_mem_issue_addr,
                   dut.u_obuf.norm_mem_return_valid,
                   dut.u_obuf.norm_mem_return_bank_sel,
                   dut.u_obuf.norm_mem_return_addr,
                   dut.u_obuf.norm_mem_return_lane);
        end
        if (((output_beats >= 64) && (output_beats < 66)) ||
            ((output_beats >= 128) && (output_beats < 130)))
          $display("OBUF_DEBUG beat=%0d src=%h l=%h norm=%h pipe_src=%h pipe_l=%h pipe_valid=%0d acc_data0=%h acc_corr=%h psum0=%h",
                   output_beats,
                   dut.u_obuf.norm_resp_source_bits,
                   dut.u_obuf.norm_resp_l_bits,
                   dut.u_obuf.norm_result_bits,
                   dut.u_obuf.norm_pipe_source_bits,
                   dut.u_obuf.norm_pipe_l_bits,
                   dut.u_obuf.norm_pipe_valid,
                   dut.u_obuf.acc_data[0],
                   dut.psum_out[0],
                   dut.u_obuf.acc_correction);
        if (errors <= 20) begin
          $display("MISMATCH #%0d beat=%0d word=%0d got=%h expected=%h group=%0d head=%0d qtile=%0d micro=%0d norm_micro=%0d obuf_row=%0d obuf_dim=%0d",
                   errors, output_beats, out_word, m_axis_tdata,
                   expected_beat, dut.gqa_group, dut.q_head,
                   dut.current_q_tile, dut.phaseb_micro_idx,
                   dut.phaseb_norm_micro_idx, dut.obuf_o_row, dut.obuf_o_dim);
        end
        if (first_error_beat < 0) begin
          first_error_beat = output_beats;
          first_got = m_axis_tdata;
          first_expected = expected_beat;
        end
      end
      output_beats = output_beats + 1;
    end
    if (rst_n && $test$plusargs("LEGACY_DEBUG") &&
        (dut.q_load_start || dut.o_write_tile_done ||
                  (dut.o_write_done && !dut.o_write_done_d))) begin
      $display("CTRL qstart=%0d qdone=%0d qinflight=%0d qready=%b qbank=%0d buf=%0d qtile=%0d kv=%0d o_tile_done=%0d o_done=%0d same_reload=%0d state=%0d",
               dut.q_load_start, dut.q_load_done, dut.u_fsm.q_load_inflight,
               dut.q_bank_ready, dut.q_load_bank_sel, dut.buf_sel,
               dut.current_q_tile, dut.current_kv_tile, dut.o_write_tile_done,
               dut.o_write_done, dut.q_same_bank_reload_pending, dut.u_fsm.state);
      if (dut.q_load_start)
        $display("QSTART_DETAIL req_g=%0d req_h=%0d req_t=%0d req_bank=%0d latched_g=%0d latched_h=%0d latched_t=%0d start_d=%0d outstanding=%0d",
                 dut.u_fsm.q_req_group, dut.u_fsm.q_req_head, dut.u_fsm.q_req_tile,
                 dut.q_load_bank_sel, dut.q_req_group_r, dut.q_req_head_r,
                 dut.q_req_tile_r, dut.q_load_start_d, dut.q_load_outstanding);
    end
    if (rst_n && $test$plusargs("LEGACY_DEBUG") &&
        dut.src_valid && dut.src_ready &&
        dut.obuf_o_row == 5'd0 && dut.obuf_o_dim == 7'd0) begin
      $display("OUT_START #%0d group=%0d head=%0d qtile=%0d micro=%0d norm_micro=%0d",
               output_beats / (TEST_SEQ * HEAD_DIM / 2),
               dut.gqa_group, dut.q_head, dut.current_q_tile,
               dut.phaseb_micro_idx, dut.phaseb_norm_micro_idx);
    end
    if (rst_n && $test$plusargs("PSTORE_DEBUG") && dut.p_valid &&
        (dut.gqa_group == 3'd0) && (dut.q_head == 2'd0) &&
        ((dut.current_q_tile == 8'd0) || (dut.current_q_tile == 8'd2) ||
         (dut.current_q_tile == 8'd3)) &&
        ((dut.current_kv_tile == 8'd0) || (dut.current_kv_tile == 8'd1))) begin
      $display("PSTORE_DEBUG qtile=%0d pending=%0d/%0d held=%0d/%0d wr=%0d rd=%0d p00=%h preg00=%h smp00=%h corr0=%h m0=%h l0=%h",
               dut.current_q_tile,
               dut.phasea_pending_micro, dut.phasea_pending_kv_blk,
               dut.phasea_held_micro, dut.phasea_held_kv_blk,
               dut.p_store_wr_addr, dut.p_store_rd_addr,
               dut.p_block[0][0], dut.u_softmax.p_data_reg[0][0],
               dut.u_softmax.sm_p[0][0], dut.correction[0],
               dut.m_state[0], dut.l_state[0]);
    end
    if (rst_n && $test$plusargs("ROW1_DEBUG") &&
        dut.obuf_update &&
        (row1_debug_events < 24) &&
        (dut.gqa_group == 3'd0) && (dut.q_head == 2'd0) &&
        (dut.current_q_tile == 8'd0) &&
        (dut.current_kv_tile == 8'd0) &&
        (dut.phaseb_dim_blk_idx == 3'd0) &&
        (dut.phaseb_row_update_idx < 5'd2)) begin
      row1_debug_events = row1_debug_events + 1;
      $display("ROW1_DEBUG state=%0d k=%0d row=%0d p0=%h p1=%h pstore0=%h pstore1=%h v0=%h v1=%h mac0=%h mac1=%h obuf_upd=%0d obuf_row=%0d obuf_dimblk=%0d",
               dut.phaseb_state, dut.phaseb_k_idx, dut.phaseb_row_update_idx,
               dut.p_store_active_word[0][31:0],
               dut.p_store_active_word[1][31:0],
               dut.p_store_active_word[0][dut.phaseb_k_idx*FP32_W + 16 +: 16],
               dut.p_store_active_word[1][dut.phaseb_k_idx*FP32_W + 16 +: 16],
               dut.v_rd_vec_data[0], dut.v_rd_vec_data[1],
               dut.mac_block_out[0][0], dut.mac_block_out[1][0],
               dut.obuf_update, dut.obuf_row, dut.obuf_dim_blk);
    end
    if (rst_n && $test$plusargs("ROW1_DEBUG") &&
        (dut.phaseb_state == 3'd1) &&
        dut.phaseb_datapath_select &&
        (dut.gqa_group == 3'd0) && (dut.q_head == 2'd0) &&
        (dut.current_q_tile == 8'd0) &&
        (dut.current_kv_tile == 8'd0) &&
        (dut.phaseb_dim_blk_idx == 3'd0) &&
        (dut.phaseb_split_idx == 2'd0) &&
        (dut.phaseb_k_idx < 4'd3)) begin
      $display("ROW1_RUN k=%0d p0=%h p1=%h row0=%h row1=%h v0=%h v1=%h prod_r00=%h prod_r10=%h acc00=%h acc10=%h block00=%h block10=%h",
               dut.phaseb_k_idx,
               dut.p_store_active_word[0][dut.phaseb_k_idx*FP32_W + 16 +: 16],
               dut.p_store_active_word[1][dut.phaseb_k_idx*FP32_W + 16 +: 16],
               dut.mac_row[0], dut.mac_row[1],
               dut.v_rd_vec_data[0], dut.v_rd_vec_data[1],
               dut.u_mac.pe_prod_r[0][0], dut.u_mac.pe_prod_r[1][0],
               dut.u_mac.block_acc_bits[0][0], dut.u_mac.block_acc_bits[1][0],
               dut.mac_block_out[0][0], dut.mac_block_out[1][0]);
    end
    if (rst_n && ($test$plusargs("PHASEB_DEBUG")) &&
        (dut.gqa_group == 3'd0) && (dut.q_head == 2'd0) &&
        ((dut.current_q_tile == 8'd2) || (dut.current_q_tile == 8'd3)) &&
        (dut.current_kv_tile == 8'd1) &&
        ((phaseb_prev_state != dut.phaseb_state) ||
         (phaseb_prev_micro != dut.phaseb_micro_idx) ||
         (phaseb_prev_kv != dut.phaseb_kv_blk_idx) ||
         (phaseb_prev_dim != dut.phaseb_dim_blk_idx) ||
         (phaseb_prev_k != dut.phaseb_k_idx) ||
         dut.p_valid || dut.phaseb_prime_now || dut.obuf_update ||
         dut.v_rd_vec_en)) begin
      phaseb_debug_events = phaseb_debug_events + 1;
      $display("PHASEB_DEBUG #%0d qtile=%0d kv=%0d state=%0d micro=%0d kvblk=%0d dim=%0d k=%0d split=%0d ready=%b prime=%0d prime_tag=%0d/%0d/%0d pvalid=%0d paddr=%0d/%0d active0=%h v0=%h mac0=%h obuf_upd=%0d row=%0d dimblk=%0d corr=%h acc0=%h",
               phaseb_debug_events, dut.current_q_tile, dut.current_kv_tile,
               dut.phaseb_state, dut.phaseb_micro_idx, dut.phaseb_kv_blk_idx,
               dut.phaseb_dim_blk_idx, dut.phaseb_k_idx, dut.phaseb_split_idx,
               dut.phaseb_microtile_ready, dut.phaseb_prime_now,
               dut.phaseb_prime_micro_idx, dut.phaseb_prime_kv_blk_idx,
               dut.phaseb_prime_dim_blk_idx, dut.p_valid,
               dut.p_store_wr_addr, dut.p_store_rd_addr,
               dut.p_store_active_word[0][31:0], dut.v_rd_vec_data[0],
               dut.mac_block_out[0][0], dut.obuf_update, dut.obuf_row,
               dut.obuf_dim_blk, dut.obuf_corr_sel, dut.u_obuf.acc_data[0]);
    end
    if (rst_n) begin
      phaseb_prev_state = dut.phaseb_state;
      phaseb_prev_micro = dut.phaseb_micro_idx;
      phaseb_prev_kv = dut.phaseb_kv_blk_idx;
      phaseb_prev_dim = dut.phaseb_dim_blk_idx;
      phaseb_prev_k = dut.phaseb_k_idx;
    end
  end

  initial begin
    string q_path;
    string k_path;
    string v_path;
  string expected_path;
  integer case_causal;
  integer case_q_pos_base;
  integer case_kv_pos_base;
  logic [31:0] perf_cycles;
  logic [31:0] perf_mac_cycles;
  logic [31:0] perf_stall_cycles;
  logic [31:0] retained_cycles;
  logic [31:0] retained_mac_cycles;
  logic [31:0] retained_stall_cycles;

    if (!$value$plusargs("CASE_DIR=%s", case_dir))
      case_dir = "/tmp/lara_case_l128";
    if (!$value$plusargs("CAUSAL=%d", case_causal))
      case_causal = 1;
    if (!$value$plusargs("Q_POS_BASE=%d", case_q_pos_base))
      case_q_pos_base = 3;
    if (!$value$plusargs("KV_POS_BASE=%d", case_kv_pos_base))
      case_kv_pos_base = 3;
    if (case_q_pos_base < 0 || case_q_pos_base + TEST_SEQ > 17'h1_0000 ||
        case_kv_pos_base < 0 || case_kv_pos_base + TEST_SEQ > 17'h1_0000) begin
      $display("FAIL invalid absolute positions q_pos=%0d kv_pos=%0d L=%0d",
               case_q_pos_base, case_kv_pos_base, TEST_SEQ);
      $fatal(1);
    end
    actual_fd = 0;
    if ($value$plusargs("ACTUAL_PATH=%s", actual_path)) begin
      actual_fd = $fopen(actual_path, "w");
      if (actual_fd == 0) begin
        $display("FAIL unable to open ACTUAL_PATH=%s", actual_path);
        $fatal(1);
      end
    end
    q_path = {case_dir, "/q.hex"};
    k_path = {case_dir, "/k.hex"};
    v_path = {case_dir, "/v.hex"};
    expected_path = {case_dir, "/expected.hex"};
    $readmemh(q_path, q_mem);
    $readmemh(k_path, k_mem);
    $readmemh(v_path, v_mem);
    $readmemh(expected_path, expected_mem);

    clk = 1'b0;
    rst_n = 1'b0;
    s_axi_awaddr = '0;
    s_axi_araddr = '0;
    s_axi_awvalid = 1'b0;
    s_axi_wvalid = 1'b0;
    s_axi_bready = 1'b0;
    s_axi_arvalid = 1'b0;
    s_axi_rready = 1'b0;
    s_axi_wdata = '0;
    s_axi_wstrb = 4'hf;
    s_axis_tdata = '0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    errors = 0;
    output_beats = 0;
    k_v_requests = 0;
    q_requests = 0;
    first_error_beat = -1;
    softmax_debug_dumps = 0;
    phasea_debug_cycles = 0;
    phaseb_debug_events = 0;
    phaseb_prev_state = -1;
    phaseb_prev_micro = -1;
    phaseb_prev_kv = -1;
    phaseb_prev_dim = -1;
    phaseb_prev_k = -1;
    row1_debug_events = 0;
    first_got = '0;
    first_expected = '0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    axi_write(CSR_SEQ_LEN, TEST_SEQ);
    axi_write(CSR_Q_POS_BASE, case_q_pos_base);
    axi_write(CSR_KV_POS_BASE, case_kv_pos_base);
    axi_write(CSR_CFG, case_causal);
    axi_write(CSR_RESULT_LEN, OUTPUT_WORDS * 2);
    axi_write(CSR_CTRL, 32'd1);

    while (!dut.done) begin
      if (dut.kv_load_req)
        service_kv_request(dut.kv_req_group_r);
      else if (dut.q_load_req)
        service_q_request(dut.q_req_group_r, dut.q_req_head_r, dut.q_req_tile_r);
      else
        @(posedge clk);
    end
    repeat (20) @(posedge clk);

    // Match the PYNQ driver: read the counters through AXI-Lite only after
    // DONE, when the core is already back in IDLE.  The completed values must
    // be nonzero and remain readable until the next accepted transaction.
    axi_read(CSR_PERF_CYCLES, perf_cycles);
    axi_read(CSR_PERF_MAC, perf_mac_cycles);
    axi_read(CSR_PERF_STALLS, perf_stall_cycles);
    if ((perf_cycles == 0) || (perf_mac_cycles == 0) ||
        (perf_stall_cycles == 0)) begin
      $display("FAIL performance CSR returned zero after DONE: total=%0d mac=%0d stall=%0d",
               perf_cycles, perf_mac_cycles, perf_stall_cycles);
      errors = errors + 1;
    end
    repeat (4) @(posedge clk);
    axi_read(CSR_PERF_CYCLES, retained_cycles);
    axi_read(CSR_PERF_MAC, retained_mac_cycles);
    axi_read(CSR_PERF_STALLS, retained_stall_cycles);
    if ((retained_cycles != perf_cycles) ||
        (retained_mac_cycles != perf_mac_cycles) ||
        (retained_stall_cycles != perf_stall_cycles)) begin
      $display("FAIL performance CSR changed in IDLE: first=%0d/%0d/%0d retained=%0d/%0d/%0d",
               perf_cycles, perf_mac_cycles, perf_stall_cycles,
               retained_cycles, retained_mac_cycles, retained_stall_cycles);
      errors = errors + 1;
    end
    $display("PERF_CSR_AFTER_DONE total=%0d mac=%0d stall=%0d",
             perf_cycles, perf_mac_cycles, perf_stall_cycles);

    if (k_v_requests != N_KV_HEADS) begin
      $display("FAIL board case K/V requests got=%0d expected=%0d", k_v_requests, N_KV_HEADS);
      errors = errors + 1;
    end
    if (q_requests != N_KV_HEADS * GQA_GROUP_SIZE * ((TEST_SEQ + TILE_Q - 1) / TILE_Q)) begin
      $display("FAIL board case Q requests got=%0d expected=%0d",
               q_requests, N_KV_HEADS * GQA_GROUP_SIZE *
               ((TEST_SEQ + TILE_Q - 1) / TILE_Q));
      errors = errors + 1;
    end
    if (output_beats != OUTPUT_BEATS) begin
      $display("FAIL board case output beats got=%0d expected=%0d",
               output_beats, OUTPUT_BEATS);
      errors = errors + 1;
    end

    if (errors == 0) begin
      if (actual_fd != 0)
        $fclose(actual_fd);
      $display("BOARD CASE PASS L=%0d q_pos=%0d kv_pos=%0d causal=%0d k_v_requests=%0d q_requests=%0d output_beats=%0d",
               TEST_SEQ, case_q_pos_base, case_kv_pos_base, case_causal,
               k_v_requests, q_requests, output_beats);
      $finish(0);
    end
    if (actual_fd != 0)
      $fclose(actual_fd);
    $display("BOARD CASE FAIL errors=%0d first_error_beat=%0d got=%h expected=%h",
             errors, first_error_beat, first_got, first_expected);
    $fatal(1);
  end

  initial begin
    #50_000_000_000;
    $display("FAIL board case timeout state=%0d done=%0b kv_req=%0b q_req=%0b output_beats=%0d",
             dut.u_fsm.state, dut.done, dut.kv_load_req, dut.q_load_req, output_beats);
    $fatal(1);
  end
endmodule
