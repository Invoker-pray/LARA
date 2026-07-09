`timescale 1ns / 1ps

module tb_kv_cache_ram;
  import attn_pkg::*;

  logic clk, rst_n, wr_en, rd_en;
  logic rd_vec_en;
  logic [15:0] wr_addr, rd_token_start;
  logic [15:0] rd_vec_token_idx;
  logic [15:0] wr_data;
  logic [6:0]  rd_dim, rd_vec_dim_start;
  logic [15:0] rd_data [TILE_KV];
  logic [15:0] rd_vec_data [TILE_COLS];

  integer err, tok;

  kv_cache_ram dut (
    .clk, .rst_n,
    .wr_en, .wr_addr, .wr_data,
    .rd_en, .rd_token_start, .rd_dim, .rd_data,
    .rd_vec_en, .rd_vec_token_idx, .rd_vec_dim_start, .rd_vec_data
  );

  always #5 clk = ~clk;

  task automatic write_elem(input int token_idx, input int dim_idx, input logic [15:0] data);
    begin
      wr_en   <= 1'b1;
      wr_addr <= 16'(token_idx * HEAD_DIM + dim_idx);
      wr_data <= data;
      @(posedge clk);
      wr_en   <= 1'b0;
      wr_addr <= '0;
      wr_data <= '0;
    end
  endtask

  task automatic check_tile(input int token_base, input int dim_idx);
    logic [15:0] exp_val;
    begin
      rd_en <= 1'b1;
      rd_token_start <= 16'(token_base);
      rd_dim <= 7'(dim_idx);
      @(posedge clk);
      #1;
      rd_en <= 1'b0;

      for (tok = 0; tok < TILE_KV; tok++) begin
        exp_val = 16'(((token_base + tok) << 8) | dim_idx);
        if (rd_data[tok] !== exp_val) begin
          $display("FAIL read tile=%0d dim=%0d tok=%0d got=0x%04h exp=0x%04h",
                   token_base, dim_idx, tok, rd_data[tok], exp_val);
          err++;
        end
      end
    end
  endtask

  task automatic check_vec(input int token_idx, input int dim_base);
    logic [15:0] exp_val;
    begin
      rd_vec_en <= 1'b1;
      rd_vec_token_idx <= 16'(token_idx);
      rd_vec_dim_start <= 7'(dim_base);
      @(posedge clk);
      #1;
      rd_vec_en <= 1'b0;

      for (tok = 0; tok < TILE_COLS; tok++) begin
        exp_val = 16'(((token_idx << 8) | (dim_base + tok)));
        if (rd_vec_data[tok] !== exp_val) begin
          $display("FAIL vec token=%0d dim=%0d slot=%0d got=0x%04h exp=0x%04h",
                   token_idx, dim_base, tok, rd_vec_data[tok], exp_val);
          err++;
        end
      end
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    wr_en = 1'b0;
    rd_en = 1'b0;
    rd_vec_en = 1'b0;
    wr_addr = '0;
    wr_data = '0;
    rd_token_start = '0;
    rd_dim = '0;
    rd_vec_token_idx = '0;
    rd_vec_dim_start = '0;
    err = 0;

    $display("TB: kv_cache_ram banked read test");
    #20 rst_n = 1'b1;
    @(posedge clk);

    // Fill two TILE_KV groups across dims 0..31 with easy-to-check patterns.
    for (int dim_idx = 0; dim_idx < 32; dim_idx++) begin
      for (int token_idx = 0; token_idx < 128; token_idx++) begin
        write_elem(token_idx, dim_idx, 16'(((token_idx << 8) | dim_idx)));
      end
    end

    check_tile(0, 3);
    check_tile(64, 3);
    check_tile(0, 17);
    check_tile(64, 17);
    check_vec(5, 0);
    check_vec(37, 16);

    if (err == 0)
      $display("ALL 288 TESTS PASSED");
    else
      $display("%0d ERRORS", err);

    $finish;
  end
endmodule
