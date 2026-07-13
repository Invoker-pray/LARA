`timescale 1ns / 1ps
module tb_psum_accum;
  import attn_pkg::*;
  localparam shortreal EXP_ACC = 84.0;
  localparam shortreal EXP_CLR = 0.0;
  logic clk, rst_n, clear, en, en_lo, en_hi, en_q0, en_q1, en_q2, en_q3;
  logic [31:0] tile_col [TILE_COLS];
  logic [31:0] col_lo [TILE_COLS], col_hi [TILE_COLS];
  logic [31:0] col_q0 [TILE_COLS], col_q1 [TILE_COLS];
  logic [31:0] col_q2 [TILE_COLS], col_q3 [TILE_COLS];
  logic [31:0] psum_out [TILE_COLS];
  logic tick_marker;
  integer err, i;

  psum_accum dut(.clk,.rst_n,.clear,.en,.tile_col,.en_lo,.en_hi,.col_lo,.col_hi,
    .en_q0,.en_q1,.en_q2,.en_q3,.col_q0,.col_q1,.col_q2,.col_q3,.psum(psum_out));

  always #5 clk=~clk;

  task automatic tick;
    begin
      @(posedge clk) tick_marker = ~tick_marker;
    end
  endtask

  initial begin
    clk=1'b0; rst_n=1'b0; clear=1'b0; en=1'b0; en_lo=1'b0; en_hi=1'b0;
    en_q0=1'b0; en_q1=1'b0; en_q2=1'b0; en_q3=1'b0;
    tick_marker = 1'b0;
    for(i=0;i<TILE_COLS;i++) begin
      tile_col[i]=32'd0; col_lo[i]=32'd0; col_hi[i]=32'd0;
      col_q0[i]=32'd0; col_q1[i]=32'd0; col_q2[i]=32'd0; col_q3[i]=32'd0;
    end

    $display("TB: psum_accum test");
    #20 rst_n=1'b1; tick(); tick();

    // Test 1: Accumulate + Clear
    err=0;
    for(i=0;i<TILE_COLS;i++) begin
      col_lo[i]=$shortrealtobits(42.0);
      col_hi[i]=$shortrealtobits(42.0);
    end
    en_lo=1'b1; en_hi=1'b1; tick(); en_lo=1'b0; en_hi=1'b0; tick();
    for(i=0;i<TILE_COLS;i++) if($bitstoshortreal(psum_out[i])!=EXP_ACC) begin
      $display("FAIL acc col[%0d]=%e",i,$bitstoshortreal(psum_out[i])); err=err+1; end
    clear=1'b1; tick(); clear=1'b0; tick(); tick();
    for(i=0;i<TILE_COLS;i++) if($bitstoshortreal(psum_out[i])!=EXP_CLR) begin
      $display("FAIL clr col[%0d]",i); err=err+1; end

    if(err==0) $display("ALL %0d TESTS PASSED", TILE_COLS*2);
    else $display("%0d ERRORS", err);
    $finish;
  end
endmodule
