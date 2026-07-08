module attn_top
  import attn_pkg::*;
( clk, rst_n, s_axi_awaddr, s_axi_awvalid, s_axi_awready, s_axi_wdata, s_axi_wstrb, s_axi_wvalid, s_axi_wready, s_axi_bresp, s_axi_bvalid, s_axi_bready, s_axi_araddr, s_axi_arvalid, s_axi_arready, s_axi_rdata, s_axi_rresp, s_axi_rvalid, s_axi_rready, s_axis_tdata, s_axis_tvalid, s_axis_tready, s_axis_tlast, m_axis_tdata, m_axis_tvalid, m_axis_tready, m_axis_tlast );
  input logic clk, rst_n;
  input logic [13:0] s_axi_awaddr;
  input logic s_axi_awvalid; output logic s_axi_awready;
  input logic [31:0] s_axi_wdata;
  input logic [3:0] s_axi_wstrb;
  input logic s_axi_wvalid; output logic s_axi_wready;
  output logic [1:0] s_axi_bresp;
  output logic s_axi_bvalid; input logic s_axi_bready;
  input logic [13:0] s_axi_araddr;
  input logic s_axi_arvalid; output logic s_axi_arready;
  output logic [31:0] s_axi_rdata;
  output logic [1:0] s_axi_rresp;
  output logic s_axi_rvalid; input logic s_axi_rready;
  input logic [31:0] s_axis_tdata;
  input logic s_axis_tvalid; output logic s_axis_tready;
  input logic s_axis_tlast;
  output logic [31:0] m_axis_tdata;
  output logic m_axis_tvalid; input logic m_axis_tready;
  output logic m_axis_tlast;
  logic start, done, busy; logic [15:0] seq_len; logic [31:0] cycle_cnt, mac_cycles;
  logic kv_load_start, kv_load_done, q_load_start, q_load_done, o_write_start, o_write_done;
  logic mac_phase, mac_start, mac_done, softmax_start, softmax_done, kv_tile_first, kv_tile_last;
  logic [6:0] depth_cnt; logic depth_last;
  assign depth_last = (depth_cnt == HEAD_DIM - 1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) depth_cnt <= 7'd0;
    else if (!mac_start) depth_cnt <= 7'd0;
    else depth_cnt <= depth_cnt + 7'd1;
  end
  logic axis_valid; logic [15:0] axis_data; logic axis_last;
  logic src_valid, src_last; logic [15:0] src_data;
  logic buf_sel, tile_ready; logic [15:0] q_buf_rd;
  logic [4:0] q_rd_row; logic [6:0] q_rd_dim;
  logic [15:0] k_rd [TILE_KV], v_rd [TILE_KV];
  logic k_wr_en, v_wr_en, k_rd_en, v_rd_en;
  logic [15:0] k_wr_addr, v_wr_addr, k_rd_start, v_rd_start;
  logic [6:0] k_rd_dim, v_rd_dim;
  logic [15:0] mac_row [TILE_ROWS], mac_col [TILE_COLS];
  logic [1:0] mac_split; logic [31:0] mac_col_out [TILE_COLS];
  logic [15:0] p_latch [TILE_ROWS][TILE_COLS];
  logic s_valid, p_valid; logic [31:0] s_block [TILE_ROWS][TILE_COLS];
  logic [31:0] p_block [TILE_ROWS][TILE_COLS];
  logic [31:0] m_state [TILE_ROWS], l_state [TILE_ROWS], correction [TILE_ROWS];
  logic psum_en, psum_clear; logic [31:0] psum_in [TILE_COLS], psum_out [TILE_COLS];
  logic obuf_update, obuf_norm; logic [4:0] obuf_row; logic [31:0] obuf_data [HEAD_DIM];
  genvar grm, gcm, gpi, gslr, gslc, goi, glr, glc;
  generate
    for (glr=0;glr<TILE_ROWS;glr++) for (glc=0;glc<TILE_COLS;glc++) begin:PL
      always_ff @(posedge clk) if(p_valid) p_latch[glr][glc] <= p_block[glr][glc][31:16];
    end
    for (grm=0;grm<TILE_ROWS;grm++) begin:RM assign mac_row[grm] = (!mac_phase) ? q_buf_rd : p_latch[grm][depth_cnt[3:0]]; end
    for (gcm=0;gcm<TILE_COLS;gcm++) begin:CM assign mac_col[gcm] = (!mac_phase) ? k_rd[gcm] : v_rd[gcm]; end
    for (gpi=0;gpi<TILE_COLS;gpi++) begin:PI assign psum_in[gpi] = mac_col_out[gpi]; end
    for (gslr=0;gslr<TILE_ROWS;gslr++) for (gslc=0;gslc<TILE_COLS;gslc++) begin:SB
      always_ff @(posedge clk) if(depth_last && !mac_phase) s_block[gslr][gslc] <= psum_out[gslc];
    end
    for (goi=0;goi<HEAD_DIM;goi++) begin:OB assign obuf_data[goi] = psum_out[goi % TILE_COLS]; end
  endgenerate
  always_ff @(posedge clk) begin s_valid <= (depth_last && !mac_phase); end
  assign mac_split=2'd0; assign obuf_update = depth_last && mac_phase; assign obuf_row=5'd0;
  assign obuf_norm = kv_tile_last; assign mac_done = depth_last;
  assign kv_load_done=tile_ready; assign q_load_done=tile_ready; assign o_write_done=1'b0;
  assign psum_en=1'b1; assign psum_clear = kv_tile_first && depth_cnt==7'd0;
  assign k_wr_en=axis_valid&&kv_load_start; assign v_wr_en=axis_valid&&kv_load_start;
  assign k_wr_addr=16'd0; assign v_wr_addr=16'd0;
  assign k_rd_en=mac_start&&!mac_phase; assign v_rd_en=mac_start&&mac_phase;
  assign k_rd_start=16'd0; assign v_rd_start=16'd0;
  assign k_rd_dim=depth_cnt; assign v_rd_dim=depth_cnt;
  assign q_rd_row=5'd0; assign q_rd_dim=depth_cnt; assign buf_sel=1'b0;
  assign src_last=1'b0;
  attn_axi_lite_slave u_csr(.clk,.rst_n,.s_axi_awaddr,.s_axi_awvalid,.s_axi_awready,.s_axi_wdata,.s_axi_wstrb,.s_axi_wvalid,.s_axi_wready,.s_axi_bresp,.s_axi_bvalid,.s_axi_bready,.s_axi_araddr,.s_axi_arvalid,.s_axi_arready,.s_axi_rdata,.s_axi_rresp,.s_axi_rvalid,.s_axi_rready,.start,.seq_len,.gqa_group(),.q_head(),.done,.cycle_cnt,.mac_cycles);
  attn_axi_stream_sink u_sink(.clk,.rst_n,.s_axis_tdata,.s_axis_tvalid,.s_axis_tready,.s_axis_tlast,.data_valid(axis_valid),.data_out(axis_data),.data_last(axis_last),.cfg_dest(2'd0),.cfg_len(32'd0),.cfg_burst(4'd0),.dest_sel(),.bytes_received(),.overflow(),.underflow(),.done());
  attn_axi_stream_source u_src(.clk,.rst_n,.data_valid(src_valid),.data_in(src_data),.data_last(src_last),.cfg_len(32'd0),.m_axis_tdata,.m_axis_tvalid,.m_axis_tready,.m_axis_tlast,.bytes_sent(),.done());
  attn_core u_fsm(.clk,.rst_n,.start,.seq_len,.done,.busy,.kv_load_start,.kv_load_done,.q_load_start,.q_load_done,.o_write_start,.o_write_done,.mac_phase,.mac_start,.mac_done,.softmax_start,.softmax_done,.kv_tile_first,.kv_tile_last,.cycle_cnt,.mac_cycles);
  kv_cache_ram u_kcache(.clk,.rst_n,.wr_en(k_wr_en),.wr_addr(k_wr_addr),.wr_data(axis_data),.rd_en(k_rd_en),.rd_token_start(k_rd_start),.rd_dim(k_rd_dim),.rd_data(k_rd));
  kv_cache_ram u_vcache(.clk,.rst_n,.wr_en(v_wr_en),.wr_addr(v_wr_addr),.wr_data(axis_data),.rd_en(v_rd_en),.rd_token_start(v_rd_start),.rd_dim(v_rd_dim),.rd_data(v_rd));
  tile_buffer u_qbuf(.clk,.rst_n,.wr_en(1'b0),.wr_data(axis_data),.rd_en(mac_start&&!mac_phase),.rd_row(q_rd_row),.rd_dim(q_rd_dim),.rd_data(q_buf_rd),.buf_sel,.tile_ready);
  attn_tile u_mac(.clk,.rst_n,.phase_sel(mac_phase),.row_data(mac_row),.col_data(mac_col),.split_phase(mac_split),.accum_en(1'b1),.col_out(mac_col_out));
  softmax_engine u_softmax(.clk,.rst_n,.s_valid,.s_data(s_block),.kv_tile_first,.kv_tile_last,.causal_mask_en(1'b1),.q_tile_start(16'd0),.kv_tile_start(16'd0),.m_state,.l_state,.p_valid,.p_data(p_block),.correction,.done(softmax_done));
  psum_accum u_psum(.clk,.rst_n,.clear(psum_clear),.en(psum_en),.tile_col(psum_in),.en_lo(1'b0),.en_hi(1'b0),.col_lo('{default:32'd0}),.col_hi('{default:32'd0}),.en_q0(1'b0),.en_q1(1'b0),.en_q2(1'b0),.en_q3(1'b0),.col_q0('{default:32'd0}),.col_q1('{default:32'd0}),.col_q2('{default:32'd0}),.col_q3('{default:32'd0}),.psum(psum_out));
  output_buffer u_obuf(.clk,.rst_n,.acc_update(obuf_update),.acc_row(obuf_row),.acc_data(obuf_data),.correction(correction),.normalize(obuf_norm),.l_state(l_state),.o_valid(src_valid),.o_row(),.o_dim(),.o_data(src_data));
  rope_engine u_rope(.clk,.rst_n,.data_valid(1'b0),.data_in(16'd0),.pos(16'd0),.dim(7'd0),.data_out_valid(),.data_out());
endmodule
