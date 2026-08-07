`timescale 1ns / 1ps

module tb_output_buffer_rows;
  import attn_pkg::*;

  logic clk, rst_n;
  logic acc_update, acc_ready, bank_sel, normalize, clear_bank, clear_bank_sel;
  logic [clog2_safe(TILE_ROWS)-1:0] acc_row;
  logic [2:0] acc_dim_blk;
  logic [4:0] active_rows;
  logic [31:0] acc_data [TILE_COLS];
  logic [31:0] acc_correction;
  logic [31:0] l_state [TILE_ROWS];
  logic o_valid, o_ready;
  logic [4:0] o_row;
  logic [6:0] o_dim;
  logic [15:0] o_data;

  integer row, lane;
  integer errors;
  integer samples;

  output_buffer dut(.*);

  always #5 clk = ~clk;

  task automatic tick;
    begin
      @(posedge clk);
      #1;
    end
  endtask

  task automatic update_chunk(input integer update_row, input integer update_blk);
    begin
      acc_row = update_row[clog2_safe(TILE_ROWS)-1:0];
      acc_dim_blk = update_blk[2:0];
      for (lane = 0; lane < TILE_COLS; lane = lane + 1)
        acc_data[lane] = (lane == 0) ? (32'h3F80_0000 + (update_row << 23)) : 32'd0;
      acc_update = 1'b1;
      tick();
      acc_update = 1'b0;
      tick();
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    acc_update = 1'b0;
    bank_sel = 1'b1;
    normalize = 1'b0;
    clear_bank = 1'b0;
    clear_bank_sel = 1'b1;
    acc_row = '0;
    acc_dim_blk = '0;
    active_rows = TILE_ROWS[4:0];
    acc_correction = 32'h3F80_0000;
    o_ready = 1'b1;
    errors = 0;
    samples = 0;

    for (row = 0; row < TILE_ROWS; row = row + 1)
      l_state[row] = 32'h3F80_0000;
    for (lane = 0; lane < TILE_COLS; lane = lane + 1)
      acc_data[lane] = 32'd0;

    repeat (2) tick();
    rst_n = 1'b1;
    tick();

    clear_bank = 1'b1;
    tick();
    clear_bank = 1'b0;

    for (row = 0; row < TILE_ROWS; row = row + 1)
      update_chunk(row, 0);

    bank_sel = 1'b0;
    normalize = 1'b1;
    tick();
    normalize = 1'b0;

    while (samples < TILE_ROWS * HEAD_DIM) begin
      tick();
      if (o_valid) begin
        if (o_row !== samples / HEAD_DIM || o_dim !== samples % HEAD_DIM) begin
          $display("FAIL index sample=%0d got row=%0d dim=%0d expected row=%0d dim=%0d",
                   samples, o_row, o_dim, samples / HEAD_DIM, samples % HEAD_DIM);
          errors = errors + 1;
        end
        if (o_dim == 0) begin
          if (o_data !== (16'h3F80 + ((samples / HEAD_DIM) << 7))) begin
            $display("FAIL data row=%0d got=%h expected=%h",
                     o_row, o_data, 16'h3F80 + (o_row << 7));
            errors = errors + 1;
          end
        end else if (o_data !== 16'h0000) begin
          $display("FAIL nonzero lane row=%0d dim=%0d data=%h",
                   o_row, o_dim, o_data);
          errors = errors + 1;
        end
        samples = samples + 1;
      end
    end

    if (errors == 0)
      $display("OUTPUT BUFFER ROWS PASS samples=%0d", samples);
    else
      $display("OUTPUT BUFFER ROWS FAIL errors=%0d samples=%0d", errors, samples);
    $finish(errors == 0 ? 0 : 1);
  end
endmodule
