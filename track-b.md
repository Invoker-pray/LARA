---
name: track-b
description: "FPT'26 Track B FPGA Attention Accelerator — coding standard, project conventions, and team coordination. Use when writing or reviewing ANY code."
version: 2.0.0
---

# Track B — FPGA Attention Accelerator Team Collaboration Specification

## Overview

This skill is the **sole source of coding standards** for the FPT'26 Track B project. All team members must follow it when using Claude Code.

**Core principle**: Code written by four different people at different times and in different places should read as if written by a single person.

---

## 0. Skill File Management Rules

**This file is the team's coding contract. Once confirmed, it should not be modified lightly.**

- The standards in this file (`track-b.md`) are binding on all team members. When encountering scenarios not covered by the standard, flexible solutions are allowed, but **this must not be used as an excuse to bypass existing standards**.
- If a genuinely new problem is encountered that the standard cannot cover, or a particular rule is found to be impractical:
  1. **Discuss within the team first** and reach consensus
  2. **A designated maintainer** uniformly modifies this file
  3. Commit message: `docs(skill): <reason for change>`
- **It is forbidden** for an individual to modify this file on their own branch to "make things easier" for the current task without prior discussion. Such behavior causes inconsistent agent behavior guidelines across team members, undermining the uniformity of code style.
- The version number in this file (`version` field) increments with each modification as a change tracker.

**In short: standards constrain code, not thinking; modify standards carefully, not casually.**

---

## 1. Project File Organization

```
LARA/
├── CLAUDE.md                         # Project-level Claude guidance
├── README.md                         # Project overview + environment setup + quick start
├── memory.txt                        # Conversation export log (read-only)
│
├── hw/                               # ──────── Hardware Design ────────
│   ├── rtl/
│   │   ├── pkg/
│   │   │   └── attn_pkg.sv           # ★ Global parameter package (sole parameter source)
│   │   ├── core/                     # Compute core (no AXI protocol dependency)
│   │   │   ├── bf16_mac.sv           # bf16 multiply-accumulate (atomic unit)
│   │   │   ├── attn_tile.sv          # MAC array
│   │   │   ├── softmax_engine.sv     # Softmax hardware engine
│   │   │   ├── psum_accum.sv         # Partial sum accumulator
│   │   │   └── attn_core.sv          # Top-level FSM + FlashAttention loop
│   │   ├── mem/                      # Pure storage modules (no compute logic)
│   │   │   ├── weight_sram.sv        # Weight storage
│   │   │   ├── tile_buffer.sv        # Q/K/V tile double-buffer
│   │   │   └── output_buffer.sv      # Output buffer
│   │   ├── axi/                      # AXI protocol interfaces (storage/compute unaware of AXI)
│   │   │   ├── attn_axi_lite_slave.sv  # AXI4-Lite CSR
│   │   │   ├── attn_axi_stream_sink.sv # AXIS data receive (DDR→PL)
│   │   │   └── attn_axi_stream_source.sv # AXIS result send (PL→DDR)
│   │   └── attn_top.sv               # Top-level wrapper + MUX
│   ├── tb/                           # One TB per module under test
│   │   ├── tb_bf16_mac.sv
│   │   ├── tb_attn_tile.sv
│   │   ├── tb_softmax.sv
│   │   ├── tb_attn_head.sv
│   │   └── tb_attn_e2e.sv
│   ├── scripts/                      # Simulation + build scripts (one run script per TB)
│   │   ├── run_tb_bf16_mac.sh
│   │   ├── run_tb_attn_tile.sh
│   │   ├── run_regression.sh         # Full regression
│   │   └── vivado_build.tcl          # Vivado synthesis
│   └── constraints/
│       └── attn_soc.xdc
│
├── sw/                               # ──────── Software Design ────────
│   ├── attention_golden.py           # ★ bf16 bit-accurate Golden Model
│   ├── attn_driver.py                # PYNQ Python driver
│   ├── extract_weights.py            # .pth → .hex weight export
│   ├── benchmark.py                  # Performance benchmark
│   ├── tests/
│   │   ├── test_golden_model.py      # pytest regression
│   │   └── test_attn_driver.py
│   └── scripts/
│       └── plot_latency.py
│
├── docs/                             # ──────── Documentation ────────
│   ├── architecture.md               # Architecture design document
│   ├── dataflow.md                   # Dataflow details
│   ├── interfaces.md                 # ★ Module interface spec (interface-first)
│   ├── vivado_bd_guide.md            # Vivado Block Design guide
│   └── paper/                        # Paper drafts
│
└── .claude/skills/track-b.md         # This file
```

