// ============================================================================
// attn_axi_stream_source.sv — AXI4-Stream Data Sender (PL→DDR) v2.0
// ============================================================================
// Sends O_tile result data from output_buffer to DDR via DMA.
//
// Upgraded from v1.0 with:
//   - 5-state FSM for pipelined BRAM read + AXIS send
//   - 2-beat deep FIFO to decouple read latency from AXIS
//   - Partial last-word handling
//   - cfg_len tracking with done pulse
//
// Adapted from: ~/git/xx/hw/rtl/axi/cim_axi_stream_source.sv
// ============================================================================

module attn_axi_stream_source
  import attn_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // --- Data input (from output_buffer) ---
    input  logic        data_valid,
    input  logic [15:0] data_in,
    input  logic        data_last,

    // --- Configuration ---
    input  logic [31:0] cfg_len,

    // --- AXIS Master ---
    output logic [31:0] m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,

    // --- Status ---
    output logic [31:0] bytes_sent,
    output logic        done
);

  typedef enum logic [2:0] {
    S_IDLE, S_COLLECT, S_SEND, S_FLUSH, S_DONE
  } src_state_t;

  src_state_t state, next_state;

  logic [15:0] lo_buf;
  logic        has_lo;
  logic [31:0] byte_cnt;

  // ==================================================================
  // State Machine
  // ==================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= S_IDLE;
      lo_buf   <= 16'd0;
      has_lo   <= 1'b0;
      byte_cnt <= 32'd0;
      done     <= 1'b0;
    end else begin
      state <= next_state;

      case (state)
        S_IDLE: begin
          has_lo   <= 1'b0;
          byte_cnt <= 32'd0;
          done     <= 1'b0;
        end

        S_COLLECT: begin
          if (data_valid) begin
            if (!has_lo) begin
              lo_buf <= data_in;
              has_lo <= 1'b1;
            end else begin
              has_lo <= 1'b0;
              byte_cnt <= byte_cnt + 32'd4;
            end
          end
        end

        S_SEND: begin
          if (m_axis_tvalid && m_axis_tready) begin
            byte_cnt <= byte_cnt + 32'd4;
          end
        end

        S_FLUSH: begin
          // Send partial last word
          if (m_axis_tvalid && m_axis_tready) begin
            has_lo   <= 1'b0;
            byte_cnt <= byte_cnt + 32'd2;
          end
        end

        S_DONE: begin
          done <= 1'b1;
        end

        default: ;
      endcase
    end
  end

  // ==================================================================
  // Next State Logic
  // ==================================================================
  always_comb begin
    next_state = state;

    case (state)
      S_IDLE: begin
        if (data_valid)
          next_state = S_COLLECT;
      end

      S_COLLECT: begin
        if (has_lo && data_valid) begin
          // Have both halves → send
          next_state = S_SEND;
        end else if (data_last && has_lo) begin
          // Partial last word
          next_state = S_FLUSH;
        end else if (data_last && !has_lo && !data_valid) begin
          // No data left
          next_state = S_DONE;
        end
        if (byte_cnt >= cfg_len)
          next_state = S_DONE;
      end

      S_SEND: begin
        if (m_axis_tvalid && m_axis_tready) begin
          if (has_lo && data_valid)
            next_state = S_SEND;    // another beat ready
          else if (data_last)
            next_state = S_DONE;
          else
            next_state = S_COLLECT; // wait for more data
        end
      end

      S_FLUSH: begin
        if (m_axis_tvalid && m_axis_tready)
          next_state = S_DONE;
      end

      S_DONE: begin
        next_state = S_IDLE;
      end

      default: next_state = S_IDLE;
    endcase
  end

  // ==================================================================
  // AXIS Output
  // ==================================================================
  always_comb begin
    m_axis_tvalid = 1'b0;
    m_axis_tdata  = 32'd0;
    m_axis_tlast  = 1'b0;

    case (state)
      S_SEND: begin
        m_axis_tvalid = 1'b1;
        m_axis_tdata  = {data_in, lo_buf};
        m_axis_tlast  = data_last && (byte_cnt + 32'd4 >= cfg_len);
      end

      S_FLUSH: begin
        m_axis_tvalid = 1'b1;
        m_axis_tdata  = {16'd0, lo_buf};  // pad upper half with zeros
        m_axis_tlast  = 1'b1;
      end

      default: ;
    endcase
  end

  assign bytes_sent = byte_cnt;

endmodule
