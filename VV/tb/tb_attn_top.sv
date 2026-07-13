`timescale 1ns / 1ps

module tb_attn_top;
  import attn_pkg::*;

  localparam logic [15:0] BF16_ONE = 16'h3F80;
  localparam logic [15:0] BF16_TWO = 16'h4000;
  localparam logic [31:0] FP32_NEG_INF = 32'hFF80_0000;
  localparam int Q_MICROTILES = TILE_Q / TILE_ROWS;
  localparam int TEST_SEQ = 32;
  localparam int KV_SUBBLOCKS = TILE_KV / TILE_COLS;
  localparam int TEST_KV_SUBBLOCKS = (TEST_SEQ + TILE_COLS - 1) / TILE_COLS;
  localparam int DIM_SUBBLOCKS = HEAD_DIM / TILE_COLS;
  localparam int PA_LOAD_CTX = 1;

  logic clk, rst_n;
  logic [13:0] s_axi_awaddr, s_axi_araddr;
  logic s_axi_awvalid, s_axi_wvalid, s_axi_bready, s_axi_arvalid, s_axi_rready;
  logic [31:0] s_axi_wdata;
  logic [3:0] s_axi_wstrb;
  logic [31:0] s_axis_tdata;
  logic s_axis_tvalid, s_axis_tlast;
  logic s_axi_awready, s_axi_wready, s_axi_bvalid, s_axi_arready, s_axi_rvalid;
  logic [1:0] s_axi_bresp, s_axi_rresp;
  logic [31:0] s_axi_rdata;
  logic s_axis_tready;
  logic [31:0] m_axis_tdata;
  logic m_axis_tvalid, m_axis_tready, m_axis_tlast;
  logic preload_buf_sel;
  logic preload_q_wr_en;
  logic [15:0] preload_q_wr_data;
  logic preload_k_wr_en, preload_v_wr_en;
  logic [15:0] preload_k_wr_addr, preload_v_wr_addr;
  logic [15:0] preload_k_wr_data, preload_v_wr_data;
  logic tick_marker;

  int err;
  int capture_count;
  int out_samples;
  int out_beats;
  int exp_logical_row;
  int exp_dim;
  bit saw_micro0_reload;
  bit saw_micro1_fresh;
  bit saw_tlast;
  bit saw_writeback_overlap;
  bit backpressure_active;
  bit saw_last_sample_stall;
  int backpressure_cycles;

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

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_axis_tready <= 1'b1;
      backpressure_active <= 1'b0;
      backpressure_cycles <= 0;
    end else if (!backpressure_active &&
                 dut.writeback_active &&
                 (dut.phaseb_norm_micro_idx == 1'd0) &&
                 dut.obuf_valid_raw &&
                 (dut.obuf_o_row == 5'(TILE_ROWS - 1)) &&
                 (dut.obuf_o_dim == 7'(HEAD_DIM - 3))) begin
      // Fill the source packer's low half, then hold its completed AXIS word.
      // The following final sample of microtile 0 must remain unaccepted.
      m_axis_tready <= 1'b0;
      backpressure_active <= 1'b1;
      backpressure_cycles <= 0;
    end else if (backpressure_active) begin
      if (backpressure_cycles == 4) begin
        m_axis_tready <= 1'b1;
        backpressure_active <= 1'b0;
      end else begin
        backpressure_cycles <= backpressure_cycles + 1;
      end
    end
  end

  task automatic tick;
    begin
      @(posedge clk) tick_marker = ~tick_marker;
    end
  endtask

  task automatic wait_done_flag;
    begin
      while (dut.done !== 1'b1)
        tick();
    end
  endtask

  task automatic qbuf_write(input logic [15:0] val);
    begin
      preload_buf_sel = 1'b1;
      preload_q_wr_en = 1'b1;
      preload_q_wr_data = val;
      tick();
      preload_q_wr_en = 1'b0;
    end
  endtask

  task automatic kv_write(input bit is_v, input int token_idx, input int dim_idx, input logic [15:0] val);
    begin
      if (is_v) begin
        preload_v_wr_en = 1'b1;
        preload_v_wr_addr = 16'(token_idx * HEAD_DIM + dim_idx);
        preload_v_wr_data = val;
      end else begin
        preload_k_wr_en = 1'b1;
        preload_k_wr_addr = 16'(token_idx * HEAD_DIM + dim_idx);
        preload_k_wr_data = val;
      end
      tick();
      if (is_v) begin
        preload_v_wr_en = 1'b0;
      end else begin
        preload_k_wr_en = 1'b0;
      end
    end
  endtask

  task automatic preload_qbuf;
    int row, dim;
    begin
      for (row = 0; row < TILE_Q; row++) begin
        for (dim = 0; dim < HEAD_DIM; dim++) begin
          if (row < TILE_ROWS)
            qbuf_write(BF16_ONE);
          else
            qbuf_write(BF16_TWO);
        end
      end
      preload_buf_sel = 1'b0;
    end
  endtask

  task automatic preload_kv;
    int tok, dim, blk;
    logic [15:0] vval;
    begin
      for (tok = 0; tok < TILE_KV; tok++) begin
        for (dim = 0; dim < HEAD_DIM; dim++) begin
          kv_write(1'b0, tok, dim, BF16_ONE);
          blk = dim / TILE_COLS;
          case (blk)
            0: vval = 16'h3F80;
            1: vval = 16'h4000;
            2: vval = 16'h4040;
            3: vval = 16'h4080;
            4: vval = 16'h40A0;
            5: vval = 16'h40C0;
            6: vval = 16'h40E0;
            default: vval = 16'h4100;
          endcase
          kv_write(1'b1, tok, dim, vval);
        end
      end
    end
  endtask

  always @(negedge clk) begin
    int exp_micro, exp_kv, exp_dim_blk, rem;
    int logical_row;

    if (rst_n) begin
      if ((dut.phasea_state == 3'd2) && (dut.depth_cnt == 0) && !saw_micro0_reload &&
          (dut.phasea_micro_idx == 0) && (dut.phasea_kv_blk_idx == 1)) begin
        if ((dut.sm_state_l_in[0] == 32'd0) || (dut.sm_state_m_in[0] == FP32_NEG_INF)) begin
          $display("FAIL micro0 reload context was not preserved");
          err++;
        end
        saw_micro0_reload = 1'b1;
      end

      if ((dut.phasea_state == 3'd2) && (dut.depth_cnt == 0) && !saw_micro1_fresh &&
          (dut.phasea_micro_idx == 1) && (dut.phasea_kv_blk_idx == 0)) begin
        for (int ri = 0; ri < TILE_ROWS; ri++) begin
          if ((dut.sm_state_m_in[ri] !== FP32_NEG_INF) || (dut.sm_state_l_in[ri] !== 32'd0)) begin
            $display("FAIL micro1 fresh context mismatch row=%0d m=%h l=%h",
                     ri, dut.sm_state_m_in[ri], dut.sm_state_l_in[ri]);
            err++;
          end
        end
        saw_micro1_fresh = 1'b1;
      end

      if (dut.obuf_update && (dut.obuf_row == 0)) begin
        exp_micro = capture_count / (TEST_KV_SUBBLOCKS * DIM_SUBBLOCKS);
        rem = capture_count % (TEST_KV_SUBBLOCKS * DIM_SUBBLOCKS);
        exp_kv = rem / DIM_SUBBLOCKS;
        exp_dim_blk = rem % DIM_SUBBLOCKS;
        if ((dut.phaseb_micro_idx != exp_micro[0:0]) ||
            (dut.phaseb_kv_blk_idx != exp_kv[1:0]) ||
            (dut.phaseb_dim_blk_idx != exp_dim_blk[2:0])) begin
          $display("FAIL phaseB order idx=%0d got=(%0d,%0d,%0d) exp=(%0d,%0d,%0d)",
                   capture_count, dut.phaseb_micro_idx, dut.phaseb_kv_blk_idx,
                   dut.phaseb_dim_blk_idx, exp_micro, exp_kv, exp_dim_blk);
          err++;
        end
        capture_count++;
      end

      if (backpressure_active &&
          !m_axis_tready &&
          dut.obuf_valid_raw &&
          (dut.obuf_o_row == 5'(TILE_ROWS - 1)) &&
          (dut.obuf_o_dim == 7'(HEAD_DIM - 1)) &&
          !dut.src_ready) begin
        saw_last_sample_stall = 1'b1;
        if ((dut.phaseb_norm_micro_idx != 1'd0) ||
            !dut.writeback_active || dut.o_write_done) begin
          $display("FAIL microtile writeback advanced while final sample was stalled idx=%0d active=%0b done=%0b",
                   dut.phaseb_norm_micro_idx, dut.writeback_active, dut.o_write_done);
          err++;
        end
      end

      if (dut.src_valid && dut.src_ready) begin
        if (dut.mac_phase)
          saw_writeback_overlap = 1'b1;
        logical_row = (dut.phaseb_norm_micro_idx * TILE_ROWS) + int'(dut.obuf_o_row);
        if ((logical_row != exp_logical_row) || (dut.obuf_o_dim != 7'(exp_dim))) begin
          $display("FAIL output order got row=%0d dim=%0d exp row=%0d dim=%0d",
                   logical_row, dut.obuf_o_dim, exp_logical_row, exp_dim);
          err++;
        end
        out_samples++;
        if (exp_dim == HEAD_DIM - 1) begin
          exp_dim = 0;
          exp_logical_row++;
        end else begin
          exp_dim++;
        end
      end

      if (m_axis_tvalid && m_axis_tready) begin
        out_beats++;
        if (m_axis_tlast) begin
          if (saw_tlast) begin
            $display("FAIL multiple tlast pulses");
            err++;
          end
          if (out_beats != ((TILE_Q * HEAD_DIM) / 2)) begin
            $display("FAIL tlast beat count got=%0d exp=%0d", out_beats, (TILE_Q * HEAD_DIM) / 2);
            err++;
          end
          saw_tlast = 1'b1;
        end
      end
    end
  end

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    s_axi_awaddr = '0;
    s_axi_awvalid = 1'b0;
    s_axi_wdata = '0;
    s_axi_wstrb = 4'hF;
    s_axi_wvalid = 1'b0;
    s_axi_bready = 1'b1;
    s_axi_araddr = '0;
    s_axi_arvalid = 1'b0;
    s_axi_rready = 1'b1;
    s_axis_tdata = '0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    preload_buf_sel = 1'b0;
    preload_q_wr_en = 1'b0;
    preload_q_wr_data = '0;
    preload_k_wr_en = 1'b0;
    preload_v_wr_en = 1'b0;
    preload_k_wr_addr = '0;
    preload_v_wr_addr = '0;
    tick_marker = 1'b0;
    preload_k_wr_data = '0;
    preload_v_wr_data = '0;
    err = 0;
    capture_count = 0;
    out_samples = 0;
    out_beats = 0;
    exp_logical_row = 0;
    exp_dim = 0;
    saw_micro0_reload = 1'b0;
    saw_micro1_fresh = 1'b0;
    saw_tlast = 1'b0;
    saw_writeback_overlap = 1'b0;
    saw_last_sample_stall = 1'b0;

    #20 rst_n = 1'b1;
    tick();

    force dut.buf_sel = preload_buf_sel;
    force dut.u_qbuf.wr_en = preload_q_wr_en;
    force dut.u_qbuf.wr_data = preload_q_wr_data;
    force dut.u_kcache.wr_en = preload_k_wr_en;
    force dut.u_kcache.wr_addr = preload_k_wr_addr;
    force dut.u_kcache.wr_data = preload_k_wr_data;
    force dut.u_vcache.wr_en = preload_v_wr_en;
    force dut.u_vcache.wr_addr = preload_v_wr_addr;
    force dut.u_vcache.wr_data = preload_v_wr_data;

    preload_qbuf();
    preload_kv();

    release dut.buf_sel;
    release dut.u_qbuf.wr_en;
    release dut.u_qbuf.wr_data;
    release dut.u_kcache.wr_en;
    release dut.u_kcache.wr_addr;
    release dut.u_kcache.wr_data;
    release dut.u_vcache.wr_en;
    release dut.u_vcache.wr_addr;
    release dut.u_vcache.wr_data;

    force dut.seq_len = 16'(TEST_SEQ);
    force dut.result_len_cfg = 32'd8192;
    force dut.kv_load_done = 1'b1;
    force dut.q_load_done = 1'b1;
    force dut.u_fsm.head_cnt = 2'd3;
    force dut.u_fsm.group_cnt = 3'd7;
    force dut.start = 1'b1;
    tick();
    release dut.start;

    wait_done_flag();
    repeat (20) tick();
    release dut.u_fsm.head_cnt;
    release dut.u_fsm.group_cnt;

    if (!saw_micro0_reload) begin
      $display("FAIL did not observe micro0 reload");
      err++;
    end
    if (!saw_micro1_fresh) begin
      $display("FAIL did not observe micro1 fresh load");
      err++;
    end
    if (out_samples != (TILE_Q * HEAD_DIM)) begin
      $display("FAIL out_samples=%0d exp=%0d", out_samples, (TILE_Q * HEAD_DIM));
      err++;
    end
    if (out_beats != ((TILE_Q * HEAD_DIM) / 2)) begin
      $display("FAIL out_beats=%0d exp=%0d", out_beats, ((TILE_Q * HEAD_DIM) / 2));
      err++;
    end
    if (!saw_tlast) begin
      $display("FAIL missing final tlast");
      err++;
    end
    if (Q_MICROTILES > 1 && !saw_writeback_overlap) begin
      $display("FAIL did not observe writeback overlap during mac_phase");
      err++;
    end
    if (!saw_last_sample_stall) begin
      $display("FAIL did not exercise final-sample AXIS backpressure");
      err++;
    end

    if (err == 0)
      $display("ALL ATTN_TOP CHECKS PASSED");
    else begin
      $display("ATTN_TOP FAILED with %0d errors", err);
      $fatal(1);
    end

    $finish;
  end

  initial begin
    #5_000_000 begin end
    $display("FAIL timeout waiting for attn_top completion");
    $display("DBG state=%0d busy=%0b done=%0b q_tile=%0d kv_tile=%0d phasea=%0d phaseb=%0d pcap=%0d p_valid=%0b src_valid=%0b src_done=%0b",
             dut.u_fsm.state, dut.busy, dut.done, dut.u_fsm.q_tile_idx, dut.u_fsm.kv_tile_idx,
             dut.phasea_state, dut.phaseb_state, dut.phasea_p_capture_cnt, dut.p_valid,
             dut.src_valid, dut.src_done);
    $display("DBG micro0_ctx m_in0=%h l_in0=%h m_ctx0=%h l_ctx0=%h pending_micro=%0d pending_kv=%0d",
             dut.sm_state_m_in[0], dut.sm_state_l_in[0], dut.sm_m_ctx[0][0], dut.sm_l_ctx[0][0],
             dut.phasea_pending_micro, dut.phasea_pending_kv_blk);
    $fatal(1);
  end
endmodule
