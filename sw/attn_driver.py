#!/usr/bin/env python3
"""
attn_driver.py — PYNQ Driver for LARA Attention Accelerator

KV260 on-board control: loads bitstream, configures DMA, drives attention
computation, and reads back results via AXI4-Lite + AXI4-Stream DMA.

Requires: PYNQ v2.7+ with pynq.overlay and pynq.lib.dma

Usage:
  python attn_driver.py --bitstream lara_attention.bit --check
"""

import numpy as np
import os
import sys
import time

# ============================================================================
# PYNQ Imports (available on KV260, mock for development)
# ============================================================================
try:
    from pynq import Overlay, allocate
    from pynq.lib import DmaWindow
    HAS_PYNQ = True
except ImportError:
    HAS_PYNQ = False
    print("WARNING: PYNQ not available (development mode). Using mock driver.")


# ============================================================================
# CSR Address Map (from attn_pkg.sv §7)
# ============================================================================
CSR_CTRL        = 0x000
CSR_STATUS      = 0x004
CSR_SEQ_LEN     = 0x008
CSR_STREAM_SRC  = 0x020
CSR_STREAM_LEN  = 0x028
CSR_STREAM_DEST = 0x02C
CSR_HEAD_IDX    = 0x014
CSR_RESULT_DST  = 0x050
CSR_RESULT_LEN  = 0x058
CSR_PERF_CYCLES = 0x100

# Stream destinations
DEST_K_CACHE = 0
DEST_V_CACHE = 1
DEST_Q_BUF   = 2

HEAD_DIM = 128
N_Q_HEADS = 32
N_KV_HEADS = 8
GQA_GROUP_SIZE = N_Q_HEADS // N_KV_HEADS


