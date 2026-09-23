`timescale 1ns/1ps
module tb_sw_hw_control_sink;
  import attn_pkg::*;
  logic clk=0, rst_n=0; always #5 clk=~clk;
  logic [31:0] s_axis_tdata; logic s_axis_tvalid, s_axis_tready, s_axis_tlast;
  logic [1:0] cfg_dest, dest_sel; logic [31:0] cfg_len, bytes_received; logic [3:0] cfg_burst;
  logic data_valid, data_last, overflow, underflow, done; logic [15:0] data_out; logic done_seen; int errors=0, count=0;
  int done_count=0, k_count=0, v_count=0, q_count=0;
  logic desc_queue_enabled, inband_command_enabled, desc_valid, desc_ready;
  logic kv_load_req, q_load_req;
  logic kv_wr_ready = 1'b1;
  logic [1:0] desc_dest; logic [31:0] desc_len;
  attn_axi_stream_sink dut(.*);
  task automatic send(input logic [31:0] data, input logic last);
    begin @(negedge clk); wait(s_axis_tready); s_axis_tdata=data; s_axis_tlast=last; s_axis_tvalid=1;
      @(posedge clk); @(negedge clk); s_axis_tvalid=0; s_axis_tlast=0; repeat(3) @(posedge clk); end
  endtask
  task automatic offer_desc(input logic [1:0] dest, input logic [31:0] len);
    begin
      @(negedge clk); desc_dest=dest; desc_len=len; desc_valid=1;
      wait(desc_ready); @(posedge clk); @(negedge clk); desc_valid=0;
    end
  endtask
  always @(posedge clk) if (data_valid) begin
    count++;
    case (dest_sel)
      STREAM_TO_K_CACHE: k_count++;
      STREAM_TO_V_CACHE: v_count++;
      STREAM_TO_Q_BUF: q_count++;
      default: begin end
    endcase
  end
  always @(posedge clk) if (done) begin done_seen = 1'b1; done_count++; end
  initial begin
    s_axis_tdata=0; s_axis_tvalid=0; s_axis_tlast=0; cfg_dest=STREAM_TO_K_CACHE; cfg_len=8; cfg_burst=0; done_seen=0;
    desc_queue_enabled=0; desc_valid=0; desc_dest=0; desc_len=0;
    inband_command_enabled=0; kv_load_req=0; q_load_req=0;
    repeat(3) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
    send(32'h2222_1111,0); send(32'h4444_3333,1);
    if (!done_seen || overflow || underflow || bytes_received != 8 || count != 4) errors++;
    rst_n=0; repeat(2) @(posedge clk); rst_n=1; cfg_dest=STREAM_TO_V_CACHE; cfg_len=4; count=0; done_seen=0;
    send(32'hBBBB_AAAA,1); if (!done_seen || overflow || underflow || count != 2) errors++;
    rst_n=0; repeat(2) @(posedge clk); rst_n=1;
    desc_queue_enabled=1; count=0; done_count=0; k_count=0; v_count=0; q_count=0;
    offer_desc(STREAM_TO_K_CACHE, 4);
    send(32'h0002_0001,0);
    offer_desc(STREAM_TO_V_CACHE, 8);
    send(32'h0004_0003,0);
    send(32'h0006_0005,0);
    offer_desc(STREAM_TO_Q_BUF, 4);
    send(32'h0008_0007,1);
    if (done_count != 3 || k_count != 2 || v_count != 4 || q_count != 2 ||
        overflow || underflow || bytes_received != 16) begin
      $display("descriptor batch mismatch done=%0d k=%0d v=%0d q=%0d bytes=%0d ov=%0b uf=%0b",
               done_count, k_count, v_count, q_count, bytes_received, overflow, underflow);
      errors++;
    end
    rst_n=0; repeat(2) @(posedge clk); rst_n=1;
    desc_queue_enabled=1; inband_command_enabled=1;
    count=0; done_count=0; k_count=0; v_count=0; q_count=0;
    kv_load_req=0; q_load_req=0;
    send(32'h0000_0004,0); // one-word K command; payload must wait for request
    if (s_axis_tready) errors++;
    kv_load_req=1; repeat(2) @(posedge clk);
    send(32'h0012_0011,0);
    kv_load_req=0;
    send(32'h0000_0006,0); // one-word Q command
    if (s_axis_tready) errors++;
    q_load_req=1; repeat(2) @(posedge clk);
    send(32'h0014_0013,1);
    if (done_count != 2 || k_count != 2 || q_count != 2 ||
        overflow || underflow || bytes_received != 16) begin
      $display("inband stream mismatch done=%0d k=%0d q=%0d bytes=%0d ov=%0b uf=%0b",
               done_count, k_count, q_count, bytes_received, overflow, underflow);
      errors++;
    end
    if (errors==0) begin $display("TB_SW_HW_CONTROL_SINK PASS"); $finish(0); end
    else begin $display("TB_SW_HW_CONTROL_SINK FAIL errors=%0d",errors); $finish(1); end
  end
endmodule
