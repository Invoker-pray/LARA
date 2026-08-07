# KV260 Final Board Validation Results (2026-08-07)

## 1. Evidence identity

- Board: AMD Kria KV260 revB, four Cortex-A53 cores.
- Runtime: Ubuntu 22.04.4, PYNQ 3.0.1, NumPy 1.26.4.
- PL clock: explicitly set and read back as `71.427857 MHz` after every Overlay
  download. The offline board clock/date is intentionally not evidence.
- CPU baseline: one thread pinned to CPU 3; CPU frequency was stable at
  `1.333333 GHz` before and after the run.
- FPGA build: `build-20260806T_v4_71p428MHz_counterfix`.
- Post-route timing: WNS `+0.039 ns`, TNS `0`, WHS `+0.008 ns`, THS `0`.
- Bitstream SHA-256:
  `0aeaa5439686b7a8f53801d28897c5895e9f7ad58c8db63d1bcf6bf928f9a9f4`.
- HWH SHA-256:
  `e6b6f413749ea6cc3975cb54fff0bfafd16998f1279c9ebb6e2da48f8035d6ec`.
- XSA SHA-256:
  `59ad2ec94610a899e8811881b25bdf21f239732d7a26983df80d7f9fc3ec3847`.
- Evidence archive SHA-256:
  `697c325248a29d658e48c6694cdb476f1c319f8035eb757ccf5fba07f64f5cda`.

The environment report is PASS with no issues. The full run manifest and
consolidated result are PASS. The 65 MiB archive contains 171 entries and passes
its SHA-256 check.

## 2. Correctness coverage

- q3/kv3: L1, L16, L32, L64, L128, causal and noncausal: `10/10 PASS`.
- q31/kv7: L1, L16, L32, L64, L128, causal and noncausal: `10/10 PASS`.
- All 20 formal performance cases are also bit-exact with zero mismatches.
- L512 q0/kv0 causal, q3/kv3 causal, and q3/kv3 noncausal: `3/3 PASS`.
- q31/kv7 L512 causal separately passed functional and one-sample performance
  validation.
- RTL performance CSRs are nonzero and retained after DONE. Cycle-derived time
  is consistent with host wall time after correcting FCLK0.

## 3. Formal performance methodology

The table below uses one CPU/FPGA warmup followed by five measured runs and
reports the median. A fresh Overlay is programmed before every FPGA sample to
isolate PL state. Overlay programming and PYNQ buffer allocation are outside the
recorded FPGA latency.

- `PL active`: `(total cycles - external stall cycles) / live FCLK0`. It covers
  controller-active attention work, including internal control and softmax. It
  is not an end-to-end metric and not a claim of MAC-only time.
- `PL transaction`: `total cycles / live FCLK0`, including external DMA/request
  stalls between accepted start and DONE.
- `FPGA E2E`: host wall time for the driver attention call, including request
  service and DMA but excluding Overlay programming and initial buffer allocation.
- `CPU`: same-board NumPy FP32 GQA attention using the same BF16 inputs, shape,
  causal mask, and one CPU thread.
- Speedup is `CPU time / FPGA time`; a value above 1 means FPGA is faster.

