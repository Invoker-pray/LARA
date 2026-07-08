// ============================================================================
// tb_bf16_mac.sv — bf16 MAC unit test (103 vectors from Golden Model)
// ============================================================================
// Verifies bf16_mac.sv against pre-computed golden vectors from
// python_godel/attention_golden.py.
//
// Test structure (inherited from tb_cim_tile.sv patterns):
//   - Load 103 random test vectors from VV/data/bf16_mac_vectors.hex
//   - Drive each vector through dut, capture output
//   - Compare against golden expected value
//   - Report pass/fail with error count
//
// Golden Model correspondence:
//   Python: attention_golden.py::bf16_mac()
//   Export:  python attention_golden.py --export-tb-data --module bf16_mac
// ============================================================================

`timescale 1ns / 1ps

module tb_bf16_mac;
  import attn_pkg::*;

  // DUT signals
  logic                clk;
  logic                rst_n;
  logic [BF16_W-1:0]   a_bf16;
  logic [BF16_W-1:0]   b_bf16;
  logic [FP32_W-1:0]   c_fp32;
  logic [FP32_W-1:0]   out_fp32;

  // DUT instantiation
  bf16_mac dut (
    .clk     (clk),
    .rst_n   (rst_n),
    .a_bf16  (a_bf16),
    .b_bf16  (b_bf16),
    .c_fp32  (c_fp32),
    .out_fp32(out_fp32)
  );

  // Clock generation: 100 MHz (10 ns period)
  always #5 clk = ~clk;

  // ==================================================================
  // Test vector storage
  // ==================================================================
  localparam int N_VECTORS = 103;

  logic [15:0] vec_a     [N_VECTORS];
  logic [15:0] vec_b     [N_VECTORS];
  logic [31:0] vec_c     [N_VECTORS];
  logic [31:0] vec_golden[N_VECTORS];

  // ==================================================================
  // Load test vectors from hex file
  // ==================================================================
  task automatic load_vectors();
    int fd, i;
    int scan_result;
    logic [15:0] a_val;
    logic [15:0] b_val;
    logic [31:0] c_val;
    logic [31:0] g_val;

    fd = $fopen("VV/data/bf16_mac_vectors.hex", "r");
    if (fd == 0) begin
      $display("ERROR: Cannot open VV/data/bf16_mac_vectors.hex");
      $display("  Run: python python_godel/attention_golden.py --export-tb-data --module bf16_mac");
      $fatal;
    end

    // Skip header line
    $fgets(fd);

    for (i = 0; i < N_VECTORS; i++) begin
      scan_result = $fscanf(fd, "%h %h %h %h\n", a_val, b_val, c_val, g_val);
      if (scan_result != 4) begin
        $display("ERROR: Failed to read vector %0d from hex file (got %0d values)", i, scan_result);
        $fatal;
      end
      vec_a[i]      = a_val;
      vec_b[i]      = b_val;
      vec_c[i]      = c_val;
      vec_golden[i] = g_val;
    end
    $fclose(fd);
    $display("Loaded %0d test vectors from VV/data/bf16_mac_vectors.hex", N_VECTORS);
  endtask

  // ==================================================================
  // Drive a single test vector and check result
  // ==================================================================
  int err_cnt;
  int test_cnt;

  task automatic run_test(int idx);
    logic [31:0] expected;
    logic [31:0] actual;

    // Drive inputs (bf16 values are stored as upper 16 bits of fp32)
    a_bf16 = vec_a[idx];
    b_bf16 = vec_b[idx];
    c_fp32 = vec_c[idx];
    expected = vec_golden[idx];

    // Wait 2 cycles (matching pipeline depth: Stage1 + Stage2)
    @(posedge clk);
    @(posedge clk);

    // With C4_MUL_PIPE=0 (combinational multiply), result is available after 1 cycle.
    // We wait 2 cycles to be safe for both C4_MUL_PIPE=0 and =1.
    // The golden model produces the correct value regardless of pipeline depth.
    actual = out_fp32;

    if (actual !== expected) begin
      $display("FAIL test %0d:", idx);
      $display("  a=0x%04h  b=0x%04h  c=0x%08h", vec_a[idx], vec_b[idx], vec_c[idx]);
      $display("  got=0x%08h  exp=0x%08h", actual, expected);
      // Show as float for debugging
      $display("  got=%e  exp=%e", $bitstoshortreal(actual), $bitstoshortreal(expected));
      err_cnt++;
    end
    test_cnt++;
  endtask

  // ==================================================================
  // Main test sequence
  // ==================================================================
  initial begin
    err_cnt  = 0;
    test_cnt = 0;

    clk   = 1'b0;
    rst_n = 1'b0;

    $display("============================================");
    $display("TB: bf16_mac — atomic bf16 MAC unit test");
    $display("  TILE_SPLIT_FACTOR = %0d", TILE_SPLIT_FACTOR);
    $display("  C4_MUL_PIPE       = %0d", C4_MUL_PIPE);
    $display("  N_VECTORS         = %0d", N_VECTORS);
    $display("============================================");

    // Load golden test vectors
    load_vectors();

    // Reset
    #20 rst_n = 1'b1;
    @(posedge clk);

    // Run all 103 tests
    $display("Running %0d test vectors...", N_VECTORS);
    for (int i = 0; i < N_VECTORS; i++) begin
      run_test(i);
    end

    // Final report (matches tb_cim_tile.sv output format)
    $display("============================================");
    $display("Total tests: %0d, Errors: %0d", test_cnt, err_cnt);
    if (err_cnt == 0)
      $display(">>> ALL %0d TESTS PASSED <<<", test_cnt);
    else
      $display(">>> %0d TESTS FAILED <<<", err_cnt);
    $display("============================================");

    $finish;
  end

endmodule