**Directory separation principles** (inherited from INT8-CIM project experience):

| Directory      | Responsibility                  | Forbidden                                                          |
| -------------- | ------------------------------- | ------------------------------------------------------------------ |
| `hw/rtl/pkg/`  | Parameter package files only    | No functional modules                                              |
| `hw/rtl/core/` | Compute core: MAC, Softmax, FSM | No awareness of AXI protocol                                       |
| `hw/rtl/mem/`  | Pure storage: SRAM/Buffer       | No compute logic                                                   |
| `hw/rtl/axi/`  | AXI protocol interfaces         | Storage/compute modules must not directly depend on this directory |
| `hw/tb/`       | Simulation verification         | Name as `tb_<module_name>.sv`                                      |
| `sw/`          | Pure Python                     | Dependencies limited to `numpy + torch + ml_dtypes + pynq`         |

**Platform portability rules** (inherited from KV260 migration experience):

- All code under `hw/rtl/` is **FPGA-model agnostic** and fully portable
- Changing the platform only requires changes to `hw/scripts/vivado_build.tcl` and `hw/constraints/*.xdc`
- The Python software stack is **platform-agnostic** (only AXI base addresses need changing)

---

## 2. Parameter Management — Unified Parameter Management (★★★ Most Important)

### 2.1 Single Source of Truth Principle

**All configurable parameters must be defined in `hw/rtl/pkg/attn_pkg.sv`. Hardcoding any numeric constants inside RTL modules is forbidden. Defining module-internal `parameter` to replace values from pkg is not allowed.**

```systemverilog
// ✅ Correct — all parameters from pkg
module attn_tile
  import attn_pkg::*;
(
  input logic signed [BF16_EXP_W-1:0] ...
);
  localparam int PHASE_COLS = TILE_COLS / TILE_SPLIT_FACTOR;  // Use localparam for derived values
endmodule

// ❌ Wrong
module attn_tile (...);
  parameter int TILE_ROWS = 16;       // No! Already in pkg
  logic [7:0] exp;                     // No! Use BF16_EXP_W
endmodule
```

### 2.2 Internal Organization of pkg File

`attn_pkg.sv` must be organized in the following layered order (do not reorder):

```systemverilog
package attn_pkg;

  // ==================================================================
  // 1. Tile Geometry — MAC array dimensions
  // ==================================================================
  parameter int TILE_ROWS = 16;
  parameter int TILE_COLS = 16;
  parameter int TILE_ELEMS = TILE_ROWS * TILE_COLS;

  // ==================================================================
  // 2. Pipeline Split — Pipeline splitting (one-click rollback mechanism)
  // ==================================================================
  // SPLIT_FACTOR=1: single-cycle 16-wide (safe ≤60MHz)
  // SPLIT_FACTOR=2: two-cycle 8+8 (target 100-125MHz)
  // SPLIT_FACTOR=4: four-cycle 4+4+4+4 (100+ MHz)
  parameter int TILE_SPLIT_FACTOR = 2;
  parameter bit TILE_MAC_REUSE = 1'b1;     // MAC resource reuse
  parameter bit C4_MUL_PIPE = 1'b0;        // DSP product register

  // ==================================================================
  // 3. Data Widths — Data type widths
  // ==================================================================
  parameter int BF16_EXP_W = 8;
  parameter int BF16_MANT_W = 7;
  parameter int BF16_W = 16;
  parameter int FP32_W = 32;
  parameter int PSUM_W = 32;

  // ==================================================================
  // 4. Attention Parameters — Algorithm parameters
  // ==================================================================
  parameter int MAX_SEQ_LEN = 2048;
  parameter int HEAD_DIM = 128;
  parameter int N_Q_HEADS = 32;
  parameter int N_KV_HEADS = 8;

  // ==================================================================
  // 5. Tiling — Tiling configuration
  // ==================================================================
  parameter int TILE_Q = 32;
  parameter int TILE_KV = 64;

  // ==================================================================
  // 6. Memory Sizing — Auto-derived from the above parameters
  //    Rule: no manual numbers; must derive from upstream parameters via formulas
  // ==================================================================
  parameter int MAX_N_Q_TILES = (MAX_SEQ_LEN + TILE_Q - 1) / TILE_Q;
  parameter int MAX_N_KV_TILES = (MAX_SEQ_LEN + TILE_KV - 1) / TILE_KV;
  parameter int WSRAM_DEPTH = MAX_N_Q_TILES * MAX_N_KV_TILES;

  // ==================================================================
  // 7. CSR Address Map — Control registers
  // ==================================================================
  parameter logic [13:0] CSR_CTRL            = 14'h000;
  parameter logic [13:0] CSR_STATUS          = 14'h004;
  // ... all CSR addresses
  parameter logic [13:0] CSR_STREAM_DEST     = 14'h050;
  parameter logic [13:0] CSR_STREAM_LEN      = 14'h054;
  parameter logic [13:0] CSR_RESULT_LEN      = 14'h060;

  // ==================================================================
  // 8. FSM State Enum — State machine
  // ==================================================================
  typedef enum logic [5:0] {
    ST_IDLE,
    ST_LOAD_WT,
    // ...
    ST_DONE
  } attn_state_t;

  // ==================================================================
  // 9. Helper Functions — Utility functions
  // ==================================================================
  function automatic int clog2_safe(input int val);
    if (val <= 1) return 1;
    else return $clog2(val);
  endfunction

endpackage
```

