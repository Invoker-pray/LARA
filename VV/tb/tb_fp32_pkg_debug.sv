`timescale 1ns/1ps
module tb_fp32_pkg_debug;
  import attn_pkg::*;
  logic [31:0] a, b;
  initial begin
    a = 32'hbbc6f1c9;
    b = 32'h3b9bc6fa;
    #1;
    $display("SUB a=%h b=%h got=%h expected=bc315c60", a, b, fp32_sub(a, b));
    $display("ADD neg_a=%h neg_b=%h got=%h", fp32_negate(a), fp32_negate(b),
             fp32_add(fp32_negate(a), fp32_negate(b)));
    $display("ADD 1+1 got=%h", fp32_add(32'h3f800000, 32'h3f800000));
    $display("SUB 1-1 got=%h", fp32_sub(32'h3f800000, 32'h3f800000));
    $finish;
  end
endmodule