| Case | L | Mode | PL active ms | PL transaction ms | FPGA E2E ms | CPU ms | Active speedup | E2E speedup |
|---|---:|---|---:|---:|---:|---:|---:|---:|
| q3kv3 | 1 | causal | 2.186 | 42.224 | 43.634 | 1.890 | 0.865x | 0.043x |
| q3kv3 | 1 | noncausal | 2.186 | 42.271 | 43.679 | 1.537 | 0.703x | 0.035x |
| q3kv3 | 16 | causal | 2.240 | 42.265 | 44.569 | 4.634 | 2.069x | 0.104x |
| q3kv3 | 16 | noncausal | 2.240 | 42.373 | 44.596 | 4.124 | 1.841x | 0.092x |
| q3kv3 | 32 | causal | 7.651 | 42.577 | 45.498 | 9.579 | 1.252x | 0.211x |
| q3kv3 | 32 | noncausal | 7.651 | 42.807 | 45.751 | 9.343 | 1.221x | 0.204x |
| q3kv3 | 64 | causal | 30.594 | 76.059 | 80.746 | 26.433 | 0.864x | 0.327x |
| q3kv3 | 64 | noncausal | 30.594 | 76.220 | 81.037 | 26.488 | 0.866x | 0.327x |
| q3kv3 | 128 | causal | 91.780 | 160.866 | 169.329 | 93.461 | 1.018x | 0.552x |
| q3kv3 | 128 | noncausal | 122.370 | 162.763 | 171.147 | 90.032 | 0.736x | 0.526x |
| q31kv7 | 1 | causal | 2.186 | 41.939 | 43.357 | 1.944 | 0.889x | 0.045x |
| q31kv7 | 1 | noncausal | 2.186 | 41.756 | 43.200 | 1.540 | 0.705x | 0.036x |
| q31kv7 | 16 | causal | 2.240 | 42.261 | 44.508 | 4.928 | 2.200x | 0.111x |
| q31kv7 | 16 | noncausal | 2.240 | 41.989 | 44.169 | 4.085 | 1.824x | 0.092x |
| q31kv7 | 32 | causal | 7.651 | 42.674 | 45.610 | 9.819 | 1.283x | 0.215x |
| q31kv7 | 32 | noncausal | 7.651 | 42.611 | 45.536 | 8.995 | 1.176x | 0.198x |
| q31kv7 | 64 | causal | 30.594 | 76.154 | 80.729 | 27.338 | 0.894x | 0.339x |
| q31kv7 | 64 | noncausal | 30.594 | 75.934 | 80.482 | 26.385 | 0.862x | 0.328x |
| q31kv7 | 128 | causal | 107.075 | 160.505 | 168.947 | 91.517 | 0.855x | 0.542x |
| q31kv7 | 128 | noncausal | 122.370 | 162.819 | 171.183 | 89.948 | 0.735x | 0.525x |

## 4. Findings

1. Correctness is complete for the formal 20-case matrix and the tested L512
   extensions. This is the strongest board result.
2. PL-internal work is faster than the one-core CPU baseline in 9 of 20 formal
   cases. The best is q31/kv7 L16 causal at `2.200x` active-stage speedup.
3. No formal case has PL-transaction or FPGA-E2E speedup above 1. The best E2E
   result is q3/kv3 L128 causal at `0.552x`. It is incorrect to claim an
   end-to-end FPGA speedup from this data.
4. The earlier quick q31/kv7 L128 `1.074x` E2E result used one cold CPU sample.
   It is superseded by the warmed five-run median and must not be quoted.
5. External request/DMA stalls are roughly 35-45 ms for L1-L64 and 40-69 ms at
   L128. They erase internal acceleration, especially for short sequences.
6. At L1 the driver sends 32 padded Q tiles, or 262144 Q bytes, for only 8192
   useful Q bytes. Request count and padding dominate latency.
7. Internal noncausal time scales consistently with quadratic attention:
   approximately 7.65 ms at L32, 30.59 ms at L64, and 122.37 ms at L128.
8. For q3/kv3 L512, causal traversal reduces controller-active cycles from
   `139847156` to `78664595`, a `43.75%` reduction (`1.778x` fewer active
   cycles), while preserving bit-exact output. This is a defensible
   architecture-optimization result independent of CPU timing.

## 5. Submission wording

Safe claims:

- The 71.427857 MHz KV260 implementation meets post-route timing and passes all
  tested bit-exact board cases through L512.
- The retained hardware counters distinguish PL active work, external stalls,
  and host-to-host latency.
- Selected workloads achieve up to `2.200x` PL-active-stage speedup over a
  pinned one-core same-board NumPy baseline.
- Causal tile traversal reduces q3/kv3 L512 active cycles by `43.75%` versus
  noncausal traversal.
- DMA/request overhead is measured and reported rather than excluded from the
  end-to-end result.

Claims that are not supported:

- Do not claim overall or end-to-end acceleration over the CPU baseline.
- Do not describe `PL active` or `MAC active` as host-to-host latency.
- Do not use the one-sample quick-run L128 speedup as the final result.
- Do not claim L2048 support; the current hardware maximum is L512.

## 6. Next optimization target

The next performance work should reduce the 32 per-head Q requests and padded
Q-tile traffic, then batch or stream request service so PS/DMA latency overlaps
PL work. This has higher expected end-to-end impact than further MAC datapath
tuning. Any protocol change must retain the current bit-exact matrix and
post-route timing evidence as the rollback baseline.

Primary raw evidence:

- `board_full_counterfix_cpu1/performance/cpu1/performance.json`
- `board_full_counterfix_cpu1/performance/cpu1/performance.csv`
- `board_full_counterfix_cpu1/consolidated_results.json`
- `board_q3kv3_L512_functional/summary.json`
- `lara_kv260_final_results_20260807.tar.gz`
