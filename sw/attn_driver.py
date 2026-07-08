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
CSR_RESULT_DST  = 0x050
CSR_RESULT_LEN  = 0x058
CSR_PERF_CYCLES = 0x100

# Stream destinations
DEST_K_CACHE = 0
DEST_V_CACHE = 1
DEST_Q_BUF   = 2


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
            self.dma_send = self.overlay.axi_dma_0.sendchannel
            self.dma_recv = self.overlay.axi_dma_0.recvchannel
            self.mmio = self.overlay.attn_accel_0.mmio  # AXI4-Lite
            self._hw_ready = True
        else:
            self.dma_send = None
            self.dma_recv = None
            self.mmio = None
            self._hw_ready = False
            print("Mock driver initialized — set HAS_PYNQ=True for hardware.")

    @property
    def hw_ready(self) -> bool:
        return self._hw_ready

    # ==================================================================
    # Configuration
    # ==================================================================

    def configure(self, seq_len: int, q_addr: int, k_addr: int,
                  v_addr: int, o_addr: int):
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
        # Stream source/dest addresses set per transfer (see load/readback)

    def start(self):
        """Pulse start bit."""
        if self.mmio:
            self.mmio.write(CSR_CTRL, 0x1)  # start=1

    def is_done(self) -> bool:
        """Poll done flag."""
        if self.mmio:
            return bool(self.mmio.read(CSR_STATUS) & 0x2)
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
            k_buf = allocate(shape=(len(k_bytes),), dtype=np.uint8)
            v_buf = allocate(shape=(len(v_bytes),), dtype=np.uint8)
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
            q_buf = allocate(shape=(len(q_bytes),), dtype=np.uint8)
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
            o_buf = allocate(shape=(o_size,), dtype=np.uint8)
            self.mmio.write(CSR_RESULT_LEN, o_size)
            self.dma_recv.transfer(o_buf)
            self.dma_recv.wait()
            O = np.frombuffer(o_buf.tobytes(), dtype=np.uint16).reshape(L, 4096)
            return O.view(np.float16)  # interpret as bf16
        else:
            print(f"READBACK O: [{L}x4096] = {o_size} bytes")
            return np.zeros((L, 4096), dtype=np.float16)

    # ==================================================================
    # High-Level API
    # ==================================================================

    def run_attention(
        self, Q: np.ndarray, K: np.ndarray, V: np.ndarray,
        seq_len: int = None
    ) -> np.ndarray:
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

        # 1. Load K/V cache (once per GQA group)
        self.load_kv_cache(K, V)

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

            self.load_q_tile(Q_tile)
            self.start()
            self.wait_done()

            O_tile = self.readback_o(q_end - q_start)
            O[q_start:q_end] = O_tile

            perf = self.read_perf()
            print(f"  Tile {tile_idx}: cycles={perf['cycles']}")

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
