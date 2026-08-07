`timescale 1ns / 1ps

module tb_attn_top_two_tiles;
  import attn_pkg::*;

  localparam logic [15:0] BF16_ONE   = 16'h3F80;
  localparam logic [15:0] BF16_TWO   = 16'h4000;
  localparam logic [15:0] BF16_THREE = 16'h4040;
  localparam logic [15:0] BF16_FOUR  = 16'h4080;
  localparam int TEST_SEQ = 64;
  localparam int TEST_RESULT_SAMPLES = TEST_SEQ * HEAD_DIM;
  localparam int TEST_RESULT_BEATS   = TEST_RESULT_SAMPLES / 2;

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
  logic [15:0] preload_axis_data;
  logic tick_marker;

  int err;
  int out_samples;
  int out_beats;
  int exp_logical_row;
  int exp_dim;
  bit saw_tile0_micro0;
  bit saw_tile0_micro1;
  bit saw_tile1_micro0;
  bit saw_tile1_micro1;
  bit saw_bufsel_tile0;
  bit saw_bufsel_tile1;
  bit saw_tlast;

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

  always_comb begin
    if (preload_q_wr_en)
      preload_axis_data = preload_q_wr_data;
    else if (preload_k_wr_en)
      preload_axis_data = preload_k_wr_data;
    else if (preload_v_wr_en)
      preload_axis_data = preload_v_wr_data;
    else
      preload_axis_data = 16'd0;
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

  task automatic qbuf_write(input logic bank_sel, input logic [15:0] val);
    begin
      preload_buf_sel = bank_sel;
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
      if (is_v)
        preload_v_wr_en = 1'b0;
      else
        preload_k_wr_en = 1'b0;
    end
  endtask

  task automatic preload_qbuf_bank(
    input logic bank_sel,
    input logic [15:0] micro0_val,
    input logic [15:0] micro1_val
  );
    int row, dim;
    begin
      for (row = 0; row < TILE_Q; row++) begin
        for (dim = 0; dim < HEAD_DIM; dim++) begin
          if (row < TILE_ROWS)
            qbuf_write(bank_sel, micro0_val);
          else
            qbuf_write(bank_sel, micro1_val);
        end
      end
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
    int logical_row;

    if (rst_n) begin
      if ((dut.phasea_state == 3'd2) && dut.phasea_depth_active &&
          (dut.depth_cnt == 7'd1) && (dut.phasea_kv_blk_idx == 0)) begin
        if (dut.q_tile_start == 16'd0) begin
          saw_bufsel_tile0 = 1'b1;
          if ((dut.phasea_micro_idx == 0) && !saw_tile0_micro0) begin
            if (dut.q_block_rd[0] !== BF16_ONE) begin
              $display("FAIL tile0 micro0 q_block_rd[0]=%h exp=%h", dut.q_block_rd[0], BF16_ONE);
              err++;
            end
            saw_tile0_micro0 = 1'b1;
          end
          if ((dut.phasea_micro_idx == 1) && !saw_tile0_micro1) begin
            if (dut.q_block_rd[0] !== BF16_TWO) begin
              $display("FAIL tile0 micro1 q_block_rd[0]=%h exp=%h", dut.q_block_rd[0], BF16_TWO);
              err++;
            end
            saw_tile0_micro1 = 1'b1;
          end
        end else if (dut.q_tile_start == 16'd32) begin
          saw_bufsel_tile1 = 1'b1;
          if ((dut.phasea_micro_idx == 0) && !saw_tile1_micro0) begin
            if (dut.q_block_rd[0] !== BF16_THREE) begin
              $display("FAIL tile1 micro0 q_block_rd[0]=%h exp=%h", dut.q_block_rd[0], BF16_THREE);
              err++;
            end
            saw_tile1_micro0 = 1'b1;
          end
          if ((dut.phasea_micro_idx == 1) && !saw_tile1_micro1) begin
            if (dut.q_block_rd[0] !== BF16_FOUR) begin
              $display("FAIL tile1 micro1 q_block_rd[0]=%h exp=%h", dut.q_block_rd[0], BF16_FOUR);
              err++;
            end
            saw_tile1_micro1 = 1'b1;
          end
        end
      end

      if (dut.src_valid) begin
        logical_row = int'(dut.q_tile_start) +
                      (dut.phaseb_norm_micro_idx * TILE_ROWS) +
                      int'(dut.obuf_o_row);
        if ((logical_row != exp_logical_row) || (dut.obuf_o_dim != 7'(exp_dim))) begin
          $display("FAIL two_tiles output order got row=%0d dim=%0d exp row=%0d dim=%0d",
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
            $display("FAIL two_tiles multiple tlast pulses");
            err++;
          end
          if (out_beats != TEST_RESULT_BEATS) begin
            $display("FAIL two_tiles tlast beat count got=%0d exp=%0d", out_beats, TEST_RESULT_BEATS);
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
    m_axis_tready = 1'b1;
    preload_buf_sel = 1'b0;
    preload_q_wr_en = 1'b0;
    preload_q_wr_data = '0;
    preload_k_wr_en = 1'b0;
    preload_v_wr_en = 1'b0;
    preload_k_wr_addr = '0;
    preload_v_wr_addr = '0;
    preload_k_wr_data = '0;
    preload_v_wr_data = '0;
    tick_marker = 1'b0;
    err = 0;
    out_samples = 0;
    out_beats = 0;
    exp_logical_row = 0;
    exp_dim = 0;
    saw_tile0_micro0 = 1'b0;
    saw_tile0_micro1 = 1'b0;
    saw_tile1_micro0 = 1'b0;
    saw_tile1_micro1 = 1'b0;
    saw_bufsel_tile0 = 1'b0;
    saw_bufsel_tile1 = 1'b0;
    saw_tlast = 1'b0;

    #20 rst_n = 1'b1;
    tick();

    force dut.buf_sel = preload_buf_sel;
    force dut.q_load_bank_sel_latched = preload_buf_sel;
    force dut.qbuf_wr_en = preload_q_wr_en;
    force dut.k_wr_en = preload_k_wr_en;
    force dut.v_wr_en = preload_v_wr_en;
    force dut.k_wr_addr = preload_k_wr_addr;
    force dut.v_wr_addr = preload_v_wr_addr;
    force dut.axis_data = preload_axis_data;

    preload_qbuf_bank(1'b1, BF16_THREE, BF16_FOUR);
    preload_qbuf_bank(1'b0, BF16_ONE, BF16_TWO);
    preload_kv();

    release dut.buf_sel;
    release dut.q_load_bank_sel_latched;
    release dut.qbuf_wr_en;
    release dut.k_wr_en;
    release dut.v_wr_en;
    release dut.k_wr_addr;
    release dut.v_wr_addr;
    release dut.axis_data;

    force dut.seq_len = 16'(TEST_SEQ);
    force dut.result_len_cfg = 32'(TEST_SEQ * HEAD_DIM * 2);
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

    if (!saw_bufsel_tile0 || !saw_bufsel_tile1) begin
      $display("FAIL two_tiles did not observe both q tile bank selections");
      err++;
    end
    if (!saw_tile0_micro0 || !saw_tile0_micro1 || !saw_tile1_micro0 || !saw_tile1_micro1) begin
      $display("FAIL two_tiles missing one or more q microtile observations");
      err++;
    end
    if (out_samples != TEST_RESULT_SAMPLES) begin
      $display("FAIL two_tiles out_samples=%0d exp=%0d", out_samples, TEST_RESULT_SAMPLES);
      err++;
    end
    if (out_beats != TEST_RESULT_BEATS) begin
      $display("FAIL two_tiles out_beats=%0d exp=%0d", out_beats, TEST_RESULT_BEATS);
      err++;
    end
    if (!saw_tlast) begin
      $display("FAIL two_tiles missing final tlast");
      err++;
    end

    if (err == 0)
      $display("ALL ATTN_TOP TWO TILE CHECKS PASSED");
    else begin
      $display("ATTN_TOP TWO TILE FAILED with %0d errors", err);
      $fatal(1);
    end

    $finish;
  end

  initial begin
    #8_000_000 begin end
    $display("FAIL timeout waiting for two-tile attn_top completion");
    $display("DBG state=%0d done=%0b busy=%0b q_tile_start=%0d active_q_rows=%0d q_head=%0d group=%0d buf_sel=%0b src_last=%0b src_done=%0b",
             dut.u_fsm.state, dut.done, dut.busy, dut.q_tile_start, dut.active_q_rows,
             dut.q_head, dut.gqa_group, dut.buf_sel, dut.src_last, dut.src_done);
    $fatal(1);
  end
endmodule
