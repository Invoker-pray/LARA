// ============================================================================
// attn_top_wrapper.v — Pure Verilog wrapper for Vivado BD integration
// ============================================================================
// Port directions are AXI4-Lite slave + AXI4-Stream sink + source
// ============================================================================

module attn_top_wrapper (
    clk, rst_n,
    // AXI4-Lite Slave (PS→PL CSR)
    s_axi_awaddr, s_axi_awvalid, s_axi_awready,
    s_axi_wdata,  s_axi_wstrb,  s_axi_wvalid,  s_axi_wready,
    s_axi_bresp,  s_axi_bvalid, s_axi_bready,
    s_axi_araddr, s_axi_arvalid, s_axi_arready,
    s_axi_rdata,  s_axi_rresp,  s_axi_rvalid,  s_axi_rready,
    // AXI4-Stream Sink (DMA→Accelerator data)
    s_axis_tdata, s_axis_tvalid, s_axis_tready, s_axis_tlast,
    // AXI4-Stream Source (Accelerator→DMA data)
    m_axis_tdata, m_axis_tvalid, m_axis_tready, m_axis_tlast
);
  // Clock + Reset
  input  wire        clk, rst_n;
  // AXI4-Lite Slave: host→slave (inputs), slave→host (outputs)
  input  wire [13:0] s_axi_awaddr;
  input  wire        s_axi_awvalid;
  output wire        s_axi_awready;
  input  wire [31:0] s_axi_wdata;
  input  wire [3:0]  s_axi_wstrb;
  input  wire        s_axi_wvalid;
  output wire        s_axi_wready;
  output wire [1:0]  s_axi_bresp;
  output wire        s_axi_bvalid;
  input  wire        s_axi_bready;
  input  wire [13:0] s_axi_araddr;
  input  wire        s_axi_arvalid;
  output wire        s_axi_arready;
  output wire [31:0] s_axi_rdata;
  output wire [1:0]  s_axi_rresp;
  output wire        s_axi_rvalid;
  input  wire        s_axi_rready;
  // AXIS Sink
  input  wire [31:0] s_axis_tdata;
  input  wire        s_axis_tvalid;
  output wire        s_axis_tready;
  input  wire        s_axis_tlast;
  // AXIS Source
  output wire [31:0] m_axis_tdata;
  output wire        m_axis_tvalid;
  input  wire        m_axis_tready;
  output wire        m_axis_tlast;

  attn_top u_top (
    .clk(clk), .rst_n(rst_n),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
    .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready), .s_axis_tlast(s_axis_tlast),
    .m_axis_tdata(m_axis_tdata), .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready), .m_axis_tlast(m_axis_tlast)
  );
endmodule
