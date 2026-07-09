// ============================================================================
// attn_tile.sv — 16×16 bf16 MAC Array (Pipelined v2.0)
// ============================================================================
// Pipeline (MAC_PIPE_STAGES=2):
//   Stage 1: bf16→fp32 expand + multiply (256 parallel, DSP48E2)
//   Stage 2: Column reduction (16-to-1 adder tree) → registered output
// Timing: ~5ns per stage → ≥200 MHz with MAC_PIPE_STAGES=2
// ============================================================================

module attn_tile
  import attn_pkg::*;
(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    phase_sel,
    input  logic [BF16_W-1:0]       row_data [TILE_ROWS],
    input  logic [BF16_W-1:0]       col_data [TILE_COLS],
    input  logic [1:0]              split_phase,
    input  logic                    clear_accum,
    input  logic                    accum_en,
    output logic [FP32_W-1:0]       block_out [TILE_ROWS][TILE_COLS],
    output logic [FP32_W-1:0]       col_out [TILE_COLS]
);

  localparam int ACTIVE_COLS_PER_SPLIT = TILE_COLS / TILE_SPLIT_FACTOR;

  // ==================================================================
  // Stage 1: Multiply (combinational)
  // ==================================================================
  shortreal prod [TILE_ROWS][TILE_COLS];
  shortreal block_acc [TILE_ROWS][TILE_COLS];
  shortreal block_next [TILE_ROWS][TILE_COLS];

