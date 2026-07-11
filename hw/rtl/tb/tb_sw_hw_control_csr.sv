`timescale 1ns/1ps

module tb_sw_hw_control_csr;
  import attn_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [13:0] awaddr;
  logic awvalid;
  logic awready;
  logic [31:0] wdata;
  logic [3:0] wstrb;
  logic wvalid;
  logic wready;
  logic [1:0] bresp;
  logic bvalid;
  logic bready;
  logic [13:0] araddr;
  logic arvalid;
  logic arready;
  logic [31:0] rdata;
  logic [1:0] rresp;
  logic rvalid;
  logic rready;

  logic start;
  logic [15:0] seq_len;
  logic [15:0] cfg_q_pos_base;
  logic [15:0] cfg_kv_pos_base;
  logic cfg_causal;
  logic [1:0] stream_dest;
  logic [31:0] stream_len;
  logic [31:0] result_len;

  logic start_ready;
  logic busy;
  logic done;
  logic core_error;
  logic [7:0] core_error_code;
  logic stream_error;
  logic [31:0] cycle_cnt;
  logic [31:0] mac_cycles;

  int errors = 0;
  int start_count = 0;

  attn_axi_lite_slave dut (
    .clk(clk), .rst_n(rst_n),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .start(start), .seq_len(seq_len), .cfg_q_pos_base(cfg_q_pos_base), .cfg_kv_pos_base(cfg_kv_pos_base),
    .cfg_causal(cfg_causal), .stream_dest(stream_dest), .stream_len(stream_len), .result_len(result_len),
    .start_ready(start_ready), .busy(busy), .done(done), .core_error(core_error), .core_error_code(core_error_code),
    .stream_error(stream_error), .cycle_cnt(cycle_cnt), .mac_cycles(mac_cycles)
  );

  always @(posedge clk) if (start) start_count++;

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
      awaddr = addr;
      wdata = data;
      wstrb = 4'hF;
      awvalid = 1'b1;
      wvalid = 1'b1;
      bready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      awvalid = 1'b0;
      wvalid = 1'b0;
      wait (bvalid === 1'b1);
      @(posedge clk);
      @(negedge clk);
      bready = 1'b0;
    end
  endtask

  task automatic axi_read(input logic [13:0] addr, output logic [31:0] data);
    begin
      @(negedge clk);
      araddr = addr;
      arvalid = 1'b1;
      rready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      arvalid = 1'b0;
      wait (rvalid === 1'b1);
      data = rdata;
      @(posedge clk);
      @(negedge clk);
      rready = 1'b0;
    end
  endtask

  logic [31:0] rd;

  initial begin
    awaddr = '0; awvalid = 0; wdata = '0; wstrb = 4'hF; wvalid = 0; bready = 0;
    araddr = '0; arvalid = 0; rready = 0;
    start_ready = 1; busy = 0; done = 0; core_error = 0; core_error_code = ERR_NONE;
    stream_error = 0; cycle_cnt = 32'h1234; mac_cycles = 32'h55;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    axi_read(CSR_STATUS, rd);
    check(rd[0] == 1'b1, "reset status start_ready should be 1");
    check(rd[4:1] == 4'd0, "reset sticky status should be clear");

    axi_write(CSR_SEQ_LEN, 32'd16);
    axi_write(CSR_Q_POS_BASE, 32'd2);
    axi_write(CSR_KV_POS_BASE, 32'd4);
    axi_write(CSR_CFG, 32'd0);
    axi_write(CSR_STREAM_DEST, STREAM_TO_Q_BUF);
    axi_write(CSR_STREAM_LEN, 32'd131072);
    axi_write(CSR_RESULT_LEN, 32'd131072);

    check(seq_len == 16, "seq_len writeback");
    check(cfg_q_pos_base == 2, "q_pos_base writeback");
    check(cfg_kv_pos_base == 4, "kv_pos_base writeback");
    check(cfg_causal == 0, "cfg_causal writeback");
    check(stream_dest == STREAM_TO_Q_BUF, "stream_dest writeback");
    check(stream_len == 32'd131072, "stream_len writeback");
    check(result_len == 32'd131072, "result_len writeback");

    axi_write(CSR_CTRL, 32'h1);
    repeat (2) @(posedge clk);
    check(start_count == 1, "accepted start should pulse exactly once");

    done = 1'b1;
    @(posedge clk);
    done = 1'b0;
    axi_read(CSR_STATUS, rd);
    check(rd[2] == 1'b1, "done sticky should set");

    @(negedge clk);
    stream_error = 1'b1;
    repeat (2) @(posedge clk);
    @(negedge clk);
    stream_error = 1'b0;
    axi_read(CSR_STATUS, rd);
    check(rd[4] == 1'b1 && rd[3] == 1'b0, "stream_error sticky should set without generic error bit");
    axi_read(CSR_ERROR_CODE, rd);
    check(rd[7:0] == ERR_STREAM_LEN, "stream_error code should default to ERR_STREAM_LEN");

    axi_write(CSR_CTRL, 32'h2);
    axi_read(CSR_STATUS, rd);
    check(rd[4:2] == 3'b000, "clear_status should clear done/error/stream_error");
    axi_read(CSR_ERROR_CODE, rd);
    check(rd[7:0] == ERR_NONE, "clear_status should clear error code");

    start_ready = 1'b0;
    busy = 1'b1;
    axi_write(CSR_CTRL, 32'h1);
    repeat (2) @(posedge clk);
    check(start_count == 1, "busy start must not create new start pulse");
    axi_read(CSR_STATUS, rd);
    check(rd[3] == 1'b1, "busy start should set sticky error");
    axi_read(CSR_ERROR_CODE, rd);
    check(rd[7:0] == ERR_BUSY_START, "busy start should report ERR_BUSY_START");

    if (errors == 0) begin
      $display("TB_SW_HW_CONTROL_CSR PASS");
      $finish(0);
    end else begin
      $display("TB_SW_HW_CONTROL_CSR FAIL errors=%0d", errors);
      $finish(1);
    end
  end
endmodule