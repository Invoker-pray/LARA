// ============================================================================
// attn_axi_lite_slave.sv — AXI4-Lite CSR Slave
// ============================================================================
// Provides host access to control/status registers via AXI4-Lite.
// Address map defined in attn_pkg.sv §7.
// Adapted from CIM capstone axi_lite pattern.
// ============================================================================

module attn_axi_lite_slave
  import attn_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // AXI4-Lite Write Address
    input  logic [ CSR_ADDR_W-1:0] s_axi_awaddr,
    input  logic                   s_axi_awvalid,
    output logic                   s_axi_awready,

    // AXI4-Lite Write Data
    input  logic [31:0]            s_axi_wdata,
    input  logic [ 3:0]            s_axi_wstrb,
    input  logic                   s_axi_wvalid,
    output logic                   s_axi_wready,

    // AXI4-Lite Write Response
    output logic [1:0]             s_axi_bresp,
    output logic                   s_axi_bvalid,
    input  logic                   s_axi_bready,

    // AXI4-Lite Read Address
    input  logic [ CSR_ADDR_W-1:0] s_axi_araddr,
    input  logic                   s_axi_arvalid,
    output logic                   s_axi_arready,

    // AXI4-Lite Read Data
    output logic [31:0]            s_axi_rdata,
    output logic [1:0]             s_axi_rresp,
    output logic                   s_axi_rvalid,
    input  logic                   s_axi_rready,

    // CSR Register Interface (to attn_core)
    output logic                   start,
    output logic [15:0]            seq_len,
    output logic                   cfg_causal,
    input  logic [2:0]             gqa_group,
    input  logic [1:0]             q_head,
    output logic [1:0]             stream_dest,
    output logic [31:0]            stream_len,
    output logic [31:0]            result_len,
    input  logic                   done,
    input  logic [31:0]            cycle_cnt,
    input  logic [31:0]            mac_cycles
);

  // Register file
  logic [31:0] reg_file [0:15];
  (* keep = "true" *) logic unused_addr_bits;

  assign unused_addr_bits = &{1'b0,
                              |s_axi_awaddr[CSR_ADDR_W-1:6], |s_axi_awaddr[1:0],
                              |s_axi_araddr[CSR_ADDR_W-1:6], |s_axi_araddr[1:0],
                              |s_axi_wstrb};

  // AXI write logic
  logic aw_acked, w_acked;

  assign s_axi_awready = !aw_acked;
  assign s_axi_wready  = !w_acked;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_acked <= 1'b0;
      w_acked  <= 1'b0;
    end else begin
      if (s_axi_awvalid && s_axi_awready) aw_acked <= 1'b1;
      if (s_axi_wvalid  && s_axi_wready)  w_acked  <= 1'b1;
      if (aw_acked && w_acked) begin
        aw_acked <= 1'b0;
        w_acked  <= 1'b0;
      end
    end
  end

  // Write response
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_axi_bvalid <= 1'b0;
      s_axi_bresp  <= 2'b00;
      for (int i = 0; i < 16; i++)
        reg_file[i] <= 32'd0;
      reg_file[CSR_CTRL[5:2]][2] <= 1'b1;
    end else begin
      if (aw_acked && w_acked && !s_axi_bvalid) begin
        s_axi_bvalid <= 1'b1;
        s_axi_bresp  <= 2'b00;  // OKAY
        reg_file[s_axi_awaddr[5:2]] <= s_axi_wdata;
      end
      if (s_axi_bvalid && s_axi_bready)
        s_axi_bvalid <= 1'b0;

      // Status register updates (read-only from host perspective)
      if (done)
        reg_file[CSR_STATUS[5:2]][0] <= 1'b1;
      if (start)
        reg_file[CSR_STATUS[5:2]][0] <= 1'b0;
      reg_file[CSR_STATUS[5:2]][3:1] <= 3'd0;
      reg_file[CSR_HEAD_IDX[5:2]][4:2] <= gqa_group;
      reg_file[CSR_HEAD_IDX[5:2]][1:0] <= q_head;
      reg_file[CSR_PERF_CYCLES[5:2]] <= cycle_cnt;
      reg_file[CSR_PERF_STALLS[5:2]] <= mac_cycles;
    end
  end

  // AXI read logic
  logic ar_acked;
  assign s_axi_arready = !ar_acked;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ar_acked     <= 1'b0;
      s_axi_rvalid <= 1'b0;
      s_axi_rdata  <= 32'd0;
      s_axi_rresp  <= 2'b00;
    end else begin
      if (s_axi_arvalid && s_axi_arready) ar_acked <= 1'b1;
      if (ar_acked && !s_axi_rvalid) begin
        s_axi_rvalid <= 1'b1;
        s_axi_rdata  <= reg_file[s_axi_araddr[5:2]];
        s_axi_rresp  <= 2'b00;
        ar_acked     <= 1'b0;
      end
      if (s_axi_rvalid && s_axi_rready)
        s_axi_rvalid <= 1'b0;
    end
  end

  // Map registers to control signals
  assign start     = reg_file[CSR_CTRL[5:2]][0];
  assign seq_len   = reg_file[CSR_SEQ_LEN[5:2]][15:0];
  assign cfg_causal = reg_file[CSR_CTRL[5:2]][2];
  assign stream_dest = reg_file[CSR_STREAM_DEST[5:2]][1:0];
  assign stream_len  = reg_file[CSR_STREAM_LEN[5:2]];
  assign result_len  = reg_file[CSR_RESULT_LEN[5:2]];

  // Status registers (merged into write-response always_ff to avoid
  // multiple driver conflict)
  // NOTE: reg_file updates for CSR_STATUS and perf counters happen
  // in the same always_ff as AXI writes above.
  // We use a separate combinational path for read-only status.
  // The performance counters and status bits are updated via the
  // AXI write-response block above (extended to handle reads).

endmodule
