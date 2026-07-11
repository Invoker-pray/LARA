// ============================================================================
// attn_axi_stream_source.sv -- AXI4-Stream Data Sender (PL -> DDR)
// ============================================================================
// Packs two bf16 elements into one 32-bit AXIS beat. CSR_RESULT_LEN configures
// the expected output byte length and tlast position; PYNQ DMA recv is still
// started by software, not by this module.
// ============================================================================

module attn_axi_stream_source (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        data_valid,
    input  logic [15:0] data_in,
    input  logic        data_last,

    input  logic [31:0] cfg_len,

    output logic [31:0] m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,

    output logic [31:0] bytes_sent,
    output logic        done
);

  import attn_pkg::*;

  logic [15:0] lo_buf;
  logic        have_lo;
  logic [31:0] pending_data;
  logic        pending_valid;
  logic        pending_last;
  logic [31:0] byte_cnt;

  assign m_axis_tdata  = pending_data;
  assign m_axis_tvalid = pending_valid;
  assign m_axis_tlast  = pending_last;
  assign bytes_sent    = byte_cnt;

  wire beat_fire = pending_valid && m_axis_tready;
  wire [31:0] next_byte_cnt = byte_cnt + 32'd4;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lo_buf        <= 16'd0;
      have_lo       <= 1'b0;
      pending_data  <= 32'd0;
      pending_valid <= 1'b0;
      pending_last  <= 1'b0;
      byte_cnt      <= 32'd0;
      done          <= 1'b0;
    end else begin
      done <= 1'b0;

      if (beat_fire) begin
        byte_cnt      <= next_byte_cnt;
        pending_valid <= 1'b0;
        pending_last  <= 1'b0;
        if (pending_last || next_byte_cnt >= cfg_len) begin
          done <= 1'b1;
        end
      end

      if (!pending_valid && data_valid) begin
        if (!have_lo) begin
          if (data_last) begin
            pending_data  <= {16'd0, data_in};
            pending_valid <= 1'b1;
            pending_last  <= 1'b1;
            have_lo       <= 1'b0;
          end else begin
            lo_buf  <= data_in;
            have_lo <= 1'b1;
          end
        end else begin
          pending_data  <= {data_in, lo_buf};
          pending_valid <= 1'b1;
          pending_last  <= data_last || (next_byte_cnt >= cfg_len);
          have_lo       <= 1'b0;
        end
      end

      if (done && !data_valid && !pending_valid) begin
        byte_cnt <= 32'd0;
      end
    end
  end

endmodule