// ============================================================================
// tile_buffer.sv — Q Tile Ping-Pong Buffer
// ============================================================================
// Double-buffers one Q tile (TILE_Q rows × HEAD_DIM bf16) from DDR stream.
// While one buffer receives new data, the other feeds the MAC array.
//
// Capacity: TILE_Q × HEAD_DIM = 32 × 128 = 4096 bf16 = 8 KB per buffer.
// Total: 2 × 8 KB = 16 KB.
// ============================================================================

module tile_buffer
  import attn_pkg::*;
(
    input  logic                       clk,
    input  logic                       rst_n,

    // Write port (streaming from DDR)
    input  logic                       wr_en,
    input  logic [BF16_W-1:0]          wr_data,

    // Read port (to MAC array)
    input  logic                       rd_en,
    input  logic [4:0]                 rd_row,
    input  logic [clog2_safe(TILE_Q / TILE_ROWS)-1:0] rd_row_start,
    input  logic [6:0]                 rd_dim,
    output logic [BF16_W-1:0]          rd_data,
    output logic [BF16_W-1:0]          rd_block_data [TILE_ROWS],

    // Explicit ping-pong bank control
    input  logic                       wr_bank_sel,
    input  logic                       rd_bank_sel,

    // Tile boundary
    output logic                       bank_ready
);

  localparam int BUF_ELEMS         = TILE_Q * HEAD_DIM;
  localparam int MICROTILE_COUNT   = TILE_Q / TILE_ROWS;
  localparam int BANK_DEPTH        = MICROTILE_COUNT * HEAD_DIM;
  localparam int BANK_ADDR_W       = clog2_safe(BANK_DEPTH);
  localparam logic [11:0] BUF_LAST = 12'(BUF_ELEMS - 1);

  logic [4:0] wr_row_idx;
  logic [3:0] wr_row_bank;
  logic [7:0] wr_bank_addr;
  logic [7:0] rd_block_addr;
  logic [11:0] wr_cnt;
  logic        rd_en_d;
  logic        rd_bank_sel_d;
  logic [3:0]  rd_lane_idx_d;

  logic [BF16_W-1:0] buf0_block_word [TILE_ROWS];
  logic [BF16_W-1:0] buf1_block_word [TILE_ROWS];

  assign wr_row_idx    = wr_cnt[11:7];
  assign wr_row_bank   = wr_row_idx[3:0];
  assign wr_bank_addr  = {wr_cnt[11], wr_cnt[6:0]};
  assign rd_block_addr = {rd_row_start, rd_dim};

`ifdef USE_XPM_MEMORY
  localparam int BYTE_LANES = BF16_W / 8;

  function automatic logic [BYTE_LANES-1:0] bf16_byte_we(input logic wr_fire);
    begin
      bf16_byte_we = wr_fire ? {BYTE_LANES{1'b1}} : '0;
    end
  endfunction

`define XPM_QBUF_BANK(INST, WR_FIRE, DOUT_SIG) \
  xpm_memory_sdpram #( \
    .ADDR_WIDTH_A(BANK_ADDR_W), .ADDR_WIDTH_B(BANK_ADDR_W), \
    .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(8), .CASCADE_HEIGHT(0), \
    .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"), \
    .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"), \
    .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"), \
    .MEMORY_SIZE(BANK_DEPTH * BF16_W), .MESSAGE_CONTROL(0), \
    .READ_DATA_WIDTH_B(BF16_W), .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"), \
    .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0), \
    .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"), \
    .WRITE_DATA_WIDTH_A(BF16_W), .WRITE_MODE_B("no_change") \
  ) INST ( \
    .sleep(1'b0), .clka(clk), .ena(WR_FIRE), .wea(bf16_byte_we(WR_FIRE)), .addra(wr_bank_addr), .dina(wr_data), \
    .injectsbiterra(1'b0), .injectdbiterra(1'b0), .clkb(clk), .rstb(1'b0), .enb(rd_en), .regceb(1'b1), \
    .addrb(rd_block_addr), .doutb(DOUT_SIG), .sbiterrb(), .dbiterrb() \
  );

  generate
    for (genvar gb = 0; gb < TILE_ROWS; gb++) begin : GEN_BUF_BANKS
      logic wr_fire0;
      logic wr_fire1;
      assign wr_fire0 = wr_en && !wr_bank_sel && (wr_row_bank == gb[3:0]);
      assign wr_fire1 = wr_en &&  wr_bank_sel && (wr_row_bank == gb[3:0]);
      `XPM_QBUF_BANK(buf0_bank_mem, wr_fire0, buf0_block_word[gb])
      `XPM_QBUF_BANK(buf1_bank_mem, wr_fire1, buf1_block_word[gb])
    end
  endgenerate

