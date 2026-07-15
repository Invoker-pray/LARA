`timescale 1ns/1ps
module tb_sw_hw_control_sink;
  import attn_pkg::*;
  logic clk=0, rst_n=0; always #5 clk=~clk;
  logic [31:0] s_axis_tdata; logic s_axis_tvalid, s_axis_tready, s_axis_tlast;
  logic [1:0] cfg_dest, dest_sel; logic [31:0] cfg_len, bytes_received; logic [3:0] cfg_burst;
  logic data_valid, data_last, overflow, underflow, done; logic [15:0] data_out; logic done_seen; int errors=0, count=0;
  attn_axi_stream_sink dut(.*);
  task automatic send(input logic [31:0] data, input logic last);
    begin @(negedge clk); wait(s_axis_tready); s_axis_tdata=data; s_axis_tlast=last; s_axis_tvalid=1;
      @(posedge clk); @(negedge clk); s_axis_tvalid=0; s_axis_tlast=0; repeat(3) @(posedge clk); end
  endtask
  always @(posedge clk) if (data_valid) count++;
  always @(posedge clk) if (done) done_seen = 1'b1;
  initial begin
    s_axis_tdata=0; s_axis_tvalid=0; s_axis_tlast=0; cfg_dest=STREAM_TO_K_CACHE; cfg_len=8; cfg_burst=0; done_seen=0;
    repeat(3) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
    send(32'h2222_1111,0); send(32'h4444_3333,1);
    if (!done_seen || overflow || underflow || bytes_received != 8 || count != 4) errors++;
    rst_n=0; repeat(2) @(posedge clk); rst_n=1; cfg_dest=STREAM_TO_V_CACHE; cfg_len=4; count=0; done_seen=0;
    send(32'hBBBB_AAAA,1); if (!done_seen || overflow || underflow || count != 2) errors++;
    if (errors==0) begin $display("TB_SW_HW_CONTROL_SINK PASS"); $finish(0); end
    else begin $display("TB_SW_HW_CONTROL_SINK FAIL errors=%0d",errors); $finish(1); end
  end
endmodule