`ifndef SYNTHESIS
  always_comb begin
    int ri, ci;
    for (ri = 0; ri < TILE_ROWS; ri++) begin
      for (ci = 0; ci < TILE_COLS; ci++) begin
        shortreal a, b;
        a = $bitstoshortreal({row_data[ri], 16'b0});
        if (split_phase == 2'd0)
          b = (ci < ACTIVE_COLS_PER_SPLIT) ? $bitstoshortreal({col_data[ci], 16'b0}) : shortreal'(0.0);
        else if (split_phase == 2'd1)
          b = (ci >= ACTIVE_COLS_PER_SPLIT) ? $bitstoshortreal({col_data[ci], 16'b0}) : shortreal'(0.0);
        else
          b = $bitstoshortreal({col_data[ci], 16'b0});
        prod[ri][ci] = a * b;
      end
    end
  end

  // ==================================================================
  // Pipeline Registers (Stage 1 → Stage 2)
  // ==================================================================
  shortreal prod_r [TILE_ROWS][TILE_COLS];
  logic    accum_en_r, clear_accum_r;

  generate
    if (MAC_PIPE_STAGES >= 2) begin : GEN_PIPE
      integer r, c;
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          for (r = 0; r < TILE_ROWS; r++)
            for (c = 0; c < TILE_COLS; c++)
              prod_r[r][c] <= shortreal'(0.0);
          accum_en_r <= 1'b0;
          clear_accum_r <= 1'b0;
        end else begin
          for (r = 0; r < TILE_ROWS; r++)
            for (c = 0; c < TILE_COLS; c++)
              prod_r[r][c] <= prod[r][c];
          accum_en_r <= accum_en;
          clear_accum_r <= clear_accum;
        end
      end
    end else begin : GEN_COMB
      integer r, c;
      always_comb begin
        for (r = 0; r < TILE_ROWS; r++)
          for (c = 0; c < TILE_COLS; c++)
            prod_r[r][c] = prod[r][c];
        accum_en_r = accum_en;
        clear_accum_r = clear_accum;
      end
    end
  endgenerate

  always_comb begin
    int ri, ci;
    for (ri = 0; ri < TILE_ROWS; ri++) begin
      for (ci = 0; ci < TILE_COLS; ci++) begin
        block_next[ri][ci] = clear_accum_r ? shortreal'(0.0) : block_acc[ri][ci];
        if (accum_en_r)
          block_next[ri][ci] = block_next[ri][ci] + prod_r[ri][ci];
      end
    end
  end

  // ==================================================================
  // Stage 2: Column Reduction (adder tree → registered output)
  // ==================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    int rr, cc;
    if (!rst_n) begin
      for (rr = 0; rr < TILE_ROWS; rr++)
        for (cc = 0; cc < TILE_COLS; cc++)
          block_acc[rr][cc] <= shortreal'(0.0);
    end else begin
      for (rr = 0; rr < TILE_ROWS; rr++)
        for (cc = 0; cc < TILE_COLS; cc++)
          block_acc[rr][cc] <= block_next[rr][cc];
    end
  end

  always_comb begin
    int rr, cc;
    for (rr = 0; rr < TILE_ROWS; rr++)
      for (cc = 0; cc < TILE_COLS; cc++)
        block_out[rr][cc] = $shortrealtobits(block_acc[rr][cc]);

    for (cc = 0; cc < TILE_COLS; cc++) begin
      if (accum_en_r) begin
        col_out[cc] = $shortrealtobits(
          ((prod_r[0][cc] + prod_r[1][cc]) + (prod_r[2][cc] + (prod_r[3][cc]))) +
          ((prod_r[4][cc] + prod_r[5][cc]) + (prod_r[6][cc] + (prod_r[7][cc]))) +
          ((prod_r[8][cc] + prod_r[9][cc]) + (prod_r[10][cc] + (prod_r[11][cc]))) +
          ((prod_r[12][cc] + prod_r[13][cc]) + (prod_r[14][cc] + (prod_r[15][cc])))
        );
      end else begin
        col_out[cc] = 32'd0;
      end
    end
  end


`else
  // Synthesis: 256 bf16_mac + binary adder tree (4-level, log2=4)
  genvar sr, sc;
  logic [31:0] pe_prod [TILE_ROWS][TILE_COLS];
  logic [31:0] block_acc_bits [TILE_ROWS][TILE_COLS];
  logic [31:0] block_next_bits [TILE_ROWS][TILE_COLS];
  logic        pe_active [TILE_ROWS][TILE_COLS];
  generate
    for (sr = 0; sr < TILE_ROWS; sr++) begin : SYN_ROW
      for (sc = 0; sc < TILE_COLS; sc++) begin : SYN_PE
        assign pe_active[sr][sc] = (split_phase == 2'd0) ? (sc < ACTIVE_COLS_PER_SPLIT) :
                                   (split_phase == 2'd1) ? (sc >= ACTIVE_COLS_PER_SPLIT) :
                                                           1'b1;
        bf16_mac u_pe(.clk, .rst_n, .a_bf16(row_data[sr]), .b_bf16(pe_active[sr][sc] ? col_data[sc] : 16'd0), .c_fp32(32'd0), .out_fp32(pe_prod[sr][sc]));
      end
    end
  endgenerate

  integer ar, ac;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (ar = 0; ar < TILE_ROWS; ar++)
        for (ac = 0; ac < TILE_COLS; ac++)
          block_acc_bits[ar][ac] <= 32'd0;
    end else begin
      for (ar = 0; ar < TILE_ROWS; ar++)
        for (ac = 0; ac < TILE_COLS; ac++)
          block_acc_bits[ar][ac] <= block_next_bits[ar][ac];
    end
  end

  generate
    for (sr = 0; sr < TILE_ROWS; sr++) begin : SYN_BLOCK_OUT
      for (sc = 0; sc < TILE_COLS; sc++) begin : SYN_BLOCK_OUT_COL
        assign block_next_bits[sr][sc] = accum_en
                                       ? fp32_add(clear_accum ? 32'd0 : block_acc_bits[sr][sc], pe_prod[sr][sc])
                                       : (clear_accum ? 32'd0 : block_acc_bits[sr][sc]);
        assign block_out[sr][sc] = block_acc_bits[sr][sc];
      end
    end
    // Binary adder tree per column: log2(16)=4 levels
    for (sc = 0; sc < TILE_COLS; sc++) begin : SYN_REDUCE
      wire [31:0] l0_0 = accum_en ? pe_prod[0][sc] : 32'd0;  wire [31:0] l0_1 = accum_en ? pe_prod[1][sc] : 32'd0;
      wire [31:0] l0_2 = accum_en ? pe_prod[2][sc] : 32'd0;  wire [31:0] l0_3 = accum_en ? pe_prod[3][sc] : 32'd0;
      wire [31:0] l0_4 = accum_en ? pe_prod[4][sc] : 32'd0;  wire [31:0] l0_5 = accum_en ? pe_prod[5][sc] : 32'd0;
      wire [31:0] l0_6 = accum_en ? pe_prod[6][sc] : 32'd0;  wire [31:0] l0_7 = accum_en ? pe_prod[7][sc] : 32'd0;
      wire [31:0] l0_8 = accum_en ? pe_prod[8][sc] : 32'd0;  wire [31:0] l0_9 = accum_en ? pe_prod[9][sc] : 32'd0;
      wire [31:0] l0_10= accum_en ? pe_prod[10][sc] : 32'd0; wire [31:0] l0_11= accum_en ? pe_prod[11][sc] : 32'd0;
      wire [31:0] l0_12= accum_en ? pe_prod[12][sc] : 32'd0; wire [31:0] l0_13= accum_en ? pe_prod[13][sc] : 32'd0;
      wire [31:0] l0_14= accum_en ? pe_prod[14][sc] : 32'd0; wire [31:0] l0_15= accum_en ? pe_prod[15][sc] : 32'd0;
      // Level 1: 16→8
      wire [31:0] l1_0 = fp32_add(l0_0, l0_1);   wire [31:0] l1_1 = fp32_add(l0_2, l0_3);
      wire [31:0] l1_2 = fp32_add(l0_4, l0_5);   wire [31:0] l1_3 = fp32_add(l0_6, l0_7);
      wire [31:0] l1_4 = fp32_add(l0_8, l0_9);   wire [31:0] l1_5 = fp32_add(l0_10, l0_11);
      wire [31:0] l1_6 = fp32_add(l0_12, l0_13); wire [31:0] l1_7 = fp32_add(l0_14, l0_15);
      // Level 2: 8→4
      wire [31:0] l2_0 = fp32_add(l1_0, l1_1); wire [31:0] l2_1 = fp32_add(l1_2, l1_3);
      wire [31:0] l2_2 = fp32_add(l1_4, l1_5); wire [31:0] l2_3 = fp32_add(l1_6, l1_7);
      // Level 3: 4→2
      wire [31:0] l3_0 = fp32_add(l2_0, l2_1); wire [31:0] l3_1 = fp32_add(l2_2, l2_3);
      // Level 4: 2→1
      assign col_out[sc] = fp32_add(l3_0, l3_1);
    end
  endgenerate
`endif // SYNTHESIS

endmodule
