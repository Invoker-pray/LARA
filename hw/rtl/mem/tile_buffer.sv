// ============================================================================
// tile_buffer.sv — Q Tile Ping-Pong Buffer
// ============================================================================
// Double-buffers one Q tile (TILE_Q rows × HEAD_DIM bf16) from DDR stream.
// While one buffer receives new data, the other feeds the MAC array.
//
// Capacity: TILE_Q × HEAD_DIM = 32 × 128 = 4096 bf16 = 8 KB per buffer.
// Total: 2 × 8 KB = 16 KB (fits in 1-2 BRAMs).
// ============================================================================

module tile_buffer
  import attn_pkg::*;
(
    input  logic                       clk,
    input  logic                       rst_n,

    // Write port (streaming from DDR)
    input  logic                       wr_en,
    input  logic [BF16_W-1:0]          wr_data,       // one bf16 element per cycle

    // Read port (to MAC array)
    input  logic                       rd_en,
    input  logic [4:0]                 rd_row,        // Q row within tile (0..TILE_Q-1)
    input  logic [6:0]                 rd_dim,        // head-dim index (0..HEAD_DIM-1)
    output logic [BF16_W-1:0]          rd_data,

    // Buffer select (controlled by FSM)
    input  logic                       buf_sel,       // 0=write to buf0/read from buf1, 1=write to buf1/read from buf0

    // Tile boundary
    output logic                       tile_ready     // high when current write buffer is full
);

  localparam int BUF_ELEMS = TILE_Q * HEAD_DIM;  // 32 × 128 = 4096

  (* ram_style = "block" *) logic [BF16_W-1:0] buf0 [0:BUF_ELEMS-1];
  (* ram_style = "block" *) logic [BF16_W-1:0] buf1 [0:BUF_ELEMS-1];

  // Write counters
  logic [11:0] wr_cnt;  // 0..4095
  logic        wr_buf_sel;  // which buffer we're writing to

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_cnt <= 12'd0;
    end else if (wr_en) begin
      if (wr_cnt == BUF_ELEMS - 1)
        wr_cnt <= 12'd0;
      else
        wr_cnt <= wr_cnt + 12'd1;
    end
  end

  // Write logic
  always_ff @(posedge clk) begin
    if (wr_en) begin
      if (!buf_sel)
        buf0[wr_cnt] <= wr_data;
      else
        buf1[wr_cnt] <= wr_data;
    end
  end

  // Read logic: read from OTHER buffer
  always_comb begin
    rd_data = 16'd0;
    if (rd_en) begin
      if (!buf_sel)
        rd_data = buf1[rd_row * HEAD_DIM + rd_dim];  // writing buf0, reading buf1
      else
        rd_data = buf0[rd_row * HEAD_DIM + rd_dim];  // writing buf1, reading buf0
    end
  end

  assign tile_ready = (wr_cnt == BUF_ELEMS - 1);

endmodule
