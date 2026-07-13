`timescale 1ns / 1ps

module tb_output_buffer;
  import attn_pkg::*;

  logic clk, rst_n;
  logic acc_update, bank_sel, normalize, clear_bank, clear_bank_sel;
  logic [clog2_safe(TILE_ROWS)-1:0] acc_row;
  logic [2:0] acc_dim_blk;
  logic [4:0] active_rows;
  logic [31:0] acc_data [TILE_COLS];
  logic [31:0] acc_correction;
  logic [31:0] l_state [TILE_ROWS];
  logic o_valid;
  logic o_ready;
  logic [4:0] o_row;
  logic [6:0] o_dim;
  logic [15:0] o_data;
  logic tick_marker;
  integer i, err;
  integer dim_seen;

  output_buffer dut(.*);

  always #5 clk = ~clk;

  task automatic tick;
    begin
      @(posedge clk) #1 tick_marker = ~tick_marker;
    end
  endtask

  task automatic wait_for_output(
    input  logic [4:0] exp_row,
    input  logic [6:0] exp_dim,
    input  logic [15:0] exp_data,
    input  integer max_ticks
  );
    integer w;
    begin
      for (w = 0; w < max_ticks; w++) begin
        tick();
        if (o_valid) begin
          if (o_row != exp_row || o_dim != exp_dim || o_data != exp_data) begin
            $display("FAIL sample valid=%0b row=%0d dim=%0d data=%h exp_row=%0d exp_dim=%0d exp_data=%h",
                     o_valid, o_row, o_dim, o_data, exp_row, exp_dim, exp_data);
            err++;
          end
          return;
        end
      end
      $display("FAIL timeout waiting output exp_row=%0d exp_dim=%0d exp_data=%h",
               exp_row, exp_dim, exp_data);
      err++;
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    acc_update = 1'b0;
    bank_sel = 1'b0;
    normalize = 1'b0;
    clear_bank = 1'b0;
    clear_bank_sel = 1'b0;
    acc_row = '0;
    acc_dim_blk = 3'd0;
    active_rows = TILE_ROWS[4:0];
    o_ready = 1'b1;
    tick_marker = 1'b0;
    err = 0;
    dim_seen = 0;

    for (i = 0; i < TILE_ROWS; i++) begin
      l_state[i] = 32'h3F80_0000;
    end
    acc_correction = 32'h3F80_0000;
    for (i = 0; i < TILE_COLS; i++) begin
      acc_data[i] = 32'd0;
    end

    $display("TB: output_buffer synth-path sanity");
    #20 rst_n = 1'b1;
    tick();

    clear_bank_sel = 1'b1;
    clear_bank = 1'b1;
    tick();
    clear_bank = 1'b0;

    // Update row 0 of bank 1 (bank_sel=1 computes bank1, normalize reads bank0)
    bank_sel = 1'b1;
    acc_row = '0;
    for (i = 0; i < TILE_COLS; i++) begin
      if (i == 0)      acc_data[i] = 32'h4000_0000; // 2.0
      else if (i == 1) acc_data[i] = 32'h4040_0000; // 3.0
      else if (i == 2) acc_data[i] = 32'h3F80_0000; // 1.0
      else             acc_data[i] = 32'd0;
    end
    acc_update = 1'b1;
    tick();
    acc_update = 1'b0;
    tick();

    // Second update on the same chunk to verify read-modify-write behavior.
    for (i = 0; i < TILE_COLS; i++) begin
      if (i == 0)      acc_data[i] = 32'h3F80_0000; // +1.0 => 3.0
      else if (i == 1) acc_data[i] = 32'h3FC0_0000; // +1.5 => 4.5
      else             acc_data[i] = 32'd0;
    end
    acc_update = 1'b1;
    tick();
    acc_update = 1'b0;
    tick();

    // Normalize from bank1 by flipping bank_sel low.
    bank_sel = 1'b0;
    active_rows = 5'd1;
    l_state[0] = 32'h3FC0_0000; // 1.5, exercises a reciprocal mantissa LUT entry
    normalize = 1'b1;
    tick();
    normalize = 1'b0;

    // Dimension 2 distinguishes the LUT approximation from exact division:
    // 1.0 / 1.5 rounds to bf16 0x3f2b exactly and 0x3f2a via this LUT.
    wait_for_output(5'd0, 7'd0, 16'h4000, 8);
    wait_for_output(5'd0, 7'd1, 16'h4040, 8);
    wait_for_output(5'd0, 7'd2, 16'h3F2A, 8);

    for (dim_seen = 3; dim_seen < HEAD_DIM; dim_seen++) begin
      wait_for_output(5'd0, dim_seen[6:0], 16'h0000, 8);
      if (o_data != 16'h0000) begin
        $display("FAIL active_rows stream mismatch valid=%0b row=%0d dim=%0d exp_dim=%0d",
                 o_valid, o_row, o_dim, dim_seen);
        err++;
        break;
      end
    end

    tick();
    if (o_valid) begin
      $display("FAIL output should stop after row 0 completed, got row=%0d dim=%0d", o_row, o_dim);
      err++;
    end

    if (err == 0) $display("ALL 3 TESTS PASSED");
    else $display("%0d ERRORS", err);
    $finish;
  end
endmodule
