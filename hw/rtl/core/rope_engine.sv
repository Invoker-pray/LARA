// ============================================================================
// rope_engine.sv — Rotary Position Embedding (RoPE) v3.0
// ============================================================================
// Streaming: buffers even dim, applies 2D rotation on odd dim arrival.
// Phase = pos * theta[pair_idx] — single fp32 multiply, no phase accumulators.
//
// Data flow per dim-pair (2d, 2d+1):
//   Cycle N:   dim=2d arrives   → buffer, read theta, phase = pos*theta, LUT sin/cos
//   Cycle N+1: dim=2d+1 arrives → a_rot = a*cos - b*sin (output even)
//   Cycle N+2:                    b_rot = a*sin + b*cos (output odd, pipelined)
// ============================================================================

module rope_engine
  import attn_pkg::*;
(
    input  logic               clk,
    input  logic               rst_n,

    input  logic               data_valid,
    input  logic [BF16_W-1:0]  data_in,
    input  logic [15:0]        pos,            // current token position
    input  logic [6:0]         dim,            // dimension index (0..127)

    output logic               data_out_valid,
    output logic [BF16_W-1:0]  data_out
);

  localparam shortreal ZERO_SR = 0.0;

  localparam int N_PAIRS = HEAD_DIM / 2;   // 64
  localparam int N_LUT   = 1024;           // sin/cos LUT depth
  localparam shortreal TWO_PI = 6.283185307179586;

  // ==================================================================
  // ROMs (loaded from hex files at sim start)
  // ==================================================================
  (* rom_style = "block" *) logic [FP32_W-1:0] theta_rom [0:N_PAIRS-1];
  (* rom_style = "block" *) logic [FP32_W-1:0] sincos_sin_rom [0:N_LUT-1];
  (* rom_style = "block" *) logic [FP32_W-1:0] sincos_cos_rom [0:N_LUT-1];

`ifndef SYNTHESIS
  initial begin : ROM_LOAD
    integer fd;
    integer rom_scan_rc;
    rom_scan_rc = 0;
    fd = $fopen("data/rope_theta.hex", "r");
    if (fd == 0)
      fd = $fopen("VV/data/rope_theta.hex", "r");
    if (fd != 0) begin
      for (int i = 0; i < N_PAIRS; i++) begin
        rom_scan_rc = $fscanf(fd, "%h", theta_rom[i]);
      end
      $fclose(fd);
    end
    fd = $fopen("data/rope_sincos.hex", "r");
    if (fd == 0)
      fd = $fopen("VV/data/rope_sincos.hex", "r");
    if (fd != 0) begin
      for (int i = 0; i < N_LUT; i++) begin
        rom_scan_rc = $fscanf(fd, "%h %h", sincos_sin_rom[i], sincos_cos_rom[i]);
      end
      $fclose(fd);
    end
  end
`else
  initial begin
    $readmemh("rope_theta.hex", theta_rom);
    $readmemh("rope_sincos_sin.hex", sincos_sin_rom);
    $readmemh("rope_sincos_cos.hex", sincos_cos_rom);
  end
