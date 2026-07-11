// ============================================================================
// attn_axi_stream_sink.sv -- AXI4-Stream Data Receiver (DDR -> PL)
// ============================================================================
// Receives full-run preload streams from PYNQ DMA. CSR_STREAM_DEST selects K, V,
// or Q storage; CSR_STREAM_LEN is a checker/config value and does not start DMA.
// Each 32-bit AXIS beat carries two bf16 elements, emitted over two cycles.
// ============================================================================

module attn_axi_stream_sink (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [31:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,

    input  logic [1:0]  cfg_dest,
    input  logic [31:0] cfg_len,
    input  logic [3:0]  cfg_burst,

    output logic        data_valid,
    output logic [15:0] data_out,
    output logic        data_last,
    output logic [1:0]  dest_sel,

    output logic [31:0] bytes_received,
    output logic        overflow,
    output logic        underflow,
    output logic        done
);

  import attn_pkg::*;

  logic        have_hi;
  logic [15:0] hi_buf;
  logic        hi_last;
  logic [31:0] byte_cnt;
  logic        in_xfer;

  wire dest_valid = (cfg_dest == STREAM_TO_K_CACHE) ||
                    (cfg_dest == STREAM_TO_V_CACHE) ||
                    (cfg_dest == STREAM_TO_Q_BUF);
  wire [31:0] next_byte_cnt = in_xfer ? (byte_cnt + 32'd4) : 32'd4;

  assign s_axis_tready = !have_hi && !overflow;
  assign bytes_received = byte_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      have_hi        <= 1'b0;
      hi_buf         <= 16'd0;
      hi_last        <= 1'b0;
      byte_cnt       <= 32'd0;
      in_xfer        <= 1'b0;
      data_valid     <= 1'b0;
      data_out       <= 16'd0;
      data_last      <= 1'b0;
      dest_sel       <= STREAM_TO_K_CACHE;
      overflow       <= 1'b0;
      underflow      <= 1'b0;
      done           <= 1'b0;
    end else begin
      data_valid <= 1'b0;
      data_last  <= 1'b0;

      if (have_hi) begin
        data_valid <= 1'b1;
        data_out   <= hi_buf;
        data_last  <= hi_last;
        dest_sel   <= cfg_dest;
        have_hi    <= 1'b0;
      end else if (s_axis_tvalid && s_axis_tready) begin
        if (!in_xfer) begin
          byte_cnt  <= 32'd0;
          done      <= 1'b0;
          overflow  <= 1'b0;
          underflow <= 1'b0;
          in_xfer   <= 1'b1;
        end

        data_valid <= 1'b1;
        data_out   <= s_axis_tdata[15:0];
        data_last  <= 1'b0;
        dest_sel   <= cfg_dest;
        hi_buf     <= s_axis_tdata[31:16];
        hi_last    <= s_axis_tlast;
        have_hi    <= 1'b1;
        byte_cnt   <= next_byte_cnt;

        if (!dest_valid) begin
          overflow <= 1'b1;
        end
        if (next_byte_cnt > cfg_len) begin
          overflow <= 1'b1;
        end
        if (next_byte_cnt == cfg_len && !s_axis_tlast) begin
          overflow <= 1'b1;
        end
        if (s_axis_tlast) begin
          done    <= 1'b1;
          in_xfer <= 1'b0;
          if (next_byte_cnt < cfg_len) begin
            underflow <= 1'b1;
          end
        end
      end
    end
  end

endmodule