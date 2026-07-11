`timescale 1ns/1ps

module tb_sw_hw_control_sink;
  import attn_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [31:0] s_axis_tdata;
  logic s_axis_tvalid;
  logic s_axis_tready;
  logic s_axis_tlast;
  logic [1:0] cfg_dest;
  logic [31:0] cfg_len;
  logic [3:0] cfg_burst;
  logic data_valid;
  logic [15:0] data_out;
  logic data_last;
  logic [1:0] dest_sel;
  logic [31:0] bytes_received;
  logic overflow;
  logic underflow;
  logic done;

  int errors = 0;
  int out_count = 0;
  logic [15:0] out_data [0:31];
  logic [1:0] out_dest [0:31];
  logic out_last [0:31];

  attn_axi_stream_sink dut (
    .clk(clk), .rst_n(rst_n),
    .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready), .s_axis_tlast(s_axis_tlast),
    .cfg_dest(cfg_dest), .cfg_len(cfg_len), .cfg_burst(cfg_burst),
    .data_valid(data_valid), .data_out(data_out), .data_last(data_last), .dest_sel(dest_sel),
    .bytes_received(bytes_received), .overflow(overflow), .underflow(underflow), .done(done)
  );

  always @(posedge clk) begin
    if (data_valid) begin
      out_data[out_count] = data_out;
      out_dest[out_count] = dest_sel;
      out_last[out_count] = data_last;
      out_count++;
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

  task automatic clear_capture;
    begin
      out_count = 0;
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

  task automatic reset_dut;
    begin
      rst_n = 1'b0;
      s_axis_tdata = 32'd0;
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      cfg_dest = STREAM_TO_K_CACHE;
      cfg_len = 32'd0;
      cfg_burst = 4'd0;
      clear_capture();
      repeat (3) @(posedge clk);
      rst_n = 1'b1;
      repeat (2) @(posedge clk);
    end
  endtask

  initial begin
    reset_dut();

    cfg_dest = STREAM_TO_K_CACHE;
    cfg_len = 32'd8;
    send_beat(32'h2222_1111, 1'b0);
    send_beat(32'h4444_3333, 1'b1);
    repeat (3) @(posedge clk);
    check(done && !overflow && !underflow, "exact two-beat transfer should complete cleanly");
    check(bytes_received == 32'd8, "exact transfer byte count");
    check(out_count == 4, "exact transfer should emit four bf16 values");
    check(out_data[0] == 16'h1111 && out_data[1] == 16'h2222 && out_data[2] == 16'h3333 && out_data[3] == 16'h4444, "bf16 unpack order low then high");
    check(out_dest[0] == STREAM_TO_K_CACHE && out_dest[3] == STREAM_TO_K_CACHE, "dest should pass through K");
    check(out_last[3] == 1'b1, "last should align with high half of final beat");

    reset_dut();
    cfg_dest = STREAM_TO_V_CACHE;
    cfg_len = 32'd4;
    send_beat(32'hBBBB_AAAA, 1'b1);
    repeat (3) @(posedge clk);
    check(done && !overflow && !underflow, "single V beat should complete cleanly");
    check(out_count == 2 && out_dest[0] == STREAM_TO_V_CACHE && out_dest[1] == STREAM_TO_V_CACHE, "V route should pass dest");

    reset_dut();
    cfg_dest = STREAM_TO_Q_BUF;
    cfg_len = 32'd4;
    send_beat(32'hDDDD_CCCC, 1'b1);
    repeat (3) @(posedge clk);
    check(done && !overflow && !underflow, "single Q beat should complete cleanly");
    check(out_count == 2 && out_dest[0] == STREAM_TO_Q_BUF && out_dest[1] == STREAM_TO_Q_BUF, "Q route should pass dest");

    reset_dut();
    cfg_dest = STREAM_TO_K_CACHE;
    cfg_len = 32'd8;
    send_beat(32'h0002_0001, 1'b1);
    repeat (3) @(posedge clk);
    check(done && underflow, "early tlast should set underflow");

    reset_dut();
    cfg_dest = STREAM_TO_K_CACHE;
    cfg_len = 32'd4;
    send_beat(32'h0004_0003, 1'b0);
    repeat (3) @(posedge clk);
    check(overflow, "missing tlast at expected length should set overflow");

    reset_dut();
    cfg_dest = 2'd3;
    cfg_len = 32'd4;
    send_beat(32'h0006_0005, 1'b1);
    repeat (3) @(posedge clk);
    check(overflow, "illegal dest should set overflow/error indication");

    if (errors == 0) begin
      $display("TB_SW_HW_CONTROL_SINK PASS");
      $finish(0);
    end else begin
      $display("TB_SW_HW_CONTROL_SINK FAIL errors=%0d", errors);
      $finish(1);
    end
  end
endmodule