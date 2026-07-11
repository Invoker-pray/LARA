#!/usr/bin/env python3
"""
PYNQ driver for the Phase-1 attention accelerator contract.

Main mode: full_run_preload_then_start
  1. Software starts PYNQ DMA transfers for complete K, V, and Q tensors.
  2. CSR_STREAM_DEST/CSR_STREAM_LEN configure the PL-side stream checker only.
  3. A single CSR_CTRL.start launches the full-run core transaction.
  4. Software receives the complete O tensor through the output DMA.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any, Optional

import numpy as np

try:
    from pynq import Overlay, allocate  # type: ignore
    HAS_PYNQ = True
except ImportError:  # pragma: no cover - exercised on non-KV260 hosts
    Overlay = None
    allocate = None
    HAS_PYNQ = False


# CSR map, mirrored from src/hw/rtl/pkg/attn_pkg.sv
CSR_CTRL = 0x000
CSR_STATUS = 0x004
CSR_SEQ_LEN = 0x008
CSR_Q_POS_BASE = 0x00C
CSR_KV_POS_BASE = 0x010
CSR_CFG = 0x014
CSR_ERROR_CODE = 0x018
CSR_STREAM_LEN = 0x028
CSR_STREAM_DEST = 0x02C
CSR_RESULT_LEN = 0x058
CSR_PERF_CYCLES = 0x100
CSR_PERF_MAC_CYCLES = 0x108

CTRL_START = 1 << 0
CTRL_CLEAR_STATUS = 1 << 1
STATUS_START_READY = 1 << 0
STATUS_BUSY = 1 << 1
STATUS_DONE = 1 << 2
STATUS_ERROR = 1 << 3
STATUS_STREAM_ERROR = 1 << 4

DEST_K_CACHE = 0
DEST_V_CACHE = 1
DEST_Q_BUF = 2

HEAD_DIM = 128
N_Q_HEADS = 32
N_KV_HEADS = 8
MAX_SEQ_LEN = 2048
BF16_BYTES = 2

ERR_NONE = 0x00
ERR_BAD_CFG = 0x01
ERR_BUSY_START = 0x02
ERR_STREAM_LEN = 0x10
ERR_STREAM_DEST = 0x11
ERR_RESULT_LEN = 0x12


class MockMMIO:
    """Small MMIO stand-in for workstation tests."""

    def __init__(self) -> None:
        self.regs: dict[int, int] = {CSR_STATUS: STATUS_START_READY}
        self.trace: list[tuple[str, int, int]] = []

    def write(self, offset: int, value: int) -> None:
        value = int(value) & 0xFFFFFFFF
        self.trace.append(("write", offset, value))
        if offset == CSR_CTRL:
            if value & CTRL_CLEAR_STATUS:
                self.regs[CSR_STATUS] = STATUS_START_READY
                self.regs[CSR_ERROR_CODE] = ERR_NONE
            if value & CTRL_START:
                self.regs[CSR_STATUS] = STATUS_DONE | STATUS_START_READY
            return
        self.regs[offset] = value

    def read(self, offset: int) -> int:
        value = self.regs.get(offset, 0)
        self.trace.append(("read", offset, value))
        return value


class MockDMAChannel:
    def __init__(self, name: str = "dma") -> None:
        self.name = name
        self.last_buffer: Optional[np.ndarray] = None
        self.trace: list[tuple[str, str, int]] = []

    def transfer(self, buf: np.ndarray) -> None:
        self.last_buffer = buf
        self.trace.append(("transfer", self.name, int(buf.nbytes)))

    def wait(self) -> None:
        self.trace.append(("wait", self.name, 0))
        return


@dataclass(frozen=True)
class TensorByteCounts:
    q_bytes: int
    k_bytes: int
    v_bytes: int
    o_bytes: int


class AttentionAccelerator:
    """Driver matching docs/spec/interfaces.md full-run control contract."""

    def __init__(self, bitstream_path: str | None = None, overlay: Any | None = None) -> None:
        if HAS_PYNQ:
            self.overlay = overlay if overlay is not None else Overlay(bitstream_path)
            self.dma_send = self.overlay.axi_dma_0.sendchannel
            self.dma_recv = self.overlay.axi_dma_0.recvchannel
            self.mmio = self.overlay.attn_accel_0.mmio
            self._hw_ready = True
        else:
            self.overlay = None
            self.dma_send = MockDMAChannel("send")
            self.dma_recv = MockDMAChannel("recv")
            self.mmio = MockMMIO()
            self._hw_ready = False

    @property
    def hw_ready(self) -> bool:
        return self._hw_ready

    @staticmethod
    def byte_counts(seq_len: int) -> TensorByteCounts:
        AttentionAccelerator._validate_seq_len(seq_len)
        return TensorByteCounts(
            q_bytes=N_Q_HEADS * seq_len * HEAD_DIM * BF16_BYTES,
            k_bytes=N_KV_HEADS * seq_len * HEAD_DIM * BF16_BYTES,
            v_bytes=N_KV_HEADS * seq_len * HEAD_DIM * BF16_BYTES,
            o_bytes=N_Q_HEADS * seq_len * HEAD_DIM * BF16_BYTES,
        )

    @staticmethod
    def _validate_seq_len(seq_len: int) -> None:
        if seq_len <= 0 or seq_len > MAX_SEQ_LEN:
            raise ValueError(f"seq_len must be in 1..{MAX_SEQ_LEN}, got {seq_len}")

    @staticmethod
    def _as_u16_contiguous(array: np.ndarray, expected_shape: tuple[int, ...], name: str) -> np.ndarray:
        if array.shape != expected_shape:
            raise ValueError(f"{name} shape must be {expected_shape}, got {array.shape}")
        if array.dtype == np.uint16:
            return np.ascontiguousarray(array)
        return np.ascontiguousarray(array.view(np.uint16))

    def clear_status(self) -> None:
        self.mmio.write(CSR_CTRL, CTRL_CLEAR_STATUS)

    def configure(self, seq_len: int, q_pos_base: int = 0, kv_pos_base: int = 0, causal: bool = True) -> None:
        self._validate_seq_len(seq_len)
        if q_pos_base < 0 or kv_pos_base < 0:
            raise ValueError("position bases must be non-negative")
        if q_pos_base + seq_len > MAX_SEQ_LEN or kv_pos_base + seq_len > MAX_SEQ_LEN:
            raise ValueError("position base + seq_len exceeds MAX_SEQ_LEN")

        self.mmio.write(CSR_SEQ_LEN, seq_len)
        self.mmio.write(CSR_Q_POS_BASE, q_pos_base)
        self.mmio.write(CSR_KV_POS_BASE, kv_pos_base)
        self.mmio.write(CSR_CFG, 1 if causal else 0)

    def _transfer_to_device(self, dest: int, payload_u16: np.ndarray) -> None:
        byte_len = payload_u16.nbytes
        self.mmio.write(CSR_STREAM_DEST, dest)
        self.mmio.write(CSR_STREAM_LEN, byte_len)

        if HAS_PYNQ:
            buf = allocate(shape=(byte_len,), dtype=np.uint8)
            buf[:] = payload_u16.view(np.uint8).reshape(-1)
        else:
            buf = payload_u16.view(np.uint8).reshape(-1).copy()

        self.dma_send.transfer(buf)
        self.dma_send.wait()

    def preload_k(self, k_heads: np.ndarray, seq_len: int) -> None:
        expected = (N_KV_HEADS, seq_len, HEAD_DIM)
        self._transfer_to_device(DEST_K_CACHE, self._as_u16_contiguous(k_heads, expected, "K"))

    def preload_v(self, v_heads: np.ndarray, seq_len: int) -> None:
        expected = (N_KV_HEADS, seq_len, HEAD_DIM)
        self._transfer_to_device(DEST_V_CACHE, self._as_u16_contiguous(v_heads, expected, "V"))

    def preload_q(self, q_heads: np.ndarray, seq_len: int) -> None:
        expected = (N_Q_HEADS, seq_len, HEAD_DIM)
        self._transfer_to_device(DEST_Q_BUF, self._as_u16_contiguous(q_heads, expected, "Q"))

    def start(self) -> None:
        status = self.mmio.read(CSR_STATUS)
        if not (status & STATUS_START_READY):
            raise RuntimeError("accelerator is not ready to accept start")
        self.mmio.write(CSR_CTRL, CTRL_START)

    def status(self) -> int:
        return self.mmio.read(CSR_STATUS)

    def is_done(self) -> bool:
        return bool(self.status() & STATUS_DONE)

    def check_errors(self) -> None:
        status = self.status()
        if status & (STATUS_ERROR | STATUS_STREAM_ERROR):
            code = self.mmio.read(CSR_ERROR_CODE) & 0xFF
            raise RuntimeError(f"accelerator error status=0x{status:08x}, code=0x{code:02x}")

    def wait_done(self, timeout_ms: int = 5000) -> None:
        deadline = time.time() + timeout_ms / 1000.0
        while not self.is_done():
            self.check_errors()
            if time.time() > deadline:
                raise TimeoutError("attention accelerator timed out")
            time.sleep(0.001)
        self.check_errors()

    def readback_o(self, seq_len: int) -> np.ndarray:
        counts = self.byte_counts(seq_len)
        self.mmio.write(CSR_RESULT_LEN, counts.o_bytes)

        if HAS_PYNQ:
            out_buf = allocate(shape=(counts.o_bytes,), dtype=np.uint8)
        else:
            out_buf = np.zeros((counts.o_bytes,), dtype=np.uint8)

        self.dma_recv.transfer(out_buf)
        self.dma_recv.wait()
        return np.frombuffer(out_buf.tobytes(), dtype=np.uint16).reshape(N_Q_HEADS, seq_len, HEAD_DIM)

    def read_perf(self) -> dict[str, int]:
        return {
            "cycles": self.mmio.read(CSR_PERF_CYCLES),
            "mac_cycles": self.mmio.read(CSR_PERF_MAC_CYCLES),
        }

    def run_attention(
        self,
        q_heads: np.ndarray,
        k_heads: np.ndarray,
        v_heads: np.ndarray,
        *,
        seq_len: int | None = None,
        q_pos_base: int = 0,
        kv_pos_base: int = 0,
        causal: bool = True,
        timeout_ms: int = 5000,
    ) -> np.ndarray:
        """Run one full attention transaction with head-major tensors."""
        L = int(seq_len if seq_len is not None else q_heads.shape[1])
        self.configure(L, q_pos_base=q_pos_base, kv_pos_base=kv_pos_base, causal=causal)
        self.clear_status()
        self.preload_k(k_heads, L)
        self.preload_v(v_heads, L)
        self.preload_q(q_heads, L)
        self.mmio.write(CSR_RESULT_LEN, self.byte_counts(L).o_bytes)
        self.start()
        self.wait_done(timeout_ms=timeout_ms)
        return self.readback_o(L)


def _self_test() -> None:
    accel = AttentionAccelerator()
    assert not accel.hw_ready

    seq_len = 16
    counts = accel.byte_counts(seq_len)
    assert counts.q_bytes == 32 * seq_len * 128 * 2
    assert counts.k_bytes == 8 * seq_len * 128 * 2
    assert counts.v_bytes == counts.k_bytes
    assert counts.o_bytes == counts.q_bytes

    q = np.zeros((N_Q_HEADS, seq_len, HEAD_DIM), dtype=np.uint16)
    k = np.zeros((N_KV_HEADS, seq_len, HEAD_DIM), dtype=np.uint16)
    v = np.zeros((N_KV_HEADS, seq_len, HEAD_DIM), dtype=np.uint16)
    o = accel.run_attention(q, k, v, seq_len=seq_len)
    assert o.shape == (N_Q_HEADS, seq_len, HEAD_DIM)
    print("attn_driver full-run mock self-test PASSED")


if __name__ == "__main__":
    _self_test()