### 2.3 Parameter Naming Dictionary

| Type                  | Naming Convention               | Example                         |
| --------------------- | ------------------------------- | ------------------------------- |
| Compile-time constant | `UPPER_SNAKE_CASE`              | `TILE_ROWS`, `MAX_SEQ_LEN`      |
| Data width            | `<TYPE>_W`                      | `BF16_W`, `FP32_W`, `PSUM_W`    |
| CSR address           | `CSR_<NAME>`                    | `CSR_CTRL`, `CSR_STREAM_LEN`    |
| FSM state             | `ST_<ACTION>`                   | `ST_IDLE`, `ST_COMPUTE`         |
| Enum type             | `lower_snake_case` + `_t`       | `attn_state_t`, `stream_dest_t` |
| Local derived         | `lower_snake_case` (localparam) | `phase_cols`, `wsram_aw`        |

### 2.4 One-Click Rollback Mechanism (inherited from CIM's SPLIT_FACTOR design)

Any performance optimization parameter must preserve a rollback path:

```systemverilog
// In pkg, set default to safe value
parameter int TILE_SPLIT_FACTOR = 1;   // 1=safe low-frequency, 2/4=high-frequency optimization

// Preserve all paths in generate blocks
generate
  if (TILE_SPLIT_FACTOR == 1) begin : GEN_SAFE
    // Safe path, relaxed timing
  end else begin : GEN_FAST
    // Optimized path
  end
endgenerate
```

Switching back to safe mode only requires changing one parameter value in pkg — no RTL code changes needed.

---

## 3. Behavioral Guidelines

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

### 3.1 Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 3.2 Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3.3 Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

### 3.4 Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

### 3.5 Design Decision Documentation (learned from C3 design documents)

Core design decisions must be documented, including:

- **Approach A vs. Approach B comparison** (with tradeoff table)
- **Final chosen approach + rationale**
- **Rejected approaches + reasons for rejection**

```
Example ──────────────────────────────────────────
Decision: cfg_start trigger mechanism

Approach A (chosen): Write CSR_STREAM_LEN as implicit trigger
  Rationale: atomic, saves one CSR write

Approach B (rejected): Separate CSR_STREAM_CTRL bit-write pulse
  Rejection reason: adds 1.5µs overhead × N times/inference
──────────────────────────────────────────────
```

---

## 4. SystemVerilog Coding Conventions

### 4.1 File Header Comment

```systemverilog
// ============================================================================
// <module_name>.sv — <one-line functional description>
// ============================================================================
// <detailed description, in English>
//
// Key design decisions:
//   1. <decision + rationale>
//   2. <decision + rationale>
//
// Correspondence with Golden Model:
//   Python: attention_golden.py::<function_name>()
//   Verification: tb_<module_name>.sv
// ============================================================================
```