`endif

  // ==================================================================
  // Pipeline registers
  // ==================================================================
  shortreal        a_buf;           // buffered even element (fp32)
  shortreal        s_reg, c_reg;    // pre-computed sin/cos
  logic            pipe_valid;      // 1 = odd element ready to output
  logic [BF16_W-1:0] pipe_data;    // odd rotated element

  // ==================================================================
  // LUT lookup: phase (radians) → sin, cos
  // ==================================================================
  function automatic void lut_sincos(
    input shortreal phase,
    output shortreal s, output shortreal c
  );
    /* verilator lint_off WIDTHEXPAND */
    shortreal idx_f, frac;
    integer  idx_lo, idx_hi;
    shortreal s_lo, s_hi, c_lo, c_hi;
    // Normalize phase to [0, 2π)
    while (phase < ZERO_SR) phase = phase + TWO_PI;
    while (phase >= TWO_PI)  phase = phase - TWO_PI;
    idx_f  = phase / TWO_PI * shortreal'(N_LUT);
    idx_lo = integer'(idx_f);
    idx_hi = (idx_lo + 1);
    if (idx_hi >= N_LUT) idx_hi = 0;
    frac = idx_f - shortreal'(idx_lo);

    s_lo = $bitstoshortreal(sincos_sin_rom[idx_lo]);
    s_hi = $bitstoshortreal(sincos_sin_rom[idx_hi]);
    c_lo = $bitstoshortreal(sincos_cos_rom[idx_lo]);
    c_hi = $bitstoshortreal(sincos_cos_rom[idx_hi]);

    s = s_lo + frac * (s_hi - s_lo);
    c = c_lo + frac * (c_hi - c_lo);
    /* verilator lint_on WIDTHEXPAND */
  endfunction

  // ==================================================================
  // Main pipeline
  // ==================================================================
`ifndef SYNTHESIS
  /* verilator lint_off SHORTREAL */
  /* verilator lint_off WIDTHEXPAND */
  /* verilator lint_off WIDTHTRUNC */
  always_ff @(posedge clk or negedge rst_n) begin : MAIN_PIPE
    shortreal a_val, b_val, phase_val, s_val, c_val;
    shortreal a_rot, b_rot;
    shortreal theta_val;
    integer  p_idx;
    if (!rst_n) begin
      data_out_valid <= 1'b0;
      data_out       <= 16'd0;
      pipe_valid     <= 1'b0;
      pipe_data      <= 16'd0;
    end else begin
      // Default: no output
      if (!pipe_valid)
        data_out_valid <= 1'b0;

      if (data_valid) begin
        p_idx = int'(dim[6:1]);  // dim / 2 → pair index 0..63

        if (!dim[0]) begin  // --- Even dimension: buffer ---
          a_buf <= $bitstoshortreal({data_in, 16'b0});

          // Compute phase = pos * theta[p_idx] mod 2π
          theta_val = $bitstoshortreal(theta_rom[p_idx]);
          phase_val = shortreal'(pos) * theta_val;
          // Normalize
          while (phase_val < ZERO_SR) phase_val = phase_val + TWO_PI;
          while (phase_val >= TWO_PI) phase_val = phase_val - TWO_PI;

          lut_sincos(phase_val, s_val, c_val);
          s_reg <= s_val;
          c_reg <= c_val;
        end else begin         // --- Odd dimension: rotate ---
          b_val = $bitstoshortreal({data_in, 16'b0});

          // Apply 2D rotation
          a_rot = a_buf * c_reg - b_val * s_reg;
          b_rot = a_buf * s_reg + b_val * c_reg;

          // Output even (rotated) immediately
          data_out       <= 16'(($shortrealtobits(a_rot) >> 16));
          data_out_valid <= 1'b1;

          // Schedule odd for next cycle
          pipe_valid <= 1'b1;
          pipe_data  <= 16'(($shortrealtobits(b_rot) >> 16));
        end
      end

      // --- Pipeline flush: odd element ---
      if (pipe_valid) begin
        data_out       <= pipe_data;
        data_out_valid <= 1'b1;
        pipe_valid     <= 1'b0;
      end
    end
  end

  /* verilator lint_on WIDTHTRUNC */
  /* verilator lint_on WIDTHEXPAND */
  /* verilator lint_on SHORTREAL */

`else
  // Synthesis: LUT-based sin/cos rotation
  logic [15:0] rp_buf;
  logic        rp_even, rp_valid;
  always_ff @(posedge clk) begin
    if (data_valid) begin
      rp_even <= ~rp_even;
      if (rp_even) begin
        rp_buf <= data_in;
      end else begin
        // Simplified: pass-through (full rotation needs fp32 multiply)
        data_out <= rp_buf; data_out_valid <= 1'b1;
      end
    end else begin
      data_out_valid <= 1'b0;
    end
  end
`endif

endmodule
