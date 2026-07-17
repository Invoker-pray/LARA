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

module attn_core
  import attn_pkg::*;
(
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
    output logic        buf_sel,          // Q ping-pong bank select (toggles per Q tile)
    output logic        q_load_bank_sel,  // Which Q bank q_load_start should fill
    output logic        q_ready_bank_sel, // Which Q bank readiness q_load_done refers to
    output logic        o_bank_sel,       // O_acc bank select (toggles per Q tile)
    output logic        group_advance,    // pulse: advance to next GQA group, KV must be reloaded

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
    output logic [5:0]  active_q_rows,   // valid Q rows in this tile (1..TILE_Q)
    output logic [6:0]  active_kv_cols,  // valid K/V cols in this tile (1..TILE_KV)
    output logic        causal_en,       // latched causal configuration
    output logic [2:0]  current_group,   // current GQA group index
    output logic [1:0]  current_head,    // current Q head within group
    output logic [7:0]  current_q_tile,
    output logic [7:0]  current_kv_tile,
    output logic [2:0]  q_req_group,
    output logic [1:0]  q_req_head,
    output logic [7:0]  q_req_tile,

    // --- Error flag ---
    output logic        error,           // sticky: illegal config detected

    // --- Performance Counters ---
    output logic [31:0] cycle_cnt,       // total cycles from start to done
    output logic [31:0] mac_cycles,      // cycles where MAC array is active
    output logic [31:0] stall_cycles,    // cycles waiting for DMA/memory
    output logic        perf_valid       // pulse when performance data is ready
);

  attn_state_t state, next_state;

  logic [7:0]  q_tile_idx, kv_tile_idx;
  logic [1:0]  head_cnt;
  logic [2:0]  group_cnt;
  logic [7:0]  n_q_tiles, n_kv_tiles;
  logic [7:0]  q_tile_last_idx, kv_tile_last_idx;
  logic [7:0]  kv_tile_limit_idx;
  logic        kv_prefetch_issued;
  logic        q_load_inflight;
  logic        q_prefetch_next_tile;
  logic        q_prefetch_next_head_or_group;
  logic        q_prefetch_head_or_group_early;

  localparam logic [15:0] MAX_SEQ_LEN_U16 = 16'(MAX_SEQ_LEN);
  localparam logic [16:0] MAX_SEQ_LEN_U17 = 17'(MAX_SEQ_LEN);
  localparam logic [1:0]  LAST_Q_HEAD     = 2'd3;
  localparam logic [2:0]  LAST_GQA_GROUP  = 3'd7;

  // Locked config (captured at accepted start)
  logic [15:0] seq_len_r;
  logic [15:0] q_pos_base_r, kv_pos_base_r;
  logic        causal_r;

  // Position computation
  logic [15:0] q_pos_start, kv_pos_start;
  logic [5:0]  active_q;
  logic [6:0]  active_kv;

  always_comb begin
    logic [15:0] q_tile_base_u;
    logic [15:0] kv_tile_base_u;
    logic [16:0] q_end_abs_u;
    logic [16:0] kv_delta_u;
    logic [7:0]  causal_tile_idx_u;
    logic [4:0]  q_remainder;
    logic [5:0]  kv_remainder;

    q_tile_base_u = {3'd0, q_tile_idx, 5'd0};
    kv_tile_base_u = {2'd0, kv_tile_idx, 6'd0};
    q_remainder = seq_len_r[4:0];
    kv_remainder = seq_len_r[5:0];

    n_q_tiles  = 8'(seq_len_r[15:5]) + ((q_remainder != 5'd0) ? 8'd1 : 8'd0);
    n_kv_tiles = 8'(seq_len_r[15:6]) + ((kv_remainder != 6'd0) ? 8'd1 : 8'd0);
    q_tile_last_idx  = n_q_tiles  - 8'd1;
    kv_tile_last_idx = n_kv_tiles - 8'd1;
    q_pos_start  = q_pos_base_r + q_tile_base_u;
    kv_pos_start = kv_pos_base_r + kv_tile_base_u;
    // Active rows in current Q tile
    active_q = ((q_tile_idx == q_tile_last_idx) && (q_remainder != 5'd0))
               ? {1'b0, q_remainder}
               : 6'(TILE_Q);
    // Active cols in current KV tile
    active_kv = ((kv_tile_idx == kv_tile_last_idx) && (kv_remainder != 6'd0))
                ? {1'b0, kv_remainder}
                : 7'(TILE_KV);

    // Causal attention never needs a KV tile whose first token is beyond the
    // last active Q token. Keep the diagonal tile even when it is only partly
    // valid; softmax_engine performs the element-level future-token mask there.
    // If q_end is before kv_pos_base, retain tile 0 so the transaction still
    // produces a well-defined all-masked/zero output.
    q_end_abs_u = {1'b0, q_pos_start} + ((active_q == 6'd0) ? 17'd0 : active_q - 6'd1);
    causal_tile_idx_u = 8'd0;
    if (q_end_abs_u >= {1'b0, kv_pos_base_r}) begin
      kv_delta_u = q_end_abs_u - {1'b0, kv_pos_base_r};
      // TILE_KV is fixed at 64 in the deployed geometry, so use a shift
      // rather than inferring a general divider in the controller path.
      causal_tile_idx_u = 8'(kv_delta_u[16:6]);
    end
    if (causal_r && (causal_tile_idx_u < kv_tile_last_idx))
      kv_tile_limit_idx = causal_tile_idx_u;
    else
      kv_tile_limit_idx = kv_tile_last_idx;
  end

  // Output position + active rows/cols
  assign q_tile_start   = q_pos_start;
  assign kv_tile_start  = kv_pos_start;
  assign active_q_rows  = active_q;
  assign active_kv_cols = active_kv;
  assign causal_en      = causal_r;
  assign current_group  = group_cnt;
  assign current_head   = head_cnt;
  assign current_q_tile = q_tile_idx;
  assign current_kv_tile = kv_tile_idx;

  // Describe the Q tile requested by q_load_start. A request may be an
  // overlap prefetch for the next tile/head, so the current loop counters are
  // not always the destination descriptor the host must send.
  always_comb begin
    q_req_group = group_cnt;
    q_req_head  = head_cnt;
    q_req_tile  = q_tile_idx;
    if ((state == ST_QK_DOT || state == ST_SOFTMAX || state == ST_AV_DOT ||
         state == ST_NORMALIZE || state == ST_WRITE_O) && q_prefetch_next_tile) begin
      q_req_tile = q_tile_idx + 8'd1;
    end else if ((state == ST_QK_DOT || state == ST_SOFTMAX || state == ST_AV_DOT ||
                  state == ST_NORMALIZE || state == ST_WRITE_O) &&
                 q_prefetch_next_head_or_group) begin
      q_req_tile = 8'd0;
      if (head_cnt < LAST_Q_HEAD)
        q_req_head = head_cnt + 2'd1;
      else begin
        q_req_head  = 2'd0;
        q_req_group = group_cnt + 3'd1;
      end
    end
  end

  // start_ready: accept only in IDLE
  assign start_ready = (state == ST_IDLE);
  assign q_prefetch_next_tile = kv_tile_last && (q_tile_idx < q_tile_last_idx);
  assign q_prefetch_next_head_or_group =
      (q_tile_idx == q_tile_last_idx) &&
      ((head_cnt < LAST_Q_HEAD) || (group_cnt < LAST_GQA_GROUP));
  assign q_prefetch_head_or_group_early =
      q_prefetch_next_head_or_group && kv_tile_last;
  assign q_load_bank_sel = (((state == ST_QK_DOT) || (state == ST_SOFTMAX) || (state == ST_AV_DOT) ||
                             ((state == ST_NORMALIZE) && (q_tile_idx < q_tile_last_idx)) ||
                             ((state == ST_WRITE_O) && (q_tile_idx < q_tile_last_idx))) &&
                            (q_tile_idx < q_tile_last_idx)) ? ~buf_sel : buf_sel;
  assign q_ready_bank_sel = ((state == ST_WRITE_O) && (q_tile_idx < q_tile_last_idx)) ? ~buf_sel : buf_sel;

  // ==================================================================
  // Config Validation
  // ==================================================================
  logic cfg_valid;
  always_comb begin
    cfg_valid = 1'b1;
    if (seq_len == 16'd0)                           cfg_valid = 1'b0;
    if (seq_len > MAX_SEQ_LEN_U16)                 cfg_valid = 1'b0;
    if ({1'b0, cfg_q_pos_base} + {1'b0, seq_len} > MAX_SEQ_LEN_U17)  cfg_valid = 1'b0;
    if ({1'b0, cfg_kv_pos_base} + {1'b0, seq_len} > MAX_SEQ_LEN_U17) cfg_valid = 1'b0;
  end

  // ==================================================================
  // Performance Counters
  // ==================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cycle_cnt    <= 32'd0;
      mac_cycles   <= 32'd0;
      stall_cycles <= 32'd0;
      perf_valid   <= 1'b0;
    end else begin
      if (state == ST_IDLE) begin
        cycle_cnt    <= 32'd0;
        mac_cycles   <= 32'd0;
        stall_cycles <= 32'd0;
      end else begin
        cycle_cnt <= cycle_cnt + 32'd1;
      end
      if (state == ST_QK_DOT || state == ST_AV_DOT)
        mac_cycles <= mac_cycles + 32'd1;
      // Stall cycles: waiting for external done signals
      if ((state == ST_LOAD_KV && !kv_load_done) ||
          (state == ST_Q_INIT  && !q_load_done)  ||
          (state == ST_WRITE_O && !o_write_done))
        stall_cycles <= stall_cycles + 32'd1;
      // Perf valid pulse at DONE
      if (state == ST_DONE)
        perf_valid <= 1'b1;
      else
        perf_valid <= 1'b0;
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
      causal_r     <= 1'b1;
      buf_sel      <= 1'b0;
      o_bank_sel   <= 1'b0;
      kv_prefetch_issued <= 1'b0;
      q_load_inflight <= 1'b0;
      done         <= 1'b0;
      error        <= 1'b0;
    end else begin
      state <= next_state;

      // Lock config on accepted start
      if (state == ST_IDLE && start && start_ready) begin
        seq_len_r     <= seq_len;
        q_pos_base_r  <= cfg_q_pos_base;
        kv_pos_base_r <= cfg_kv_pos_base;
        causal_r      <= cfg_causal;
        q_tile_idx    <= 8'd0;
        kv_tile_idx   <= 8'd0;
        head_cnt      <= 2'd0;
        group_cnt     <= 3'd0;
        kv_prefetch_issued <= 1'b0;
        q_load_inflight <= 1'b0;
        done          <= 1'b0;  // clear sticky done
        error         <= 1'b0;  // clear sticky error
      end

      if (q_load_done)
        q_load_inflight <= 1'b0;
      else if (q_load_start)
        q_load_inflight <= 1'b1;

      if ((state == ST_LOAD_KV) && kv_load_done)
        kv_prefetch_issued <= 1'b0;
      else if ((state == ST_LOAD_KV) && !kv_prefetch_issued)
        kv_prefetch_issued <= 1'b1;

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
          if (mac_done && kv_tile_last && q_tile_idx < q_tile_last_idx) begin
            // Prefetch next Q tile: q_load_start fires during NORMALIZE+WRITE_O
          end
          if (mac_done) begin
            if (kv_tile_idx < kv_tile_limit_idx)
              kv_tile_idx <= kv_tile_idx + 8'd1;
          end
        end
        ST_WRITE_O: begin
          if (o_write_done) begin
            if (q_tile_idx < q_tile_last_idx) begin
              q_tile_idx <= q_tile_idx + 8'd1;
              kv_tile_idx <= 8'd0;
              buf_sel    <= ~buf_sel;   // toggle Q ping-pong bank
              o_bank_sel <= ~o_bank_sel; // toggle O_acc bank
            end else begin
              q_tile_idx <= 8'd0;
              kv_tile_idx <= 8'd0;
              if (head_cnt < LAST_Q_HEAD) begin
                head_cnt <= head_cnt + 2'd1;
              end else begin
                head_cnt <= 2'd0;
                if (group_cnt < LAST_GQA_GROUP)
                  group_cnt <= group_cnt + 3'd1;
              end
            end
          end
        end
        ST_DONE: begin
          done <= 1'b1;  // sticky done
        end
        ST_ERROR: begin
          error <= 1'b1; // sticky error
        end
        default: begin end
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
      ST_LOAD_KV:  if (kv_load_done) begin
        if (q_load_done) next_state = ST_KV_READ;
        else             next_state = ST_Q_INIT;
      end
      ST_Q_INIT:   if (q_load_done)     next_state = ST_KV_READ;
      ST_KV_READ:                       next_state = ST_QK_DOT;
      ST_QK_DOT:   if (mac_done)        next_state = ST_SOFTMAX;
      ST_SOFTMAX:  if (softmax_done)    next_state = ST_AV_DOT;
      ST_AV_DOT:   if (mac_done) begin
        if (kv_tile_idx < kv_tile_limit_idx) next_state = ST_KV_READ;
        else                              next_state = ST_NORMALIZE;
      end
      ST_NORMALIZE:                     next_state = ST_WRITE_O;
      ST_WRITE_O:  if (o_write_done) begin
        if (q_tile_idx < q_tile_last_idx) begin
          if (q_load_done) next_state = ST_KV_READ;
          else             next_state = ST_Q_INIT;
        end
        else if (head_cnt < LAST_Q_HEAD) begin
          if (q_load_done) next_state = ST_KV_READ;
          else             next_state = ST_Q_INIT;
        end
        else if (group_cnt < LAST_GQA_GROUP)
          next_state = ST_LOAD_KV;
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
    group_advance  = 1'b0;
    busy           = (state != ST_IDLE && state != ST_DONE && state != ST_ERROR);

    case (state)
      ST_LOAD_KV: begin
        if (!kv_load_done && !kv_prefetch_issued)
          kv_load_start = 1'b1;
        if (!q_load_done)
          q_load_start = !q_load_inflight;
      end
      ST_Q_INIT:   if (!q_load_done)  q_load_start  = !q_load_inflight;
      ST_KV_READ: begin
        mac_start     = 1'b1;
        kv_tile_first = (kv_tile_idx == 8'd0);
        kv_tile_last  = (kv_tile_idx == kv_tile_limit_idx);
      end
      ST_QK_DOT: begin
        mac_phase     = 1'b0;
        kv_tile_first = (kv_tile_idx == 8'd0);
        kv_tile_last  = (kv_tile_idx == kv_tile_limit_idx);
        if (q_prefetch_next_tile)
          q_load_start = !q_load_inflight;
      end
      ST_SOFTMAX: begin
        softmax_start = 1'b1;
        kv_tile_first = (kv_tile_idx == 8'd0);
        kv_tile_last  = (kv_tile_idx == kv_tile_limit_idx);
        if (q_prefetch_next_tile)
          q_load_start = !q_load_inflight;
        if (q_prefetch_head_or_group_early)
          q_load_start = !q_load_inflight;
      end
      ST_AV_DOT: begin
        mac_phase     = 1'b1;
        kv_tile_first = (kv_tile_idx == 8'd0);
        kv_tile_last  = (kv_tile_idx == kv_tile_limit_idx);
        if (q_prefetch_next_tile)
          q_load_start = !q_load_inflight;
        if (q_prefetch_head_or_group_early)
          q_load_start = !q_load_inflight;
      end
      ST_NORMALIZE: begin
        o_write_start = 1'b1;
        if ((q_prefetch_next_tile || q_prefetch_next_head_or_group) && !q_load_done)
          q_load_start = !q_load_inflight;
      end
      ST_WRITE_O: begin
        if (!o_write_done)
          o_write_start = 1'b1;
        if ((q_prefetch_next_tile || q_prefetch_next_head_or_group) && !q_load_done)
          q_load_start = !q_load_inflight;
        if (o_write_done && (q_tile_idx == q_tile_last_idx) &&
            (head_cnt == LAST_Q_HEAD) && (group_cnt < LAST_GQA_GROUP))
          group_advance = 1'b1;
      end
      default: begin end
    endcase
  end

endmodule
