// ============================================================================
// tb_attn_e2e.sv — End-to-End FlashAttention Test (L=16, Single Head)
// ============================================================================
// This test exercises the current deployable datapath shape:
//   Phase A: QxK^T on one 16x16 block over HEAD_DIM=128
//   Softmax: one online-softmax update on the 16x16 score block
//   Phase B: P_block x V_block over 8 output-dimension microblocks (16 dims each)
//   Output: output_buffer correction + normalize + bf16 streamout
//
// The test compares the full O[16][128] stream against Python golden data.
// ============================================================================
`timescale 1ns / 1ps

module tb_attn_e2e;
  import attn_pkg::*;

  localparam int L  = 16;
  localparam int HD = 128;
  localparam int DIM_SUBBLOCKS = HEAD_DIM / TILE_COLS;
  localparam logic [4:0] TILE_ROWS_U5 = 5'(TILE_ROWS);
  localparam logic [4:0] TILE_COLS_U5 = 5'(TILE_COLS);
`ifndef SYNTHESIS
  localparam shortreal ZERO_SR = 0.0;
  localparam shortreal DIFF_TOL_SR = 0.05;
`endif

  // ==================================================================
  // Clock + Reset
  // ==================================================================
  logic clk, rst_n;
  always #5 clk = ~clk;

  // ==================================================================
  // Test Data Storage
  // ==================================================================
  logic [15:0] Q_mem [0:L-1][0:HD-1];
  logic [15:0] K_mem [0:L-1][0:HD-1];
  logic [15:0] V_mem [0:L-1][0:HD-1];
  logic [15:0] O_golden [0:L-1][0:HD-1];

  // ==================================================================
  // Module I/O
  // ==================================================================
  logic [15:0] mac_row [TILE_ROWS];
  logic [15:0] mac_col [TILE_COLS];
  logic [31:0] mac_block_out [TILE_ROWS][TILE_COLS];
  logic mac_clear_accum;
  logic mac_accum_en;

  logic s_valid, sm_s_ready, p_valid, softmax_done;
  logic kv_tile_first, kv_tile_last;
  logic [31:0] s_block [TILE_ROWS][TILE_COLS];
  logic [31:0] p_block [TILE_ROWS][TILE_COLS];
  logic [31:0] m_state [TILE_ROWS], l_state [TILE_ROWS], correction [TILE_ROWS];
  logic sm_state_load;
  logic [31:0] sm_state_m_in [TILE_ROWS];
  logic [31:0] sm_state_l_in [TILE_ROWS];

  logic obuf_update, obuf_norm;
  logic obuf_clear_bank, obuf_clear_bank_sel;
  logic obuf_bank_sel;
  logic obuf_ready, obuf_acc_ready;
  logic [clog2_safe(TILE_ROWS)-1:0] obuf_row;
  logic [2:0] obuf_dim_blk;
  logic [31:0] obuf_data [TILE_COLS];
  logic obuf_valid;
  logic [15:0] obuf_out;
  logic [4:0] obuf_o_row;
  logic [6:0] obuf_o_dim;

  logic [31:0] delta_o [0:TILE_ROWS-1][0:HEAD_DIM-1];
  logic [15:0] O_seen [0:L-1][0:HD-1];
  logic tick_marker;
  logic settle_marker;

  // ==================================================================
  // DUT Instances
  // ==================================================================
  attn_tile u_mac (.clk,.rst_n,.phase_sel(1'b0),.row_data(mac_row),.col_data(mac_col),.split_phase(2'd2),.clear_accum(mac_clear_accum),.accum_en(mac_accum_en),.block_out(mac_block_out),.col_out());
  softmax_engine u_sm(.clk,.rst_n,.s_valid,.s_ready(sm_s_ready),.s_data(s_block),.kv_tile_first,.kv_tile_last,.causal_mask_en(1'b1),.q_tile_start(16'd0),.kv_tile_start(16'd0),.active_rows(TILE_ROWS_U5),.active_cols(TILE_COLS_U5),.state_load(sm_state_load),.state_m_in(sm_state_m_in),.state_l_in(sm_state_l_in),.m_state,.l_state,.p_valid,.p_data(p_block),.correction,.done(softmax_done));
  output_buffer u_obuf(.clk,.rst_n,.clear_bank(obuf_clear_bank),.clear_bank_sel(obuf_clear_bank_sel),.acc_update(obuf_update),.acc_ready(obuf_acc_ready),.acc_row(obuf_row),.acc_dim_blk(obuf_dim_blk),.acc_data(obuf_data),.acc_correction(correction[obuf_row]),.bank_sel(obuf_bank_sel),.normalize(obuf_norm),.active_rows(TILE_ROWS_U5),.l_state(l_state),.o_ready(obuf_ready),.o_valid(obuf_valid),.o_row(obuf_o_row),.o_dim(obuf_o_dim),.o_data(obuf_out));

  // ==================================================================
  // Block Progress
  // ==================================================================
  // ==================================================================
  // Load test data from hex files
  // ==================================================================
  task load_data(input string fname, output logic [15:0] mem [0:L-1][0:HD-1]);
    integer fd, r, c, val, scan_rc;
    fd = $fopen(fname, "r");
    for (r = 0; r < L; r++)
      for (c = 0; c < HD; c++) begin
        scan_rc = $fscanf(fd, "%h", val);
        mem[r][c] = val[15:0];
      end
    $fclose(fd);
  endtask

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

  // ==================================================================
  // Main Test
  // ==================================================================
  integer err, ri, ci, di, blk, got_count;
`ifndef SYNTHESIS
  shortreal got_val, exp_val, diff_val;
