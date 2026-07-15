// ============================================================================
// attn_axi_stream_source.sv - AXI4-Stream DMA output packer
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
  logic have_lo;
  logic [31:0] pending_data;
  logic pending_valid, pending_last;
  logic [2:0] pending_bytes;
  logic [31:0] xfer_len;
  logic [31:0] formed_byte_cnt;
  logic [31:0] emitted_byte_cnt;
  logic [31:0] bytes_sent_r;
  logic in_xfer;
  wire beat_fire = pending_valid && m_axis_tready;

  // Do not accept a new transfer in the cycle that the final beat retires.
  assign data_ready    = !pending_valid || (m_axis_tready && !pending_last);
  assign m_axis_tdata  = pending_data;
  assign m_axis_tvalid = pending_valid;
  assign m_axis_tlast  = pending_last;
  assign bytes_sent    = bytes_sent_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lo_buf        <= 16'd0;
      have_lo       <= 1'b0;
      pending_data  <= 32'd0;
      pending_valid <= 1'b0;
      pending_last  <= 1'b0;
      pending_bytes <= 3'd0;
      xfer_len      <= 32'd0;
      formed_byte_cnt <= 32'd0;
      emitted_byte_cnt <= 32'd0;
      bytes_sent_r  <= 32'd0;
      in_xfer       <= 1'b0;
      done          <= 1'b0;
    end else begin
      done <= 1'b0;

      if (beat_fire) begin
        pending_valid <= 1'b0;
        pending_last  <= 1'b0;
        emitted_byte_cnt <= emitted_byte_cnt + {{29{1'b0}}, pending_bytes};
        if (pending_last) begin
          done             <= 1'b1;
          bytes_sent_r     <= emitted_byte_cnt + {{29{1'b0}}, pending_bytes};
          in_xfer          <= 1'b0;
          emitted_byte_cnt <= 32'd0;
        end
      end

      if (data_valid && data_ready) begin
        if (!in_xfer) begin
          xfer_len         <= cfg_len;
          formed_byte_cnt  <= 32'd0;
          emitted_byte_cnt <= 32'd0;
          bytes_sent_r     <= 32'd0;
          in_xfer          <= 1'b1;
        end

        if (!have_lo) begin
          if (data_last) begin
            pending_data  <= {16'd0, data_in};
            pending_valid <= 1'b1;
            pending_last  <= 1'b1;
            pending_bytes <= 3'd2;
            formed_byte_cnt <= 32'd2;
            have_lo       <= 1'b0;
          end else begin
            lo_buf  <= data_in;
            have_lo <= 1'b1;
          end
        end else begin
          pending_data  <= {data_in, lo_buf};
          pending_valid <= 1'b1;
          pending_last  <= data_last ||
                           ((formed_byte_cnt + 32'd4) >= (in_xfer ? xfer_len : cfg_len));
          pending_bytes <= 3'd4;
          formed_byte_cnt <= formed_byte_cnt + 32'd4;
          have_lo       <= 1'b0;
        end
      end
    end
  end
endmodule
