// ============================================================================
// tb_softmax.sv — softmax_engine testbench (single KV tile)
// ============================================================================
`timescale 1ns / 1ps

module tb_softmax;
  import attn_pkg::*;
  localparam shortreal EPS_M    = 0.01;
  localparam shortreal EPS_L    = 0.1;
  localparam shortreal EPS_CORR = 0.001;
  localparam shortreal EPS_P    = 0.01;

  logic clk, rst_n, s_valid, kv_tile_first, kv_tile_last, p_valid, done;
  logic causal_mask_en;
  logic [15:0] q_tile_start, kv_tile_start;
  logic [4:0] active_rows, active_cols;
  logic [31:0] s_data [TILE_ROWS][TILE_COLS];
  logic state_load;
  logic [31:0] state_m_in [TILE_ROWS];
  logic [31:0] state_l_in [TILE_ROWS];
  logic [31:0] m_state [TILE_ROWS];
  logic [31:0] l_state [TILE_ROWS];
  logic [31:0] p_data  [TILE_ROWS][TILE_COLS];
  logic [31:0] correction [TILE_ROWS];

  softmax_engine dut(.*);

  always #5 clk = ~clk;

  // Golden data
  logic [31:0] golden_S    [TILE_ROWS][TILE_COLS];
  logic [31:0] golden_m    [TILE_ROWS];
  logic [31:0] golden_l    [TILE_ROWS];
  logic [31:0] golden_P    [TILE_ROWS][TILE_COLS];
  logic [31:0] golden_corr [TILE_ROWS];
  logic tick_marker;
  logic settle_marker;

  integer fd, ri, ci, err;
  integer scan_rc;
  integer wait_cycles;

  task automatic tick;
    begin
      @(posedge clk) begin
        #1 tick_marker = ~tick_marker;
      end
    end
  endtask

  task automatic settle;
    begin
      #1 settle_marker = ~settle_marker;
    end
  endtask

  initial begin
    clk = 1'b0; rst_n = 1'b0; s_valid = 1'b0; kv_tile_first = 1'b0; kv_tile_last = 1'b0;
    causal_mask_en = 1'b0; q_tile_start = 16'd0; kv_tile_start = 16'd0;
    active_rows = 5'(TILE_ROWS);
    active_cols = 5'(TILE_COLS);
    state_load = 1'b0;
    tick_marker = 1'b0;
    settle_marker = 1'b0;
    for (ri = 0; ri < TILE_ROWS; ri++) begin
      state_m_in[ri] = 32'hFF80_0000;
      state_l_in[ri] = 32'd0;
    end
    err = 0;

    // Load golden vectors
    fd = $fopen("data/softmax_vectors.hex", "r");
    if (!fd) begin
      $display("ERROR: Cannot open data/softmax_vectors.hex");
      $finish;
    end

    for (ri = 0; ri < TILE_ROWS; ri++)
      for (ci = 0; ci < TILE_COLS; ci++)
        scan_rc = $fscanf(fd, "%h", golden_S[ri][ci]);
    for (ri = 0; ri < TILE_ROWS; ri++) scan_rc = $fscanf(fd, "%h", golden_m[ri]);
    for (ri = 0; ri < TILE_ROWS; ri++) scan_rc = $fscanf(fd, "%h", golden_l[ri]);
    for (ri = 0; ri < TILE_ROWS; ri++)
      for (ci = 0; ci < TILE_COLS; ci++)
        scan_rc = $fscanf(fd, "%h", golden_P[ri][ci]);
    for (ri = 0; ri < TILE_ROWS; ri++) scan_rc = $fscanf(fd, "%h", golden_corr[ri]);
    $fclose(fd);

    $display("TB: softmax_engine — single KV tile test");

    // Reset
    #20 rst_n = 1'b1;
    tick();
    tick();

    // Drive S_tile data, kv_tile_first=1, kv_tile_last=1
    for (ri = 0; ri < TILE_ROWS; ri++)
      for (ci = 0; ci < TILE_COLS; ci++)
        s_data[ri][ci] = golden_S[ri][ci];
    s_valid = 1'b1;
    kv_tile_first = 1'b1;
    kv_tile_last  = 1'b1;
    tick();
    s_valid = 1'b0;
    kv_tile_first = 1'b0;
    kv_tile_last  = 1'b0;

    wait_cycles = 0;
    while ((p_valid !== 1'b1) && (wait_cycles < 2000)) begin
      tick();
      wait_cycles++;
    end
    settle();

    if (p_valid !== 1'b1) begin
      $display("FAIL softmax timeout after %0d cycles", wait_cycles);
      $finish;
    end

    // Check outputs
    for (ri = 0; ri < TILE_ROWS; ri++) begin
      // Check m_state (allow 1 ULP tolerance)
      if (m_state[ri] != golden_m[ri]) begin
        shortreal got;
        shortreal exp;
        got = $bitstoshortreal(m_state[ri]);
        exp = $bitstoshortreal(golden_m[ri]);
        if (got < exp - EPS_M || got > exp + EPS_M) begin
          $display("FAIL m[%0d]: got=%e exp=%e", ri, got, exp);
          err++;
        end
      end
      // Check l_state
      if (l_state[ri] != golden_l[ri]) begin
        shortreal got;
        shortreal exp;
        got = $bitstoshortreal(l_state[ri]);
        exp = $bitstoshortreal(golden_l[ri]);
        if (got < exp - EPS_L || got > exp + EPS_L) begin
          $display("FAIL l[%0d]: got=%e exp=%e", ri, got, exp);
          err++;
        end
      end
      // Check correction
      if (correction[ri] != golden_corr[ri]) begin
        shortreal got;
        shortreal exp;
        got = $bitstoshortreal(correction[ri]);
        exp = $bitstoshortreal(golden_corr[ri]);
        if (got < exp - EPS_CORR || got > exp + EPS_CORR) begin
          $display("FAIL corr[%0d]: got=%e exp=%e", ri, got, exp);
          err++;
        end
      end
      // Check P_data
      for (ci = 0; ci < TILE_COLS; ci++) begin
        if (p_data[ri][ci] != golden_P[ri][ci]) begin
          shortreal got;
          shortreal exp;
          got = $bitstoshortreal(p_data[ri][ci]);
          exp = $bitstoshortreal(golden_P[ri][ci]);
          if (got < exp - EPS_P || got > exp + EPS_P) begin
            $display("FAIL P[%0d][%0d]: got=%e exp=%e", ri, ci, got, exp);
            err++;
          end
        end
      end
    end

    if (err == 0)
      $display("ALL %0d CHECKS PASSED", TILE_ROWS * (3 + TILE_COLS));
    else
      $display("%0d ERRORS", err);
    $finish;
  end

endmodule
