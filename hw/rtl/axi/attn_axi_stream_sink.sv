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
    input  logic        desc_queue_enabled,
    input  logic        inband_command_enabled,
    input  logic        desc_valid,
    input  logic [1:0]  desc_dest,
    input  logic [31:0] desc_len,
    output logic        desc_ready,
    input  logic        kv_load_req,
    input  logic        q_load_req,
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
  logic [1:0] segment_dest;
  logic [31:0] segment_len;
  logic [31:0] segment_byte_cnt;
  logic [31:0] total_byte_cnt;
  logic segment_active;
  logic packet_active;
  logic hi_packet_last;
  logic inband_header_valid;
  logic [1:0] inband_header_dest;
  logic [31:0] inband_header_len;
  (* keep = "true" *) logic unused_cfg_burst;

  wire fifo_mode = desc_queue_enabled && !inband_command_enabled;
  wire framed_mode = fifo_mode || inband_command_enabled;
  wire [1:0] accepted_dest = segment_active ? segment_dest : cfg_dest;
  wire [31:0] accepted_len = segment_active ? segment_len : cfg_len;
  wire dest_valid = (accepted_dest == STREAM_TO_K_CACHE) ||
                    (accepted_dest == STREAM_TO_V_CACHE) ||
                    (accepted_dest == STREAM_TO_Q_BUF);
  wire [31:0] next_segment_byte_cnt = segment_active ? segment_byte_cnt + 32'd4 : 32'd4;
  wire segment_boundary = framed_mode &&
                          (next_segment_byte_cnt == accepted_len);
  wire inband_header_dest_valid = (inband_header_dest == STREAM_TO_K_CACHE) ||
                                  (inband_header_dest == STREAM_TO_V_CACHE) ||
                                  (inband_header_dest == STREAM_TO_Q_BUF);
  wire inband_request_ready = !inband_header_dest_valid ||
                              (((inband_header_dest == STREAM_TO_K_CACHE) ||
                                (inband_header_dest == STREAM_TO_V_CACHE)) && kv_load_req) ||
                              ((inband_header_dest == STREAM_TO_Q_BUF) && q_load_req);

  assign unused_cfg_burst = &{1'b0, |cfg_burst};
  // Keep draining a malformed transfer through TLAST so AXI DMA cannot wedge.
  assign desc_ready = fifo_mode && !segment_active && !have_hi;
  assign s_axis_tready = !have_hi &&
                         (inband_command_enabled
                            ? (segment_active || !inband_header_valid)
                            : (!fifo_mode || segment_active));
  assign bytes_received = total_byte_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      have_hi    <= 1'b0;
      hi_buf     <= 16'd0;
      hi_last    <= 1'b0;
      segment_dest <= STREAM_TO_K_CACHE;
      segment_len  <= 32'd0;
      segment_byte_cnt <= 32'd0;
      total_byte_cnt <= 32'd0;
      segment_active <= 1'b0;
      packet_active <= 1'b0;
      hi_packet_last <= 1'b0;
      inband_header_valid <= 1'b0;
      inband_header_dest <= STREAM_TO_K_CACHE;
      inband_header_len <= 32'd0;
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

      if (fifo_mode && !segment_active && !have_hi && desc_valid) begin
        segment_dest <= desc_dest;
        segment_len <= desc_len;
        segment_byte_cnt <= 32'd0;
        segment_active <= 1'b1;
      end

      if (inband_command_enabled && !segment_active && !have_hi &&
          inband_header_valid && inband_request_ready) begin
        segment_dest <= inband_header_dest;
        segment_len <= inband_header_len;
        segment_byte_cnt <= 32'd0;
        segment_active <= 1'b1;
        inband_header_valid <= 1'b0;
      end

      if (have_hi) begin
        data_valid <= 1'b1;
        data_out   <= hi_buf;
        data_last  <= hi_last;
        dest_sel   <= segment_dest;
        have_hi    <= 1'b0;
        if (hi_last) begin
          done    <= 1'b1;
          segment_active <= 1'b0;
          if (segment_byte_cnt < segment_len)
            underflow <= 1'b1;
        end
        if (hi_packet_last)
          packet_active <= 1'b0;
      end else if (s_axis_tvalid && s_axis_tready &&
                   inband_command_enabled && !segment_active) begin
        inband_header_dest <= s_axis_tdata[1:0];
        inband_header_len <= {s_axis_tdata[31:2], 2'b00};
        inband_header_valid <= 1'b1;
        total_byte_cnt <= packet_active ? total_byte_cnt + 32'd4 : 32'd4;
        packet_active <= 1'b1;
        overflow <= 1'b0;
        underflow <= 1'b0;
        if ((s_axis_tdata[1:0] > STREAM_TO_Q_BUF) ||
            (s_axis_tdata[31:2] == 30'd0) || s_axis_tlast)
          overflow <= 1'b1;
      end else if (s_axis_tvalid && s_axis_tready) begin
        if (!segment_active) begin
          segment_byte_cnt <= 32'd0;
          overflow  <= 1'b0;
          underflow <= 1'b0;
          segment_dest <= cfg_dest;
          segment_len  <= cfg_len;
          segment_active <= 1'b1;
        end

        data_valid <= 1'b1;
        data_out   <= s_axis_tdata[15:0];
        data_last  <= 1'b0;
        dest_sel   <= segment_active ? segment_dest : cfg_dest;
        hi_buf     <= s_axis_tdata[31:16];
        hi_last    <= framed_mode ? (segment_boundary || s_axis_tlast)
                                  : s_axis_tlast;
        hi_packet_last <= s_axis_tlast;
        have_hi    <= 1'b1;
        segment_byte_cnt <= next_segment_byte_cnt;
        total_byte_cnt <= packet_active ? total_byte_cnt + 32'd4 : 32'd4;
        packet_active <= 1'b1;

        if (!dest_valid || next_segment_byte_cnt > accepted_len ||
            (!framed_mode && next_segment_byte_cnt == accepted_len && !s_axis_tlast) ||
            (framed_mode && s_axis_tlast && next_segment_byte_cnt != accepted_len))
          overflow <= 1'b1;
      end
    end
  end
endmodule