### 4.2 Module Declaration Format

```systemverilog
module module_name
  import attn_pkg::*;              // import immediately after module
#(
    parameter int DEPTH = 64       // overridable parameters defaulting to pkg values
) (
    input  logic        clk,       // clock first
    input  logic        rst_n,     // active-low uses _n suffix

    // --- Control Interface ---     port grouping comments, no blank-line stacking
    input  logic        start,
    output logic        busy,
    output logic        done,

    // --- Data Input ---
    input  logic [15:0] data_in,

    // --- Data Output ---
    output logic [31:0] data_out
);
```

Port order: **clock/reset → control → config → data input → data output → status**

### 4.3 Signal Declaration and Naming

```systemverilog
// Group declarations by type, with comment separators
localparam int ADDR_W = clog2_safe(MAX_DEPTH);
localparam int PHASE_COLS = TILE_COLS / TILE_SPLIT_FACTOR;

// FSM state
attn_state_t state, state_nxt;

// Counters
logic [15:0] ob_group, ob_group_nxt;

// Data registers
logic signed [BF16_W-1:0] a_bf16;
logic [FP32_W-1:0] acc_fp32;
```

| Suffix/Prefix | Meaning          | Example                     |
| ------------- | ---------------- | --------------------------- |
| `_n`          | Active-low       | `rst_n`, `ready_n`          |
| `_nxt`        | Next-cycle value | `state_nxt`, `ob_group_nxt` |
| `_r`          | Register output  | `w_rd_addr_r`               |
| `_idx`        | Index            | `tile_idx`                  |
| `_cnt`        | Counter          | `beat_cnt`                  |
| `_en`         | Enable           | `wr_en`                     |

### 4.4 Two-Process FSM Pattern

```systemverilog
// Process 1: Sequential logic — state registers + data registers
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    state <= ST_IDLE;
    ob_group <= '0;
  end else begin
    state <= state_nxt;
    ob_group <= ob_group_nxt;
    // Latch data in specific states
    if (state == ST_WAIT_SRAM) w_tile_reg <= w_rd_tile;
  end
end

// Process 2: Combinational logic — next state + outputs
always_comb begin
  // ⚠️ Assign defaults first to prevent latches
  state_nxt = state;
  ob_group_nxt = ob_group;
  busy = 1'b0;
  done = 1'b0;

  case (state)
    ST_IDLE: if (start) begin
      ob_group_nxt = '0;
      state_nxt = ST_NEXT;
    end
    // ...
    default: state_nxt = ST_IDLE;
  endcase
end
```

**FSM rules**:

- Two-process: `always_ff` for state registers, `always_comb` for next state and outputs
- **Assign defaults first** in the combinational process (this is key to preventing latches)
- `case` `default` returns to `ST_IDLE`
- State names use verb phrases: `ST_LOAD_WT`, `ST_COMPUTE_QKV`

### 4.5 Generate Blocks

```systemverilog
genvar g;
generate
  for (g = 0; g < PAR_LEL; g++) begin : GEN_TILE   // ← must have label
    attn_tile u_tile (.clk(clk), .x_eff(x_eff_latched), ...);
  end

  if (SPLIT_FACTOR == 2) begin : GEN_SPLIT2          // ← compile-time selection
    // 8+8 split path
  end else begin : GEN_MONO
    // 16-wide single-cycle path
  end
endgenerate
```

### 4.6 Synthesis Attributes

```systemverilog
(* ram_style = "block" *) logic [127:0] bank_mem[DEPTH];  // Force BRAM
(* use_dsp = "yes" *) logic signed [31:0] mac_product;     // Force DSP
(* max_fanout = 50 *) logic [15:0] high_fanout_signal;     // Fanout constraint
```

### 4.7 Operations and Bit Widths

```systemverilog
// Explicit sign
assign x_full = $signed({1'b0, x_uint8}) - input_zp;

// Explicit bit widths (avoid implicit truncation)
assign w_addr = ({16'd0, ob} + {28'd0, fc}) * {16'd0, cfg_n_ib};

// Bit selection uses +: syntax
assign byte_val = rd_word[gc*W+:W];       // ✅
```

