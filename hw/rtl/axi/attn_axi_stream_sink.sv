// ============================================================================
// attn_axi_stream_sink.sv - AXI4-Stream DMA input unpacker
// ============================================================================
// One AXIS beat contains {bf16_hi, bf16_lo}. A transfer completion is pulsed
// only after the buffered high half has been delivered to the selected memory.
// This makes K/V/Q request completion unambiguous to the top-level controller.

module attn_axi_stream_sink
  import attn_pkg::*;
(
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
  logic have_hi;
  logic [15:0] hi_buf;
  logic hi_last;
  logic [1:0] xfer_dest;
  logic [31:0] xfer_len;
  logic [31:0] byte_cnt;
  logic in_xfer;
  (* keep = "true" *) logic unused_cfg_burst;

  wire [1:0] accepted_dest = in_xfer ? xfer_dest : cfg_dest;
  wire [31:0] accepted_len = in_xfer ? xfer_len : cfg_len;
  wire dest_valid = (accepted_dest == STREAM_TO_K_CACHE) ||
                    (accepted_dest == STREAM_TO_V_CACHE) ||
                    (accepted_dest == STREAM_TO_Q_BUF);
  wire [31:0] next_byte_cnt = in_xfer ? byte_cnt + 32'd4 : 32'd4;

  assign unused_cfg_burst = &{1'b0, |cfg_burst};
  // Keep draining a malformed transfer through TLAST so AXI DMA cannot wedge.
  assign s_axis_tready = !have_hi;
  assign bytes_received = byte_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      have_hi    <= 1'b0;
      hi_buf     <= 16'd0;
      hi_last    <= 1'b0;
      xfer_dest  <= STREAM_TO_K_CACHE;
      xfer_len   <= 32'd0;
      byte_cnt   <= 32'd0;
      in_xfer    <= 1'b0;
      data_valid <= 1'b0;
      data_out   <= 16'd0;
      data_last  <= 1'b0;
      dest_sel   <= STREAM_TO_K_CACHE;
      overflow   <= 1'b0;
      underflow  <= 1'b0;
      done       <= 1'b0;
    end else begin
      data_valid <= 1'b0;
      data_last  <= 1'b0;
      done       <= 1'b0;

      if (have_hi) begin
        data_valid <= 1'b1;
        data_out   <= hi_buf;
        data_last  <= hi_last;
        dest_sel   <= xfer_dest;
        have_hi    <= 1'b0;
        if (hi_last) begin
          done    <= 1'b1;
          in_xfer <= 1'b0;
          if (byte_cnt < xfer_len)
            underflow <= 1'b1;
        end
      end else if (s_axis_tvalid && s_axis_tready) begin
        if (!in_xfer) begin
          byte_cnt  <= 32'd0;
          overflow  <= 1'b0;
          underflow <= 1'b0;
          xfer_dest <= cfg_dest;
          xfer_len  <= cfg_len;
          in_xfer   <= 1'b1;
        end

        data_valid <= 1'b1;
        data_out   <= s_axis_tdata[15:0];
        data_last  <= 1'b0;
        dest_sel   <= in_xfer ? xfer_dest : cfg_dest;
        hi_buf     <= s_axis_tdata[31:16];
        hi_last    <= s_axis_tlast;
        have_hi    <= 1'b1;
        byte_cnt   <= next_byte_cnt;

        if (!dest_valid || next_byte_cnt > accepted_len ||
            (next_byte_cnt == accepted_len && !s_axis_tlast))
          overflow <= 1'b1;
      end
    end
  end
endmodule
