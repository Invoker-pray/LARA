// ============================================================================
// attn_axi_stream_source.sv — AXI4-Stream Data Sender (PL→DDR) v2.1
// ============================================================================
// Packs one bf16 sample per cycle into 32-bit AXIS words.
// Two bf16 values form one full word; an odd trailing sample is zero-padded.
// ============================================================================

module attn_axi_stream_source
  import attn_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    input  logic        data_valid,
    input  logic [15:0] data_in,
    input  logic        data_last,
    output logic        data_ready,

    input  logic [31:0] cfg_len,

    output logic [31:0] m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,

    output logic [31:0] bytes_sent,
    output logic        done
);

  logic [15:0] lo_buf;
  logic        has_lo;
  logic [31:0] out_buf;
  logic        out_valid;
  logic        out_last;
  logic [2:0]  out_bytes;
  logic [31:0] byte_cnt;
  logic [31:0] bytes_sent_r;

  assign data_ready = !has_lo || !out_valid || m_axis_tready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lo_buf    <= 16'd0;
      has_lo    <= 1'b0;
      out_buf   <= 32'd0;
      out_valid <= 1'b0;
      out_last  <= 1'b0;
      out_bytes <= 3'd0;
      byte_cnt  <= 32'd0;
      bytes_sent_r <= 32'd0;
      done      <= 1'b0;
    end else begin
      done <= 1'b0;

      if (out_valid && m_axis_tready) begin
        byte_cnt <= byte_cnt + {29'd0, out_bytes};
        bytes_sent_r <= byte_cnt + {29'd0, out_bytes};
        if (out_last)
          done <= 1'b1;
        out_valid <= 1'b0;
        out_last  <= 1'b0;
        out_bytes <= 3'd0;
      end

      // Accept one bf16 input per cycle. A full 32-bit word is emitted when the
      // second half arrives; a lone final halfword is flushed with zero padding.
      if (data_valid && data_ready) begin
        if (!has_lo && !out_valid)
          bytes_sent_r <= 32'd0;
        if (!has_lo) begin
          if (data_last) begin
            out_buf   <= {16'd0, data_in};
            out_valid <= 1'b1;
            out_last  <= 1'b1;
            out_bytes <= 3'd2;
          end else begin
            lo_buf <= data_in;
            has_lo <= 1'b1;
          end
        end else begin
          out_buf   <= {data_in, lo_buf};
          out_valid <= 1'b1;
          out_last  <= data_last || ((byte_cnt + 32'd4) >= cfg_len);
          out_bytes <= 3'd4;
          has_lo    <= 1'b0;
        end
      end

      if (done) begin
        has_lo   <= 1'b0;
        byte_cnt <= 32'd0;
      end
    end
  end

  assign m_axis_tdata  = out_buf;
  assign m_axis_tvalid = out_valid;
  assign m_axis_tlast  = out_last;
  assign bytes_sent    = bytes_sent_r;

endmodule
