// ============================================================================
// tb_attn_tile.sv — MAC Array test (cycle-accurate, split-factor aware)
// ============================================================================
// Drives the real controller protocol: a block starts with clear+accum on
// split 0 and then accumulates every split window exactly once per sweep.
// Revisiting a window one cycle after a clear cycle is not part of the
// protocol (the RTL zero-holds acc_base for one cycle after a clear), so the
// old split=2 two-phase stimulus was retired with the v2.6 split change.
//
// SYNTHESIS-path visibility contract modelled here:
//   after the tick of sample i,
//     block_out[window(S_i)]  = (C_i||C_{i-1} ? 0 : committed) + A_i?prod_i
//     block_out[other w]      = C_i ? 0 : committed-after-edge
//   where block_acc_bits commits sample i-1's window value at sample i's
//   edge (one-sample lag) and the clear wipe also lands one sample late.
// `ifndef SYNTHESIS block_out shows the pre-sample accumulator (the
// behavioral model's registered state), which the sweep protocol keeps
// numerically identical for every non-active window.
// ============================================================================
`timescale 1ns / 1ps

module tb_attn_tile;
  import attn_pkg::*;

  logic clk, rst_n, phase_sel, accum_en;
  logic [TILE_SPLIT_INDEX_W-1:0] split_phase;
  logic clear_accum;
  logic [15:0] row_data [TILE_ROWS];
  logic [15:0] col_data [TILE_COLS];
  logic [31:0] block_out [TILE_ROWS][TILE_COLS];
  logic [31:0] col_out [TILE_COLS];
  logic tick_marker;
  logic settle_marker;

  shortreal ref_state [TILE_ROWS][TILE_COLS];
  shortreal pending_win_val [TILE_ROWS][TILE_COLS];
  bit pending_valid;
  bit prev_clear;
  bit prev_accum;
  logic [TILE_SPLIT_INDEX_W-1:0] prev_split;
  integer err, r, c;
  shortreal got_val, exp_val;

  attn_tile dut(.clk,.rst_n,.phase_sel,.row_data,.col_data,.split_phase,.clear_accum,.accum_en,.block_out,.col_out);

  always #5 clk = ~clk;

  task automatic tick;
    begin
      @(posedge clk) tick_marker = ~tick_marker;
    end
  endtask

  task automatic settle;
    begin
      #1 settle_marker = ~settle_marker;
    end
  endtask

  function automatic shortreal bf16_to_shortreal(input logic [15:0] bits);
    bf16_to_shortreal = $bitstoshortreal({bits, 16'b0});
  endfunction

  task automatic set_const_inputs(input shortreal row_val, input shortreal col_val);
    integer ri, ci;
    begin
      for (ri = 0; ri < TILE_ROWS; ri = ri + 1)
        row_data[ri] = 16'(($shortrealtobits(row_val) >> 16));
      for (ci = 0; ci < TILE_COLS; ci = ci + 1)
        col_data[ci] = 16'(($shortrealtobits(col_val) >> 16));
    end
  endtask

  task automatic set_ramp_inputs;
    integer ri, ci;
    begin
      for (ri = 0; ri < TILE_ROWS; ri = ri + 1)
        row_data[ri] = 16'(($shortrealtobits(shortreal'(ri + 1)) >> 16));
      for (ci = 0; ci < TILE_COLS; ci = ci + 1)
        col_data[ci] = 16'(($shortrealtobits(shortreal'(ci + 1)) >> 16));
    end
  endtask

  // Fold the previous sample's commit into ref_state: the clear wipe and the
  // previous window write both land at the current sample's edge.
  task automatic fold_pending_commit;
    integer ri, ci, wlo, whi;
    begin
      if (prev_clear) begin
        for (ri = 0; ri < TILE_ROWS; ri = ri + 1)
          for (ci = 0; ci < TILE_COLS; ci = ci + 1)
            ref_state[ri][ci] = shortreal'(0.0);
      end
      if (pending_valid && prev_accum) begin
        wlo = prev_split * (TILE_COLS / TILE_SPLIT_FACTOR);
        whi = wlo + (TILE_COLS / TILE_SPLIT_FACTOR);
        for (ri = 0; ri < TILE_ROWS; ri = ri + 1)
          for (ci = wlo; ci < whi; ci = ci + 1)
            ref_state[ri][ci] = pending_win_val[ri][ci];
      end
      pending_valid = 1'b0;
    end
  endtask

  task automatic sample_cycle(
    input string tag,
    input logic do_clear,
    input logic do_accum,
    input logic [TILE_SPLIT_INDEX_W-1:0] sp
  );
    shortreal exp_win  [TILE_ROWS][TILE_COLS];
    shortreal exp_post [TILE_ROWS][TILE_COLS];
    shortreal exp_col  [TILE_COLS];
    shortreal a, b, prod;
    integer ri, ci, wlo, whi;
    begin
      wlo = sp * (TILE_COLS / TILE_SPLIT_FACTOR);
      whi = wlo + (TILE_COLS / TILE_SPLIT_FACTOR);

      // Expected visible values for this sample are computed from the
      // pre-edge committed state (ref_state before folding this edge).
      for (ri = 0; ri < TILE_ROWS; ri = ri + 1) begin
        for (ci = 0; ci < TILE_COLS; ci = ci + 1) begin
          a = bf16_to_shortreal(row_data[ri]);
          if ((TILE_SPLIT_FACTOR <= 1) || ((ci >= wlo) && (ci < whi)))
            b = bf16_to_shortreal(col_data[ci]);
          else
            b = shortreal'(0.0);
          prod = a * b;

          if ((ci >= wlo) && (ci < whi)) begin
            exp_win[ri][ci] = (do_clear || prev_clear) ? shortreal'(0.0)
                                                       : ref_state[ri][ci];
            if (do_accum)
              exp_win[ri][ci] = exp_win[ri][ci] + prod;
          end

          // Non-window columns show the post-edge state: previous sample's
          // wipe/window commit applied, then this sample's clear.
          exp_post[ri][ci] = ref_state[ri][ci];
        end
      end

      for (ci = 0; ci < TILE_COLS; ci = ci + 1)
        exp_col[ci] = shortreal'(0.0);
      if (do_accum) begin
        for (ri = 0; ri < TILE_ROWS; ri = ri + 1) begin
          a = bf16_to_shortreal(row_data[ri]);
          for (ci = wlo; ci < whi; ci = ci + 1) begin
            b = bf16_to_shortreal(col_data[ci]);
            exp_col[ci] = exp_col[ci] + a * b;
          end
        end
      end

      // Apply this edge: fold the previous commit into ref_state.  Window
      // expectations (exp_win) were derived above from the pre-edge state;
      // non-window columns show the post-edge state.
      fold_pending_commit();
      for (ri = 0; ri < TILE_ROWS; ri = ri + 1)
        for (ci = 0; ci < TILE_COLS; ci = ci + 1)
          exp_post[ri][ci] = do_clear ? shortreal'(0.0) : ref_state[ri][ci];

      clear_accum = do_clear;
      accum_en    = do_accum;
      split_phase = sp;

      tick();
      settle();

      for (ci = 0; ci < TILE_COLS; ci = ci + 1) begin
        got_val = $bitstoshortreal(col_out[ci]);
        if (got_val != exp_col[ci]) begin
          $display("FAIL %s COL c[%0d]=%e exp=%e", tag, ci, got_val, exp_col[ci]);
          err = err + 1;
        end
      end

      for (ri = 0; ri < TILE_ROWS; ri = ri + 1) begin
        for (ci = 0; ci < TILE_COLS; ci = ci + 1) begin
          got_val = $bitstoshortreal(block_out[ri][ci]);
`ifdef SYNTHESIS
          if ((ci >= wlo) && (ci < whi))
            exp_val = exp_win[ri][ci];
          else
            exp_val = exp_post[ri][ci];
          if (got_val != exp_val) begin
            $display("FAIL %s BLK r[%0d] c[%0d]=%e exp=%e", tag, ri, ci, got_val, exp_val);
            err = err + 1;
          end
