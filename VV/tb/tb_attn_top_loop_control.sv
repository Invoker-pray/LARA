`timescale 1ns / 1ps

module tb_attn_top_loop_control;
  import attn_pkg::*;

  localparam int TEST_SEQ = 64;
  localparam int EXPECT_GROUPS = N_KV_HEADS;
  localparam int EXPECT_HEADS = N_Q_HEADS;
  localparam int EXPECT_Q_LOADS = EXPECT_HEADS * ((TEST_SEQ + TILE_Q - 1) / TILE_Q);

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

  int err;
  int kv_load_pulses;
  int q_load_pulses;
  int group_advance_pulses;
  bit saw_overlap_prefetch;
  bit seen_all_groups;
  logic kv_load_start_d, q_load_start_d, group_advance_d;

  logic kv_done_drv, o_done_drv;
  logic axis_done_drv;
  logic [1:0] axis_dest_drv;

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

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      kv_done_drv <= 1'b0;
      o_done_drv <= 1'b0;
      axis_done_drv <= 1'b0;
      axis_dest_drv <= STREAM_TO_Q_BUF;
      kv_load_start_d <= 1'b0;
      q_load_start_d <= 1'b0;
      group_advance_d <= 1'b0;
    end else begin
      kv_done_drv <= dut.kv_load_start;
      o_done_drv  <= dut.o_write_start;
      axis_done_drv <= 1'b0;
      if (dut.q_load_start && !q_load_start_d) begin
        axis_done_drv <= 1'b1;
        axis_dest_drv <= STREAM_TO_Q_BUF;
      end
      kv_load_start_d <= dut.kv_load_start;
      q_load_start_d <= dut.q_load_start;
      group_advance_d <= dut.group_advance;
    end
  end

  always @(negedge clk) begin
    if (rst_n) begin
      if (dut.kv_load_start && !kv_load_start_d)
        kv_load_pulses++;
      if (dut.q_load_start && !q_load_start_d)
        q_load_pulses++;
      if (dut.group_advance && !group_advance_d)
        group_advance_pulses++;

      if (dut.kv_load_start && !kv_load_start_d)
        $display("DBG kv_load pulse state=%0d group=%0d head=%0d q_tile=%0d",
                 dut.u_fsm.state, dut.u_fsm.group_cnt, dut.u_fsm.head_cnt, dut.u_fsm.q_tile_idx);
      if (dut.q_load_start && !q_load_start_d)
        $display("DBG q_load pulse state=%0d group=%0d head=%0d q_tile=%0d kv_tile=%0d",
                 dut.u_fsm.state, dut.u_fsm.group_cnt, dut.u_fsm.head_cnt,
                 dut.u_fsm.q_tile_idx, dut.u_fsm.kv_tile_idx);
      if (dut.group_advance && !group_advance_d)
        $display("DBG group_advance group=%0d head=%0d", dut.u_fsm.group_cnt, dut.u_fsm.head_cnt);

      if ((dut.q_load_start && !q_load_start_d) &&
          (dut.u_fsm.state == ST_AV_DOT))
        saw_overlap_prefetch = 1'b1;

      if ((dut.u_fsm.group_cnt == 3'd7) && (dut.u_fsm.head_cnt == 2'd3))
        seen_all_groups = 1'b1;
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
    err = 0;
    kv_load_pulses = 0;
    q_load_pulses = 0;
    group_advance_pulses = 0;
    saw_overlap_prefetch = 1'b0;
    seen_all_groups = 1'b0;

    #20 rst_n = 1'b1;
    @(posedge clk);

    force dut.seq_len = 16'(TEST_SEQ);
    force dut.kv_load_done = kv_done_drv;
    force dut.o_write_done = o_done_drv;
    force dut.mac_done = 1'b1;
    force dut.softmax_done = 1'b1;
    force dut.axis_done = axis_done_drv;
    force dut.axis_dest = axis_dest_drv;

    force dut.start = 1'b1;
    @(posedge clk);
    force dut.start = 1'b0;

    wait (dut.done === 1'b1);
    repeat (4) @(posedge clk);

    release dut.start;
    release dut.kv_load_done;
    release dut.o_write_done;
    release dut.mac_done;
    release dut.softmax_done;
    release dut.axis_done;
    release dut.axis_dest;

    if (kv_load_pulses != EXPECT_GROUPS) begin
      $display("FAIL kv_load_pulses=%0d exp=%0d", kv_load_pulses, EXPECT_GROUPS);
      err++;
    end
    if (q_load_pulses != EXPECT_Q_LOADS) begin
      $display("FAIL q_load_pulses=%0d exp=%0d", q_load_pulses, EXPECT_Q_LOADS);
      err++;
    end
    if (group_advance_pulses != (EXPECT_GROUPS - 1)) begin
      $display("FAIL group_advance_pulses=%0d exp=%0d", group_advance_pulses, EXPECT_GROUPS - 1);
      err++;
    end
    if (!saw_overlap_prefetch) begin
      $display("FAIL did not observe overlap prefetch in ST_AV_DOT");
      err++;
    end
    if (!seen_all_groups) begin
      $display("FAIL did not observe terminal group/head traversal");
      err++;
    end

    if (err == 0)
      $display("ALL ATTN_TOP LOOP CONTROL CHECKS PASSED");
    else begin
      $display("ATTN_TOP LOOP CONTROL FAILED with %0d errors", err);
      $fatal(1);
    end

    $finish;
  end

  initial begin
    #1_000_000;
    $display("FAIL timeout waiting for attn_top loop control completion");
    $fatal(1);
  end
endmodule
