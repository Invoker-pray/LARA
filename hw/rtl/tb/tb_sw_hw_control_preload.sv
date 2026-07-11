`timescale 1ns/1ps

module tb_sw_hw_control_preload;
  import attn_pkg::*;

  localparam int SEQ = 1;
  localparam int K_BYTES = N_KV_HEADS * SEQ * HEAD_DIM * 2;
  localparam int V_BYTES = N_KV_HEADS * SEQ * HEAD_DIM * 2;
  localparam int Q_BYTES = N_Q_HEADS * SEQ * HEAD_DIM * 2;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [13:0] s_axi_awaddr;
  logic s_axi_awvalid;
  logic s_axi_awready;
  logic [31:0] s_axi_wdata;
  logic [3:0] s_axi_wstrb;
  logic s_axi_wvalid;
  logic s_axi_wready;
  logic [1:0] s_axi_bresp;
  logic s_axi_bvalid;
  logic s_axi_bready;
  logic [13:0] s_axi_araddr;
  logic s_axi_arvalid;
  logic s_axi_arready;
  logic [31:0] s_axi_rdata;
  logic [1:0] s_axi_rresp;
  logic s_axi_rvalid;
  logic s_axi_rready;
  logic [31:0] s_axis_tdata;
  logic s_axis_tvalid;
  logic s_axis_tready;
  logic s_axis_tlast;
  logic [31:0] m_axis_tdata;
  logic m_axis_tvalid;
  logic m_axis_tready;
  logic m_axis_tlast;

  int errors = 0;
  int k_count = 0;
  int v_count = 0;
  int q_count = 0;
  int mixed_count = 0;
  logic [15:0] word_lo;
  logic [15:0] word_hi;

  attn_top dut (
    .clk(clk), .rst_n(rst_n),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
    .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready), .s_axis_tlast(s_axis_tlast),
    .m_axis_tdata(m_axis_tdata), .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready), .m_axis_tlast(m_axis_tlast)
  );

  always @(posedge clk) begin
    if (rst_n) begin
      if (dut.k_wr_en) k_count++;
      if (dut.v_wr_en) v_count++;
      if (dut.q_wr_en) q_count++;
      if ((dut.k_wr_en + dut.v_wr_en + dut.q_wr_en) > 1) mixed_count++;
    end
  end

  task automatic fail(input string msg);
    begin
      $display("FAIL: %s", msg);
      errors++;
    end
  endtask

  task automatic check(input bit cond, input string msg);
    begin
      if (!cond) fail(msg);
    end
  endtask

  task automatic axi_write(input logic [13:0] addr, input logic [31:0] data);
    begin
      @(negedge clk);
      s_axi_awaddr = addr;
      s_axi_wdata = data;
      s_axi_wstrb = 4'hF;
      s_axi_awvalid = 1'b1;
      s_axi_wvalid = 1'b1;
      s_axi_bready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      s_axi_awvalid = 1'b0;
      s_axi_wvalid = 1'b0;
      wait (s_axi_bvalid === 1'b1);
      @(posedge clk);
      @(negedge clk);
      s_axi_bready = 1'b0;
    end
  endtask

  task automatic send_beat(input logic [31:0] data, input logic last);
    begin
      @(negedge clk);
      wait (s_axis_tready === 1'b1);
      s_axis_tdata = data;
      s_axis_tlast = last;
      s_axis_tvalid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      s_axis_tdata = 32'd0;
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic stream_words(input logic [1:0] dest, input int byte_len, input logic [15:0] base);
    int beats;
    int ii;
    begin
      beats = byte_len / 4;
      axi_write(CSR_STREAM_DEST, dest);
      axi_write(CSR_STREAM_LEN, byte_len);
      for (ii = 0; ii < beats; ii++) begin
        word_lo = base + (ii * 2);
        word_hi = base + (ii * 2 + 1);
        send_beat({word_hi, word_lo}, (ii == beats - 1));
      end
      repeat (6) @(posedge clk);
    end
  endtask

  initial begin
    s_axi_awaddr = '0; s_axi_awvalid = 0; s_axi_wdata = '0; s_axi_wstrb = 4'hF; s_axi_wvalid = 0; s_axi_bready = 0;
    s_axi_araddr = '0; s_axi_arvalid = 0; s_axi_rready = 0;
    s_axis_tdata = '0; s_axis_tvalid = 0; s_axis_tlast = 0;
    m_axis_tready = 1'b1;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    stream_words(STREAM_TO_K_CACHE, K_BYTES, 16'h1000);
    check(dut.k_loaded, "K loaded flag should set");
    check(k_count == K_BYTES / 2, "K write count should match K bf16 elements");
    check(v_count == 0 && q_count == 0, "K stream must not write V/Q");

    stream_words(STREAM_TO_V_CACHE, V_BYTES, 16'h2000);
    check(dut.v_loaded, "V loaded flag should set");
    check(v_count == V_BYTES / 2, "V write count should match V bf16 elements");
    check(q_count == 0, "V stream must not write Q");

    stream_words(STREAM_TO_Q_BUF, Q_BYTES, 16'h3000);
    check(dut.q_loaded, "Q loaded flag should set");
    check(q_count == Q_BYTES / 2, "Q write count should match Q bf16 elements");
    check(mixed_count == 0, "K/V/Q write enables must be mutually exclusive");
    check(dut.sink_bytes == Q_BYTES, "sink byte counter should report final Q stream length");
    check(!dut.stream_error, "full-run preload should not set stream_error");

    if (errors == 0) begin
      $display("TB_SW_HW_CONTROL_PRELOAD PASS");
      $finish(0);
    end else begin
      $display("TB_SW_HW_CONTROL_PRELOAD FAIL errors=%0d", errors);
      $finish(1);
    end
  end
endmodule