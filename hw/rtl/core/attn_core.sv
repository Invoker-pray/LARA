// ============================================================================
// attn_core.sv — FlashAttention FSM Controller v2.0
// ============================================================================
// Improvements (aligned with docs/review/attn_core_fsm_alignment.md):
//   - Position base (cfg_q_pos_base, cfg_kv_pos_base) for causal masking
//   - cfg_causal port, start_ready handshake
//   - ST_ERROR with config validation
//   - active_q_rows / active_kv_cols for partial last tile
//   - sticky done, sticky error
//
// FSM: ST_IDLE→ST_LOAD_KV→ST_Q_INIT→[ST_KV_READ→ST_QK_DOT→ST_SOFTMAX→
//       ST_AV_DOT]*→ST_NORMALIZE→ST_WRITE_O→ST_DONE
// ============================================================================

module attn_core (
    input  logic        clk,
    input  logic        rst_n,

    // --- Host Control ---
    input  logic        start,
    output logic        start_ready,     // high when FSM can accept new start
    input  logic [15:0] seq_len,
    input  logic [15:0] cfg_q_pos_base,  // absolute Q start position
    input  logic [15:0] cfg_kv_pos_base, // absolute K/V start position
    input  logic        cfg_causal,      // enable causal masking
    output logic        done,            // sticky: latched until next start or reset
    output logic        busy,

    // --- Memory Control ---
    output logic        kv_load_start,
    input  logic        kv_load_done,
    output logic        q_load_start,
    input  logic        q_load_done,
    output logic        o_write_start,
    input  logic        o_write_done,

    // --- Compute Control ---
    output logic        mac_phase,
    output logic        mac_start,
    input  logic        mac_done,
    output logic        softmax_start,
    input  logic        softmax_done,
    output logic        kv_tile_first,
    output logic        kv_tile_last,

    // --- Position Output (to softmax_engine for causal masking) ---
    output logic [15:0] q_tile_start,    // absolute Q row start this tile
    output logic [15:0] kv_tile_start,   // absolute K col start this tile
    output logic [4:0]  active_q_rows,   // valid Q rows in this tile (1..TILE_Q)
    output logic [6:0]  active_kv_cols,  // valid K/V cols in this tile (1..TILE_KV)

    // --- Error flag ---
    output logic        error,           // sticky: illegal config detected
    output logic [7:0]  error_code,      // sticky reason code

    // --- Performance Counters ---
    output logic [31:0] cycle_cnt,
    output logic [31:0] mac_cycles
);
  import attn_pkg::*;


  attn_state_t state, next_state;

  logic [7:0]  q_tile_idx, kv_tile_idx;
  logic [1:0]  head_cnt;
  logic [2:0]  group_cnt;
  logic [7:0]  n_q_tiles, n_kv_tiles;

  // Locked config (captured at accepted start)
  logic [15:0] seq_len_r;
  logic [15:0] q_pos_base_r, kv_pos_base_r;
  logic        causal_r;

  // Position computation
  logic [15:0] q_pos_start, kv_pos_start;
  logic [4:0]  active_q;
  logic [6:0]  active_kv;

  always_comb begin
    n_q_tiles  = (seq_len_r + TILE_Q  - 1) / TILE_Q;
    n_kv_tiles = (seq_len_r + TILE_KV - 1) / TILE_KV;
    q_pos_start  = q_pos_base_r + q_tile_idx * TILE_Q;
    kv_pos_start = kv_pos_base_r + kv_tile_idx * TILE_KV;
    // Active rows in current Q tile
    active_q = (q_tile_idx == n_q_tiles - 1 && (seq_len_r % TILE_Q) != 0)
               ? seq_len_r[4:0] - q_tile_idx[4:0] * TILE_Q[4:0]
               : TILE_Q[4:0];
    // Active cols in current KV tile
    active_kv = (kv_tile_idx == n_kv_tiles - 1 && (seq_len_r % TILE_KV) != 0)
                ? seq_len_r[6:0] - kv_tile_idx[6:0] * TILE_KV[6:0]
                : TILE_KV[6:0];
  end

  // Output position + active rows/cols
  assign q_tile_start   = q_pos_start;
  assign kv_tile_start  = kv_pos_start;
  assign active_q_rows  = active_q;
  assign active_kv_cols = active_kv;

  // start_ready: accept only in IDLE
  assign start_ready = (state == ST_IDLE);

  // ==================================================================
  // Config Validation
  // ==================================================================
  logic cfg_valid;
  always_comb begin
    cfg_valid = 1'b1;
    if (seq_len == 16'd0)                         cfg_valid = 1'b0;
    if (seq_len > MAX_SEQ_LEN)                     cfg_valid = 1'b0;
    if (cfg_q_pos_base + seq_len > MAX_SEQ_LEN)   cfg_valid = 1'b0;
    if (cfg_kv_pos_base + seq_len > MAX_SEQ_LEN)  cfg_valid = 1'b0;
    if (seq_len == 16'd0)                          cfg_valid = 1'b0;
  end

  // ==================================================================
  // Performance Counters
  // ==================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cycle_cnt  <= 32'd0;
      mac_cycles <= 32'd0;
    end else begin
      if (state == ST_IDLE) cycle_cnt <= 32'd0;
      else cycle_cnt <= cycle_cnt + 32'd1;
      if (state == ST_QK_DOT || state == ST_AV_DOT)
        mac_cycles <= mac_cycles + 32'd1;
    end
  end

  // ==================================================================
  // FSM Sequential + Counter Logic
  // ==================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= ST_IDLE;
      q_tile_idx  <= 8'd0;
      kv_tile_idx <= 8'd0;
      head_cnt    <= 2'd0;
      group_cnt   <= 3'd0;
      seq_len_r    <= 16'd0;
      q_pos_base_r <= 16'd0;
      kv_pos_base_r<= 16'd0;
      causal_r     <= 1'b0;
      done         <= 1'b0;
      error        <= 1'b0;
      error_code   <= ERR_NONE;
    end else begin
      state <= next_state;

      // Lock config on accepted start
      if (state == ST_IDLE && start && start_ready) begin
        seq_len_r     <= seq_len;
        q_pos_base_r  <= cfg_q_pos_base;
        kv_pos_base_r <= cfg_kv_pos_base;
        causal_r      <= cfg_causal;
        done          <= 1'b0;  // clear sticky done
        error         <= 1'b0;  // clear sticky error
        error_code    <= ERR_NONE;
      end

      case (state)
        ST_LOAD_KV: begin
          if (kv_load_done) begin
            q_tile_idx  <= 8'd0;
            kv_tile_idx <= 8'd0;
          end
        end
        ST_Q_INIT: begin
          if (q_load_done) kv_tile_idx <= 8'd0;
        end
        ST_AV_DOT: begin
          if (mac_done) begin
            if (kv_tile_idx < n_kv_tiles - 1)
              kv_tile_idx <= kv_tile_idx + 8'd1;
          end
        end
        ST_WRITE_O: begin
          if (o_write_done) begin
            if (q_tile_idx < n_q_tiles - 1) begin
              q_tile_idx <= q_tile_idx + 8'd1;
            end else begin
              q_tile_idx <= 8'd0;
              if (head_cnt < 2'd3) begin
                head_cnt <= head_cnt + 2'd1;
              end else begin
                head_cnt <= 2'd0;
                if (group_cnt < 3'd7)
                  group_cnt <= group_cnt + 3'd1;
              end
            end
          end
        end
        ST_DONE: begin
          done <= 1'b1;  // sticky done
        end
        ST_ERROR: begin
          error      <= 1'b1; // sticky error
          error_code <= ERR_BAD_CFG;
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
      ST_IDLE: begin
        if (start && start_ready) begin
          if (!cfg_valid)   next_state = ST_ERROR;
          else              next_state = ST_LOAD_KV;
        end
      end
      ST_LOAD_KV:  if (kv_load_done)    next_state = ST_Q_INIT;
      ST_Q_INIT:   if (q_load_done)     next_state = ST_KV_READ;
      ST_KV_READ:                       next_state = ST_QK_DOT;
      ST_QK_DOT:   if (mac_done)        next_state = ST_SOFTMAX;
      ST_SOFTMAX:  if (softmax_done)    next_state = ST_AV_DOT;
      ST_AV_DOT:   if (mac_done) begin
        if (kv_tile_idx < n_kv_tiles - 1) next_state = ST_KV_READ;
        else                              next_state = ST_NORMALIZE;
      end
      ST_NORMALIZE:                     next_state = ST_WRITE_O;
      ST_WRITE_O:  if (o_write_done) begin
        if (q_tile_idx < n_q_tiles - 1)      next_state = ST_Q_INIT;
        else if (head_cnt < 2'd3)             next_state = ST_Q_INIT;
        else if (group_cnt < 3'd7)            next_state = ST_LOAD_KV;
        else                                  next_state = ST_DONE;
      end
      ST_DONE:                           next_state = ST_IDLE;
      ST_ERROR:                          next_state = ST_IDLE; // wait for reset or new start
      default:                           next_state = ST_IDLE;
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
    busy           = (state != ST_IDLE && state != ST_DONE && state != ST_ERROR);

    case (state)
      ST_LOAD_KV:  if (!kv_load_done) kv_load_start = 1'b1;
      ST_Q_INIT:   if (!q_load_done)  q_load_start  = 1'b1;
      ST_KV_READ: begin
        mac_start     = 1'b1;
        kv_tile_first = (kv_tile_idx == 8'd0);
        kv_tile_last  = (kv_tile_idx == n_kv_tiles - 1);
      end
      ST_QK_DOT: begin
        mac_phase     = 1'b0;
        kv_tile_first = (kv_tile_idx == 8'd0);
        kv_tile_last  = (kv_tile_idx == n_kv_tiles - 1);
      end
      ST_SOFTMAX: begin
        softmax_start = 1'b1;
        kv_tile_first = (kv_tile_idx == 8'd0);
        kv_tile_last  = (kv_tile_idx == n_kv_tiles - 1);
      end
      ST_AV_DOT: begin
        mac_phase     = 1'b1;
        kv_tile_first = (kv_tile_idx == 8'd0);
        kv_tile_last  = (kv_tile_idx == n_kv_tiles - 1);
      end
      ST_WRITE_O: if (!o_write_done) o_write_start = 1'b1;
      default: ;
    endcase
  end

endmodule
