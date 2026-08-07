`timescale 1ns / 1ps

module tb_attn_top_loop_control_delayed;
  import attn_pkg::*;

  localparam int TEST_SEQ = 64;
  localparam int EXPECT_GROUPS = N_KV_HEADS;
  localparam int EXPECT_HEADS = N_Q_HEADS;
  localparam int EXPECT_Q_LOADS = EXPECT_HEADS * ((TEST_SEQ + TILE_Q - 1) / TILE_Q);
  localparam int KV_DONE_DELAY = 3;
  localparam int Q_DONE_DELAY  = 2;
  localparam int O_DONE_DELAY  = 4;

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
  bit saw_phasea_prefetch_window;
  bit saw_phaseb_prefetch_window;
  bit saw_overlap_prefetch_softmax;
  bit saw_head_switch_prefetch;
  bit saw_group_switch_prefetch;
  bit saw_head_switch_prefetch_norm;
  bit saw_group_switch_prefetch_norm;
  bit seen_all_groups;
  bit saw_qk_authorization;
  logic kv_load_start_d, q_load_start_d, group_advance_d;
  logic tick_marker;

  logic kv_done_drv, o_done_drv;
  logic axis_done_drv;
  logic [1:0] axis_dest_drv;
  int kv_delay_ctr;
  int q_delay_ctr;
  int o_delay_ctr;
  logic kv_pending;
  logic q_pending;
  logic o_pending;

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

  task automatic tick;
    begin
      @(posedge clk) tick_marker = ~tick_marker;
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      kv_done_drv <= 1'b0;
      o_done_drv <= 1'b0;
      axis_done_drv <= 1'b0;
      axis_dest_drv <= STREAM_TO_Q_BUF;
      kv_load_start_d <= 1'b0;
      q_load_start_d <= 1'b0;
      group_advance_d <= 1'b0;
      kv_delay_ctr <= 0;
      q_delay_ctr <= 0;
      o_delay_ctr <= 0;
      kv_pending <= 1'b0;
      q_pending <= 1'b0;
      o_pending <= 1'b0;
    end else begin
      // Completion indications model one-cycle acknowledgements.  Holding
      // either level high would let every later group/tile complete without a
      // new request and would hide the delayed-handshake behavior under test.
      kv_done_drv <= 1'b0;
      o_done_drv <= 1'b0;
      axis_done_drv <= 1'b0;

      if (dut.kv_load_start && !kv_load_start_d) begin
        kv_done_drv <= 1'b0;
        kv_pending <= 1'b1;
        kv_delay_ctr <= KV_DONE_DELAY;
      end else if (kv_pending) begin
        if (kv_delay_ctr == 0) begin
          kv_done_drv <= 1'b1;
          kv_pending <= 1'b0;
        end else begin
          kv_delay_ctr <= kv_delay_ctr - 1;
        end
      end

      if (dut.q_load_start && !q_load_start_d) begin
        q_pending <= 1'b1;
        q_delay_ctr <= Q_DONE_DELAY;
        axis_dest_drv <= STREAM_TO_Q_BUF;
      end else if (q_pending) begin
        if (q_delay_ctr == 0) begin
          axis_done_drv <= 1'b1;
          axis_dest_drv <= STREAM_TO_Q_BUF;
          q_pending <= 1'b0;
        end else begin
          q_delay_ctr <= q_delay_ctr - 1;
        end
      end

      if (dut.o_write_start && !o_pending && !dut.o_write_done) begin
        o_done_drv <= 1'b0;
        o_pending <= 1'b1;
        o_delay_ctr <= O_DONE_DELAY;
      end else if (o_pending) begin
        if (o_delay_ctr == 0) begin
          o_done_drv <= 1'b1;
          o_pending <= 1'b0;
        end else begin
          o_delay_ctr <= o_delay_ctr - 1;
        end
      end

      kv_load_start_d <= dut.kv_load_start;
      q_load_start_d <= dut.q_load_start;
      group_advance_d <= dut.group_advance;
    end
  end

  always @(negedge clk) begin
    if (rst_n) begin
      if (dut.mac_start && !dut.mac_phase)
        saw_qk_authorization = 1'b1;
      if (!saw_qk_authorization && dut.phasea_window) begin
        $display("FAIL Phase-A started before the first QK authorization");
        err++;
      end
      if (dut.kv_load_start && !kv_load_start_d)
        kv_load_pulses++;
      if (dut.q_load_start && !q_load_start_d)
        q_load_pulses++;
      if (dut.group_advance && !group_advance_d)
        group_advance_pulses++;

      if ((dut.q_load_start && !q_load_start_d) &&
          (dut.u_fsm.state == ST_QK_DOT)) begin
        saw_overlap_prefetch = 1'b1;
        if (dut.phasea_window)
          saw_phasea_prefetch_window = 1'b1;
        else begin
          $display("FAIL delayed phasea_window dropped during ST_QK_DOT q prefetch");
          err++;
        end
      end
      if ((dut.q_load_start && !q_load_start_d) &&
          (dut.u_fsm.state == ST_AV_DOT)) begin
        saw_overlap_prefetch = 1'b1;
        if (dut.phaseb_window)
          saw_phaseb_prefetch_window = 1'b1;
        else begin
          $display("FAIL delayed phaseb_window dropped during ST_AV_DOT q prefetch");
          err++;
        end
      end
      if ((dut.q_load_start && !q_load_start_d) &&
          (dut.u_fsm.state == ST_SOFTMAX))
        saw_overlap_prefetch_softmax = 1'b1;
      if ((dut.q_load_start && !q_load_start_d) &&
          ((dut.u_fsm.state == ST_AV_DOT) || (dut.u_fsm.state == ST_SOFTMAX) || (dut.u_fsm.state == ST_WRITE_O)) &&
          (dut.u_fsm.head_cnt < 2'd3) &&
          (dut.u_fsm.q_tile_idx == dut.u_fsm.q_tile_last_idx))
        saw_head_switch_prefetch = 1'b1;
      if ((dut.q_load_start && !q_load_start_d) &&
          ((dut.u_fsm.state == ST_AV_DOT) || (dut.u_fsm.state == ST_SOFTMAX) || (dut.u_fsm.state == ST_WRITE_O)) &&
          (dut.u_fsm.head_cnt == 2'd3) &&
          (dut.u_fsm.group_cnt < 3'd7) &&
          (dut.u_fsm.q_tile_idx == dut.u_fsm.q_tile_last_idx))
        saw_group_switch_prefetch = 1'b1;
      if ((dut.q_load_start && !q_load_start_d) &&
          (dut.u_fsm.state == ST_NORMALIZE) &&
          (dut.u_fsm.head_cnt < 2'd3))
        saw_head_switch_prefetch_norm = 1'b1;
      if ((dut.q_load_start && !q_load_start_d) &&
          (dut.u_fsm.state == ST_NORMALIZE) &&
          (dut.u_fsm.head_cnt == 2'd3) &&
          (dut.u_fsm.group_cnt < 3'd7))
        saw_group_switch_prefetch_norm = 1'b1;
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
    saw_phasea_prefetch_window = 1'b0;
    saw_phaseb_prefetch_window = 1'b0;
    saw_overlap_prefetch_softmax = 1'b0;
    saw_head_switch_prefetch = 1'b0;
    saw_group_switch_prefetch = 1'b0;
    saw_head_switch_prefetch_norm = 1'b0;
    saw_group_switch_prefetch_norm = 1'b0;
    seen_all_groups = 1'b0;
    saw_qk_authorization = 1'b0;
    tick_marker = 1'b0;

    #20 rst_n = 1'b1;
    tick();

    force dut.seq_len = 16'(TEST_SEQ);
    force dut.kv_load_done = kv_done_drv;
    force dut.o_write_done = o_done_drv;
    force dut.mac_done = 1'b1;
    force dut.softmax_done = 1'b1;
    force dut.axis_done = axis_done_drv;
    force dut.axis_dest = axis_dest_drv;

    force dut.start = 1'b1;
    tick();
    force dut.start = 1'b0;

    wait (dut.done === 1'b1) tick_marker = ~tick_marker;
    repeat (8) tick();

    release dut.start;
    release dut.kv_load_done;
    release dut.o_write_done;
    release dut.mac_done;
    release dut.softmax_done;
    release dut.axis_done;
    release dut.axis_dest;

    if (kv_load_pulses != EXPECT_GROUPS) begin
      $display("FAIL delayed kv_load_pulses=%0d exp=%0d", kv_load_pulses, EXPECT_GROUPS);
      err++;
    end
    if (q_load_pulses != EXPECT_Q_LOADS) begin
      $display("FAIL delayed q_load_pulses=%0d exp=%0d", q_load_pulses, EXPECT_Q_LOADS);
      err++;
    end
    if (group_advance_pulses != (EXPECT_GROUPS - 1)) begin
      $display("FAIL delayed group_advance_pulses=%0d exp=%0d", group_advance_pulses, EXPECT_GROUPS - 1);
      err++;
    end
    if (!(saw_overlap_prefetch || saw_overlap_prefetch_softmax)) begin
      $display("FAIL delayed no overlap prefetch observed");
      err++;
    end
    if (!saw_phasea_prefetch_window && !saw_phaseb_prefetch_window && !saw_overlap_prefetch_softmax) begin
      $display("FAIL delayed no active phase window during q prefetch");
      err++;
    end
    if (!(saw_head_switch_prefetch || saw_head_switch_prefetch_norm)) begin
      $display("FAIL delayed no head-switch prefetch observed");
      err++;
    end
    if (!(saw_group_switch_prefetch || saw_group_switch_prefetch_norm)) begin
      $display("FAIL delayed no group-switch prefetch observed");
      err++;
    end
    if (!seen_all_groups) begin
      $display("FAIL delayed did not observe terminal group/head traversal");
      err++;
    end

    if (err == 0)
      $display("ALL ATTN_TOP LOOP CONTROL DELAYED CHECKS PASSED");
    else begin
      $display("ATTN_TOP LOOP CONTROL DELAYED FAILED with %0d errors", err);
      $fatal(1);
    end

    $finish;
  end

  initial begin
    #2_000_000 tick_marker = ~tick_marker;
    $display("FAIL timeout waiting for delayed attn_top loop control completion");
    $display("DBG state=%0d q_tile=%0d kv_tile=%0d head=%0d group=%0d busy=%0b done=%0b kv_done=%0b q_done=%0b o_done=%0b q_pending=%0b kv_pending=%0b o_pending=%0b q_load_start=%0b q_inflight=%0b",
             dut.u_fsm.state, dut.u_fsm.q_tile_idx, dut.u_fsm.kv_tile_idx,
             dut.u_fsm.head_cnt, dut.u_fsm.group_cnt, dut.busy, dut.done,
             dut.kv_load_done, dut.q_load_done, dut.o_write_done,
             q_pending, kv_pending, o_pending, dut.q_load_start, dut.u_fsm.q_load_inflight);
    $display("DBG q_bank_ready=%b q_load_bank_sel=%0b q_load_bank_sel_latched=%0b q_ready_bank_sel=%0b buf_sel=%0b q_compute_bank_sel=%0b q_outstanding=%0b same_bank_pending=%0b",
             dut.q_bank_ready, dut.q_load_bank_sel, dut.q_load_bank_sel_latched,
             dut.q_ready_bank_sel, dut.buf_sel, dut.q_compute_bank_sel,
             dut.q_load_outstanding, dut.q_same_bank_reload_pending);
    $fatal(1);
  end
endmodule
