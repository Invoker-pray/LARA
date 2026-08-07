`timescale 1ns/1ps

// Minimal end-to-end request-path reproduction.
// Unlike tb_attn_top, this test does not preload or force the data memories.
// It drives the same CSR/load-request/AXIS sequence as sw/attn_driver.py.
module tb_attn_top_real_request;
  import attn_pkg::*;

  localparam logic [15:0] BF16_ONE = 16'h3f80;
  localparam logic [15:0] BF16_TWO = 16'h4000;
  localparam int K_V_BEATS = (HEAD_DIM * 2) / 4;
  localparam int Q_BEATS = (TILE_Q * HEAD_DIM * 2) / 4;

  logic clk, rst_n;
  logic [13:0] s_axi_awaddr, s_axi_araddr;
  logic s_axi_awvalid, s_axi_wvalid, s_axi_bready, s_axi_arvalid, s_axi_rready;
  logic [31:0] s_axi_wdata, s_axi_rdata;
  logic [3:0] s_axi_wstrb;
  logic s_axi_awready, s_axi_wready, s_axi_bvalid, s_axi_arready, s_axi_rvalid;
  logic [1:0] s_axi_bresp, s_axi_rresp;
  logic [31:0] s_axis_tdata;
  logic s_axis_tvalid, s_axis_tready, s_axis_tlast;
  logic [31:0] m_axis_tdata;
  logic m_axis_tvalid, m_axis_tready, m_axis_tlast;

  integer errors;
  integer output_beats;
  integer output_nonzero_beats;
  integer output_x_beats;
  integer request_count;
  integer k_write_count;
  integer v_write_count;
  integer q_write_count;
  integer v_read_debug_count;
  integer q_read_debug_count;
  integer p_debug_count;
  integer obuf_debug_count;
  integer q_request_count;
  integer kv_request_count;
  integer last_output_data;
  integer last_debug_head;
  integer last_debug_group;
  logic saw_k_request, saw_v_request, saw_q_request;
  logic full_real;

  localparam logic [13:0] CSR_CTRL        = 14'h000;
  localparam logic [13:0] CSR_SEQ_LEN     = 14'h008;
  localparam logic [13:0] CSR_Q_POS_BASE  = 14'h00c;
  localparam logic [13:0] CSR_KV_POS_BASE = 14'h010;
  localparam logic [13:0] CSR_CFG         = 14'h014;
  localparam logic [13:0] CSR_STREAM_LEN  = 14'h028;
  localparam logic [13:0] CSR_STREAM_DEST = 14'h02c;
  localparam logic [13:0] CSR_RESULT_LEN  = 14'h058;
  localparam logic [31:0] CTRL_START      = 32'h1;

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
      s_axi_awaddr  = addr;
      s_axi_wdata   = value;
      s_axi_wstrb   = 4'hf;
      s_axi_awvalid = 1'b1;
      s_axi_wvalid  = 1'b1;
      s_axi_bready  = 1'b1;
      @(posedge clk);
      @(negedge clk);
      s_axi_awvalid = 1'b0;
      s_axi_wvalid  = 1'b0;
      wait (s_axi_bvalid);
      @(posedge clk);
      @(negedge clk);
      s_axi_bready  = 1'b0;
    end
  endtask

  task automatic send_stream(
    input logic [1:0] dest,
    input integer beats,
    input logic [15:0] active_word,
    input logic zero_after_first
  );
    integer beat;
    logic [15:0] lo_word;
    logic [15:0] hi_word;
    begin
      axi_write(CSR_STREAM_DEST, {30'd0, dest});
      axi_write(CSR_STREAM_LEN, beats * 4);
      s_axis_tvalid = 1'b0;
      s_axis_tlast  = 1'b0;
      for (beat = 0; beat < beats; beat = beat + 1) begin
        if (zero_after_first && beat >= 64)
          lo_word = 16'd0;
        else
          lo_word = active_word;
        if (zero_after_first && beat >= 64)
          hi_word = 16'd0;
        else
          hi_word = active_word;
        @(negedge clk);
        s_axis_tdata  = {hi_word, lo_word};
        s_axis_tlast  = (beat == beats - 1);
        s_axis_tvalid = 1'b1;
        do @(posedge clk); while (!s_axis_tready);
        @(negedge clk);
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
      end
      // The sink emits the buffered high half one cycle after the final beat.
      while (!dut.axis_done)
        @(posedge clk);
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic service_kv_request;
    begin
      request_count = request_count + 1;
      kv_request_count = kv_request_count + 1;
      if (full_real || $test$plusargs("DEBUG_REAL"))
        $display("REAL_REQ K/V group=%0d count=%0d", dut.kv_req_group_r,
                 kv_request_count);
      saw_k_request = 1'b1;
      send_stream(STREAM_TO_K_CACHE, K_V_BEATS, BF16_ONE, 1'b0);
      saw_v_request = 1'b1;
      send_stream(STREAM_TO_V_CACHE, K_V_BEATS, BF16_TWO, 1'b0);
    end
  endtask

  task automatic service_q_request;
    begin
      request_count = request_count + 1;
      q_request_count = q_request_count + 1;
      if (full_real || $test$plusargs("DEBUG_REAL"))
        $display("REAL_REQ Q group=%0d head=%0d tile=%0d bank=%0d count=%0d",
                 dut.q_req_group_r, dut.q_req_head_r, dut.q_req_tile_r,
                 dut.q_load_bank_sel_latched, q_request_count);
      saw_q_request = 1'b1;
      // The driver sends a full 32-row tile. Only row zero is nonzero.
      send_stream(STREAM_TO_Q_BUF, Q_BEATS, BF16_ONE, 1'b1);
    end
  endtask

  always @(posedge clk) begin
    if (rst_n && dut.k_wr_en) begin
      k_write_count = k_write_count + 1;
      if ($test$plusargs("DEBUG_REAL") &&
          ((k_write_count <= 2) || (dut.k_wr_addr >= 16'd126)))
        $display("REAL_K_WRITE count=%0d addr=%0d data=%h",
                 k_write_count, dut.k_wr_addr, dut.axis_data);
    end
    if (rst_n && dut.v_wr_en) begin
      v_write_count = v_write_count + 1;
      if ($test$plusargs("DEBUG_REAL") &&
          ((v_write_count <= 2) || (dut.v_wr_addr >= 16'd126)))
        $display("REAL_V_WRITE count=%0d addr=%0d data=%h",
                 v_write_count, dut.v_wr_addr, dut.axis_data);
    end
    if (rst_n && dut.qbuf_wr_en) begin
      q_write_count = q_write_count + 1;
      if ($test$plusargs("DEBUG_REAL") &&
          ((q_write_count <= 2) || (q_write_count >= Q_BEATS * 2 - 2)))
        $display("REAL_Q_WRITE count=%0d data=%h bank=%0b",
                 q_write_count, dut.axis_data, dut.q_load_bank_sel_latched);
    end
    if ($test$plusargs("DEBUG_REAL") && rst_n && dut.v_rd_vec_en &&
        (v_read_debug_count < 24)) begin
      $display("REAL_V_READ count=%0d state=%0d token=%0d dim=%0d v0=%h v15=%h",
               v_read_debug_count, dut.phaseb_state, dut.v_rd_vec_token_idx,
               dut.v_rd_vec_dim_start, dut.v_rd_vec_data[0],
               dut.v_rd_vec_data[15]);
      v_read_debug_count = v_read_debug_count + 1;
    end
    if ($test$plusargs("DEBUG_REAL") && rst_n && dut.phasea_depth_active &&
        (q_read_debug_count < 12)) begin
      $display("REAL_QK_READ count=%0d depth=%0d q0=%h k0=%h",
               q_read_debug_count, dut.depth_cnt, dut.q_block_rd[0],
               dut.k_rd[0]);
      q_read_debug_count = q_read_debug_count + 1;
    end
    if (full_real && rst_n && dut.phasea_depth_active &&
        ((last_debug_head != dut.u_fsm.head_cnt) ||
         (last_debug_group != dut.u_fsm.group_cnt))) begin
      $display("REAL_HEAD_START group=%0d head=%0d qbank=%0b qready=%b qoutstanding=%0b qload_done=%0b q0=%h",
               dut.u_fsm.group_cnt, dut.u_fsm.head_cnt,
               dut.q_compute_bank_sel, dut.q_bank_ready,
               dut.q_load_outstanding, dut.q_load_done, dut.q_block_rd[0]);
      last_debug_head = dut.u_fsm.head_cnt;
      last_debug_group = dut.u_fsm.group_cnt;
    end
    if ($test$plusargs("DEBUG_REAL") && rst_n && dut.p_valid &&
        (p_debug_count < 8)) begin
      $display("REAL_P count=%0d p00=%h correction0=%h",
               p_debug_count, dut.p_block[0][0], dut.correction[0]);
      p_debug_count = p_debug_count + 1;
    end
    if ($test$plusargs("DEBUG_REAL") && rst_n && dut.obuf_update &&
        (obuf_debug_count < 8)) begin
      $display("REAL_OBUF count=%0d data0=%h corr=%h l=%h",
               obuf_debug_count, dut.obuf_data[0], dut.obuf_corr_sel,
               dut.obuf_l_sel[0]);
      obuf_debug_count = obuf_debug_count + 1;
    end
    if (rst_n && m_axis_tvalid && m_axis_tready) begin
    output_beats = output_beats + 1;
      last_output_data = m_axis_tdata;
      if (^m_axis_tdata === 1'bx)
        output_x_beats = output_x_beats + 1;
      else if (m_axis_tdata != 32'd0)
        output_nonzero_beats = output_nonzero_beats + 1;
      if (output_beats <= 4)
        $display("REAL_OUT beat=%0d data=%h last=%0b",
                 output_beats, m_axis_tdata, m_axis_tlast);
      else if (full_real && ((output_beats % (HEAD_DIM / 2)) == 1))
        $display("REAL_OUT_HEAD beat=%0d head_index=%0d data=%h fsm_group=%0d fsm_head=%0d qbank=%0b qready=%b q0=%h",
                 output_beats, (output_beats - 1) / (HEAD_DIM / 2),
                 m_axis_tdata, dut.u_fsm.group_cnt, dut.u_fsm.head_cnt,
                 dut.q_compute_bank_sel, dut.q_bank_ready, dut.q_block_rd[0]);
    end
  end

  initial begin
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
    output_nonzero_beats = 0;
    output_x_beats = 0;
    request_count = 0;
    k_write_count = 0;
    v_write_count = 0;
    q_write_count = 0;
    v_read_debug_count = 0;
    q_read_debug_count = 0;
    p_debug_count = 0;
    obuf_debug_count = 0;
    q_request_count = 0;
    kv_request_count = 0;
    last_output_data = 0;
    last_debug_head = -1;
    last_debug_group = -1;
    saw_k_request = 1'b0;
    saw_v_request = 1'b0;
    saw_q_request = 1'b0;
    full_real = $test$plusargs("FULL_REAL");

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    axi_write(CSR_SEQ_LEN, 32'd1);
    axi_write(CSR_Q_POS_BASE, 32'd3);
    axi_write(CSR_KV_POS_BASE, 32'd3);
    axi_write(CSR_CFG, 32'd1);
    if (full_real) begin
      // Match board_test.py for L=1: 32 Q heads x 128 BF16 values.
      axi_write(CSR_RESULT_LEN, 32'd8192);
    end else begin
      // Focused single group/head reproducer.
      axi_write(CSR_RESULT_LEN, 32'd256);
      force dut.u_fsm.head_cnt  = 2'd3;
      force dut.u_fsm.group_cnt = 3'd7;
    end
    axi_write(CSR_CTRL, CTRL_START);

    while (!dut.done) begin
      if (dut.kv_load_req)
        service_kv_request();
      else if (dut.q_load_req)
        service_q_request();
      else
        @(posedge clk);
    end
    repeat (20) @(posedge clk);

    if (!full_real) begin
      release dut.u_fsm.head_cnt;
      release dut.u_fsm.group_cnt;
    end

    if (!saw_k_request || !saw_v_request || !saw_q_request) begin
      $display("FAIL missing request K=%0b V=%0b Q=%0b",
               saw_k_request, saw_v_request, saw_q_request);
      errors = errors + 1;
    end
    if (output_beats != (full_real ? (N_Q_HEADS * HEAD_DIM / 2)
                                   : (HEAD_DIM / 2))) begin
      $display("FAIL output beat count got=%0d expected=%0d",
               output_beats,
               full_real ? (N_Q_HEADS * HEAD_DIM / 2)
                         : (HEAD_DIM / 2));
      errors = errors + 1;
    end
    if (output_nonzero_beats == 0) begin
      $display("FAIL output has no known nonzero beats (x_beats=%0d)",
               output_x_beats);
      errors = errors + 1;
    end
    if (output_beats > 0 && last_output_data !== 32'h4000_4000) begin
      $display("FAIL final observed output beat=%h expected=40004000",
               last_output_data);
      errors = errors + 1;
    end
    if (full_real && q_request_count != N_Q_HEADS) begin
      $display("FAIL Q request count got=%0d expected=%0d",
               q_request_count, N_Q_HEADS);
      errors = errors + 1;
    end
    if (full_real && kv_request_count != N_KV_HEADS) begin
      $display("FAIL K/V request count got=%0d expected=%0d",
               kv_request_count, N_KV_HEADS);
      errors = errors + 1;
    end
    if (output_x_beats != 0) begin
      $display("FAIL output contains X beats=%0d", output_x_beats);
      errors = errors + 1;
    end
    if (errors == 0) begin
      $display("REAL REQUEST PATH PASS mode=%s requests=%0d q_requests=%0d kv_requests=%0d output_beats=%0d nonzero_beats=%0d x_beats=%0d",
               full_real ? "full" : "focused", request_count, q_request_count,
               kv_request_count, output_beats, output_nonzero_beats,
               output_x_beats);
      $finish(0);
    end
    $display("REAL REQUEST PATH FAIL errors=%0d", errors);
    $fatal(1);
  end

  initial begin
    #5_000_000;
    $display("FAIL real request path timeout state=%0d busy=%0b done=%0b kv_req=%0b q_req=%0b",
             dut.u_fsm.state, dut.busy, dut.done, dut.kv_load_req, dut.q_load_req);
    $fatal(1);
  end
endmodule