class AttentionAccelerator:
    """PYNQ driver for LARA attention accelerator."""

    def __init__(self, bitstream_path: str = None):
        """
        Load bitstream and initialize DMA.

        Args:
            bitstream_path: path to .bit or .hwh file
        """
        if HAS_PYNQ:
            self.overlay = Overlay(bitstream_path)
            # The BD uses the instance names /axi_dma and /accel. Keep the
            # legacy aliases as a fallback for older overlays.
            dma = getattr(self.overlay, "axi_dma", None)
            if dma is None:
                dma = self.overlay.axi_dma_0
            accel = getattr(self.overlay, "accel", None)
            if accel is None:
                accel = self.overlay.attn_accel_0
            self.dma_send = dma.sendchannel
            self.dma_recv = dma.recvchannel
            self.mmio = accel.mmio  # AXI4-Lite
            self._hw_ready = True
        else:
            self.dma_send = None
            self.dma_recv = None
            self.mmio = None
            self._hw_ready = False
            print("Mock driver initialized — set HAS_PYNQ=True for hardware.")
        self._send_cache = {}
        self._recv_cache = {}

    @property
    def hw_ready(self) -> bool:
        return self._hw_ready

    # ==================================================================
    # Configuration
    # ==================================================================

    def configure(self, seq_len: int, q_addr: int, k_addr: int,
                  v_addr: int, o_addr: int,
                  gqa_group: int = 0, q_head: int = 0):
        """
        Configure the accelerator for one attention computation.

        Args:
            seq_len:   sequence length (≤ MAX_SEQ_LEN)
            q_addr:    Q data DDR physical address
            k_addr:    K data DDR physical address
            v_addr:    V data DDR physical address
            o_addr:    O (output) DDR physical address
        """
        if self.mmio is None:
            print(f"CONFIG: seq_len={seq_len}, Q={q_addr:#x}, K={k_addr:#x}, "
                  f"V={v_addr:#x}, O={o_addr:#x}")
            return

        self.mmio.write(CSR_SEQ_LEN, seq_len)
        self.mmio.write(CSR_HEAD_IDX, ((gqa_group & 0x7) << 2) | (q_head & 0x3))
        # Stream source/dest addresses set per transfer (see load/readback)

    def start(self):
        """Pulse start bit."""
        if self.mmio:
            self.mmio.write(CSR_CTRL, 0x1)  # start=1
            # attn_core samples start as a level while idle; clear it after
            # the AXI write so a completed run cannot be retriggered.
            self.mmio.write(CSR_CTRL, 0x0)

    def is_done(self) -> bool:
        """Poll done flag."""
        if self.mmio:
            # Current RTL exposes sticky done on status bit 0.
            return bool(self.mmio.read(CSR_STATUS) & 0x1)
        return True

    def wait_done(self, timeout_ms: int = 5000):
        """Block until computation completes."""
        t0 = time.time()
        while not self.is_done():
            if (time.time() - t0) * 1000 > timeout_ms:
                raise TimeoutError("Attention accelerator timed out")
            time.sleep(0.001)

    def read_perf(self) -> dict:
        """Read performance counters."""
        if self.mmio is None:
            return {"cycles": 0, "mac_cycles": 0}
        return {
            "cycles": self.mmio.read(CSR_PERF_CYCLES),
        }

    # ==================================================================
    # Data Transfer
    # ==================================================================

    def _get_buffer(self, cache: dict, nbytes: int):
        """Reuse PYNQ DMA buffers to avoid per-tile allocate/free overhead."""
        if not HAS_PYNQ:
            return None
        buf = cache.get(nbytes)
        if buf is None:
            buf = allocate(shape=(nbytes,), dtype=np.uint8)
            cache[nbytes] = buf
        return buf

    def load_kv_cache(self, K: np.ndarray, V: np.ndarray):
        """
        Load K and V matrices into URAM caches.

        Args:
            K: [L, 1024] bf16 (8 KV heads × 128 dim)
            V: [L, 1024] bf16
        """
        L = K.shape[0]
        k_bytes = K.view(np.uint16).tobytes()
        v_bytes = V.view(np.uint16).tobytes()

        if HAS_PYNQ:
            k_buf = self._get_buffer(self._send_cache, len(k_bytes))
            v_buf = self._get_buffer(self._send_cache, len(v_bytes))
            k_buf[:] = np.frombuffer(k_bytes, dtype=np.uint8)
            v_buf[:] = np.frombuffer(v_bytes, dtype=np.uint8)

            self.mmio.write(CSR_STREAM_DEST, DEST_K_CACHE)
            self.mmio.write(CSR_STREAM_LEN, len(k_bytes))
            self.dma_send.transfer(k_buf)
            self.dma_send.wait()

            self.mmio.write(CSR_STREAM_DEST, DEST_V_CACHE)
            self.mmio.write(CSR_STREAM_LEN, len(v_bytes))
            self.dma_send.transfer(v_buf)
            self.dma_send.wait()
        else:
            print(f"LOAD: K[{L}x1024] + V[{L}x1024] = {len(k_bytes)+len(v_bytes)} bytes")

    def load_q_tile(self, Q_tile: np.ndarray):
        """
        Load one Q tile [TILE_Q, 4096] bf16 into ping-pong buffer.

        Args:
            Q_tile: [32, 4096] bf16 (TILE_Q rows × N_Q_HEADS × HEAD_DIM)
        """
        q_bytes = Q_tile.view(np.uint16).tobytes()

        if HAS_PYNQ:
            q_buf = self._get_buffer(self._send_cache, len(q_bytes))
            q_buf[:] = np.frombuffer(q_bytes, dtype=np.uint8)
            self.mmio.write(CSR_STREAM_DEST, DEST_Q_BUF)
            self.mmio.write(CSR_STREAM_LEN, len(q_bytes))
            self.dma_send.transfer(q_buf)
            self.dma_send.wait()
        else:
            print(f"LOAD Q: {Q_tile.shape} = {len(q_bytes)} bytes")

    def readback_o(self, L: int) -> np.ndarray:
        """
        Read back O result [L, 4096] bf16 from DDR.

        Returns:
            O: [L, 4096] bf16 numpy array
        """
        o_size = L * 4096 * 2  # bytes

        if HAS_PYNQ:
            o_buf = self._get_buffer(self._recv_cache, o_size)
            self.mmio.write(CSR_RESULT_LEN, o_size)
            self.dma_recv.transfer(o_buf)
            self.dma_recv.wait()
            O = np.frombuffer(o_buf.tobytes(), dtype=np.uint16).reshape(L, 4096)
            return O.view(np.float16)  # interpret as bf16
        else:
            print(f"READBACK O: [{L}x4096] = {o_size} bytes")
            return np.zeros((L, 4096), dtype=np.float16)

    def run_attention_group(
        self,
        Q_group: np.ndarray,
        K_head: np.ndarray,
        V_head: np.ndarray,
        seq_len: int = None,
        group_idx: int = 0,
        collect_profile: bool = False,
    ):
        """
        Run one GQA group: 4 Q heads share one KV head.

        Args:
            Q_group: [L, GQA_GROUP_SIZE*HEAD_DIM] bf16-equivalent
            K_head:  [L, HEAD_DIM]
            V_head:  [L, HEAD_DIM]
        Returns:
            O_group: [L, GQA_GROUP_SIZE*HEAD_DIM]
        """
        L = Q_group.shape[0] if seq_len is None else seq_len
        o_group = np.zeros_like(Q_group)
        profile = {
            "group_idx": group_idx,
            "q_heads": [],
            "kv_load_s": 0.0,
        }

        t0 = time.perf_counter()
        self.load_kv_cache(K_head, V_head)
        profile["kv_load_s"] = time.perf_counter() - t0

        for qh in range(GQA_GROUP_SIZE):
            q_slice = Q_group[:, qh * HEAD_DIM:(qh + 1) * HEAD_DIM]
            self.configure(L, 0, 0, 0, 0, gqa_group=group_idx, q_head=qh)
            result = self.run_attention(
                q_slice, K_head, V_head, seq_len=L,
                collect_profile=True, reuse_kv_cache=True
            )
            o_head, q_prof = result
            o_group[:, qh * HEAD_DIM:(qh + 1) * HEAD_DIM] = o_head
            profile["q_heads"].append(q_prof)

        if collect_profile:
            return o_group, profile
        return o_group

    def run_attention_gqa(
        self,
        Q: np.ndarray,
        K: np.ndarray,
        V: np.ndarray,
        seq_len: int = None,
        collect_profile: bool = False,
    ):
        """
        Execute all GQA groups while reusing each group's KV cache once.

        Expected shapes:
            Q: [L, N_Q_HEADS*HEAD_DIM]
            K: [L, N_KV_HEADS*HEAD_DIM]
            V: [L, N_KV_HEADS*HEAD_DIM]
        """
        L = Q.shape[0] if seq_len is None else seq_len
        O = np.zeros_like(Q)
        profiles = []

        for group_idx in range(N_KV_HEADS):
            q_lo = group_idx * GQA_GROUP_SIZE * HEAD_DIM
            q_hi = q_lo + GQA_GROUP_SIZE * HEAD_DIM
            kv_lo = group_idx * HEAD_DIM
            kv_hi = kv_lo + HEAD_DIM

            result = self.run_attention_group(
                Q[:, q_lo:q_hi],
                K[:, kv_lo:kv_hi],
                V[:, kv_lo:kv_hi],
                seq_len=L,
                group_idx=group_idx,
                collect_profile=True,
            )
            o_group, group_profile = result
            O[:, q_lo:q_hi] = o_group
            profiles.append(group_profile)

        if collect_profile:
            return O, profiles
        return O

    # ==================================================================
    # High-Level API
    # ==================================================================

    def run_attention(
        self, Q: np.ndarray, K: np.ndarray, V: np.ndarray,
        seq_len: int = None, collect_profile: bool = False,
        reuse_kv_cache: bool = False
    ):
        """
        Run full attention computation for one GQA group (one KV head, 4 Q heads).

        Args:
            Q: [L, N_Q_HEADS*HEAD_DIM] bf16 (= [L, 4096] for Llama3)
            K: [L, N_KV_HEADS*HEAD_DIM] bf16 (= [L, 1024])
            V: [L, N_KV_HEADS*HEAD_DIM] bf16 (= [L, 1024])
            seq_len: current sequence length
        Returns:
            O: [L, N_Q_HEADS*HEAD_DIM] bf16 (= [L, 4096])
        """
        L = Q.shape[0] if seq_len is None else seq_len
        print(f"Attention: L={L}")
        profile = {
            "kv_load_s": 0.0,
            "q_load_s": 0.0,
            "compute_s": 0.0,
            "readback_s": 0.0,
            "tiles": [],
        }

        # 1. Load K/V cache (once per GQA group)
        if not reuse_kv_cache:
            t0 = time.perf_counter()
            self.load_kv_cache(K, V)
            profile["kv_load_s"] = time.perf_counter() - t0

        # 2. For each Q tile (TILE_Q=32):
        #    a. Load Q tile to ping-pong buffer
        #    b. Start computation
        #    c. Wait for completion
        #    d. Read back O tile
        O = np.zeros_like(Q)
        n_q_tiles = (L + 31) // 32  # ceil(L/TILE_Q)

        for tile_idx in range(n_q_tiles):
            q_start = tile_idx * 32
            q_end = min(q_start + 32, L)
            Q_tile = Q[q_start:q_end]

            t0 = time.perf_counter()
            self.load_q_tile(Q_tile)
            q_load_s = time.perf_counter() - t0
            profile["q_load_s"] += q_load_s

            t0 = time.perf_counter()
            self.start()
            self.wait_done()
            compute_s = time.perf_counter() - t0
            profile["compute_s"] += compute_s

            t0 = time.perf_counter()
            O_tile = self.readback_o(q_end - q_start)
            readback_s = time.perf_counter() - t0
            profile["readback_s"] += readback_s
            O[q_start:q_end] = O_tile

            perf = self.read_perf()
            print(f"  Tile {tile_idx}: cycles={perf['cycles']}")
            profile["tiles"].append({
                "tile_idx": tile_idx,
                "q_rows": q_end - q_start,
                "q_load_s": q_load_s,
                "compute_s": compute_s,
                "readback_s": readback_s,
                "cycles": perf["cycles"],
            })

        if collect_profile:
            return O, profile
        return O


# ============================================================================
# Self-Test (Mock)
# ============================================================================

def _self_test():
    """Verify driver interface without hardware."""
    accel = AttentionAccelerator()
    assert not accel.hw_ready, "Mock should report hw_ready=False"

    L = 64
    Q = np.zeros((L, 4096), dtype=np.float16)
    K = np.zeros((L, 1024), dtype=np.float16)
    V = np.zeros((L, 1024), dtype=np.float16)

    accel.configure(L, 0x10000000, 0x11000000, 0x12000000, 0x13000000)
    accel.start()
    accel.wait_done()

    O = accel.run_attention(Q, K, V)
    assert O.shape == (L, 4096), f"O shape: {O.shape}"
    print("Driver self-test PASSED")


if __name__ == "__main__":
    if "--check" in sys.argv:
        _self_test()
    else:
        print("PYNQ driver for LARA attention accelerator.")
        print(f"HAS_PYNQ={HAS_PYNQ}")
        print("Usage: python attn_driver.py --check")
