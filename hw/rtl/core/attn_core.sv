// ============================================================================
// attn_core.sv — FlashAttention FSM Controller (Double-Loop Orchestrator)
// ============================================================================
// FSM states (from attn_pkg::attn_state_t):
//   ST_IDLE → ST_LOAD_KV → ST_Q_INIT → [ST_KV_READ → ST_QK_DOT →
//   ST_SOFTMAX → ST_AV_DOT]* → ST_NORMALIZE → ST_WRITE_O → ST_DONE
//
// Loop nest: GQA_groups × Q_heads × Q_tiles × KV_tiles
// ============================================================================

module attn_core
  import attn_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // --- Host Control ---
    input  logic        start,
    input  logic [15:0] seq_len,
    output logic        done,
    output logic        busy,

    // --- Memory Control ---
    output logic        kv_load_start,
    input  logic        kv_load_done,
    output logic        q_load_start,
    input  logic        q_load_done,
    output logic        o_write_start,
    input  logic        o_write_done,

    // --- Compute Control ---
    output logic        mac_phase,      // 0=Q×K^T, 1=P×V
    output logic        mac_start,
    input  logic        mac_done,
    output logic        softmax_start,
    input  logic        softmax_done,
    output logic        kv_tile_first,
    output logic        kv_tile_last,

    // --- Performance Counters ---
    output logic [31:0] cycle_cnt,
    output logic [31:0] mac_cycles
);

  // ==================================================================
  // State Register
  // ==================================================================
  attn_state_t state, next_state;

  // ==================================================================
  // Loop Counters
  // ==================================================================
  logic [7:0]  q_tile_idx;     // 0..N_Q_TILES-1
  logic [7:0]  kv_tile_idx;    // 0..N_KV_TILES-1
  logic [1:0]  head_cnt;       // 0..3 (4 Q heads per GQA group)
  logic [2:0]  group_cnt;      // 0..7 (8 GQA groups)

  logic [7:0] n_q_tiles;
  logic [7:0] n_kv_tiles;

  always_comb begin
    n_q_tiles  = (seq_len + TILE_Q  - 1) / TILE_Q;
    n_kv_tiles = (seq_len + TILE_KV - 1) / TILE_KV;
  end

  // ==================================================================
  // Performance Counters
  // ==================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cycle_cnt  <= 32'd0;
      mac_cycles <= 32'd0;
    end else begin
      if (state == ST_IDLE)
        cycle_cnt <= 32'd0;
      else
        cycle_cnt <= cycle_cnt + 32'd1;
      if (mac_start || state == ST_QK_DOT || state == ST_AV_DOT)
        mac_cycles <= mac_cycles + 32'd1;
    end
  end

  // ==================================================================
  // FSM State Transition + Counter Logic
  // ==================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= ST_IDLE;
      q_tile_idx  <= 8'd0;
      kv_tile_idx <= 8'd0;
      head_cnt    <= 2'd0;
      group_cnt   <= 3'd0;
    end else begin
      state <= next_state;

      case (state)
        ST_LOAD_KV: begin
          if (kv_load_done) begin
            q_tile_idx  <= 8'd0;
            kv_tile_idx <= 8'd0;
          end
        end
        ST_Q_INIT: begin
          if (q_load_done)
            kv_tile_idx <= 8'd0;
        end
        ST_AV_DOT: begin
          if (mac_done) begin
            if (kv_tile_idx < n_kv_tiles - 1)
              kv_tile_idx <= kv_tile_idx + 8'd1;
          end
        end
        ST_WRITE_O: begin
          if (o_write_done) begin
            if (q_tile_idx < n_q_tiles - 1)
              q_tile_idx <= q_tile_idx + 8'd1;
            else begin
              q_tile_idx <= 8'd0;
              if (head_cnt < 2'd3)
                head_cnt <= head_cnt + 2'd1;
              else begin
                head_cnt <= 2'd0;
                if (group_cnt < 3'd7)
                  group_cnt <= group_cnt + 3'd1;
              end
            end
          end
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
      ST_IDLE:     if (start)            next_state = ST_LOAD_KV;
      ST_LOAD_KV:  if (kv_load_done)     next_state = ST_Q_INIT;
      ST_Q_INIT:   if (q_load_done)      next_state = ST_KV_READ;
      ST_KV_READ:                        next_state = ST_QK_DOT;
      ST_QK_DOT:   if (mac_done)         next_state = ST_SOFTMAX;
      ST_SOFTMAX:  if (softmax_done)     next_state = ST_AV_DOT;
      ST_AV_DOT:   if (mac_done) begin
        if (kv_tile_idx < n_kv_tiles - 1)
          next_state = ST_KV_READ;       // next KV tile
        else
          next_state = ST_NORMALIZE;     // last KV tile done
      end
      ST_NORMALIZE:                      next_state = ST_WRITE_O;
      ST_WRITE_O:  if (o_write_done) begin
        if (q_tile_idx < n_q_tiles - 1)
          next_state = ST_Q_INIT;        // next Q tile
        else if (head_cnt < 2'd3)
          next_state = ST_Q_INIT;        // next Q head, same K/V
        else if (group_cnt < 3'd7)
          next_state = ST_LOAD_KV;       // next GQA group
        else
          next_state = ST_DONE;
      end
      ST_DONE:                            next_state = ST_IDLE;
      default:                            next_state = ST_IDLE;
    endcase
  end

  // ==================================================================
  // Control Outputs
  // ==================================================================
  always_comb begin
    kv_load_start  = 1'b0;
    q_load_start   = 1'b0;
    o_write_start  = 1'b0;
    mac_phase      = 1'b0;
    mac_start      = 1'b0;
    softmax_start  = 1'b0;
    kv_tile_first  = 1'b0;
    kv_tile_last   = 1'b0;
    done           = 1'b0;
    busy           = (state != ST_IDLE && state != ST_DONE);

    case (state)
      ST_LOAD_KV:  if (!kv_load_done) kv_load_start = 1'b1;
      ST_Q_INIT:   if (!q_load_done)  q_load_start  = 1'b1;
      ST_KV_READ:  begin
        mac_start      = 1'b1;
        kv_tile_first  = (kv_tile_idx == 8'd0);
        kv_tile_last   = (kv_tile_idx == n_kv_tiles - 1);
      end
      ST_QK_DOT: begin
        mac_phase      = 1'b0;
        kv_tile_first  = (kv_tile_idx == 8'd0);
        kv_tile_last   = (kv_tile_idx == n_kv_tiles - 1);
      end
      ST_SOFTMAX: begin
        softmax_start  = 1'b1;
        kv_tile_first  = (kv_tile_idx == 8'd0);
        kv_tile_last   = (kv_tile_idx == n_kv_tiles - 1);
      end
      ST_AV_DOT: begin
        mac_phase      = 1'b1;
        kv_tile_first  = (kv_tile_idx == 8'd0);
        kv_tile_last   = (kv_tile_idx == n_kv_tiles - 1);
      end
      ST_WRITE_O: if (!o_write_done) o_write_start = 1'b1;
      ST_DONE:    done = 1'b1;
      default: ;
    endcase
  end

endmodule