### 4.8 Comments — Explain WHY, not WHAT

```systemverilog
// C4 fix: x_eff is now SIGNED. Previous impl clamped to [0,511],
//         silently breaking standard affine UINT8 zero-points.
//         Changing to signed 10-bit supports all zp∈[0,255] values.

// Inline explanation of non-obvious logic
assign tiles_this_pass = (ob_group + PAR_OB > cfg_n_ob)
  ? cfg_n_ob - ob_group   // partial last pass
  : PAR_OB[7:0];          // full pass
```

---

## 5. Interface-First Design (★★★)

### 5.1 Interface Specification Document

Before writing any RTL, **the interface document must be written first**. Use the port table format:

```markdown
### bf16_mac Interface

| Port     | Direction | Width | Description                       |
| -------- | --------- | ----- | --------------------------------- |
| clk      | in        | 1     | System clock                      |
| rst_n    | in        | 1     | Asynchronous reset (active-low)   |
| a_bf16   | in        | 16    | Operand A (bf16)                  |
| b_bf16   | in        | 16    | Operand B (bf16)                  |
| c_fp32   | in        | 32    | Accumulation input (fp32)         |
| out_fp32 | out       | 32    | Multiply-accumulate result (fp32) |
```

### 5.2 New Module Development Process

```
1. Interface definition → docs/interfaces.md (must be confirmed by the whole team)
2. Golden Model → new function in sw/attention_golden.py
3. Generate test vectors → python attention_golden.py --export-tb-data
4. RTL implementation + testbench (interface strictly matching the definition from step 1)
5. VCS simulation pass
6. PR → Code Review → Merge
```

Do not proceed to step 4 (RTL coding) before the interface from step 1 is confirmed.

---

## 6. Design Review Checklist

Learned from the C3 DMA project: ask yourself before every major design decision:

```
[ ] Is bit-exactness protected? (Changes must not break existing correctness)
[ ] Is the compute core untouched? (Minimize changes to core/ directory)
[ ] Is there a dual-path rollback? (New features controlled by parameter switches)
[ ] Is there a git tag rollback point? (Tag before irreversible changes)
[ ] Has the interface document been updated? (docs/interfaces.md)
[ ] Are acceptance criteria quantified? ("≤ 25 ms/img" not "faster")
[ ] Are risks registered? (Probability + impact + mitigation)
[ ] Is the software upper-level API unchanged? (Changes transparent to callers)
```

---

## 7. Python Coding Conventions

### 7.1 Golden Model

```python
#!/usr/bin/env python3
"""
attention_golden.py — bf16 bit-accurate Attention golden model.

Correspondence with RTL:
  bf16_mul()       ↔ bf16_mac.sv
  attention_head() ↔ attn_core.sv

Usage:
  python attention_golden.py --self-test
  python attention_golden.py --export-tb-data --module bf16_mac
  python attention_golden.py --export-hex --output-dir path/
"""

# ==================================================================
# Hardware parameters (MUST match attn_pkg.sv)
# ==================================================================
HEAD_DIM = 128
N_Q_HEADS = 32
N_KV_HEADS = 8
# ... one-to-one correspondence with attn_pkg.sv

def _apply_seed(seed):
    """Fixed seed ensures reproducibility. seed=None means fully random."""
    if seed is not None:
        np.random.seed(seed)

def bf16_mul(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """bf16 multiplication, simulating RTL behavior. Bit-exact match with bf16_mac.sv."""
    ...

def attention_forward(Q, K, V, ...):
    """Full Attention forward pass. Computation order matches attn_core.sv."""
    ...
```

**Golden Model rules**:

- Hardware parameters declared centrally at the top of the file, one-to-one with `attn_pkg.sv`
- Key functions annotate their corresponding RTL module
- Support `--self-test` and `--export-hex` CLI
- Return dict containing intermediate results for stepwise comparison
- `_apply_seed()` controls randomness

### 7.2 Driver Code

