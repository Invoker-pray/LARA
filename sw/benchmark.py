#!/usr/bin/env python3
"""benchmark.py — LARA performance metric calculation"""
import sys
sys.path.insert(0, 'python_godel')
from attention_golden import HEAD_DIM, N_Q_HEADS, N_KV_HEADS, MAX_SEQ_LEN

# Design parameters
MAC_DSP = 256        # DSP48E2 units in 16x16 array
FREQ_MHZ = 200       # Target clock frequency (MHz)
TILE_Q, TILE_KV = 32, 64

def compute_metrics(L=512):
    n_q_tiles = (L + TILE_Q - 1) // TILE_Q
    n_kv_tiles = (L + TILE_KV - 1) // TILE_KV
    cycles_per_kv = 260  # 128(A)+2(pipe)+128(B)+2(psum)
    total_cycles = 8 * 4 * n_q_tiles * n_kv_tiles * cycles_per_kv  # groups×heads×Q×KV
    latency_us = total_cycles / FREQ_MHZ
    throughput_tps = L / (latency_us / 1e6)
    mac_ops = 2 * L * HEAD_DIM * (L + L)  # QK^T + PV, per head-pair
    total_gops = (mac_ops * N_Q_HEADS) / (latency_us / 1e6) / 1e9
    gops_per_dsp = total_gops / MAC_DSP
    return {
        'seq_len': L, 'freq_mhz': FREQ_MHZ, 'dsp_count': MAC_DSP,
        'latency_us': latency_us, 'throughput_tps': throughput_tps,
        'total_gops': total_gops, 'gops_per_dsp': gops_per_dsp,
    }

if __name__ == '__main__':
    for L in [128, 256, 512, 1024, 2048]:
        m = compute_metrics(L)
        print(f"L={m['seq_len']:4d}: latency={m['latency_us']:7.1f}us  "
              f"throughput={m['throughput_tps']:7.1f} tok/s  "
              f"GOPS={m['total_gops']:6.2f}  GOPS/DSP={m['gops_per_dsp']:.3f}")
