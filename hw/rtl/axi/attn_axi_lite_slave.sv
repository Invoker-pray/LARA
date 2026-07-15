// ============================================================================
// attn_axi_lite_slave.sv - Host control/status register interface
// ============================================================================

module attn_axi_lite_slave
  import attn_pkg::*;
(
    input  logic                   clk,
    input  logic                   rst_n,

    input  logic [CSR_ADDR_W-1:0]  s_axi_awaddr,
    input  logic                   s_axi_awvalid,
    output logic                   s_axi_awready,
    input  logic [31:0]            s_axi_wdata,
    input  logic [3:0]             s_axi_wstrb,
    input  logic                   s_axi_wvalid,
    output logic                   s_axi_wready,
    output logic [1:0]             s_axi_bresp,
    output logic                   s_axi_bvalid,
    input  logic                   s_axi_bready,

    input  logic [CSR_ADDR_W-1:0]  s_axi_araddr,
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
    input  logic                   stream_error,
    input  logic                   kv_load_req,
    input  logic                   q_load_req,
    input  logic                   q_load_bank,
    input  logic [2:0]             kv_req_group,
    input  logic [2:0]             q_req_group,
    input  logic [1:0]             q_req_head,
    input  logic [7:0]             q_req_tile,
    input  logic [31:0]            cycle_cnt,
    input  logic [31:0]            mac_cycles,
    input  logic [31:0]            stall_cycles
);

  logic aw_acked, w_acked;
  logic [CSR_ADDR_W-1:0] awaddr_r;
  logic [31:0] wdata_r;
  logic [3:0] wstrb_r;
  logic done_sticky, error_sticky, stream_error_sticky;
  logic [7:0] error_code_r;

  wire write_fire = aw_acked && w_acked && !s_axi_bvalid;

  function automatic logic [31:0] merge_wstrb(
    input logic [31:0] old_value,
    input logic [31:0] new_value,
    input logic [3:0]  strobe
  );
    logic [31:0] merged;
    begin
      merged = old_value;
      for (int byte_idx = 0; byte_idx < 4; byte_idx++) begin
        if (strobe[byte_idx])
          merged[byte_idx*8 +: 8] = new_value[byte_idx*8 +: 8];
      end
      merge_wstrb = merged;
    end
  endfunction

  function automatic logic [15:0] merge16(
    input logic [15:0] old_value,
    input logic [31:0] new_value,
    input logic [3:0]  strobe
  );
    logic [15:0] merged;
    begin
      merged = old_value;
      if (strobe[0]) merged[7:0]  = new_value[7:0];
      if (strobe[1]) merged[15:8] = new_value[15:8];
      merge16 = merged;
    end
  endfunction

  function automatic logic merge1(
    input logic old_value,
    input logic [31:0] new_value,
    input logic [3:0]  strobe
  );
    merge1 = strobe[0] ? new_value[0] : old_value;
  endfunction

  function automatic logic [1:0] merge2(
    input logic [1:0] old_value,
    input logic [31:0] new_value,
    input logic [3:0]  strobe
  );
    logic [1:0] merged;
    begin
      merged = old_value;
      if (strobe[0]) merged = new_value[1:0];
      merge2 = merged;
    end
  endfunction

  assign s_axi_awready = !aw_acked;
  assign s_axi_wready  = !w_acked;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_acked <= 1'b0;
      w_acked  <= 1'b0;
      awaddr_r <= '0;
      wdata_r  <= 32'd0;
      wstrb_r  <= 4'd0;
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

      if (done)
        done_sticky <= 1'b1;
      if (core_error) begin
        error_sticky <= 1'b1;
        error_code_r <= ERR_BAD_CFG;
      end
      if (stream_error) begin
        stream_error_sticky <= 1'b1;
        if (error_code_r == ERR_NONE)
          error_code_r <= ERR_STREAM_LEN;
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
          CSR_SEQ_LEN:     seq_len         <= merge16(seq_len, wdata_r, wstrb_r);
          CSR_Q_POS_BASE:  cfg_q_pos_base  <= merge16(cfg_q_pos_base, wdata_r, wstrb_r);
          CSR_KV_POS_BASE: cfg_kv_pos_base <= merge16(cfg_kv_pos_base, wdata_r, wstrb_r);
          CSR_CFG:         cfg_causal      <= merge1(cfg_causal, wdata_r, wstrb_r);
          CSR_STREAM_DEST: stream_dest     <= merge2(stream_dest, wdata_r, wstrb_r);
          CSR_STREAM_LEN:  stream_len      <= merge_wstrb(stream_len, wdata_r, wstrb_r);
          CSR_RESULT_LEN:  result_len      <= merge_wstrb(result_len, wdata_r, wstrb_r);
          default: begin end
        endcase
      end

      if (s_axi_bvalid && s_axi_bready)
        s_axi_bvalid <= 1'b0;
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
          CSR_STATUS:          s_axi_rdata <= {25'd0, q_load_req, kv_load_req,
                                                stream_error_sticky, error_sticky,
                                                done_sticky, busy, start_ready};
          CSR_SEQ_LEN:         s_axi_rdata <= {16'd0, seq_len};
          CSR_Q_POS_BASE:      s_axi_rdata <= {16'd0, cfg_q_pos_base};
          CSR_KV_POS_BASE:     s_axi_rdata <= {16'd0, cfg_kv_pos_base};
          CSR_CFG:             s_axi_rdata <= {31'd0, cfg_causal};
          CSR_ERROR_CODE:      s_axi_rdata <= {24'd0, error_code_r};
          CSR_LOAD_REQ: begin
            s_axi_rdata <= 32'd0;
            s_axi_rdata[0]    <= kv_load_req;
            s_axi_rdata[1]    <= q_load_req;
            s_axi_rdata[2]    <= q_load_bank;
            s_axi_rdata[6:4]  <= kv_req_group;
            s_axi_rdata[10:8] <= q_req_group;
            s_axi_rdata[13:12] <= q_req_head;
            s_axi_rdata[23:16] <= q_req_tile;
          end
          CSR_STREAM_DEST:     s_axi_rdata <= {30'd0, stream_dest};
          CSR_STREAM_LEN:      s_axi_rdata <= stream_len;
          CSR_RESULT_LEN:      s_axi_rdata <= result_len;
          CSR_PERF_CYCLES:     s_axi_rdata <= cycle_cnt;
          CSR_PERF_CYCLES_HI:  s_axi_rdata <= 32'd0;
          CSR_PERF_MAC_CYCLES: s_axi_rdata <= mac_cycles;
          CSR_PERF_STALLS:     s_axi_rdata <= stall_cycles;
          default:             s_axi_rdata <= 32'd0;
        endcase
      end else if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
      end
    end
  end

endmodule
