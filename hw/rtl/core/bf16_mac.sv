// ============================================================================
// bf16_mac.sv — Atomic bf16 Multiply-Accumulate PE (Dual-Mode)
// ============================================================================
// Simulation: shortreal (IEEE 754 compatible, VCS/Verilator)
// Synthesis:  DSP48E2-inferred bf16 multiply + LUT fp32 accumulate
// Vivado auto-defines SYNTHESIS during synth/impl runs.
// ============================================================================
module bf16_mac
  import attn_pkg::*;
(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic [BF16_W-1:0]    a_bf16,
    input  logic [BF16_W-1:0]    b_bf16,
    input  logic [FP32_W-1:0]    c_fp32,
    output logic [FP32_W-1:0]    out_fp32
);

`ifndef SYNTHESIS
  // ==================================================================
  // Simulation path (shortreal)
  // ==================================================================
  logic _u;
  assign _u = |{clk, rst_n};

  logic [FP32_W-1:0] a_fp32, b_fp32;
  assign a_fp32 = {a_bf16, 16'b0};
  assign b_fp32 = {b_bf16, 16'b0};

  shortreal a_real, b_real, prod_real;
  assign a_real    = $bitstoshortreal(a_fp32);
  assign b_real    = $bitstoshortreal(b_fp32);
  assign prod_real = a_real * b_real;

  logic [FP32_W-1:0] prod_r, c_r;
  generate
    if (C4_MUL_PIPE) begin : GEN_PIPE
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin prod_r <= 32'd0; c_r <= 32'd0; end
        else begin prod_r <= $shortrealtobits(prod_real); c_r <= c_fp32; end
      end
    end else begin : GEN_COMB
      always_comb begin prod_r = $shortrealtobits(prod_real); c_r = c_fp32; end
    end
  endgenerate

  shortreal prod_staged, c_staged;
  assign prod_staged = $bitstoshortreal(prod_r);
  assign c_staged    = $bitstoshortreal(c_r);
  assign out_fp32 = $shortrealtobits(prod_staged + c_staged);

`else
  // ==================================================================
  // Synthesis path: DSP48E2-inferred bf16 multiply + fp32 accumulate
  // ==================================================================
  (* use_dsp = "yes" *)
  logic [FP32_W-1:0] product_fp32;

  // Extract bf16 fields
  logic        sign_a, sign_b;
  logic [7:0]  exp_a,  exp_b;
  logic [7:0]  mant_a, mant_b; // 1.M, 8-bit with implicit 1

  assign sign_a = a_bf16[15];
  assign exp_a  = a_bf16[14:7];
  assign mant_a = {1'b1, a_bf16[6:0]};

  assign sign_b = b_bf16[15];
  assign exp_b  = b_bf16[14:7];
  assign mant_b = {1'b1, b_bf16[6:0]};

  // Mantissa multiply: 8-bit × 8-bit → 16-bit (DSP48E2 inference)
  (* use_dsp = "yes" *) logic [15:0] mant_prod;
  assign mant_prod = mant_a * mant_b;

  // Sign: XOR
  logic sign_prod;
  assign sign_prod = sign_a ^ sign_b;

  // Exponent: Ea + Eb - 127 (9-bit signed)
  logic [8:0] exp_prod;
  assign exp_prod = {1'b0, exp_a} + {1'b0, exp_b} - 9'd127;

  // Normalize: if mant_prod[15]=1, shift right 1 and inc exponent
  logic       norm_shift;
  logic [7:0] exp_norm;
  logic [6:0] mant_norm; // 7-bit explicit for bf16-range fp32

  assign norm_shift = mant_prod[15];
  assign exp_norm   = norm_shift ? (exp_prod[7:0] + 8'd1) : exp_prod[7:0];
  assign mant_norm  = norm_shift ? mant_prod[14:8] : mant_prod[13:7];

  // Zeros/special values
  logic a_zero, b_zero, a_inf, b_inf, a_nan, b_nan;
  assign a_zero = (a_bf16[14:7] == 8'd0);
  assign b_zero = (b_bf16[14:7] == 8'd0);
  assign a_inf  = (a_bf16[14:7] == 8'hFF) && (a_bf16[6:0] == 7'd0);
  assign b_inf  = (b_bf16[14:7] == 8'hFF) && (b_bf16[6:0] == 7'd0);
  assign a_nan  = (a_bf16[14:7] == 8'hFF) && (a_bf16[6:0] != 7'd0);
  assign b_nan  = (b_bf16[14:7] == 8'hFF) && (b_bf16[6:0] != 7'd0);

  always_comb begin
    if (a_nan | b_nan)
      product_fp32 = {1'b0, 8'hFF, 1'b1, 22'd0};    // quiet NaN
    else if ((a_inf & b_zero) | (a_zero & b_inf))
      product_fp32 = {1'b0, 8'hFF, 1'b1, 22'd0};    // ∞×0 = NaN
    else if (a_inf | b_inf)
      product_fp32 = {sign_prod, 8'hFF, 23'd0};      // ∞
    else if (a_zero | b_zero)
      product_fp32 = {sign_prod, 8'd0, 23'd0};       // 0
    else
      product_fp32 = {sign_prod, exp_norm, mant_norm, 16'd0}; // normal
  end

  // Pipeline register (C4_MUL_PIPE)
  logic [FP32_W-1:0] prod_r, c_r;
  generate
    if (C4_MUL_PIPE) begin : GEN_PIPE_S
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin prod_r <= 32'd0; c_r <= 32'd0; end
        else begin prod_r <= product_fp32; c_r <= c_fp32; end
      end
    end else begin : GEN_COMB_S
      always_comb begin prod_r = product_fp32; c_r = c_fp32; end
    end
  endgenerate

  // fp32 accumulation: align → add (synthesis infers LUT adder)
  // For proper IEEE 754 fp32 add, use Vivado Floating Point IP.
  // For v1.0 synthesis: simple sign-magnitude approach.
  logic        sign_c, sign_p;
  logic [7:0]  exp_c_f,  exp_p_f;
  logic [23:0] mant_c_f, mant_p_f; // 24-bit with explicit 1

  assign sign_p  = prod_r[31];
  assign exp_p_f = (prod_r[30:23] == 8'd0) ? 8'd1 : prod_r[30:23];
  assign mant_p_f = {1'b1, prod_r[22:0]};

  assign sign_c  = c_r[31];
  assign exp_c_f = (c_r[30:23] == 8'd0) ? 8'd1 : c_r[30:23];
  assign mant_c_f = {1'b1, c_r[22:0]};

  logic [7:0]   exp_diff;
  logic         p_larger;
  logic [7:0]   exp_l;
  logic [24:0]  mant_large, mant_small; // 25-bit for overflow
  logic         sign_large, effective_sub;

  assign p_larger = (exp_p_f >= exp_c_f);
  assign exp_diff = p_larger ? (exp_p_f - exp_c_f) : (exp_c_f - exp_p_f);
  assign exp_l    = p_larger ? exp_p_f : exp_c_f;
  assign mant_large  = p_larger ? {1'b0, mant_p_f} : {1'b0, mant_c_f};
  assign mant_small  = p_larger ? {1'b0, mant_c_f} : {1'b0, mant_p_f};
  assign sign_large  = p_larger ? sign_p : sign_c;
  assign effective_sub = sign_p ^ sign_c;

  // Shift smaller mantissa
  logic [24:0] mant_small_shifted;
  assign mant_small_shifted = (exp_diff >= 8'd25) ? 25'd0 : (mant_small >> exp_diff[4:0]);

  // Add or subtract
  logic [24:0] mant_sum;
  assign mant_sum = effective_sub ? (mant_large - mant_small_shifted) : (mant_large + mant_small_shifted);

  // Normalize result (fixed LZD priority encoder — synthesizable)
  logic [4:0]  lz_count;
  logic [7:0]  exp_result;
  logic [22:0] mant_result;

  always_comb begin
    // LZD: count leading zeros in mant_sum[23:0]
    if      (mant_sum[23]) lz_count = 5'd0;
    else if (mant_sum[22]) lz_count = 5'd1;
    else if (mant_sum[21]) lz_count = 5'd2;
    else if (mant_sum[20]) lz_count = 5'd3;
    else if (mant_sum[19]) lz_count = 5'd4;
    else if (mant_sum[18]) lz_count = 5'd5;
    else if (mant_sum[17]) lz_count = 5'd6;
    else if (mant_sum[16]) lz_count = 5'd7;
    else if (mant_sum[15]) lz_count = 5'd8;
    else if (mant_sum[14]) lz_count = 5'd9;
    else if (mant_sum[13]) lz_count = 5'd10;
    else if (mant_sum[12]) lz_count = 5'd11;
    else if (mant_sum[11]) lz_count = 5'd12;
    else if (mant_sum[10]) lz_count = 5'd13;
    else if (mant_sum[9])  lz_count = 5'd14;
    else if (mant_sum[8])  lz_count = 5'd15;
    else if (mant_sum[7])  lz_count = 5'd16;
    else if (mant_sum[6])  lz_count = 5'd17;
    else if (mant_sum[5])  lz_count = 5'd18;
    else if (mant_sum[4])  lz_count = 5'd19;
    else if (mant_sum[3])  lz_count = 5'd20;
    else if (mant_sum[2])  lz_count = 5'd21;
    else if (mant_sum[1])  lz_count = 5'd22;
    else if (mant_sum[0])  lz_count = 5'd23;
    else                   lz_count = 5'd24; // result is zero

    if (mant_sum[24]) begin
      exp_result  = exp_l + 8'd1;
      mant_result = mant_sum[23:1];
    end else if (|mant_sum[23:0]) begin
      exp_result  = exp_l - {3'd0, lz_count};
      mant_result = mant_sum[22:0] << lz_count;
    end else begin
      exp_result  = 8'd0;
      mant_result = 23'd0;
    end
  end

  assign out_fp32 = {sign_large, exp_result, mant_result};
`endif

endmodule
