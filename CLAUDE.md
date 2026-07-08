# CLAUDE.md — FPT'26 Track B: FPGA Attention Accelerator

## Project Overview

FPGA-based attention mechanism accelerator for Llama3-8B (bf16 precision). Targeting Kria KV260. Four-person team collaboration.

## The Most Important Rule

**Before writing ANY code in this repository, invoke the project skill:**

```
/track-b
```

This loads the complete coding standard, project conventions, and team coordination guidelines. All team members share this single source of truth.

If `/track-b` is unavailable, read `.claude/skills/track-b.md` directly.

## Branch Architecture

```
master    → Deployment source only (hw/, sw/) — clean, on-board ready
develop   → Full development tree (hw/, sw/, python_godel/, VV/) — validation included
```

| Branch   | Purpose                                      | Contents                              |
| -------- | -------------------------------------------- | ------------------------------------- |
| `master` | On-board deployment source                   | `hw/`, `sw/`, `docs/`                 |
| `develop`| Development + validation                     | `hw/`, `sw/`, `python_godel/`, `VV/`  |

- **Develop on `develop`**, validate with Python golden model + VCS/Verilator
- **Cherry-pick or merge `hw/` and `sw/` changes** from `develop` → `master` when validated
- `python_godel/` and `VV/` NEVER exist on `master` (enforced by `.gitignore`)

## Three-Layer Verification Methodology

```
Layer 1: Python Golden Model  → python_godel/ (design-level bit-accurate verification)
Layer 2: VCS / Verilator      → VV/          (logic-level RTL verification)
Layer 3: On-Board             → KV260        (actual hardware validation)
```

Every RTL module must pass Layer 1 → Layer 2 before board testing.

## Quick Reference

- **All parameters**: `hw/rtl/pkg/attn_pkg.sv` — single source, no hardcoded values in modules
- **Golden Model**: `python_godel/attention_golden.py` — bit-accurate bf16 reference (develop branch)
- **Interface specs**: `docs/interfaces.md` — interface-first design
- **Simulation**: `cd VV && bash scripts/run_tb_<name>.sh` (develop branch)
- **Full regression**: `cd VV && bash scripts/run_regression.sh` (develop branch)
- **Python tests**: `cd python_godel && pytest tests/ -v` (develop branch)
- **Vivado build**: `bash hw/scripts/vivado_build.sh`

## Key Conventions

1. **Think before coding** — state assumptions, surface tradeoffs
2. **Simplicity first** — minimum code, no speculation
3. **Surgical changes** — touch only what you must
4. **Goal-driven** — define success criteria, loop until verified
5. **Interface-first** — agree on interfaces before writing RTL
6. **Dual-path rollback** — new features behind parameter switches

## Directory Map

```
LARA/
├── CLAUDE.md                         # Project-level Claude guidance
├── README.md                         # Project overview + environment setup + quick start
├── pyproject.toml                    # Python project config (uv-based)
│
├── hw/                               # ──────── Hardware Design (master + develop) ────────
│   ├── rtl/
│   │   ├── pkg/
│   │   │   └── attn_pkg.sv           # ★ Global parameter package (sole parameter source)
│   │   ├── core/                     # Compute core (no AXI protocol dependency)
│   │   │   ├── bf16_mac.sv           # bf16 multiply-accumulate (atomic unit)
│   │   │   ├── attn_tile.sv          # MAC array (16×16, time-multiplexed)
│   │   │   ├── softmax_engine.sv     # Online Softmax hardware engine
│   │   │   ├── psum_accum.sv         # Partial sum accumulator
│   │   │   └── attn_core.sv          # Top-level FSM + FlashAttention loop
│   │   ├── mem/                      # Pure storage modules (no compute logic)
│   │   │   ├── kv_cache_ram.sv       # K/V URAM cache
│   │   │   ├── tile_buffer.sv        # Q tile ping-pong buffer
│   │   │   └── output_buffer.sv      # Output accumulator buffer
│   │   ├── axi/                      # AXI protocol interfaces (storage/compute unaware of AXI)
│   │   │   ├── attn_axi_lite_slave.sv  # AXI4-Lite CSR
│   │   │   ├── attn_axi_stream_sink.sv # AXIS data receive (DDR→PL)
│   │   │   └── attn_axi_stream_source.sv # AXIS result send (PL→DDR)
│   │   └── attn_top.v                # Top-level wrapper in Verilog
│   ├── constraints/
│   │   └── attn_soc.xdc
│   └── scripts/
│       └── vivado_build.tcl
│
├── sw/                               # ──────── On-Board Software (master + develop) ────────
│   ├── attn_driver.py                # PYNQ Python driver (AXI MMIO + DMA)
│   ├── extract_weights.py            # .pth → .hex weight export
│   ├── benchmark.py                  # Performance benchmark
│   ├── tests/
│   │   └── test_attn_driver.py
│   └── scripts/
│       └── plot_latency.py
│
├── python_godel/                     # ──── Python Golden Model (develop only) ────
│   ├── attention_golden.py           # ★ bf16 bit-accurate Golden Model
│   ├── tests/
│   │   └── test_golden_model.py      # pytest regression (Layer 1)
│   └── scripts/
│       └── export_tb_data.py         # Generate VCS/Verilator test vectors
│
├── VV/                               # ──── VCS / Verilator Validation (develop only) ────
│   ├── tb/                           # Testbenches (one per module)
│   │   ├── tb_bf16_mac.sv
│   │   ├── tb_attn_tile.sv
│   │   ├── tb_softmax.sv
│   │   ├── tb_attn_head.sv
│   │   └── tb_attn_e2e.sv
│   ├── scripts/                      # Simulation scripts (one run script per TB)
│   │   ├── run_tb_bf16_mac.sh
│   │   ├── run_tb_attn_tile.sh
│   │   └── run_regression.sh
│   └── data/                         # Auto-generated test vectors (.hex)
│
├── docs/                             # ──────── Documentation (shared) ────────
│   ├── architecture_diagram.html     # Top-level architecture + module list
│   ├── dataflow_diagram.html         # Dataflow + FSM + FlashAttention loop
│   ├── mac_array_analysis.html       # MAC array dimension analysis
│   ├── code_organization.html        # Complete module interface spec (17 chapters)
│   ├── track-b-roadmap.md            # 6-week development roadmap
│   ├── interfaces.md                 # ★ Module interface spec (interface-first)
│   └── Track-B-Submission-Guidelines.docx
│
└── .claude/skills/track-b.md         # Team coding standard (v2.0.0)
```

## Reference

The coding conventions in this project are inherited from the INT8-CIM capstone project at `~/git/xx/`. Many architectural patterns (MAC array, FSM, DMA path, ping-pong buffers, parameter package) are directly reused.
