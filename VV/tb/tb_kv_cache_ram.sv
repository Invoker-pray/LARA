`timescale 1ns / 1ps

module tb_kv_cache_ram;
  import attn_pkg::*;

  logic clk, rst_n, wr_en, rd_en;
  logic rd_vec_en;
  logic [15:0] wr_addr, rd_token_start;
  logic [15:0] rd_vec_token_idx;
  logic [15:0] wr_data;
  logic [6:0]  rd_dim, rd_vec_dim_start;
  logic [15:0] rd_data_token [TILE_KV];
  logic [15:0] rd_vec_data_token [TILE_COLS];
  logic [15:0] rd_data_vec [TILE_KV];
  logic [15:0] rd_vec_data_vec [TILE_COLS];
  logic tick_marker;
  logic settle_marker;

  integer err, tok;

  kv_cache_ram dut_token (
    .clk, .rst_n,
    .wr_en, .wr_addr, .wr_data,
    .rd_en, .rd_token_start, .rd_dim, .rd_data(rd_data_token),
    .rd_vec_en, .rd_vec_token_idx, .rd_vec_dim_start, .rd_vec_data(rd_vec_data_token)
  );

  kv_cache_ram #(.TOKEN_PARALLEL_READ(1'b0)) dut_vec (
    .clk, .rst_n,
    .wr_en, .wr_addr, .wr_data,
    .rd_en, .rd_token_start, .rd_dim, .rd_data(rd_data_vec),
    .rd_vec_en, .rd_vec_token_idx, .rd_vec_dim_start, .rd_vec_data(rd_vec_data_vec)
  );

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

  task automatic write_elem(input int token_idx, input int dim_idx, input logic [15:0] data);
    begin
      wr_en   <= 1'b1;
      wr_addr <= 16'(token_idx * HEAD_DIM + dim_idx);
      wr_data <= data;
      tick();
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
      tick();
      settle();
      rd_en <= 1'b0;

      for (tok = 0; tok < TILE_KV; tok++) begin
        exp_val = 16'(((token_base + tok) << 8) | dim_idx);
        if (rd_data_token[tok] !== exp_val) begin
          $display("FAIL read tile=%0d dim=%0d tok=%0d got=0x%04h exp=0x%04h",
                   token_base, dim_idx, tok, rd_data_token[tok], exp_val);
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
      tick();
      settle();
      rd_vec_en <= 1'b0;

      for (tok = 0; tok < TILE_COLS; tok++) begin
        exp_val = 16'(((token_idx << 8) | (dim_base + tok)));
        if (rd_vec_data_vec[tok] !== exp_val) begin
          $display("FAIL vec token=%0d dim=%0d slot=%0d got=0x%04h exp=0x%04h",
                   token_idx, dim_base, tok, rd_vec_data_vec[tok], exp_val);
          err++;
        end
      end
    end
  endtask

  task automatic check_vec_with_gap(input int token_idx, input int dim_base);
    logic [15:0] exp_val;
    begin
      rd_vec_en <= 1'b1;
      rd_vec_token_idx <= 16'(token_idx);
      rd_vec_dim_start <= 7'(dim_base);
      tick();
      settle();

      for (tok = 0; tok < TILE_COLS; tok++) begin
        exp_val = 16'(((token_idx << 8) | (dim_base + tok)));
        if (rd_vec_data_vec[tok] !== exp_val) begin
          $display("FAIL pulsed vec token=%0d dim=%0d slot=%0d got=0x%04h exp=0x%04h",
                   token_idx, dim_base, tok, rd_vec_data_vec[tok], exp_val);
          err++;
        end
      end

      rd_vec_en <= 1'b0;
      tick();
      settle();
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
    tick_marker = 1'b0;
    settle_marker = 1'b0;
    err = 0;

    $display("TB: kv_cache_ram banked read test");
    #20 rst_n = 1'b1;
    tick();

    // Fill two TILE_KV groups in the same token-major order used by the
    // streaming DMA loader on the board.
    for (int token_idx = 0; token_idx < 128; token_idx++) begin
      for (int dim_idx = 0; dim_idx < HEAD_DIM; dim_idx++) begin
        write_elem(token_idx, dim_idx, 16'(((token_idx << 8) | dim_idx)));
      end
    end

    check_tile(0, 3);
    check_tile(64, 3);
    check_tile(0, 17);
    check_tile(64, 17);
    check_vec(5, 0);
    check_vec(37, 16);
    check_vec(0, 112);
    check_vec(127, 112);
    check_vec_with_gap(0, 0);
    check_vec_with_gap(0, 112);

    if (err == 0)
      $display("ALL 320 TESTS PASSED");
    else
      $display("%0d ERRORS", err);

    $finish;
  end
endmodule