```python
class AttnDriver:
    """
    Attention Accelerator Python driver.

    Usage:
      drv = AttnDriver(use_dma=True)
      drv.load_weights('wq.hex', dest='wq')
      drv.configure(seq_len=128)
      drv.start_and_wait()
      result = drv.read_output()
    """
    def __init__(self, bitstream=None, use_dma=True): ...
    def _stream_load(self, words, dest, buf): ...  # internal methods use _ prefix
    def load_weights(self, hex_file, dest): ...
```

### 7.3 Benchmark Specification

Output CSV containing `model, seq_len, n_runs, total_s, ms_per_run, accuracy`.
Simultaneously save a latency breakdown pie chart.

### 7.4 Documentation Synchronization

When interface changes occur in files under `sw/`, **documentation must be updated synchronously**. Inter-file dependencies are recorded using ASCII diagrams:

```
attention_golden.py ──→ RTL testbench hex data
extract_weights.py ──→ attn_driver.py ──→ KV260 hardware
```

---

## 8. Verification Methodology

### 8.1 Four-Layer Verification System

```
Layer 1: Unit Test     → VCS single module, random vectors vs Golden Model
Layer 2: Integration   → VCS multi-module co-simulation
Layer 3: End-to-End    → VCS full Attention layer simulation
Layer 4: On-Board      → KV260 on-board verification
```

### 8.2 Testbench Naming

| Module Under Test | Testbench       | Script              | Verification Method               |
| ----------------- | --------------- | ------------------- | --------------------------------- |
| bf16_mac.sv       | tb_bf16_mac.sv  | run_tb_bf16_mac.sh  | 103 random vectors vs Golden      |
| attn_tile.sv      | tb_attn_tile.sv | run_tb_attn_tile.sh | Random matrices vs Golden matmul  |
| softmax_engine.sv | tb_softmax.sv   | run_tb_softmax.sh   | Random inputs vs scipy softmax    |
| attn_core.sv      | tb_attn_head.sv | run_tb_attn_head.sh | Single-head Attention integration |
| attn_top.sv       | tb_attn_e2e.sv  | run_tb_attn_e2e.sh  | Full layer end-to-end             |

### 8.3 Testbench Template

```systemverilog
// ==================================================================
// tb_bf16_mac.sv — bf16 MAC unit test (103 random vectors)
// ==================================================================
module tb_bf16_mac;
  logic clk, rst_n;
  logic [15:0] a_bf16, b_bf16;
  logic [31:0] c_fp32, out_fp32, golden_out;
  int error_cnt = 0;

  bf16_mac u_dut (.*);
  always #5 clk = ~clk;  // 100MHz

  initial begin
    clk = 0; rst_n = 0;
    #10 rst_n = 1;

    for (int i = 0; i < 103; i++) begin
      @(posedge clk);
      a_bf16 = test_vectors[i].a;
      b_bf16 = test_vectors[i].b;
      c_fp32 = test_vectors[i].c;
      @(posedge clk);
      if (out_fp32 !== golden_out) begin
        $error("Test %0d FAIL: got %h, expected %h", i, out_fp32, golden_out);
        error_cnt++;
      end
    end

    if (error_cnt == 0) $display(">>> ALL 103 TESTS PASSED <<<");
    else $display(">>> %0d TESTS FAILED <<<", error_cnt);
    $finish;
  end
endmodule
```

### 8.4 Simulation Script Template

```bash
#!/bin/bash
# run_tb_bf16_mac.sh — VCS compile + run bf16 MAC testbench
set -e
cd "$(dirname "$0")/.."

# 1. Generate golden test data (if missing)
if [ ! -f tb/tb_bf16_mac/data/vectors.hex ]; then
  python3 ../../sw/attention_golden.py --export-tb-data \
    --module bf16_mac --output-dir tb/tb_bf16_mac/data/
fi

# 2. Compile
vcs -full64 -sverilog \
  +incdir+rtl/pkg \
  rtl/pkg/attn_pkg.sv \
  rtl/core/bf16_mac.sv \
  tb/tb_bf16_mac.sv \
  -o simv_bf16_mac

# 3. Run
./simv_bf16_mac +vcs+finish
echo "tb_bf16_mac: PASS"
```

### 8.5 pytest Regression