`endif
  initial begin
    clk = 1'b0; rst_n = 1'b0;
    err = 0;
    mac_clear_accum = 1'b0;
    mac_accum_en = 1'b0;
    s_valid = 1'b0;
    kv_tile_first = 1'b1; kv_tile_last = 1'b1;
    obuf_update = 1'b0; obuf_norm = 1'b0;
    obuf_clear_bank = 1'b0; obuf_clear_bank_sel = 1'b0;
    sm_state_load = 1'b0;
    obuf_bank_sel = 1'b0;
    obuf_ready = 1'b1;
    obuf_row = '0;
    obuf_dim_blk = 3'd0;
    tick_marker = 1'b0;
    settle_marker = 1'b0;
    for (ri = 0; ri < TILE_ROWS; ri++) begin
      sm_state_m_in[ri] = 32'hFF80_0000;
      sm_state_l_in[ri] = 32'd0;
    end
    for (ri = 0; ri < TILE_ROWS; ri++)
      for (di = 0; di < HEAD_DIM; di++)
        delta_o[ri][di] = 32'd0;
    for (ri = 0; ri < L; ri++)
      for (di = 0; di < HD; di++)
        O_seen[ri][di] = 16'd0;

    $display("TB: attn_e2e — L=%0d, HD=%0d", L, HD);

    // Load data
    load_data("data/e2e_Q_L16.hex", Q_mem);
    load_data("data/e2e_K_L16.hex", K_mem);
    load_data("data/e2e_V_L16.hex", V_mem);
    load_data("data/e2e_O_L16.hex", O_golden);
    $display("Loaded Q,K,V,O golden data");

    #20 rst_n = 1'b1;
    tick();
    tick();

    // ================================================================
    // Phase A: Q×K^T — iterate depth 0..127
    // ================================================================
    $display("Phase A: QxK^T (depth 0..127)...");
    for (ri = 0; ri < TILE_ROWS; ri++)
      mac_row[ri] = Q_mem[ri][0];
    for (ci = 0; ci < TILE_COLS; ci++)
      mac_col[ci] = K_mem[ci][0];
    mac_clear_accum = 1'b1;
    mac_accum_en = 1'b0;
    tick();
    settle();

    for (di = 0; di < HD; di++) begin
      mac_clear_accum = (di == 0);
      mac_accum_en = 1'b1;
      for (ri = 0; ri < TILE_ROWS; ri++)
        mac_row[ri] = Q_mem[ri][di];
      for (ci = 0; ci < TILE_COLS; ci++)
        mac_col[ci] = K_mem[ci][di];
      tick();
      settle();
    end
    mac_clear_accum = 1'b0;
    mac_accum_en = 1'b1;
    tick();
    settle();
    mac_accum_en = 1'b0;

    for (ri = 0; ri < TILE_ROWS; ri++)
      for (ci = 0; ci < TILE_COLS; ci++)
        s_block[ri][ci] = mac_block_out[ri][ci];

    s_valid = 1'b1;
    tick();
    settle();
    s_valid = 1'b0;
    wait (p_valid === 1'b1) tick_marker = ~tick_marker;
    tick();
    settle();
    // ================================================================
    // Phase B: P×V — 8 output-dimension blocks of width 16
    // ================================================================
    $display("Phase B: PxV (8 output blocks)...");
    for (blk = 0; blk < HEAD_DIM / TILE_COLS; blk++) begin
      for (ri = 0; ri < TILE_ROWS; ri++)
        mac_row[ri] = p_block[ri][0][31:16];
      for (ci = 0; ci < TILE_COLS; ci++)
        mac_col[ci] = V_mem[0][blk * TILE_COLS + ci];
      mac_clear_accum = 1'b1;
      mac_accum_en = 1'b0;
      tick();
      settle();

      for (di = 0; di < TILE_COLS; di++) begin
        mac_clear_accum = (di == 0);
        mac_accum_en = 1'b1;
        for (ri = 0; ri < TILE_ROWS; ri++)
          mac_row[ri] = p_block[ri][di][31:16];
        for (ci = 0; ci < TILE_COLS; ci++)
          mac_col[ci] = V_mem[di][blk * TILE_COLS + ci];
        tick();
        settle();
      end
      mac_clear_accum = 1'b0;
      mac_accum_en = 1'b1;
      tick();
      settle();
      mac_accum_en = 1'b0;
      for (ri = 0; ri < TILE_ROWS; ri++)
        for (ci = 0; ci < TILE_COLS; ci++)
          delta_o[ri][blk * TILE_COLS + ci] = mac_block_out[ri][ci];
    end
    mac_clear_accum = 1'b0;

    // Route 16-dim chunk updates into output_buffer.
    for (blk = 0; blk < DIM_SUBBLOCKS; blk++) begin
      obuf_dim_blk = blk[2:0];
      for (ri = 0; ri < TILE_ROWS; ri++) begin
        obuf_row = ri[clog2_safe(TILE_ROWS)-1:0];
        for (di = 0; di < TILE_COLS; di++)
          obuf_data[di] = delta_o[ri][blk * TILE_COLS + di];
        obuf_update = 1'b1;
        tick();
        settle();
        obuf_update = 1'b0;
      end
    end

    // output_buffer normalizes the bank opposite to bank_sel.
    obuf_bank_sel = 1'b1;
    obuf_norm = 1'b1;
    tick();
    settle();
    obuf_norm = 1'b0;

    // ================================================================
    // Compare output with golden (sequential readout from obuf)
    // ================================================================
    $display("Comparing output with golden...");
    got_count = 0;
    while (got_count < (L * HD)) begin
      tick();
      settle();
      if (obuf_valid) begin
        O_seen[obuf_o_row][obuf_o_dim] = obuf_out;
`ifndef SYNTHESIS
        got_val = $bitstoshortreal({obuf_out, 16'b0});
        exp_val = $bitstoshortreal({O_golden[obuf_o_row][obuf_o_dim], 16'b0});
        diff_val = got_val - exp_val;
        if (diff_val < ZERO_SR)
          diff_val = -diff_val;
        if (diff_val > DIFF_TOL_SR) begin
`else
        if (obuf_out !== O_golden[obuf_o_row][obuf_o_dim]) begin
`endif
          err = err + 1;
          if (err <= 16) begin
            $display("Mismatch row=%0d dim=%0d got=%h exp=%h",
                     obuf_o_row, obuf_o_dim, obuf_out, O_golden[obuf_o_row][obuf_o_dim]);
          end
        end
        got_count = got_count + 1;
      end
    end

    if (err == 0) begin
      $display("ALL E2E CHECKS PASSED");
    end else begin
      $display("E2E FAILED with %0d mismatches", err);
      $fatal(1);
    end

    $finish;
  end

endmodule
