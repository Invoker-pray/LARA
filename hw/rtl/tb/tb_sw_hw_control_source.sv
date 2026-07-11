`timescale 1ns/1ps

module tb_sw_hw_control_source;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic data_valid;
  logic [15:0] data_in;
  logic data_last;
  logic [31:0] cfg_len;
  logic [31:0] m_axis_tdata;
  logic m_axis_tvalid;
  logic m_axis_tready;
  logic m_axis_tlast;
  logic [31:0] bytes_sent;
  logic done;
  int errors = 0;
  int done_count = 0;

  always @(posedge clk) if (done) done_count++;

  attn_axi_stream_source dut (
    .clk(clk), .rst_n(rst_n),
    .data_valid(data_valid), .data_in(data_in), .data_last(data_last),
    .cfg_len(cfg_len),
    .m_axis_tdata(m_axis_tdata), .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready), .m_axis_tlast(m_axis_tlast),
    .bytes_sent(bytes_sent), .done(done)
  );

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

  task automatic push(input logic [15:0] data, input logic last);
    begin
      @(negedge clk);
      data_in = data;
      data_last = last;
      data_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      data_valid = 1'b0;
      data_last = 1'b0;
      data_in = 16'd0;
    end
  endtask

  task automatic reset_dut;
    begin
      rst_n = 1'b0;
      data_valid = 1'b0;
      data_in = 16'd0;
      data_last = 1'b0;
      cfg_len = 32'd0;
      m_axis_tready = 1'b1;
      done_count = 0;
      repeat (3) @(posedge clk);
      rst_n = 1'b1;
      repeat (2) @(posedge clk);
    end
  endtask

  initial begin
    reset_dut();
    cfg_len = 32'd4;
    push(16'h1111, 1'b0);
    push(16'h2222, 1'b1);
    repeat (1) @(posedge clk);
    check(m_axis_tvalid && m_axis_tdata == 32'h2222_1111 && m_axis_tlast, "two bf16 should pack low/high with tlast");
    @(posedge clk);
    repeat (1) @(posedge clk);
    check(done_count == 1, "done should pulse after final beat accepted");

    reset_dut();
    cfg_len = 32'd4;
    m_axis_tready = 1'b0;
    push(16'hAAAA, 1'b0);
    push(16'hBBBB, 1'b1);
    repeat (1) @(posedge clk);
    check(m_axis_tvalid && m_axis_tdata == 32'hBBBB_AAAA && m_axis_tlast, "pending beat should appear under stall");
    repeat (3) @(posedge clk);
    check(m_axis_tvalid && m_axis_tdata == 32'hBBBB_AAAA && m_axis_tlast, "pending beat should stay stable under stall");
    m_axis_tready = 1'b1;
    @(posedge clk);
    repeat (1) @(posedge clk);
    check(done_count == 1, "done should pulse after stalled beat accepted");

    reset_dut();
    cfg_len = 32'd2;
    push(16'h00CC, 1'b1);
    repeat (1) @(posedge clk);
    check(m_axis_tvalid && m_axis_tdata == 32'h0000_00CC && m_axis_tlast, "odd final bf16 should flush padded beat");

    if (errors == 0) begin
      $display("TB_SW_HW_CONTROL_SOURCE PASS");
      $finish(0);
    end else begin
      $display("TB_SW_HW_CONTROL_SOURCE FAIL errors=%0d", errors);
      $finish(1);
    end
  end
endmodule