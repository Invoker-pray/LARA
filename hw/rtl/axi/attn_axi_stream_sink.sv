// ============================================================================
// attn_axi_stream_sink.sv — AXI4-Stream Data Receiver (DDR→PL)
// ============================================================================
// Receives packed 32-bit AXIS beats, each containing 2 bf16 values:
//   bits[15:0]  = elem0
//   bits[31:16] = elem1
//
// The module converts each accepted AXIS beat into two scalar bf16 output beats
// on successive cycles. This preserves every input element and keeps the rest of
// the datapath scalar, which matches tile_buffer/kv_cache_ram write interfaces.
//
// cfg_len is counted in BYTES of the AXIS input stream, not scalar output bytes.
// done/overflow/underflow therefore track the external DMA transfer contract.
// ============================================================================

module attn_axi_stream_sink
  import attn_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // --- AXIS Slave ---
    input  logic [31:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,

    // --- Configuration (from CSR) ---
    input  logic [1:0]  cfg_dest,
    input  logic [31:0] cfg_len,       // bytes expected on AXIS input
    input  logic [3:0]  cfg_burst,

    // --- Scalar bf16 output ---
    output logic        data_valid,
    output logic [15:0] data_out,
    output logic        data_last,
    output logic [1:0]  dest_sel,

    // --- Status ---
    output logic [31:0] bytes_received,
    output logic        overflow,
    output logic        underflow,
    output logic        done
);

  logic        hold_hi_valid;
  logic [15:0] hold_hi_data;
  logic        hold_hi_last;
  logic [1:0]  hold_dest;
  logic [31:0] byte_cnt;
  (* keep = "true" *) logic unused_cfg_burst;

  assign unused_cfg_burst = &{1'b0, |cfg_burst};

  // Accept a new AXIS beat only when the second half buffer is empty.
  assign s_axis_tready = !hold_hi_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hold_hi_valid <= 1'b0;
      hold_hi_data  <= 16'd0;
      hold_hi_last  <= 1'b0;
      hold_dest     <= 2'd0;
      data_valid    <= 1'b0;
      data_out      <= 16'd0;
      data_last     <= 1'b0;
      dest_sel      <= 2'd0;
      byte_cnt      <= 32'd0;
      overflow      <= 1'b0;
      underflow     <= 1'b0;
      done          <= 1'b0;
    end else begin
      data_valid <= 1'b0;
      data_last  <= 1'b0;

      // Drain second half first when present.
      if (hold_hi_valid) begin
        data_valid    <= 1'b1;
        data_out      <= hold_hi_data;
        data_last     <= hold_hi_last;
        dest_sel      <= hold_dest;
        hold_hi_valid <= 1'b0;
      end

      // Accept a new AXIS beat when possible. Low half is emitted immediately,
      // high half is buffered for the next cycle.
      if (s_axis_tvalid && s_axis_tready) begin
        data_valid    <= 1'b1;
        data_out      <= s_axis_tdata[15:0];
        data_last     <= 1'b0;
        dest_sel      <= cfg_dest;

        hold_hi_valid <= 1'b1;
        hold_hi_data  <= s_axis_tdata[31:16];
        hold_hi_last  <= s_axis_tlast;
        hold_dest     <= cfg_dest;

        byte_cnt <= byte_cnt + 32'd4;

        if (byte_cnt >= cfg_len && !s_axis_tlast)
          overflow <= 1'b1;
        if (s_axis_tlast && (byte_cnt + 32'd4 < cfg_len))
          underflow <= 1'b1;
        if (s_axis_tlast)
          done <= 1'b1;
        else if (byte_cnt == 32'd0)
          done <= 1'b0;
      end
    end
  end

  assign bytes_received = byte_cnt;

endmodule
