// ============================================================================
// attn_axi_lite_slave.sv -- AXI4-Lite CSR Slave
// ============================================================================
// CSR contract follows docs/spec/interfaces.md sections 10-13:
//   * PYNQ DMA is started by software, not by writing CSR_STREAM_LEN.
//   * CSR_STREAM_LEN/RESULT_LEN configure PL-side stream checkers.
//   * CTRL.start is a one-cycle command accepted only when start_ready is high.
//   * done/error/stream_error are sticky until clear_status or next accepted start.
// ============================================================================

module attn_axi_lite_slave (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [13:0] s_axi_awaddr,
    input  logic                   s_axi_awvalid,
    output logic                   s_axi_awready,

    input  logic [31:0]            s_axi_wdata,
    input  logic [ 3:0]            s_axi_wstrb,
    input  logic                   s_axi_wvalid,
    output logic                   s_axi_wready,

    output logic [1:0]             s_axi_bresp,
    output logic                   s_axi_bvalid,
    input  logic                   s_axi_bready,

    input  logic [13:0] s_axi_araddr,
    input  logic                   s_axi_arvalid,
    output logic                   s_axi_arready,

    output logic [31:0]            s_axi_rdata,
    output logic [1:0]             s_axi_rresp,
    output logic                   s_axi_rvalid,
    input  logic                   s_axi_rready,

    output logic                   start,
    output logic [15:0]            seq_len,
    output logic [15:0]            cfg_q_pos_base,
    output logic [15:0]            cfg_kv_pos_base,
    output logic                   cfg_causal,
    output logic [1:0]             stream_dest,
    output logic [31:0]            stream_len,
    output logic [31:0]            result_len,

    input  logic                   start_ready,
    input  logic                   busy,
    input  logic                   done,
    input  logic                   core_error,
    input  logic [7:0]             core_error_code,
    input  logic                   stream_error,
    input  logic [31:0]            cycle_cnt,
    input  logic [31:0]            mac_cycles
);

  import attn_pkg::*;

  logic aw_acked, w_acked;
  logic [13:0] awaddr_r;
  logic [31:0] wdata_r;
  logic [3:0]  wstrb_r;

  logic done_sticky;
  logic error_sticky;
  logic stream_error_sticky;
  logic [7:0] error_code_r;

  assign s_axi_awready = !aw_acked;
  assign s_axi_wready  = !w_acked;

  wire write_fire = aw_acked && w_acked && !s_axi_bvalid;

  function automatic logic [31:0] merge_wstrb(
    input logic [31:0] old_value,
    input logic [31:0] new_value,
    input logic [3:0]  strobe
  );
    logic [31:0] merged;
    begin
      merged = old_value;
      if (strobe[0]) merged[ 7: 0] = new_value[ 7: 0];
      if (strobe[1]) merged[15: 8] = new_value[15: 8];
      if (strobe[2]) merged[23:16] = new_value[23:16];
      if (strobe[3]) merged[31:24] = new_value[31:24];
      return merged;
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_acked <= 1'b0;
      w_acked  <= 1'b0;
      awaddr_r <= '0;
      wdata_r  <= 32'd0;
      wstrb_r  <= 4'h0;
    end else begin
      if (s_axi_awvalid && s_axi_awready) begin
        aw_acked <= 1'b1;
        awaddr_r <= s_axi_awaddr;
      end
      if (s_axi_wvalid && s_axi_wready) begin
        w_acked <= 1'b1;
        wdata_r <= s_axi_wdata;
        wstrb_r <= s_axi_wstrb;
      end
      if (write_fire) begin
        aw_acked <= 1'b0;
        w_acked  <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      start               <= 1'b0;
      seq_len             <= 16'd0;
      cfg_q_pos_base      <= 16'd0;
      cfg_kv_pos_base     <= 16'd0;
      cfg_causal          <= 1'b1;
      stream_dest         <= STREAM_TO_K_CACHE;
      stream_len          <= 32'd0;
      result_len          <= 32'd0;
      done_sticky         <= 1'b0;
      error_sticky        <= 1'b0;
      stream_error_sticky <= 1'b0;
      error_code_r        <= ERR_NONE;
      s_axi_bvalid        <= 1'b0;
      s_axi_bresp         <= 2'b00;
    end else begin
      start <= 1'b0;

      if (done) begin
        done_sticky <= 1'b1;
      end
      if (core_error) begin
        error_sticky <= 1'b1;
        error_code_r <= core_error_code;
      end
      if (stream_error) begin
        stream_error_sticky <= 1'b1;
        if (error_code_r == ERR_NONE) begin
          error_code_r <= ERR_STREAM_LEN;
        end
      end

      if (write_fire) begin
        s_axi_bvalid <= 1'b1;
        s_axi_bresp  <= 2'b00;

        unique case (awaddr_r)
          CSR_CTRL: begin
            if (wdata_r[1]) begin
              done_sticky         <= 1'b0;
              error_sticky        <= 1'b0;
              stream_error_sticky <= 1'b0;
              error_code_r        <= ERR_NONE;
            end
            if (wdata_r[0]) begin
              if (start_ready) begin
                start               <= 1'b1;
                done_sticky         <= 1'b0;
                error_sticky        <= 1'b0;
                stream_error_sticky <= 1'b0;
                error_code_r        <= ERR_NONE;
              end else begin
                error_sticky <= 1'b1;
                error_code_r <= ERR_BUSY_START;
              end
            end
          end
          CSR_SEQ_LEN:     seq_len         <= wdata_r[15:0];
          CSR_Q_POS_BASE:  cfg_q_pos_base  <= wdata_r[15:0];
          CSR_KV_POS_BASE: cfg_kv_pos_base <= wdata_r[15:0];
          CSR_CFG:         cfg_causal      <= wdata_r[0];
          CSR_STREAM_DEST: stream_dest     <= wdata_r[1:0];
          CSR_STREAM_LEN:  stream_len      <= merge_wstrb(stream_len, wdata_r, wstrb_r);
          CSR_RESULT_LEN:  result_len      <= merge_wstrb(result_len, wdata_r, wstrb_r);
          default: ;
        endcase
      end

      if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end
    end
  end

  assign s_axi_arready = !s_axi_rvalid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_axi_rvalid <= 1'b0;
      s_axi_rdata  <= 32'd0;
      s_axi_rresp  <= 2'b00;
    end else begin
      if (s_axi_arvalid && s_axi_arready) begin
        s_axi_rvalid <= 1'b1;
        s_axi_rresp  <= 2'b00;
        unique case (s_axi_araddr)
          CSR_CTRL:            s_axi_rdata <= 32'd0;
          CSR_STATUS:          s_axi_rdata <= {27'd0, stream_error_sticky, error_sticky, done_sticky, busy, start_ready};
          CSR_SEQ_LEN:         s_axi_rdata <= {16'd0, seq_len};
          CSR_Q_POS_BASE:      s_axi_rdata <= {16'd0, cfg_q_pos_base};
          CSR_KV_POS_BASE:     s_axi_rdata <= {16'd0, cfg_kv_pos_base};
          CSR_CFG:             s_axi_rdata <= {31'd0, cfg_causal};
          CSR_ERROR_CODE:      s_axi_rdata <= {24'd0, error_code_r};
          CSR_STREAM_DEST:     s_axi_rdata <= {30'd0, stream_dest};
          CSR_STREAM_LEN:      s_axi_rdata <= stream_len;
          CSR_RESULT_LEN:      s_axi_rdata <= result_len;
          CSR_PERF_CYCLES:     s_axi_rdata <= cycle_cnt;
          CSR_PERF_CYCLES_HI:  s_axi_rdata <= 32'd0;
          CSR_PERF_MAC_CYCLES: s_axi_rdata <= mac_cycles;
          default:             s_axi_rdata <= 32'd0;
        endcase
      end else if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
      end
    end
  end

endmodule