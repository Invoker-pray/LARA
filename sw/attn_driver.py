#!/usr/bin/env python3
"""PYNQ/host driver for the LARA attention accelerator.

The FPGA owns attention only.  The host performs RMSNorm, QKV projection and
optional RoPE, then this driver services the accelerator's load requests while
one attention transaction is running.  K/V is sent once per GQA group (four Q
heads share it); Q is sent one padded 32-row tile at a time.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any, Optional

import numpy as np

try:  # Keep board-only dependencies out of workstation simulation.
    from pynq import Overlay, allocate  # type: ignore
    HAS_PYNQ = True
except ImportError:  # pragma: no cover
    Overlay = None
    allocate = None
    HAS_PYNQ = False


# CSR map mirrors hw/rtl/pkg/attn_pkg.sv.
CSR_CTRL = 0x000
CSR_STATUS = 0x004
CSR_SEQ_LEN = 0x008
CSR_Q_POS_BASE = 0x00C
CSR_KV_POS_BASE = 0x010
CSR_CFG = 0x014
CSR_ERROR_CODE = 0x018
CSR_LOAD_REQ = 0x01C
CSR_STREAM_LEN = 0x028
CSR_STREAM_DEST = 0x02C
CSR_RESULT_LEN = 0x058
CSR_PERF_CYCLES = 0x100
CSR_PERF_MAC_CYCLES = 0x108
CSR_PERF_STALLS = 0x10C

CTRL_START = 1 << 0
CTRL_CLEAR_STATUS = 1 << 1
STATUS_START_READY = 1 << 0
STATUS_BUSY = 1 << 1
STATUS_DONE = 1 << 2
STATUS_ERROR = 1 << 3
STATUS_STREAM_ERROR = 1 << 4
STATUS_KV_LOAD_REQ = 1 << 5
STATUS_Q_LOAD_REQ = 1 << 6

DEST_K_CACHE = 0
DEST_V_CACHE = 1
DEST_Q_BUF = 2

HEAD_DIM = 128
TILE_Q = 32
N_Q_HEADS = 32
N_KV_HEADS = 8
GQA_GROUP_SIZE = N_Q_HEADS // N_KV_HEADS
MAX_SEQ_LEN = 512
BF16_BYTES = 2

ERR_NONE = 0x00
ERR_BAD_CFG = 0x01
ERR_BUSY_START = 0x02
ERR_STREAM_LEN = 0x10
ERR_STREAM_DEST = 0x11
ERR_RESULT_LEN = 0x12


def fp32_to_bf16_u16(values: np.ndarray) -> np.ndarray:
    """Pack float/quantized values into IEEE bf16 upper-half words."""
    arr = np.asarray(values)
    if arr.dtype == np.uint16:
        return np.ascontiguousarray(arr)
    f32 = np.asarray(arr, dtype=np.float32)
    bits = f32.view(np.uint32).copy()
    truncated = bits & 0xFFFF
    round_up = ((truncated >> 15) & 1) & (((bits >> 16) & 1) | ((truncated & 0x7FFF) != 0))
    bits = (bits + round_up.astype(np.uint32)) & np.uint32(0xFFFF0000)
    return np.ascontiguousarray((bits >> 16).astype(np.uint16))


def bf16_u16_to_fp32(values: np.ndarray) -> np.ndarray:
    words = np.asarray(values, dtype=np.uint16)
    return (words.astype(np.uint32) << 16).view(np.float32)


class MockMMIO:
    """Traceable MMIO model that exercises the same request-service loop."""

    def __init__(self) -> None:
        self.regs: dict[int, int] = {CSR_STATUS: STATUS_START_READY}
        self.trace: list[tuple[str, int, int]] = []
        self.requests: list[dict[str, int]] = []
        self.current: Optional[dict[str, int]] = None
        self.kv_stage = 0
        self.started = False

    def prepare(self, seq_len: int) -> None:
        self.requests = []
        for group in range(N_KV_HEADS):
            self.requests.append({"kind": 0, "group": group})
            for head in range(GQA_GROUP_SIZE):
                for tile in range((seq_len + TILE_Q - 1) // TILE_Q):
                    self.requests.append({"kind": 1, "group": group, "head": head, "tile": tile, "bank": tile & 1})
        self.current = None
        self.kv_stage = 0
        self.started = False

    def _request_word(self) -> int:
        if self.current is None and self.requests:
            self.current = self.requests[0]
        if self.current is None:
            return 0
        req = self.current
        if req["kind"] == 0:
            return 1 | ((req["group"] & 7) << 4)
        return 2 | ((req["bank"] & 1) << 2) | ((req["group"] & 7) << 8) | ((req["head"] & 3) << 12) | ((req["tile"] & 0xFF) << 16)

    def write(self, offset: int, value: int) -> None:
        value = int(value) & 0xFFFFFFFF
        self.trace.append(("write", offset, value))
        if offset == CSR_CTRL:
            if value & CTRL_CLEAR_STATUS:
                self.regs[CSR_STATUS] = STATUS_START_READY
                self.regs[CSR_ERROR_CODE] = ERR_NONE
            if value & CTRL_START:
                self.started = True
                self.regs[CSR_STATUS] = STATUS_BUSY
            return
        self.regs[offset] = value

    def read(self, offset: int) -> int:
        if offset == CSR_LOAD_REQ:
            value = self._request_word()
        elif offset == CSR_STATUS:
            if not self.started:
                value = STATUS_START_READY
                self.trace.append(("read", offset, value))
                return value
            if self.current is None and self.requests:
                self.current = self.requests[0]
            if self.current is not None:
                value = STATUS_BUSY | (STATUS_KV_LOAD_REQ if self.current["kind"] == 0 else STATUS_Q_LOAD_REQ)
            else:
                value = STATUS_DONE | STATUS_START_READY
        else:
            value = self.regs.get(offset, 0)
        self.trace.append(("read", offset, value))
        return value

    def transfer_complete(self, dest: int) -> None:
        if self.current is None:
            return
        if self.current["kind"] == 0:
            if self.kv_stage == 0 and dest == DEST_K_CACHE:
                self.kv_stage = 1
            elif self.kv_stage == 1 and dest == DEST_V_CACHE:
                self.requests.pop(0)
                self.current = None
                self.kv_stage = 0
        elif dest == DEST_Q_BUF:
            self.requests.pop(0)
            self.current = None


class MockDMAChannel:
    def __init__(self, name: str) -> None:
        self.name = name
        self.trace: list[tuple[str, str, int]] = []
        self.last_buffer: Optional[np.ndarray] = None

    def transfer(self, buf: np.ndarray) -> None:
        self.last_buffer = buf
        self.trace.append(("transfer", self.name, int(buf.nbytes)))

    def wait(self) -> None:
        self.trace.append(("wait", self.name, 0))


@dataclass(frozen=True)
class TensorByteCounts:
    q_bytes: int
    k_bytes: int
    v_bytes: int
    o_bytes: int


class AttentionAccelerator:
    def __init__(self, bitstream_path: str | None = None, overlay: Any | None = None) -> None:
        if HAS_PYNQ:
            self.overlay = overlay if overlay is not None else Overlay(bitstream_path)
            dma = getattr(self.overlay, "axi_dma", None) or getattr(self.overlay, "axi_dma_0")
            accel = getattr(self.overlay, "accel", None) or getattr(self.overlay, "attn_accel_0")
            self.dma_send = dma.sendchannel
            self.dma_recv = dma.recvchannel
            self.mmio = accel.mmio
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
    def _validate_seq_len(seq_len: int) -> None:
        if not 1 <= int(seq_len) <= MAX_SEQ_LEN:
            raise ValueError(f"seq_len must be in 1..{MAX_SEQ_LEN}, got {seq_len}")

    @classmethod
    def byte_counts(cls, seq_len: int) -> TensorByteCounts:
        cls._validate_seq_len(seq_len)
        return TensorByteCounts(
            N_Q_HEADS * seq_len * HEAD_DIM * BF16_BYTES,
            N_KV_HEADS * seq_len * HEAD_DIM * BF16_BYTES,
            N_KV_HEADS * seq_len * HEAD_DIM * BF16_BYTES,
            N_Q_HEADS * seq_len * HEAD_DIM * BF16_BYTES,
        )

    def clear_status(self) -> None:
        self.mmio.write(CSR_CTRL, CTRL_CLEAR_STATUS)

    def configure(self, seq_len: int, *, q_pos_base: int = 0, kv_pos_base: int = 0, causal: bool = True) -> None:
        self._validate_seq_len(seq_len)
        if q_pos_base < 0 or kv_pos_base < 0 or q_pos_base + seq_len > MAX_SEQ_LEN or kv_pos_base + seq_len > MAX_SEQ_LEN:
            raise ValueError("position base + seq_len exceeds MAX_SEQ_LEN")
        self.mmio.write(CSR_SEQ_LEN, seq_len)
        self.mmio.write(CSR_Q_POS_BASE, q_pos_base)
        self.mmio.write(CSR_KV_POS_BASE, kv_pos_base)
        self.mmio.write(CSR_CFG, int(causal))

    def _transfer(self, dest: int, payload: np.ndarray) -> None:
        words = fp32_to_bf16_u16(payload)
        payload_u8 = words.reshape(-1).view(np.uint8)
        self.mmio.write(CSR_STREAM_DEST, dest)
        self.mmio.write(CSR_STREAM_LEN, int(payload_u8.nbytes))
        if HAS_PYNQ:
            buf = allocate(shape=(payload_u8.size,), dtype=np.uint8)
            buf[:] = payload_u8
            if hasattr(buf, "flush"):
                buf.flush()
        else:
            buf = payload_u8.copy()
        self.dma_send.transfer(buf)
        self.dma_send.wait()
        if hasattr(self.mmio, "transfer_complete"):
            self.mmio.transfer_complete(dest)

    def _service_request(self, req: int, q_heads: np.ndarray, k_heads: np.ndarray, v_heads: np.ndarray, seq_len: int) -> None:
        if req & 1:
            group = (req >> 4) & 0x7
            self._transfer(DEST_K_CACHE, k_heads[group, :seq_len, :])
            self._transfer(DEST_V_CACHE, v_heads[group, :seq_len, :])
        elif req & 2:
            group = (req >> 8) & 0x7
            head = (req >> 12) & 0x3
            tile = (req >> 16) & 0xFF
            q_tile = np.zeros((TILE_Q, HEAD_DIM), dtype=np.uint16)
            q_src = q_heads[group * GQA_GROUP_SIZE + head]
            lo = tile * TILE_Q
            q_tile[: max(0, min(TILE_Q, seq_len - lo)), :] = q_src[lo:lo + TILE_Q, :]
            self._transfer(DEST_Q_BUF, q_tile)

    def _allocate_recv(self, nbytes: int) -> np.ndarray:
        if HAS_PYNQ:
            return allocate(shape=(nbytes,), dtype=np.uint8)
        return np.zeros((nbytes,), dtype=np.uint8)

    def start(self) -> None:
        if not (self.mmio.read(CSR_STATUS) & STATUS_START_READY):
            raise RuntimeError("accelerator is not ready to accept start")
        self.mmio.write(CSR_CTRL, CTRL_START)

    def status(self) -> int:
        return self.mmio.read(CSR_STATUS)

    def wait_done(self, q_heads: np.ndarray, k_heads: np.ndarray, v_heads: np.ndarray, seq_len: int, timeout_ms: int = 30000) -> None:
        deadline = time.monotonic() + timeout_ms / 1000.0
        while True:
            status = self.status()
            if status & (STATUS_ERROR | STATUS_STREAM_ERROR):
                code = self.mmio.read(CSR_ERROR_CODE) & 0xFF
                raise RuntimeError(f"accelerator error status=0x{status:08x}, code=0x{code:02x}")
            if status & STATUS_DONE:
                return
            if status & (STATUS_KV_LOAD_REQ | STATUS_Q_LOAD_REQ):
                self._service_request(self.mmio.read(CSR_LOAD_REQ), q_heads, k_heads, v_heads, seq_len)
            if time.monotonic() > deadline:
                raise TimeoutError("attention accelerator timed out while servicing load requests")
            if self._hw_ready:
                time.sleep(0.0005)

    def readback_o(self, seq_len: int, out_buf: np.ndarray) -> np.ndarray:
        self.dma_recv.wait()
        if HAS_PYNQ and hasattr(out_buf, "invalidate"):
            out_buf.invalidate()
        return np.frombuffer(out_buf.tobytes(), dtype=np.uint16).reshape(N_Q_HEADS, seq_len, HEAD_DIM)

    def read_perf(self) -> dict[str, int]:
        return {"cycles": self.mmio.read(CSR_PERF_CYCLES), "mac_cycles": self.mmio.read(CSR_PERF_MAC_CYCLES), "stall_cycles": self.mmio.read(CSR_PERF_STALLS)}

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
        timeout_ms: int = 30000,
    ) -> np.ndarray:
        """Run one full transaction; returns raw head-major bf16 words."""
        L = int(seq_len if seq_len is not None else q_heads.shape[1])
        self._validate_seq_len(L)
        expected_q = (N_Q_HEADS, L, HEAD_DIM)
        expected_kv = (N_KV_HEADS, L, HEAD_DIM)
        if q_heads.shape != expected_q or k_heads.shape != expected_kv or v_heads.shape != expected_kv:
            raise ValueError(f"expected Q={expected_q}, K/V={expected_kv}; got {q_heads.shape}, {k_heads.shape}, {v_heads.shape}")

        q_u16 = fp32_to_bf16_u16(q_heads)
        k_u16 = fp32_to_bf16_u16(k_heads)
        v_u16 = fp32_to_bf16_u16(v_heads)
        self.configure(L, q_pos_base=q_pos_base, kv_pos_base=kv_pos_base, causal=causal)
        self.clear_status()
        counts = self.byte_counts(L)
        self.mmio.write(CSR_RESULT_LEN, counts.o_bytes)
        out_buf = self._allocate_recv(counts.o_bytes)
        self.dma_recv.transfer(out_buf)  # arm S2MM before source can emit
        if hasattr(self.mmio, "prepare"):
            self.mmio.prepare(L)
        self.start()
        self.wait_done(q_u16, k_u16, v_u16, L, timeout_ms=timeout_ms)
        return self.readback_o(L, out_buf)

    def run_layer(self, hidden_states: np.ndarray, wq: np.ndarray, wk: np.ndarray, wv: np.ndarray,
                  rms_weight: np.ndarray | None = None, *, q_pos_base: int = 0,
                  kv_pos_base: int = 0, causal: bool = True, timeout_ms: int = 30000) -> np.ndarray:
        """Host QKV projection + optional RoPE, followed by FPGA attention."""
        try:
            from .host_attention import apply_rope_host, qkv_project, reshape_to_heads, rms_norm
        except ImportError:  # script execution from the sw/ directory
            from host_attention import apply_rope_host, qkv_project, reshape_to_heads, rms_norm
        x = hidden_states if rms_weight is None else rms_norm(hidden_states, rms_weight)
        q, k, v = qkv_project(x, wq, wk, wv)
        qh, kh, vh = reshape_to_heads(q, k, v)
        for group in range(N_KV_HEADS):
            for head in range(GQA_GROUP_SIZE):
                qh[group * GQA_GROUP_SIZE + head] = apply_rope_host(
                    qh[group * GQA_GROUP_SIZE + head], head_dim=HEAD_DIM,
                    position_base=q_pos_base)
            kh[group] = apply_rope_host(kh[group], head_dim=HEAD_DIM,
                                        position_base=kv_pos_base)
        out_words = self.run_attention(qh, kh, vh, q_pos_base=q_pos_base, kv_pos_base=kv_pos_base, causal=causal, timeout_ms=timeout_ms)
        return bf16_u16_to_fp32(out_words).transpose(1, 0, 2).reshape(hidden_states.shape[0], N_Q_HEADS * HEAD_DIM)


def _self_test() -> None:
    accel = AttentionAccelerator()
    assert not accel.hw_ready
    L = 16
    q = np.zeros((N_Q_HEADS, L, HEAD_DIM), dtype=np.uint16)
    k = np.zeros((N_KV_HEADS, L, HEAD_DIM), dtype=np.uint16)
    v = np.zeros((N_KV_HEADS, L, HEAD_DIM), dtype=np.uint16)
    out = accel.run_attention(q, k, v, seq_len=L)
    assert out.shape == (N_Q_HEADS, L, HEAD_DIM)
    assert len([x for x in accel.dma_send.trace if x[0] == "transfer"]) == N_KV_HEADS * 2 + N_KV_HEADS * GQA_GROUP_SIZE
    print("attn_driver request-service mock self-test PASSED")


if __name__ == "__main__":
    _self_test()
