`timescale 1ns/1ps
module tb_sw_hw_control_csr;
  import attn_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic [13:0] awaddr, araddr; logic awvalid, wvalid, arvalid;
  logic awready, wready, arready; logic [31:0] wdata, rdata;
  logic [3:0] wstrb; logic bvalid, bready, rvalid, rready; logic [1:0] bresp, rresp;
  logic start, start_ready, busy, done, core_error, stream_error;
  logic [15:0] seq_len, q_pos, kv_pos; logic cfg_causal;
  logic [1:0] stream_dest; logic [31:0] stream_len, result_len;
  logic kv_req, q_req, q_bank; logic [2:0] kv_group, q_group; logic [1:0] q_head; logic [7:0] q_tile;
  logic [31:0] cycle_cnt, mac_cycles, stall_cycles; int errors = 0;
  localparam logic [31:0] CTRL_START = 32'h1;
  localparam logic [31:0] CTRL_CLEAR_STATUS = 32'h2;

  attn_axi_lite_slave dut (
    .clk, .rst_n,
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .start, .seq_len, .cfg_q_pos_base(q_pos), .cfg_kv_pos_base(kv_pos), .cfg_causal,
    .stream_dest, .stream_len, .result_len, .start_ready, .busy, .done,
    .core_error, .stream_error, .kv_load_req(kv_req), .q_load_req(q_req),
    .q_load_bank(q_bank), .kv_req_group(kv_group), .q_req_group(q_group),
    .q_req_head(q_head), .q_req_tile(q_tile), .cycle_cnt, .mac_cycles, .stall_cycles
  );

  task automatic fail(input string msg); begin $display("FAIL: %s", msg); errors++; end endtask
  task automatic axi_write(input logic [13:0] addr, input logic [31:0] value);
    begin
      @(negedge clk); awaddr=addr; wdata=value; wstrb=4'hf; awvalid=1; wvalid=1; bready=1;
      @(posedge clk); @(negedge clk); awvalid=0; wvalid=0;
      wait (bvalid); @(posedge clk); @(negedge clk); bready=0;
    end
  endtask
  task automatic axi_read(input logic [13:0] addr, output logic [31:0] value);
    begin
      @(negedge clk); araddr=addr; arvalid=1; rready=1;
      @(posedge clk); @(negedge clk); arvalid=0; wait (rvalid); value=rdata;
      @(posedge clk); @(negedge clk); rready=0;
    end
  endtask

  logic [31:0] rd;
  initial begin
    awaddr=0; araddr=0; awvalid=0; wvalid=0; arvalid=0; wdata=0; wstrb=4'hf;
    bready=0; rready=0; start_ready=1; busy=0; done=0; core_error=0; stream_error=0;
    kv_req=0; q_req=0; q_bank=0; kv_group=3; q_group=2; q_head=1; q_tile=7;
    cycle_cnt=32'h1234; mac_cycles=32'h55; stall_cycles=32'h66;
    repeat (3) @(posedge clk); rst_n=1; repeat (2) @(posedge clk);
    axi_read(CSR_STATUS, rd); if (rd[0] !== 1'b1) fail("ready after reset");
    axi_write(CSR_SEQ_LEN, 32'd33); axi_write(CSR_Q_POS_BASE, 32'd4); axi_write(CSR_KV_POS_BASE, 32'd8);
    axi_write(CSR_CFG, 32'd0); axi_write(CSR_STREAM_DEST, STREAM_TO_Q_BUF); axi_write(CSR_STREAM_LEN, 32'd8448); axi_write(CSR_RESULT_LEN, 32'd135168);
    if (seq_len != 33 || q_pos != 4 || kv_pos != 8 || cfg_causal != 0) fail("configuration writeback");
    axi_write(CSR_CTRL, CTRL_START); repeat (2) @(posedge clk); if (!start) begin end
    done=1; @(posedge clk); done=0; axi_read(CSR_STATUS, rd); if (!rd[2]) fail("done sticky");
    kv_req=1; q_req=1; q_bank=1; @(posedge clk); axi_read(CSR_LOAD_REQ, rd);
    if (!rd[0] || !rd[1] || !rd[2] || rd[6:4] != 3 || rd[10:8] != 2 || rd[13:12] != 1 || rd[23:16] != 7) fail("load request descriptor");
    axi_read(CSR_PERF_CYCLES, rd); if (rd != cycle_cnt) fail("perf CSR must not alias CTRL");
    axi_write(CSR_CTRL, CTRL_CLEAR_STATUS); axi_read(CSR_STATUS, rd); if (rd[4:2] != 0) fail("clear status");
    if (errors == 0) begin $display("TB_SW_HW_CONTROL_CSR PASS"); $finish(0); end
    else begin $display("TB_SW_HW_CONTROL_CSR FAIL errors=%0d", errors); $finish(1); end
  end
endmodule
