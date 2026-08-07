// ============================================================================
// tb_attn_tile.sv — 16x16 MAC Array test (cycle-accurate)
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

  task automatic reset_ref_state;
    integer ri, ci;
    begin
      for (ri = 0; ri < TILE_ROWS; ri = ri + 1)
        for (ci = 0; ci < TILE_COLS; ci = ci + 1)
          ref_state[ri][ci] = shortreal'(0.0);
    end
  endtask

  task automatic sample_cycle(
    input string tag,
    input logic do_clear,
    input logic do_accum,
    input logic [TILE_SPLIT_INDEX_W-1:0] sp
  );
    shortreal visible_state [TILE_ROWS][TILE_COLS];
    shortreal next_state    [TILE_ROWS][TILE_COLS];
    shortreal exp_col       [TILE_COLS];
    shortreal a, b, prod;
    integer ri, ci;
    begin
      clear_accum = do_clear;
      accum_en    = do_accum;
      split_phase = sp;

      for (ri = 0; ri < TILE_ROWS; ri = ri + 1) begin
        for (ci = 0; ci < TILE_COLS; ci = ci + 1) begin
          visible_state[ri][ci] = ref_state[ri][ci];
          next_state[ri][ci] = do_clear ? shortreal'(0.0) : ref_state[ri][ci];
        end
      end

      for (ci = 0; ci < TILE_COLS; ci = ci + 1)
        exp_col[ci] = shortreal'(0.0);

      for (ri = 0; ri < TILE_ROWS; ri = ri + 1) begin
        a = bf16_to_shortreal(row_data[ri]);
        for (ci = 0; ci < TILE_COLS; ci = ci + 1) begin
          if ((TILE_SPLIT_FACTOR <= 1) ||
              ((ci >= (sp * (TILE_COLS / TILE_SPLIT_FACTOR))) &&
               (ci < ((sp + 1) * (TILE_COLS / TILE_SPLIT_FACTOR))))) begin
            b = bf16_to_shortreal(col_data[ci]);
          end else begin
            b = shortreal'(0.0);
          end

          prod = a * b;
          if (do_accum) begin
            exp_col[ci] = exp_col[ci] + prod;
            next_state[ri][ci] = next_state[ri][ci] + prod;
          end
        end
      end

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
          if (got_val != next_state[ri][ci]) begin
            $display("FAIL %s BLK r[%0d] c[%0d]=%e exp=%e", tag, ri, ci, got_val, next_state[ri][ci]);
            err = err + 1;
          end
`else
          if (got_val != visible_state[ri][ci]) begin
            $display("FAIL %s BLK r[%0d] c[%0d]=%e exp=%e", tag, ri, ci, got_val, visible_state[ri][ci]);
            err = err + 1;
          end
`endif
          ref_state[ri][ci] = next_state[ri][ci];
        end
      end

      clear_accum = 1'b0;
    end
  endtask

  task automatic check_visible_state(input string tag);
    integer ri, ci;
    begin
      accum_en = 1'b0;
      clear_accum = 1'b0;
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
            $display("FAIL %s BLK-VIS r[%0d] c[%0d]=%e exp=%e", tag, ri, ci, got_val, ref_state[ri][ci]);
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
    split_phase = 2'd0;
    tick_marker = 1'b0;
    settle_marker = 1'b0;
    err = 0;
    for (r = 0; r < TILE_ROWS; r = r + 1)
      row_data[r] = 16'd0;
    for (c = 0; c < TILE_COLS; c = c + 1)
      col_data[c] = 16'd0;
    reset_ref_state();

    $display("TB: attn_tile (MAC_PIPE_STAGES=%0d)", MAC_PIPE_STAGES);
    #20 settle_marker = ~settle_marker;
    rst_n = 1'b1;
    tick();
    tick();
    settle();

    // Constant pattern, lower half active.
    set_const_inputs(shortreal'(1.0), shortreal'(2.0));
    sample_cycle("A0", 1'b1, 1'b1, 2'd0);
    sample_cycle("A1", 1'b0, 1'b1, 2'd0);
    check_visible_state("A1-FLUSH");

    // Constant pattern, upper half active after clear.
    sample_cycle("B0", 1'b1, 1'b1, 2'd1);
    check_visible_state("B0-FLUSH");

    // Ramp pattern, lower half then upper half.
    set_ramp_inputs();
    sample_cycle("C0", 1'b1, 1'b1, 2'd0);
    check_visible_state("C0-FLUSH");
    sample_cycle("D0", 1'b1, 1'b1, 2'd1);
    check_visible_state("D0-FLUSH");

    if (err == 0) $display("ALL CYCLE-ACCURATE CHECKS PASSED");
    else $display("%0d ERRORS", err);
    $finish;
  end
endmodule