`undef XPM_QBUF_BANK

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_en_d       <= 1'b0;
      rd_bank_sel_d <= 1'b0;
      rd_lane_idx_d <= 4'd0;
      rd_data       <= '0;
      for (int bri = 0; bri < TILE_ROWS; bri++) begin
        rd_block_data[bri] <= '0;
      end
    end else begin
      rd_en_d       <= rd_en;
      rd_bank_sel_d <= rd_bank_sel;
      rd_lane_idx_d <= rd_row[3:0];

      if (rd_en_d) begin
        if (!rd_bank_sel_d) begin
          rd_data <= buf0_block_word[rd_lane_idx_d];
          for (int bri = 0; bri < TILE_ROWS; bri++) begin
            rd_block_data[bri] <= buf0_block_word[bri];
          end
        end else begin
          rd_data <= buf1_block_word[rd_lane_idx_d];
          for (int bri = 0; bri < TILE_ROWS; bri++) begin
            rd_block_data[bri] <= buf1_block_word[bri];
          end
        end
      end
    end
  end
`else
  logic [BF16_W-1:0] buf0_scalar_word [TILE_ROWS];
  logic [BF16_W-1:0] buf1_scalar_word [TILE_ROWS];

  genvar gb;
  generate
    for (gb = 0; gb < TILE_ROWS; gb++) begin : GEN_BUF0_BANK
      (* ram_style = "distributed" *) logic [BF16_W-1:0] bank_mem [0:BANK_DEPTH-1];

      always_ff @(posedge clk) begin
        if (wr_en && !wr_bank_sel && (wr_row_bank == gb[3:0]))
          bank_mem[wr_bank_addr] <= wr_data;
      end

      assign buf0_scalar_word[gb] = bank_mem[{rd_row[4], rd_dim}];
      assign buf0_block_word[gb]  = bank_mem[rd_block_addr];
    end

    for (gb = 0; gb < TILE_ROWS; gb++) begin : GEN_BUF1_BANK
      (* ram_style = "distributed" *) logic [BF16_W-1:0] bank_mem [0:BANK_DEPTH-1];

      always_ff @(posedge clk) begin
        if (wr_en && wr_bank_sel && (wr_row_bank == gb[3:0]))
          bank_mem[wr_bank_addr] <= wr_data;
      end

      assign buf1_scalar_word[gb] = bank_mem[{rd_row[4], rd_dim}];
      assign buf1_block_word[gb]  = bank_mem[rd_block_addr];
    end
  endgenerate

  always_comb begin
    rd_data = 16'd0;
    for (int bri = 0; bri < TILE_ROWS; bri++)
      rd_block_data[bri] = 16'd0;

    if (rd_en) begin
      if (!rd_bank_sel) begin
        rd_data = buf0_scalar_word[rd_row[3:0]];
        for (int bri = 0; bri < TILE_ROWS; bri++) begin
          rd_block_data[bri] = buf0_block_word[bri];
        end
      end else begin
        rd_data = buf1_scalar_word[rd_row[3:0]];
        for (int bri = 0; bri < TILE_ROWS; bri++) begin
          rd_block_data[bri] = buf1_block_word[bri];
        end
      end
    end
  end
`endif

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_cnt <= 12'd0;
    end else if (wr_en) begin
      if (wr_cnt == BUF_LAST)
        wr_cnt <= 12'd0;
      else
        wr_cnt <= wr_cnt + 12'd1;
    end
  end

  assign bank_ready = (wr_cnt == BUF_LAST);

endmodule
