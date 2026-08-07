// ============================================================================
// tb_attn_core_causal_skip.sv — Causal traversal and cycle-accounting test
// ============================================================================
// Exercises the complete 32-Q-head controller traversal without instantiating
// the datapath.  MAC, softmax, and output completions are one-cycle pulses;
// Q/KV loads use explicit ready state, matching the top-level bank protocol.
//
// Verification target:
//   attn_core.sv — causal KV-tile early exit, loop reset, partial positions
// ============================================================================
`timescale 1ns / 1ps

module tb_attn_core_causal_skip;
  import attn_pkg::*;

  logic clk;
  logic rst_n;
  logic start;
  logic start_ready;
  logic [15:0] seq_len;
  logic [15:0] cfg_q_pos_base;
  logic [15:0] cfg_kv_pos_base;
  logic cfg_causal;
  logic done;
  logic busy;
  logic kv_load_start;
  logic kv_load_done;
  logic q_load_start;
  logic q_load_done;
  logic o_write_start;
  logic o_write_done;
  logic buf_sel;
  logic q_load_bank_sel;
  logic q_ready_bank_sel;
  logic o_bank_sel;
  logic group_advance;
  logic mac_phase;
  logic mac_start;
  logic mac_done;
  logic softmax_start;
  logic softmax_done;
  logic kv_tile_first;
  logic kv_tile_last;
  logic [15:0] q_tile_start;
  logic [15:0] kv_tile_start;
  logic [5:0] active_q_rows;
  logic [6:0] active_kv_cols;
  logic causal_en;
  logic [2:0] current_group;
  logic [1:0] current_head;
  logic [7:0] current_q_tile;
  logic [7:0] current_kv_tile;
  logic [2:0] q_req_group;
  logic [1:0] q_req_head;
  logic [7:0] q_req_tile;
  logic error;
  logic [31:0] cycle_cnt;
  logic [31:0] mac_cycles;
  logic [31:0] stall_cycles;
  logic perf_valid;

  attn_state_t prev_state;
  logic kv_ready;
  logic kv_pending;
  logic [1:0] kv_delay;
  logic [1:0] q_bank_ready;
  logic q_pending;
  logic q_pending_bank;
  logic [1:0] q_delay;
  logic o_write_start_d;

  integer pair_count;
  integer phasea_cycles;
  integer softmax_cycles;
  integer phaseb_cycles;
  integer obuf_wait_cycles;
  integer memory_wait_cycles;
  integer other_cycles;
  integer err;
  integer last_group;
  integer last_head;
  integer last_q_tile;
  integer last_kv_tile;
  logic saw_expected_q_rows;
  logic saw_expected_kv_cols;
  integer expected_q_rows_r;
  integer expected_kv_cols_r;

  attn_core dut (.*);

  always #5 clk = ~clk;

  assign kv_load_done = kv_ready;
  assign q_load_done = q_pending ? q_bank_ready[q_pending_bank]
                                 : q_bank_ready[q_ready_bank_sel];

  // Model memory readiness and one-cycle compute acknowledgements.  None of
  // mac_done, softmax_done, or o_write_done may remain asserted across states.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      kv_ready <= 1'b0;
      kv_pending <= 1'b0;
      kv_delay <= 2'd0;
      q_bank_ready <= 2'b00;
      q_pending <= 1'b0;
      q_pending_bank <= 1'b0;
      q_delay <= 2'd0;
      mac_done <= 1'b0;
      softmax_done <= 1'b0;
      o_write_done <= 1'b0;
      o_write_start_d <= 1'b0;
    end else begin
      mac_done <= 1'b0;
      softmax_done <= 1'b0;
      o_write_done <= 1'b0;

      if (kv_load_start) begin
        kv_ready <= 1'b0;
        kv_pending <= 1'b1;
        kv_delay <= 2'd2;
      end else if (kv_pending && (kv_delay != 2'd0)) begin
        kv_delay <= kv_delay - 2'd1;
        if (kv_delay == 2'd1) begin
          kv_ready <= 1'b1;
          kv_pending <= 1'b0;
        end
      end

      if (q_load_start) begin
        q_bank_ready[q_load_bank_sel] <= 1'b0;
        q_pending <= 1'b1;
        q_pending_bank <= q_load_bank_sel;
        q_delay <= 2'd2;
      end else if (q_pending && (q_delay != 2'd0)) begin
        q_delay <= q_delay - 2'd1;
        if (q_delay == 2'd1) begin
          q_bank_ready[q_pending_bank] <= 1'b1;
          q_pending <= 1'b0;
        end
      end

      if ((dut.state == ST_QK_DOT) && (prev_state != ST_QK_DOT))
        mac_done <= 1'b1;
      if ((dut.state == ST_AV_DOT) && (prev_state != ST_AV_DOT))
        mac_done <= 1'b1;
      if ((dut.state == ST_SOFTMAX) && (prev_state != ST_SOFTMAX))
        softmax_done <= 1'b1;
      if (o_write_start && !o_write_start_d)
        o_write_done <= 1'b1;

      if (o_write_done)
        q_bank_ready[buf_sel] <= 1'b0;
      o_write_start_d <= o_write_start;
    end
  end

  // Plain clocked monitor: err is also updated by the scenario task.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      prev_state <= ST_IDLE;
      pair_count <= 0;
      phasea_cycles <= 0;
      softmax_cycles <= 0;
      phaseb_cycles <= 0;
      obuf_wait_cycles <= 0;
      memory_wait_cycles <= 0;
      other_cycles <= 0;
      last_group <= -1;
      last_head <= -1;
      last_q_tile <= -1;
      last_kv_tile <= -1;
      saw_expected_q_rows <= 1'b0;
      saw_expected_kv_cols <= 1'b0;
    end else begin
      prev_state <= dut.state;
      case (dut.state)
        ST_QK_DOT: phasea_cycles <= phasea_cycles + 1;
        ST_SOFTMAX: softmax_cycles <= softmax_cycles + 1;
        ST_AV_DOT: phaseb_cycles <= phaseb_cycles + 1;
        ST_WRITE_O: obuf_wait_cycles <= obuf_wait_cycles + 1;
        ST_LOAD_KV, ST_Q_INIT: memory_wait_cycles <= memory_wait_cycles + 1;
        default: if (dut.state != ST_IDLE && dut.state != ST_DONE)
          other_cycles <= other_cycles + 1;
      endcase

      if ((dut.state == ST_QK_DOT) && (prev_state != ST_QK_DOT)) begin
        pair_count <= pair_count + 1;
        if (active_q_rows == 6'(expected_q_rows_r))
          saw_expected_q_rows <= 1'b1;
        if (active_kv_cols == 7'(expected_kv_cols_r))
          saw_expected_kv_cols <= 1'b1;
        if ((last_group != integer'(current_group)) ||
            (last_head != integer'(current_head)) ||
            (last_q_tile != integer'(current_q_tile))) begin
          if (current_kv_tile != 8'd0) begin
            $display("FAIL loop transition did not reset kv_tile_idx: g=%0d h=%0d q=%0d kv=%0d",
                     current_group, current_head, current_q_tile, current_kv_tile);
            err <= err + 1;
          end
        end else if (integer'(current_kv_tile) != (last_kv_tile + 1)) begin
          $display("FAIL KV traversal discontinuity: g=%0d h=%0d q=%0d kv=%0d previous=%0d",
                   current_group, current_head, current_q_tile,
                   current_kv_tile, last_kv_tile);
          err <= err + 1;
        end
        last_group <= integer'(current_group);
        last_head <= integer'(current_head);
        last_q_tile <= integer'(current_q_tile);
        last_kv_tile <= integer'(current_kv_tile);
      end
    end
  end

  task automatic reset_case;
    begin
      rst_n = 1'b0;
      start = 1'b0;
      repeat (3) @(posedge clk);
      rst_n = 1'b1;
      @(posedge clk);
      err = 0;
    end
  endtask

  task automatic run_case(
    input string name,
    input int case_seq_len,
    input int q_base,
    input int kv_base,
    input bit causal,
    input int expected_pairs,
    input int expected_last_q_rows,
    input int expected_last_kv_cols
  );
    integer timeout_cycles;
    logic [31:0] completed_cycles;
    logic [31:0] completed_mac_cycles;
    logic [31:0] completed_stall_cycles;
    begin
      reset_case();
      expected_q_rows_r = expected_last_q_rows;
      expected_kv_cols_r = expected_last_kv_cols;
      seq_len = 16'(case_seq_len);
      cfg_q_pos_base = 16'(q_base);
      cfg_kv_pos_base = 16'(kv_base);
      cfg_causal = causal;
      start = 1'b1;
      @(posedge clk);
      start = 1'b0;

      timeout_cycles = 0;
      while ((done !== 1'b1) && (timeout_cycles < 500_000)) begin
        @(posedge clk);
        timeout_cycles++;
      end
      if (done !== 1'b1) begin
        $display("FAIL %s timeout state=%0d g=%0d h=%0d q=%0d kv=%0d",
                 name, dut.state, current_group, current_head,
                 current_q_tile, current_kv_tile);
        $fatal(1);
      end
      if (pair_count != expected_pairs) begin
        $display("FAIL %s tile pairs=%0d expected=%0d", name,
                 pair_count, expected_pairs);
        err++;
      end
      if (!saw_expected_q_rows) begin
        $display("FAIL %s never observed active_q_rows=%0d", name,
                 expected_last_q_rows);
        err++;
      end
      if (!saw_expected_kv_cols) begin
        $display("FAIL %s never observed active_kv_cols=%0d", name,
                 expected_last_kv_cols);
        err++;
      end
      if (error) begin
        $display("FAIL %s unexpected core error", name);
        err++;
      end

      // Software reads the performance CSRs after DONE, once the controller
      // has already returned to IDLE.  Results must remain stable until the
      // next accepted start rather than disappearing one idle cycle later.
      @(negedge clk);
      completed_cycles = cycle_cnt;
      completed_mac_cycles = mac_cycles;
      completed_stall_cycles = stall_cycles;
      if ((completed_cycles == 0) || (completed_mac_cycles == 0) ||
          (completed_stall_cycles == 0)) begin
        $display("FAIL %s zero counter at completion: total=%0d mac=%0d stall=%0d",
                 name, completed_cycles, completed_mac_cycles,
                 completed_stall_cycles);
        err++;
      end
      repeat (4) @(posedge clk);
      @(negedge clk);
      if ((cycle_cnt != completed_cycles) ||
          (mac_cycles != completed_mac_cycles) ||
          (stall_cycles != completed_stall_cycles)) begin
        $display("FAIL %s counters not retained in IDLE: done=%0d/%0d/%0d idle=%0d/%0d/%0d",
                 name, completed_cycles, completed_mac_cycles,
                 completed_stall_cycles, cycle_cnt, mac_cycles, stall_cycles);
        err++;
      end

      $display("CYCLE_PROFILE name=%s pairs=%0d total=%0d phase_a=%0d softmax=%0d phase_b=%0d obuf_wait=%0d memory_wait=%0d other=%0d",
               name, pair_count, cycle_cnt, phasea_cycles, softmax_cycles,
               phaseb_cycles, obuf_wait_cycles, memory_wait_cycles, other_cycles);

      // The retained result belongs to the completed transaction.  A newly
      // accepted transaction must clear it before any work is counted.
      start = 1'b1;
      @(posedge clk);
      @(negedge clk);
      start = 1'b0;
      if ((cycle_cnt != 0) || (mac_cycles != 0) || (stall_cycles != 0)) begin
        $display("FAIL %s counters not cleared on next accepted start: %0d/%0d/%0d",
                 name, cycle_cnt, mac_cycles, stall_cycles);
        err++;
      end
      if (err != 0)
        $fatal(1, "%s failed with %0d errors", name, err);
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    start = 1'b0;
    seq_len = 16'd0;
    cfg_q_pos_base = 16'd0;
    cfg_kv_pos_base = 16'd0;
    cfg_causal = 1'b0;
    err = 0;

    run_case("L512_causal", 512, 0, 0, 1'b1,
             72 * N_Q_HEADS, TILE_Q, TILE_KV);
    run_case("L512_noncausal", 512, 0, 0, 1'b0,
             128 * N_Q_HEADS, TILE_Q, TILE_KV);
    run_case("L70_partial", 70, 0, 0, 1'b1,
             4 * N_Q_HEADS, 6, 6);
    run_case("L70_position_base", 70, 64, 0, 1'b1,
             6 * N_Q_HEADS, 6, 6);

    $display("ALL ATTN_CORE CAUSAL SKIP CHECKS PASSED");
    $finish;
  end
endmodule
