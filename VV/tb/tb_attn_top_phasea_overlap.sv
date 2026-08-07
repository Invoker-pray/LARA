`timescale 1ns / 1ps

// Focused Phase-A producer/consumer test.  The controller outputs are forced
// so this test can exercise two complete 16x16-subblock traversals without
// spending simulation time on AXI/DMA traffic or Phase B.
module tb_attn_top_phasea_overlap;
  import attn_pkg::*;

  localparam logic [31:0] FP32_NEG_INF = 32'hFF80_0000;
  localparam logic [31:0] FP32_ZERO    = 32'h0000_0000;
  localparam logic [31:0] FP32_ONE     = 32'h3F80_0000;
  localparam int Q_MICROTILES = TILE_Q / TILE_ROWS;

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

  logic test_window;
  logic test_kv_first, test_kv_last, test_causal;
  logic [15:0] test_q_start, test_kv_start;
  logic [5:0] test_active_rows;
  logic [6:0] test_active_cols;
  logic [31:0] forced_score;
  logic tick_marker;

  integer err;
  integer round_id;
  integer launch_count;
  integer retire_count;
  integer dump_fd;
  integer round0_cycles, round1_cycles;
  integer ready_stall_event;
  string dump_bits_path;
  logic [31:0] saved_m [Q_MICROTILES][TILE_ROWS];
  logic [31:0] saved_l [Q_MICROTILES][TILE_ROWS];

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

  always_comb begin
    // Every score in a block is equal, but blocks have distinct exact FP32
    // values.  Causal masking therefore gives deterministic partial and
    // all-masked rows while making stale-context bugs visible in m/l.
    unique case ({dut.phasea_micro_idx, dut.phasea_kv_blk_idx})
      3'b000: forced_score = 32'h3F80_0000; // 1.0
      3'b001: forced_score = 32'h4000_0000; // 2.0
      3'b010: forced_score = 32'h4040_0000; // 3.0
      3'b011: forced_score = 32'h4080_0000; // 4.0
      3'b100: forced_score = 32'h3FC0_0000; // 1.5
      3'b101: forced_score = 32'h4020_0000; // 2.5
      3'b110: forced_score = 32'h4060_0000; // 3.5
      default: forced_score = 32'h4090_0000; // 4.5
    endcase
  end

  task automatic dump_retire(input integer rid, input integer micro, input integer block_idx);
    begin
      if (dump_fd) begin
        for (int ri = 0; ri < TILE_ROWS; ri++) begin
          $fdisplay(dump_fd, "R %0d T %0d %0d M %0d %08x", rid, micro, block_idx, ri,
                    dut.m_state[ri]);
          $fdisplay(dump_fd, "R %0d T %0d %0d L %0d %08x", rid, micro, block_idx, ri,
                    dut.l_state[ri]);
          $fdisplay(dump_fd, "R %0d T %0d %0d C %0d %08x", rid, micro, block_idx, ri,
                    dut.correction[ri]);
          for (int ci = 0; ci < TILE_COLS; ci++)
            $fdisplay(dump_fd, "R %0d T %0d %0d P %0d %0d %08x", rid, micro,
                      block_idx, ri, ci, dut.p_block[ri][ci]);
        end
      end
    end
  endtask

  // Check issue order, the subblock-local first tag, and the context actually
  // visible inside softmax at each accepted block.
  always @(posedge clk) begin
    integer exp_micro, exp_block;
    if (rst_n && dut.s_valid && dut.sm_s_ready && dut.phasea_softmax_accept_enable) begin
      if (round_id == 0) begin
        exp_micro = launch_count / 4;
        exp_block = launch_count % 4;
      end else begin
        exp_micro = launch_count;
        exp_block = 0;
      end
      if ((dut.phasea_held_micro !== exp_micro[0:0]) ||
          (dut.phasea_held_kv_blk !== exp_block[1:0])) begin
        $display("FAIL launch tag round=%0d idx=%0d got=(%0d,%0d) exp=(%0d,%0d)",
                 round_id, launch_count, dut.phasea_held_micro,
                 dut.phasea_held_kv_blk, exp_micro, exp_block);
        err++;
      end
      if (dut.u_softmax.kv_tile_first !== ((round_id == 0) && (exp_block == 0))) begin
        $display("FAIL first tag round=%0d tag=(%0d,%0d) got=%b exp=%b",
                 round_id, exp_micro, exp_block, dut.u_softmax.kv_tile_first,
                 ((round_id == 0) && (exp_block == 0)));
        err++;
      end
      if (!((round_id == 0) && (exp_block == 0))) begin
        for (int ri = 0; ri < TILE_ROWS; ri++) begin
          if ((dut.u_softmax.m_state[ri] !== dut.sm_m_ctx[exp_micro][ri]) ||
              (dut.u_softmax.l_state[ri] !== dut.sm_l_ctx[exp_micro][ri])) begin
            $display("FAIL loaded context round=%0d tag=(%0d,%0d) row=%0d sm=(%h,%h) ctx=(%h,%h)",
                     round_id, exp_micro, exp_block, ri,
                     dut.u_softmax.m_state[ri], dut.u_softmax.l_state[ri],
                     dut.sm_m_ctx[exp_micro][ri], dut.sm_l_ctx[exp_micro][ri]);
            err++;
          end
        end
      end
      launch_count++;
    end
  end

  always @(negedge clk) begin
    if (rst_n && dut.p_valid) begin
      dump_retire(round_id, dut.phasea_pending_micro, dut.phasea_pending_kv_blk);
      if (round_id == 1) begin
        for (int ri = 0; ri < TILE_ROWS; ri++) begin
          if ((dut.m_state[ri] !== saved_m[dut.phasea_pending_micro][ri]) ||
              (dut.l_state[ri] !== saved_l[dut.phasea_pending_micro][ri]) ||
              (dut.correction[ri] !== FP32_ONE)) begin
            $display("FAIL all-masked state tag=(%0d,%0d) row=%0d got=(%h,%h,%h) exp=(%h,%h,%h)",
                     dut.phasea_pending_micro, dut.phasea_pending_kv_blk, ri,
                     dut.m_state[ri], dut.l_state[ri], dut.correction[ri],
                     saved_m[dut.phasea_pending_micro][ri],
                     saved_l[dut.phasea_pending_micro][ri], FP32_ONE);
            err++;
          end
          for (int ci = 0; ci < TILE_COLS; ci++) begin
            if (dut.p_block[ri][ci] !== FP32_ZERO) begin
              $display("FAIL all-masked P tag=(%0d,%0d) row=%0d col=%0d got=%h",
                       dut.phasea_pending_micro, dut.phasea_pending_kv_blk,
                       ri, ci, dut.p_block[ri][ci]);
              err++;
            end
          end
        end
      end
      retire_count++;
    end
  end

  // Deterministic pseudo-random consumer backpressure.  Hierarchical force is
  // confined to this focused test; both the consumer and producer observe the
  // same s_ready value, and PA_LAUNCH must hold the complete payload stable.
  initial begin : READY_BACKPRESSURE
    integer stall_cycles_local;
    ready_stall_event = 0;
    wait (rst_n === 1'b1);
    forever begin
      wait ((dut.phasea_state == 3'd5) && dut.phasea_held_valid);
      stall_cycles_local = ((ready_stall_event * 5 + 1) % 4) + 1;
      force dut.phasea_softmax_accept_enable = 1'b0;
      repeat (stall_cycles_local)
        @(posedge clk);
      @(negedge clk);
      release dut.phasea_softmax_accept_enable;
      ready_stall_event++;
      wait (dut.phasea_state != 3'd5);
    end
  end

  task automatic run_phasea_round(input integer rid, output integer elapsed);
    begin
      round_id = rid;
      launch_count = 0;
      retire_count = 0;
      elapsed = 0;
      test_window = 1'b1;
      @(negedge clk);
      while (!dut.phasea_done_all && (elapsed < 20000)) begin
        tick();
        @(negedge clk);
        elapsed++;
      end
      test_window = 1'b0;
      tick();
      tick();
      tick();
      @(negedge clk);
      if (!dut.phasea_done_all && (elapsed >= 20000)) begin
        $display("FAIL Phase-A timeout round=%0d", rid);
        err++;
      end
      if (launch_count != ((rid == 0) ? 8 : 2)) begin
        $display("FAIL launch count round=%0d got=%0d exp=%0d", rid, launch_count,
                 ((rid == 0) ? 8 : 2));
        err++;
      end
      if (retire_count != ((rid == 0) ? 8 : 2)) begin
        $display("FAIL retire count round=%0d got=%0d exp=%0d", rid, retire_count,
                 ((rid == 0) ? 8 : 2));
        err++;
      end
      $display("PHASEA_PROFILE round=%0d cycles=%0d launches=%0d retires=%0d",
               rid, elapsed, launch_count, retire_count);
    end
  endtask

  genvar gr, gc;
  generate
    for (gr = 0; gr < TILE_ROWS; gr++) begin : GEN_FORCE_ROW
      for (gc = 0; gc < TILE_COLS; gc++) begin : GEN_FORCE_COL
        initial force dut.mac_block_out[gr][gc] = forced_score;
      end
    end
  endgenerate

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
    test_window = 1'b0;
    test_kv_first = 1'b1;
    test_kv_last = 1'b0;
    test_causal = 1'b1;
    test_q_start = 16'd0;
    test_kv_start = 16'd0;
    test_active_rows = 6'(TILE_Q);
    test_active_cols = 7'(TILE_KV);
    tick_marker = 1'b0;
    err = 0;
    round_id = 0;
    launch_count = 0;
    retire_count = 0;
    ready_stall_event = 0;
    dump_fd = 0;
    for (int mi = 0; mi < Q_MICROTILES; mi++) begin
      for (int ri = 0; ri < TILE_ROWS; ri++) begin
        saved_m[mi][ri] = FP32_NEG_INF;
        saved_l[mi][ri] = FP32_ZERO;
      end
    end

    if ($value$plusargs("DUMP_BITS=%s", dump_bits_path)) begin
      dump_fd = $fopen(dump_bits_path, "w");
      if (!dump_fd) begin
        $display("FAIL cannot open dump %s", dump_bits_path);
        err++;
      end
    end

    #20 rst_n = 1'b1;
    tick();

    force dut.busy = test_window;
    force dut.phasea_authorized = test_window;
    force dut.mac_phase = 1'b0;
    force dut.mac_start = 1'b0;
    force dut.softmax_start = 1'b0;
    force dut.kv_load_start = 1'b0;
    force dut.q_load_start = 1'b0;
    force dut.o_write_start = 1'b0;
    force dut.kv_tile_first = test_kv_first;
    force dut.kv_tile_last = test_kv_last;
    force dut.causal_en = test_causal;
    force dut.q_tile_start = test_q_start;
    force dut.kv_tile_start = test_kv_start;
    force dut.active_q_rows = test_active_rows;
    force dut.active_kv_cols = test_active_cols;

    run_phasea_round(0, round0_cycles);
    for (int mi = 0; mi < Q_MICROTILES; mi++) begin
      for (int ri = 0; ri < TILE_ROWS; ri++) begin
        saved_m[mi][ri] = dut.sm_m_ctx[mi][ri];
        saved_l[mi][ri] = dut.sm_l_ctx[mi][ri];
      end
    end

    // A later controller KV tile with only five active columns.  Because its
    // absolute K positions are beyond every Q row, both subblocks are fully
    // causal-masked and must preserve the saved online-softmax state exactly.
    test_kv_first = 1'b0;
    test_kv_last = 1'b1;
    test_kv_start = 16'd64;
    test_active_cols = 7'd5;
    run_phasea_round(1, round1_cycles);

    if (dump_fd)
      $fclose(dump_fd);
    if (err == 0)
      $display("ALL PHASEA OVERLAP CHECKS PASSED");
    else
      $display("%0d PHASEA OVERLAP ERRORS", err);
    $finish;
  end
endmodule