`else
          // Behavioral model: block_out shows the accumulator state before
          // this sample's effect (registered behavioral state).
          if (got_val != ref_state[ri][ci]) begin
            $display("FAIL %s BLK r[%0d] c[%0d]=%e exp=%e", tag, ri, ci,
                     got_val, ref_state[ri][ci]);
            err = err + 1;
          end
`endif
        end
      end

      // Remember this sample's window value; it commits at the next edge.
      for (ri = 0; ri < TILE_ROWS; ri = ri + 1)
        for (ci = wlo; ci < whi; ci = ci + 1)
          pending_win_val[ri][ci] = exp_win[ri][ci];
      pending_valid = 1'b1;
      prev_clear = do_clear;
      prev_accum = do_accum;
      prev_split = sp;
      clear_accum = 1'b0;
    end
  endtask

  // One full block sweep in the controller's real order: clear (optional)
  // together with split 0, then every remaining split window once.
  task automatic mac_sweep(input string tag, input logic clear_first);
    integer sp;
    begin
      for (sp = 0; sp < TILE_SPLIT_FACTOR; sp = sp + 1) begin
        sample_cycle($sformatf("%s-S%0d", tag, sp),
                     clear_first && (sp == 0), 1'b1, TILE_SPLIT_INDEX_W'(sp));
      end
    end
  endtask

  task automatic check_visible_state(input string tag);
    integer ri, ci;
    begin
      accum_en = 1'b0;
      clear_accum = 1'b0;
      // First tick folds the final pending window commit; second tick lets
      // the synthesis path's acc_base passthrough settle so every column
      // shows the committed accumulator.
      tick();
      fold_pending_commit();
      prev_clear = 1'b0;
      tick();
      settle();

      for (ci = 0; ci < TILE_COLS; ci = ci + 1) begin
        got_val = $bitstoshortreal(col_out[ci]);
        if (got_val != shortreal'(0.0)) begin
          $display("FAIL %s COL-IDLE c[%0d]=%e", tag, ci, got_val);
          err = err + 1;
        end
      end

      for (ri = 0; ri < TILE_ROWS; ri = ri + 1) begin
        for (ci = 0; ci < TILE_COLS; ci = ci + 1) begin
          got_val = $bitstoshortreal(block_out[ri][ci]);
          if (got_val != ref_state[ri][ci]) begin
            $display("FAIL %s BLK-VIS r[%0d] c[%0d]=%e exp=%e", tag, ri, ci,
                     got_val, ref_state[ri][ci]);
            err = err + 1;
          end
        end
      end
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    phase_sel = 1'b0;
    clear_accum = 1'b0;
    accum_en = 1'b0;
    split_phase = '0;
    tick_marker = 1'b0;
    settle_marker = 1'b0;
    err = 0;
    pending_valid = 1'b0;
    prev_clear = 1'b0;
    prev_accum = 1'b0;
    prev_split = '0;
    for (r = 0; r < TILE_ROWS; r = r + 1)
      row_data[r] = 16'd0;
    for (c = 0; c < TILE_COLS; c = c + 1)
      col_data[c] = 16'd0;
    for (r = 0; r < TILE_ROWS; r = r + 1)
      for (c = 0; c < TILE_COLS; c = c + 1) begin
        ref_state[r][c] = shortreal'(0.0);
        pending_win_val[r][c] = shortreal'(0.0);
      end

    $display("TB: attn_tile (MAC_PIPE_STAGES=%0d TILE_SPLIT_FACTOR=%0d)",
             MAC_PIPE_STAGES, TILE_SPLIT_FACTOR);
    #20 settle_marker = ~settle_marker;
    rst_n = 1'b1;
    tick();
    tick();
    settle();

    // Constant pattern: fresh sweep with clear, then re-accumulation of the
    // same windows without clear (the old A0/A1 accumulation intent).
    set_const_inputs(shortreal'(1.0), shortreal'(2.0));
    mac_sweep("A", 1'b1);                 // every col = 2.0
    check_visible_state("A-FLUSH");
    mac_sweep("A2", 1'b0);                // every col = 4.0
    check_visible_state("A2-FLUSH");

    // Accum-disable sample: the window must pass the committed value
    // through untouched and col_out must stay idle.
    sample_cycle("A2-IDLE", 1'b0, 1'b0, '0);
    check_visible_state("A2-IDLE-FLUSH");

    // New constant with clear: the previous accumulation must be wiped.
    set_const_inputs(shortreal'(3.0), shortreal'(2.0));
    mac_sweep("B", 1'b1);                 // every col = 6.0
    check_visible_state("B-FLUSH");

    // Ramp pattern: per-column values with clear, then doubling sweep.
    set_ramp_inputs();
    mac_sweep("C", 1'b1);                 // block[r][c] = (r+1)*(c+1)
    check_visible_state("C-FLUSH");
    mac_sweep("D", 1'b0);                 // block[r][c] = 2*(r+1)*(c+1)
    check_visible_state("D-FLUSH");

    if (err == 0) $display("ALL CYCLE-ACCURATE CHECKS PASSED");
    else $display("%0d ERRORS", err);
    $finish;
  end
endmodule
