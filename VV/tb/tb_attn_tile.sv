// ============================================================================
// tb_attn_tile.sv — 16×16 MAC Array test (pipeline-aware)
// ============================================================================
`timescale 1ns / 1ps
module tb_attn_tile;
  import attn_pkg::*;
  logic clk, rst_n, phase_sel, accum_en;
  logic [1:0] split_phase;
  logic [15:0] row_data [TILE_ROWS];
  logic [15:0] col_data [TILE_COLS];
  logic [31:0] col_out [TILE_COLS];
  integer err, r, c;
  shortreal got_val, exp_val;

  attn_tile dut(.clk,.rst_n,.phase_sel,.row_data,.col_data,.split_phase,.accum_en,.col_out);

  always #5 clk = ~clk;

  // Wait N cycles for pipeline to produce output
  task wait_pipe;
    begin
      repeat(MAC_PIPE_STAGES) @(posedge clk);
      #1; // settle
    end
  endtask

  initial begin
    clk=0; rst_n=0; phase_sel=0; accum_en=0; split_phase=0;
    for(r=0;r<TILE_ROWS;r++) row_data[r]=0;
    for(c=0;c<TILE_COLS;c++) col_data[c]=0;
    err=0;

    $display("TB: attn_tile (MAC_PIPE_STAGES=%0d)", MAC_PIPE_STAGES);
    #20 rst_n=1; @(posedge clk); @(posedge clk);

    // === Constant test: Q=1.0, K=2.0 → col = 16*2 = 32.0 ===
    for(r=0;r<TILE_ROWS;r++) row_data[r]=$shortrealtobits(1.0)>>16;
    for(c=0;c<TILE_COLS;c++) col_data[c]=$shortrealtobits(2.0)>>16;
    accum_en=1; split_phase=2'd0;
    wait_pipe;
    for(c=0;c<8;c++) begin
      got_val=$bitstoshortreal(col_out[c]);
      if(got_val!=32.0) begin $display("FAIL A c[%0d]=%e",c,got_val); err=err+1; end
    end
    for(c=8;c<16;c++) begin
      if($bitstoshortreal(col_out[c])!=0.0) begin $display("FAIL A-inact c[%0d]=%e",c,$bitstoshortreal(col_out[c])); err=err+1; end
    end

    split_phase=2'd1; wait_pipe;
    for(c=0;c<8;c++) begin
      if($bitstoshortreal(col_out[c])!=0.0) begin $display("FAIL B-inact c[%0d]=%e",c,$bitstoshortreal(col_out[c])); err=err+1; end
    end
    for(c=8;c<16;c++) begin
      if($bitstoshortreal(col_out[c])!=32.0) begin $display("FAIL B c[%0d]=%e",c,$bitstoshortreal(col_out[c])); err=err+1; end
    end

    // === Varied K test ===
    for(c=0;c<TILE_COLS;c++) col_data[c]=$shortrealtobits(shortreal'(c+1))>>16;
    split_phase=2'd0; wait_pipe;
    for(c=0;c<8;c++) begin
      exp_val=16.0*shortreal'(c+1); got_val=$bitstoshortreal(col_out[c]);
      if(got_val!=exp_val) begin $display("FAIL C c[%0d]=%e exp=%e",c,got_val,exp_val); err=err+1; end
    end
    split_phase=2'd1; wait_pipe;
    for(c=8;c<16;c++) begin
      exp_val=16.0*shortreal'(c+1); got_val=$bitstoshortreal(col_out[c]);
      if(got_val!=exp_val) begin $display("FAIL D c[%0d]=%e exp=%e",c,got_val,exp_val); err=err+1; end
    end

    if(err==0) $display("ALL 64 TESTS PASSED");
    else $display("%0d ERRORS", err);
    $finish;
  end
endmodule
