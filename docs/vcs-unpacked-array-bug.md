# VCS Unpacked Array + always_ff Bug

## Environment

- VCS: W-2024.09-SP1
- OS: Arch Linux, Linux 6.18.38-1-lts
- GCC: 16.1.1

## Symptom

Modules with **unpacked array ports** + `always_ff` blocks containing `for (int i = ...)` loops fail at simulation runtime:

- **Compilation**: passes (0 errors)
- **Simulation**: values read as 0 or corrupted, `$bitstoshortreal()` on unpacked array elements produces wrong results

### Working (scalar ports)

```systemverilog
// ✅ bf16_mac.sv — scalar ports work fine
module bf16_mac(input [15:0] a_bf16, input [15:0] b_bf16, ...);
```

### Failing (unpacked array ports)

```systemverilog
// ❌ psum_accum.sv — unpacked array ports fail
module psum_accum(input [31:0] col_lo [0:15], output [31:0] psum [0:15]);
  always_ff @(posedge clk) begin
    for (int i = 0; i < 16; i++)   // ← `int i` is AUTOMATIC
      psum[i] <= ...;               // ← VCS error: "Illegal reference to automatic variable"
  end
endmodule
```

## Root Cause

VCS W-2024.09 treats `for (int i = ...)` loop variables as **automatic** storage class. When these automatic variables are used to index **module-level unpacked arrays** (which are **static**), VCS reports:

```
Error-[SV-IRTAV] Illegal reference to automatic variable
  "psum_accum.2.i"
```

This is a VCS parser/elaborator limitation — the SystemVerilog LRM allows automatic variables to index static arrays.

Even when the error is not explicitly reported (depending on VCS flags), the simulation produces silently corrupted values, suggesting an internal VCS data structure inconsistency.

## Fix

Replace `int i` with module-level `integer`:

```systemverilog
// ✅ Fixed version
module psum_accum(input [31:0] col_lo [0:15], output [31:0] psum [0:15]);
  integer ii;  // ← module-level STATIC variable
  always_ff @(posedge clk) begin
    for (ii = 0; ii < 16; ii++)
      psum[ii] <= ...;
  end
endmodule
```

## Additional Findings

### Testbench Stability

Multi-test VCS testbenches with unpacked array signals experience **state contamination** between test sections:

- Test 1 (first after reset): always works correctly
- Test 2+ (after signal changes): values may be stale or corrupted

**Workaround**: Write independent single-purpose testbenches, each with its own reset sequence.

### What is NOT the cause

| Suspected | Verdict | Evidence |
|-----------|---------|----------|
| GCC version | ❌ Not the cause | Simple unpacked array tests pass with GCC 16 |
| Kernel incompatibility | ❌ Not the cause | Same tests pass on kernel 6.18 |
| libstdc++ ABI | ❌ Not the cause | ldd shows correct linkage |
| Generate blocks | ❌ Not the cause | `always_comb` without generate has same issue |

## Verilator Alternative

Verilator 5.050 handles the same modules correctly and is the recommended Layer 2 verification tool for modules with unpacked array ports on this platform.
