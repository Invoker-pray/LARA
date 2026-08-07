`timescale 1ns/1ps
module tb_softmax_func_debug;
  import attn_pkg::*;
  logic clk, rst_n, s_valid, s_ready, kv_tile_first, kv_tile_last;
  logic causal_mask_en, state_load, p_valid, done;
  logic [15:0] q_tile_start, kv_tile_start;
  logic [4:0] active_rows, active_cols;
  logic [31:0] s_data [TILE_ROWS][TILE_COLS];
  logic [31:0] state_m_in [TILE_ROWS], state_l_in [TILE_ROWS];
  logic [31:0] m_state [TILE_ROWS], l_state [TILE_ROWS];
  wire [31:0] p_data [TILE_ROWS][TILE_COLS];
  logic [31:0] correction [TILE_ROWS];

  softmax_engine dut (
    .clk, .rst_n, .s_valid, .s_ready, .s_data,
    .kv_tile_first, .kv_tile_last, .causal_mask_en,
    .q_tile_start, .kv_tile_start, .active_rows, .active_cols,
    .state_load, .state_m_in, .state_l_in,
    .m_state, .l_state, .p_valid, .p_data, .correction, .done
  );

  initial begin
    #1;
    $display("EXP bc315c62=%h", dut.exp_lookup_bits(32'hbc315c62));
    $display("EXP bc315c60=%h", dut.exp_lookup_bits(32'hbc315c60));
    $display("EXP bc822a40=%h", dut.exp_lookup_bits(32'hbc822a40));
    $display("EXP 00000000=%h", dut.exp_lookup_bits(32'h00000000));
    $finish;
  end
endmodule
