`timescale 1ns / 1ps

module tb_output_buffer;
  import attn_pkg::*;

  logic clk, rst_n;
  logic acc_update, bank_sel, normalize, clear_bank, clear_bank_sel;
  logic [4:0] acc_row;
  logic [31:0] acc_data [HEAD_DIM];
  logic [31:0] correction [TILE_ROWS];
  logic [31:0] l_state [TILE_ROWS];
  logic o_valid;
  logic [4:0] o_row;
  logic [6:0] o_dim;
  logic [15:0] o_data;

  output_buffer dut(.*);

  always #5 clk = ~clk;

  integer i, err;
  initial begin
    clk = 0;
    rst_n = 0;
    acc_update = 0;
    bank_sel = 0;
    normalize = 0;
    clear_bank = 0;
    clear_bank_sel = 0;
    acc_row = 0;
    err = 0;

    for (i = 0; i < TILE_ROWS; i++) begin
      correction[i] = 32'h3F80_0000;
      l_state[i] = 32'h3F80_0000;
    end
    for (i = 0; i < HEAD_DIM; i++) begin
      acc_data[i] = 32'd0;
    end

    $display("TB: output_buffer synth-path sanity");
    #20 rst_n = 1;
    @(posedge clk);

    clear_bank_sel = 1'b1;
    clear_bank = 1'b1;
    @(posedge clk);
    clear_bank = 1'b0;

    // Update row 0 of bank 1 (bank_sel=1 computes bank1, normalize reads bank0)
    bank_sel = 1'b1;
    acc_row = 5'd0;
    for (i = 0; i < HEAD_DIM; i++) begin
      if (i == 0)      acc_data[i] = 32'h4000_0000; // 2.0
      else if (i == 1) acc_data[i] = 32'h4040_0000; // 3.0
      else             acc_data[i] = 32'd0;
    end
    acc_update = 1'b1;
    @(posedge clk);
    acc_update = 1'b0;
    @(posedge clk);

    // Normalize from bank1 by flipping bank_sel low.
    bank_sel = 1'b0;
    normalize = 1'b1;
    @(posedge clk);
    normalize = 1'b0;

    // First streamed sample appears one cycle later.
    @(posedge clk);
    if (!o_valid || o_row != 5'd0 || o_dim != 7'd0 || o_data != 16'h4000) begin
      $display("FAIL sample0 valid=%0b row=%0d dim=%0d data=%h", o_valid, o_row, o_dim, o_data);
      err++;
    end

    @(posedge clk);
    if (!o_valid || o_row != 5'd0 || o_dim != 7'd1 || o_data != 16'h4040) begin
      $display("FAIL sample1 valid=%0b row=%0d dim=%0d data=%h", o_valid, o_row, o_dim, o_data);
      err++;
    end

    if (err == 0) $display("ALL 2 TESTS PASSED");
    else $display("%0d ERRORS", err);
    $finish;
  end
endmodule