```python
def test_bf16_mul_random():
    """Random bf16 multiplication, compared against ml_dtypes reference."""
    np.random.seed(42)
    a = np.random.randn(128).astype(np.float32)
    b = np.random.randn(128).astype(np.float32)
    result = bf16_mul(a, b)
    assert np.allclose(result, expected, atol=1e-3)

def test_attention_single_head():
    """Single-head Attention, seq_len=64, compared against PyTorch reference."""
    ...

def test_attention_gqa():
    """Full GQA Attention, seq_len=128."""
    ...
```

---

## 9. Git Workflow

### 9.1 Commit Message

```
<type>(<scope>): <short description>

<detailed description (in English)>

Co-Authored-By: Claude <noreply@anthropic.com>
```

| Type       | Purpose       | Scope | Meaning           |
| ---------- | ------------- | ----- | ----------------- |
| `feat`     | New feature   | `rtl` | Hardware code     |
| `fix`      | Bug fix       | `sw`  | Software code     |
| `refactor` | Refactoring   | `tb`  | Testbench         |
| `test`     | Testing       | `pkg` | Parameter package |
| `docs`     | Documentation | `mem` | Memory modules    |
| `chore`    | Build         | `axi` | AXI interfaces    |

### 9.2 Branch Strategy

```
master          ← Protected branch
  ├── dev        ← Integration branch (nightly merge)
  │   ├── feat/bf16-mac
  │   ├── feat/softmax-engine
  │   ├── feat/golden-model
  │   └── feat/attn-fsm
  └── paper       ← Paper branch
```

### 9.3 Pre-Commit Checklist

```
[ ] VCS simulation passed (this module's tb)
[ ] Full regression passed (run_regression.sh)
[ ] pytest all GREEN
[ ] docs/interfaces.md updated
[ ] No hardcoded values (all from pkg)
[ ] No experimental/debug code left behind
[ ] Bit-exact behavior not broken
```

---

## 10. Team Coordination

### 10.1 Invocation

```
/track-b
```

The Agent will load this specification. **Ensure the Agent has read this file before having it write code.**

### 10.2 Multi-Person Collaboration Rules

- **Interface-first**: Must reach agreement in `docs/interfaces.md` before writing RTL
- **Daily sync**: Feature branches merged into `dev` nightly
- **Code Review mandatory checks**:
  1. Are parameters sourced from pkg?
  2. Does it comply with SV coding conventions?
  3. Is there a Golden Model test?
  4. Do comments explain WHY and not just WHAT?
  5. Is there any over-engineering?

### 10.3 Platform Heterogeneity Notes

Team members may have different development environments:

- **Members with KV260**: Responsible for on-board verification, Vivado synthesis
- **Members without the board**: Can fully develop independently using VCS simulation + Golden Model
- **RTL behaves identically across all platforms** (this is the result of unified pkg parameters)

---

## 11. Track B Competition Reference

### 11.1 Llama3.1-8B Attention Specifications

```
dim=4096, n_q_heads=32, n_kv_heads=8, head_dim=128
Wq/Wo: [4096, 4096] bf16
Wk/Wv: [1024, 4096] bf16
Single layer weights ≈ 80 MB, 32-layer Attention weights ≈ 2.5 GB
```

### 11.2 bf16 Format

```
[15] sign | [14:7] exponent (8-bit, bias=127) | [6:0] mantissa (7-bit)
Value = (-1)^s × 2^(e-127) × 1.m
Dynamic range ≈ fp32, precision ≈ 3 significant digits
DSP48E2 direct mapping: 9-bit mantissa multiplication + 8-bit exponent addition
```

### 11.3 Target Platform

- Kria KV260: 1248 DSP48E2, 64 URAM (20.7 Mb), 144 BRAM (5.1 Mb), 4GB DDR4
- Vivado 2025.2 / Vitis 2025.2
- Parameterized scaling supported for larger platforms (Versal/Alveo)

### 11.4 Key Dates

| Milestone             | Date           |
| --------------------- | -------------- |
| Registration deadline | 2026-07-07 AoE |
| Submission deadline   | 2026-08-07 AoE |
| Finalists announced   | 2026-08-21     |

---

_This file is the shared coding contract for the entire team. Modifications must go through review and be marked `docs(skill): <description>`._
_All coding experience extracted from the RTL, Python, documentation, and design flow of the INT8-CIM capstone project._
