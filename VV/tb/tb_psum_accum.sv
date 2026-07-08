`timescale 1ns / 1ps
module tb_psum_accum;
  import attn_pkg::*;
  logic clk, rst_n, clear, en, en_lo, en_hi, en_q0, en_q1, en_q2, en_q3;
  logic [31:0] tile_col [TILE_COLS];
  logic [31:0] col_lo [TILE_COLS], col_hi [TILE_COLS];
  logic [31:0] col_q0 [TILE_COLS], col_q1 [TILE_COLS];
  logic [31:0] col_q2 [TILE_COLS], col_q3 [TILE_COLS];
  logic [31:0] psum_out [TILE_COLS];
  integer err, i;

  psum_accum dut(.clk,.rst_n,.clear,.en,.tile_col,.en_lo,.en_hi,.col_lo,.col_hi,
    .en_q0,.en_q1,.en_q2,.en_q3,.col_q0,.col_q1,.col_q2,.col_q3,.psum(psum_out));

  always #5 clk=~clk;

  initial begin
    clk=0; rst_n=0; clear=0; en=0; en_lo=0; en_hi=0; en_q0=0;en_q1=0;en_q2=0;en_q3=0;
    for(i=0;i<TILE_COLS;i++) begin
      tile_col[i]=0; col_lo[i]=0; col_hi[i]=0;
      col_q0[i]=0; col_q1[i]=0; col_q2[i]=0; col_q3[i]=0;
    end

    $display("TB: psum_accum test");
    #20 rst_n=1; @(posedge clk); @(posedge clk);

    // Test 1: Accumulate + Clear
    err=0;
    for(i=0;i<TILE_COLS;i++) begin
      col_lo[i]=$shortrealtobits(42.0);
      col_hi[i]=$shortrealtobits(42.0);
    end
    en_lo=1; en_hi=1; @(posedge clk); en_lo=0; en_hi=0; @(posedge clk);
    for(i=0;i<TILE_COLS;i++) if($bitstoshortreal(psum_out[i])!=84.0) begin
      $display("FAIL acc col[%0d]=%e",i,$bitstoshortreal(psum_out[i])); err=err+1; end
    clear=1; @(posedge clk); clear=0; @(posedge clk); @(posedge clk);
    for(i=0;i<TILE_COLS;i++) if($bitstoshortreal(psum_out[i])!=0.0) begin
      $display("FAIL clr col[%0d]",i); err=err+1; end

    if(err==0) $display("ALL %0d TESTS PASSED", TILE_COLS*2);
    else $display("%0d ERRORS", err);
    $finish;
  end
endmodule
