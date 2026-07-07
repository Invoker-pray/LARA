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

## Quick Reference

- **All parameters**: `hw/rtl/pkg/attn_pkg.sv` — single source, no hardcoded values in modules
- **Golden Model**: `sw/attention_golden.py` — bit-accurate bf16 reference
- **Interface specs**: `docs/interfaces.md` — interface-first design
- **Simulation**: `cd hw && bash scripts/run_tb_<name>.sh`
- **Full regression**: `cd hw && bash scripts/run_regression.sh`
- **Python tests**: `cd sw && pytest tests/ -v`
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
hw/rtl/pkg/    → parameters (attn_pkg.sv)
hw/rtl/core/   → compute: MAC, Softmax, FSM
hw/rtl/mem/    → storage: SRAM, buffers
hw/rtl/axi/    → AXI interfaces (Lite, Stream)
hw/tb/         → testbenches
sw/            → Python: golden model, driver, benchmark
docs/          → architecture, interfaces, guides
```

## Reference

The coding conventions in this project are inherited from the INT8-CIM capstone project at `~/git/xx/`. Many architectural patterns (MAC array, FSM, DMA path, ping-pong buffers, parameter package) are directly reused.
