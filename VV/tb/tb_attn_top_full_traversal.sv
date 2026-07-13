`timescale 1ns / 1ps

module tb_attn_top_full_traversal;
  import attn_pkg::*;

  localparam logic [15:0] BF16_ONE = 16'h3F80;
  localparam int TEST_SEQ = 32;
  localparam int TOTAL_HEADS = N_Q_HEADS;
  localparam int TEST_RESULT_SAMPLES = TOTAL_HEADS * TEST_SEQ * HEAD_DIM;
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
  int last_head_linear;
  int head_switches;
  bit saw_tlast;
  bit saw_final_head;

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

  task automatic preload_qbuf_bank(input logic bank_sel, input logic [15:0] val);
    int row, dim;
    begin
      for (row = 0; row < TILE_Q; row++) begin
        for (dim = 0; dim < HEAD_DIM; dim++) begin
          qbuf_write(bank_sel, val);
        end
      end
    end
  endtask

  task automatic preload_kv;
    int tok, dim;
    begin
      for (tok = 0; tok < TILE_KV; tok++) begin
        for (dim = 0; dim < HEAD_DIM; dim++) begin
          kv_write(1'b0, tok, dim, BF16_ONE);
          kv_write(1'b1, tok, dim, BF16_ONE);
        end
      end
    end
  endtask

  always @(negedge clk) begin
    int cur_head_linear;

    if (rst_n) begin
      if (dut.src_valid) begin
        cur_head_linear = dut.gqa_group * GQA_GROUP_SIZE + dut.q_head;
        if ((dut.q_head == 2'd3) && (dut.gqa_group == 3'd7))
          saw_final_head = 1'b1;

        if ((dut.obuf_o_row == 5'd0) && (dut.obuf_o_dim == 7'd0)) begin
          if (last_head_linear != cur_head_linear) begin
            if (last_head_linear != -1)
              head_switches++;
            last_head_linear = cur_head_linear;
          end
        end
        out_samples++;
      end

      if (m_axis_tvalid && m_axis_tready) begin
        out_beats++;
        if (m_axis_tlast) begin
          if (saw_tlast) begin
            $display("FAIL full_traversal multiple tlast pulses");
            err++;
          end
          if (out_beats != TEST_RESULT_BEATS) begin
            $display("FAIL full_traversal tlast beat count got=%0d exp=%0d",
                     out_beats, TEST_RESULT_BEATS);
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
    last_head_linear = -1;
    head_switches = 0;
    saw_tlast = 1'b0;
    saw_final_head = 1'b0;

    #20 rst_n = 1'b1;
    tick();

    force dut.buf_sel = preload_buf_sel;
    force dut.qbuf_wr_en = preload_q_wr_en;
    force dut.k_wr_en = preload_k_wr_en;
    force dut.v_wr_en = preload_v_wr_en;
    force dut.k_wr_addr = preload_k_wr_addr;
    force dut.v_wr_addr = preload_v_wr_addr;
    force dut.axis_data = preload_axis_data;

    preload_qbuf_bank(1'b1, BF16_ONE);
    preload_qbuf_bank(1'b0, BF16_ONE);
    preload_kv();

    release dut.buf_sel;
    release dut.qbuf_wr_en;
    release dut.k_wr_en;
    release dut.v_wr_en;
    release dut.k_wr_addr;
    release dut.v_wr_addr;
    release dut.axis_data;

    force dut.seq_len = 16'(TEST_SEQ);
    force dut.result_len_cfg = 32'(TEST_RESULT_SAMPLES * 2);
    force dut.kv_load_done = 1'b1;
    force dut.q_load_done = 1'b1;
    force dut.start = 1'b1;
    tick();
    release dut.start;

    wait_done_flag();
    repeat (20) tick();

    if (out_samples != TEST_RESULT_SAMPLES) begin
      $display("FAIL full_traversal out_samples=%0d exp=%0d", out_samples, TEST_RESULT_SAMPLES);
      err++;
    end
    if (out_beats != TEST_RESULT_BEATS) begin
      $display("FAIL full_traversal out_beats=%0d exp=%0d", out_beats, TEST_RESULT_BEATS);
      err++;
    end
    if (!saw_tlast) begin
      $display("FAIL full_traversal missing final tlast");
      err++;
    end
    if (!saw_final_head) begin
      $display("FAIL full_traversal never observed final head/group on output");
      err++;
    end
    if (head_switches != (TOTAL_HEADS - 1)) begin
      $display("FAIL full_traversal head_switches=%0d exp=%0d", head_switches, TOTAL_HEADS - 1);
      err++;
    end

    if (err == 0)
      $display("ALL ATTN_TOP FULL TRAVERSAL CHECKS PASSED");
    else begin
      $display("ATTN_TOP FULL TRAVERSAL FAILED with %0d errors", err);
      $fatal(1);
    end

    $finish;
  end

  initial begin
    #12_000_000 begin end
    $display("FAIL timeout waiting for full traversal attn_top completion");
    $fatal(1);
  end
endmodule
