#!/usr/bin/env python3
"""PYNQ/host driver for the LARA attention accelerator.

The FPGA owns attention only.  The host performs RMSNorm, QKV projection and
optional RoPE, then this driver services the accelerator's load requests while
one attention transaction is running.  K/V is sent once per GQA group (four Q
heads share it); Q is sent one padded 32-row tile at a time.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import subprocess
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

import numpy as np

try:  # Keep board-only dependencies out of workstation simulation.
    from pynq import Clocks, Overlay, allocate  # type: ignore
    HAS_PYNQ = True
except ImportError:  # pragma: no cover
    Clocks = None
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
CSR_DESC_PUSH = 0x030
CSR_DESC_STATUS = 0x034
CSR_DESC_CTRL = 0x038
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

DESC_STATUS_SUPPORTED = 1 << 31
DESC_STATUS_INBAND_SUPPORTED = 1 << 30
DESC_STATUS_INBAND_ENABLED = 1 << 11
DESC_STATUS_ENABLED = 1 << 10
DESC_STATUS_FULL = 1 << 9
DESC_STATUS_EMPTY = 1 << 8
DESC_STATUS_COUNT_MASK = 0x3F
DESC_CTRL_ENABLE = 1 << 0
DESC_CTRL_CLEAR = 1 << 1
DESC_CTRL_INBAND = 1 << 2

DEST_K_CACHE = 0
DEST_V_CACHE = 1
DEST_Q_BUF = 2

HEAD_DIM = 128
TILE_Q = 32
N_Q_HEADS = 32
N_KV_HEADS = 8
GQA_GROUP_SIZE = N_Q_HEADS // N_KV_HEADS
MAX_SEQ_LEN = 512
ABSOLUTE_POSITION_LIMIT = 1 << 16
BF16_BYTES = 2
# 76.922310 MHz missed post-route setup timing; retain it for rollback evidence.
# PL_CLOCK_MHZ = 76.922310
PL_CLOCK_MHZ = 71.427856
DMA_LENGTH_WIDTH = 26
DMA_MAX_TRANSFER_BYTES = (1 << DMA_LENGTH_WIDTH) - 1
MAX_KV_HEAD_BYTES = MAX_SEQ_LEN * HEAD_DIM * BF16_BYTES
Q_TILE_BYTES = TILE_Q * HEAD_DIM * BF16_BYTES
MAX_BATCH_INPUT_BYTES = 2 * MAX_KV_HEAD_BYTES + Q_TILE_BYTES
MAX_OUTPUT_BYTES = N_Q_HEADS * MAX_SEQ_LEN * HEAD_DIM * BF16_BYTES
MAX_INPUT_PAYLOAD_BYTES = (
    N_Q_HEADS * MAX_SEQ_LEN * HEAD_DIM * BF16_BYTES
    + 2 * N_KV_HEADS * MAX_SEQ_LEN * HEAD_DIM * BF16_BYTES
)
MAX_INPUT_DESCRIPTORS = (
    2 * N_KV_HEADS
    + N_Q_HEADS * ((MAX_SEQ_LEN + TILE_Q - 1) // TILE_Q)
)
MAX_STREAM_INPUT_BYTES = MAX_INPUT_PAYLOAD_BYTES + 4 * MAX_INPUT_DESCRIPTORS
DEFAULT_REQUEST_POLL_SLEEP_US = 20.0
REQUEST_POLL_SLEEP_US_ENV = "LARA_REQUEST_POLL_SLEEP_US"
STREAM_MODE_ENV = "LARA_STREAM_MODE"
STREAM_MODES = ("auto", "inband", "descriptor", "legacy")
PREFETCH_MODE_ENV = "LARA_PREFETCH_MODE"
PREFETCH_MODES = ("off", "descriptor", "inband")

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
            value = 1 | ((req["group"] & 7) << 4)
            if len(self.requests) > 1 and self.requests[1]["kind"] == 1:
                q_req = self.requests[1]
                value |= (
                    2
                    | ((q_req["bank"] & 1) << 2)
                    | ((q_req["group"] & 7) << 8)
                    | ((q_req["head"] & 3) << 12)
                    | ((q_req["tile"] & 0xFF) << 16)
                )
            return value
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
        if offset == CSR_DESC_CTRL:
            enabled = bool(value & DESC_CTRL_ENABLE)
            self.regs[CSR_DESC_CTRL] = int(value & (DESC_CTRL_ENABLE | DESC_CTRL_INBAND))
            if value & DESC_CTRL_CLEAR:
                self.regs[CSR_DESC_STATUS] = (
                    DESC_STATUS_SUPPORTED
                    | DESC_STATUS_INBAND_SUPPORTED
                    | (DESC_STATUS_ENABLED if enabled else 0)
                    | (DESC_STATUS_INBAND_ENABLED if value & DESC_CTRL_INBAND else 0)
                    | DESC_STATUS_EMPTY
                )
            return
        if offset == CSR_DESC_PUSH:
            ctrl = self.regs.get(CSR_DESC_CTRL, 0)
            if not (ctrl & DESC_CTRL_ENABLE) or (ctrl & DESC_CTRL_INBAND):
                return
            status = self.regs.get(
                CSR_DESC_STATUS,
                DESC_STATUS_SUPPORTED | DESC_STATUS_EMPTY,
            )
            count = (status & DESC_STATUS_COUNT_MASK) + 1
            self.regs[CSR_DESC_STATUS] = (
                DESC_STATUS_SUPPORTED
                | DESC_STATUS_INBAND_SUPPORTED
                | (status & DESC_STATUS_ENABLED)
                | (status & DESC_STATUS_INBAND_ENABLED)
                | (count & DESC_STATUS_COUNT_MASK)
            )
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
            value = self.regs.get(
                offset,
                DESC_STATUS_SUPPORTED | DESC_STATUS_INBAND_SUPPORTED | DESC_STATUS_EMPTY
                if offset == CSR_DESC_STATUS else 0,
            )
        self.trace.append(("read", offset, value))
        return value

    def transfer_complete(self, dest: int) -> None:
        if self.current is None and self.requests:
            self.current = self.requests[0]
        if self.current is None:
            return
        if self.current["kind"] == 0:
            if self.kv_stage == 0 and dest == DEST_K_CACHE:
                self.kv_stage = 1
            elif self.kv_stage == 1 and dest == DEST_V_CACHE:
                self.requests.pop(0)
                self.current = self.requests[0] if self.requests else None
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


@dataclass
class RunProfile:
    timestamp_utc: str
    git_commit: str
    bitstream_sha256: str | None
    clock_mhz: float
    seq_len: int
    causal: bool
    q_pos_base: int
    kv_pos_base: int
    host_rms_norm_ms: float = 0.0
    host_qkv_projection_ms: float = 0.0
    host_rope_ms: float = 0.0
    input_pack_ms: float = 0.0
    driver_setup_ms: float = 0.0
    request_service_ms: float = 0.0
    request_poll_sleep_us: float = 0.0
    request_poll_sleeps: int = 0
    request_duplicate_polls: int = 0
    descriptor_queue_supported: bool = False
    descriptor_queue_enabled: bool = False
    inband_command_supported: bool = False
    inband_command_enabled: bool = False
    input_transport: str = "legacy"
    # v3.1 experiment gate.  This is intentionally metadata-only until the
    # RTL exposes a verified ownership/ready protocol for overlapping loads.
    prefetch_mode: str = "off"
    buffer_wait_ms: float = 0.0
    input_dma_overlap_ms: float = 0.0
    transport_stall_ms: float = 0.0
    input_dma_setup_ms: float = 0.0
    input_dma_transfer_ms: float = 0.0
    input_dma_transfers: int = 0
    input_dma_bytes: int = 0
    input_dma_protocol_bytes: int = 0
    input_dma_wire_bytes: int = 0
    input_dma_descriptors: int = 0
    input_dma_batched_transfers: int = 0
    input_dma_max_segments: int = 0
    output_dma_setup_ms: float = 0.0
    output_dma_transfer_ms: float = 0.0
    attention_total_ms: float = 0.0
    layer_total_ms: float = 0.0
    kv_dma_setup_ms: float = 0.0
    kv_dma_transfer_ms: float = 0.0
    kv_dma_transfers: int = 0
    kv_dma_bytes: int = 0
    q_dma_setup_ms: float = 0.0
    q_dma_transfer_ms: float = 0.0
    q_dma_transfers: int = 0
    q_dma_bytes: int = 0
    output_dma_transfers: int = 0
    output_dma_bytes: int = 0
    pl_total_cycles: int = 0
    pl_mac_cycles: int = 0
    pl_stall_cycles: int = 0
    pl_core_active_cycles_excluding_stalls: int = 0
    pl_total_ms: float = 0.0
    pl_mac_ms: float = 0.0
    pl_stall_ms: float = 0.0
    pl_core_active_ms_excluding_stalls: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class AttentionAccelerator:
    def __init__(
        self,
        bitstream_path: str | None = None,
        overlay: Any | None = None,
        request_poll_sleep_us: float | None = None,
        stream_mode: str | None = None,
        prefetch_mode: str | None = None,
    ) -> None:
        self.bitstream_path = str(Path(bitstream_path).resolve()) if bitstream_path else None
        self._git_hash = self._git_commit()
        self._bitstream_hash = self._bitstream_sha256()
        self._pl_clock_mhz = PL_CLOCK_MHZ
        if request_poll_sleep_us is None:
            raw_poll_sleep = os.environ.get(
                REQUEST_POLL_SLEEP_US_ENV,
                str(DEFAULT_REQUEST_POLL_SLEEP_US),
            )
            try:
                request_poll_sleep_us = float(raw_poll_sleep)
            except ValueError as exc:
                raise ValueError(
                    f"{REQUEST_POLL_SLEEP_US_ENV} must be a non-negative number, "
                    f"got {raw_poll_sleep!r}"
                ) from exc
        if not math.isfinite(request_poll_sleep_us) or request_poll_sleep_us < 0:
            raise ValueError("request_poll_sleep_us must be a finite non-negative number")
        self._request_poll_sleep_us = float(request_poll_sleep_us)
        self._request_poll_sleep_s = self._request_poll_sleep_us / 1.0e6
        if stream_mode is None:
            stream_mode = os.environ.get(STREAM_MODE_ENV, "auto")
        stream_mode = stream_mode.strip().lower()
        if stream_mode not in STREAM_MODES:
            raise ValueError(
                f"{STREAM_MODE_ENV}/stream_mode must be one of {STREAM_MODES}, got {stream_mode!r}"
            )
        self._requested_stream_mode = stream_mode
        if prefetch_mode is None:
            prefetch_mode = os.environ.get(PREFETCH_MODE_ENV, "off")
        prefetch_mode = prefetch_mode.strip().lower()
        if prefetch_mode not in PREFETCH_MODES:
            raise ValueError(
                f"{PREFETCH_MODE_ENV}/prefetch_mode must be one of {PREFETCH_MODES}, "
                f"got {prefetch_mode!r}"
            )
        # Until the matching RTL ownership protocol lands, non-off modes are
        # accepted for A/B manifest generation but do not alter transport.
        self._requested_prefetch_mode = prefetch_mode
        if HAS_PYNQ:
            self.overlay = overlay if overlay is not None else Overlay(bitstream_path)
            # Overlay.download applies the HWH divisors but does not reprogram
            # the board image's source PLL.  On KV260 that can turn the design
            # time 14:1 divisor into roughly 107 MHz.  Request the signed-off
            # frequency against the live PLL, then use the hardware readback
            # for all cycle-to-time conversion.
            Clocks.fclk0_mhz = PL_CLOCK_MHZ
            self._pl_clock_mhz = float(Clocks.fclk0_mhz)
            if abs(self._pl_clock_mhz - PL_CLOCK_MHZ) > 0.05:
                raise RuntimeError(
                    "unable to set PL FCLK0 to the signed-off frequency: "
                    f"requested={PL_CLOCK_MHZ:.6f} MHz, "
                    f"actual={self._pl_clock_mhz:.6f} MHz"
                )
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
        self._kv_send_buf = self._allocate_buffer(MAX_KV_HEAD_BYTES)
        self._q_send_buf = self._allocate_buffer(Q_TILE_BYTES)
        self._batch_send_buf = self._allocate_buffer(MAX_BATCH_INPUT_BYTES)
        self._stream_send_buf = self._allocate_buffer(MAX_STREAM_INPUT_BYTES)
        self._out_buf = self._allocate_buffer(MAX_OUTPUT_BYTES)
        self._q_tile_words = np.zeros((TILE_Q, HEAD_DIM), dtype=np.uint16)
        self._closed = False
        self.last_profile: RunProfile | None = None
        desc_status = self.mmio.read(CSR_DESC_STATUS)
        self._descriptor_queue_supported = bool(desc_status & DESC_STATUS_SUPPORTED)
        self._inband_command_supported = bool(desc_status & DESC_STATUS_INBAND_SUPPORTED)
        self._descriptor_queue_enabled = False
        self._inband_command_enabled = False
        self._input_transport = "legacy"

    @property
    def hw_ready(self) -> bool:
        return self._hw_ready

    @staticmethod
    def _allocate_buffer(nbytes: int) -> np.ndarray:
        if HAS_PYNQ:
            return allocate(shape=(nbytes,), dtype=np.uint8)
        return np.zeros((nbytes,), dtype=np.uint8)

    @staticmethod
    def _git_commit() -> str:
        try:
            return subprocess.check_output(
                ["git", "rev-parse", "--short", "HEAD"],
                cwd=Path(__file__).resolve().parents[1],
                stderr=subprocess.DEVNULL,
                text=True,
            ).strip()
        except (OSError, subprocess.SubprocessError):
            return "unknown"

    def _bitstream_sha256(self) -> str | None:
        if self.bitstream_path is None:
            return None
        path = Path(self.bitstream_path)
        if not path.is_file():
            return None
        digest = hashlib.sha256()
        with path.open("rb") as bitstream:
            for chunk in iter(lambda: bitstream.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()

    def close(self) -> None:
        if self._closed:
            return
        for buf in (
            self._kv_send_buf, self._q_send_buf, self._batch_send_buf,
            self._stream_send_buf, self._out_buf,
        ):
            free = getattr(buf, "freebuffer", None)
            if callable(free):
                free()
        self._closed = True

    def __enter__(self) -> "AttentionAccelerator":
        if self._closed:
            raise RuntimeError("attention accelerator buffers have been released")
        return self

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        self.close()

    def save_last_profile(self, path: str | Path) -> None:
        if self.last_profile is None:
            raise RuntimeError("no completed attention run is available")
        Path(path).write_text(json.dumps(self.last_profile.to_dict(), indent=2) + "\n", encoding="utf-8")

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

    def _prepare_input_transport(self) -> None:
        mode = self._requested_stream_mode
        if mode == "auto":
            # Descriptor batching keeps the legacy destination contract while
            # reducing DMA transactions.  In-band framing is experimental and
            # must be selected explicitly until its board-level gate passes.
            if self._descriptor_queue_supported:
                mode = "descriptor"
            else:
                mode = "legacy"
        if mode == "inband" and not self._inband_command_supported:
            raise RuntimeError("in-band stream mode was requested but the bitstream does not support it")
        if mode == "descriptor" and not self._descriptor_queue_supported:
            raise RuntimeError("descriptor mode was requested but the bitstream does not support it")

        control = DESC_CTRL_CLEAR
        if mode in ("inband", "descriptor"):
            control |= DESC_CTRL_ENABLE
        if mode == "inband":
            control |= DESC_CTRL_INBAND
        self.mmio.write(CSR_DESC_CTRL, control)
        status = self.mmio.read(CSR_DESC_STATUS)
        self._descriptor_queue_enabled = mode == "descriptor" and bool(
            status & DESC_STATUS_ENABLED
        )
        self._inband_command_enabled = mode == "inband" and bool(
            status & DESC_STATUS_INBAND_ENABLED
        )
        self._input_transport = mode
        enabled_ok = (
            mode == "legacy"
            or (mode == "descriptor" and self._descriptor_queue_enabled)
            or (mode == "inband" and self._inband_command_enabled)
        )
        if not enabled_ok or not (status & DESC_STATUS_EMPTY):
            raise RuntimeError(f"descriptor queue initialization failed: status=0x{status:08x}")

    @staticmethod
    def _descriptor_word(dest: int, nbytes: int) -> int:
        if dest not in (DEST_K_CACHE, DEST_V_CACHE, DEST_Q_BUF):
            raise ValueError(f"invalid descriptor destination {dest}")
        if nbytes <= 0 or nbytes % 4:
            raise ValueError(f"descriptor length must be a positive multiple of 4, got {nbytes}")
        return ((nbytes // 4) << 2) | dest

    def _record_input_dma(
        self,
        segments: list[tuple[int, int]],
        setup_ms: float,
        transfer_ms: float,
    ) -> None:
        if self.last_profile is None:
            return
        profile = self.last_profile
        total_bytes = sum(nbytes for _, nbytes in segments)
        profile.input_dma_setup_ms += setup_ms
        profile.input_dma_transfer_ms += transfer_ms
        profile.input_dma_transfers += 1
        profile.input_dma_bytes += total_bytes
        profile.input_dma_wire_bytes += total_bytes
        profile.input_dma_descriptors += len(segments)
        profile.input_dma_batched_transfers += int(len(segments) > 1)
        profile.input_dma_max_segments = max(profile.input_dma_max_segments, len(segments))
        for dest, nbytes in segments:
            share = nbytes / total_bytes
            if dest == DEST_Q_BUF:
                profile.q_dma_setup_ms += setup_ms * share
                profile.q_dma_transfer_ms += transfer_ms * share
                profile.q_dma_transfers += 1
                profile.q_dma_bytes += nbytes
            else:
                profile.kv_dma_setup_ms += setup_ms * share
                profile.kv_dma_transfer_ms += transfer_ms * share
                profile.kv_dma_transfers += 1
                profile.kv_dma_bytes += nbytes

    def configure(self, seq_len: int, *, q_pos_base: int = 0, kv_pos_base: int = 0, causal: bool = True) -> None:
        self._validate_seq_len(seq_len)
        if (
            q_pos_base < 0
            or kv_pos_base < 0
            or q_pos_base + seq_len > ABSOLUTE_POSITION_LIMIT
            or kv_pos_base + seq_len > ABSOLUTE_POSITION_LIMIT
        ):
            raise ValueError("absolute position base + seq_len exceeds 16-bit range")
        self.mmio.write(CSR_SEQ_LEN, seq_len)
        self.mmio.write(CSR_Q_POS_BASE, q_pos_base)
        self.mmio.write(CSR_KV_POS_BASE, kv_pos_base)
        self.mmio.write(CSR_CFG, int(causal))

    def _transfer(self, dest: int, payload: np.ndarray) -> None:
        if self._descriptor_queue_enabled:
            self._transfer_batch([(dest, payload)])
            return
        if self._closed:
            raise RuntimeError("attention accelerator buffers have been released")
        setup_start = time.perf_counter()
        words = fp32_to_bf16_u16(payload)
        payload_u8 = words.reshape(-1).view(np.uint8)
        buf = self._q_send_buf if dest == DEST_Q_BUF else self._kv_send_buf
        if payload_u8.nbytes > buf.nbytes:
            raise ValueError(
                f"DMA payload for destination {dest} is {payload_u8.nbytes} bytes; "
                f"reusable buffer capacity is {buf.nbytes} bytes"
            )
        buf_view = buf[:payload_u8.size]
        buf_view[:] = payload_u8
        flush = getattr(buf_view, "flush", None) or getattr(buf, "flush", None)
        if callable(flush):
            flush()
        self.mmio.write(CSR_STREAM_DEST, dest)
        self.mmio.write(CSR_STREAM_LEN, int(payload_u8.nbytes))
        setup_ms = (time.perf_counter() - setup_start) * 1000.0

        transfer_start = time.perf_counter()
        self.dma_send.transfer(buf_view)
        self.dma_send.wait()
        transfer_ms = (time.perf_counter() - transfer_start) * 1000.0
        if hasattr(self.mmio, "transfer_complete"):
            self.mmio.transfer_complete(dest)

        self._record_input_dma([(dest, int(payload_u8.nbytes))], setup_ms, transfer_ms)

    def _transfer_batch(self, segments: list[tuple[int, np.ndarray]]) -> None:
        if not self._descriptor_queue_enabled:
            for dest, payload in segments:
                self._transfer(dest, payload)
            return
        if self._closed:
            raise RuntimeError("attention accelerator buffers have been released")
        setup_start = time.perf_counter()
        packed: list[tuple[int, np.ndarray]] = []
        total_bytes = 0
        for dest, payload in segments:
            payload_u8 = fp32_to_bf16_u16(payload).reshape(-1).view(np.uint8)
            self._descriptor_word(dest, int(payload_u8.nbytes))
            packed.append((dest, payload_u8))
            total_bytes += int(payload_u8.nbytes)
        if total_bytes > self._batch_send_buf.nbytes:
            raise ValueError(
                f"batched DMA payload is {total_bytes} bytes; reusable buffer capacity "
                f"is {self._batch_send_buf.nbytes} bytes"
            )
        status = self.mmio.read(CSR_DESC_STATUS)
        if not (status & DESC_STATUS_EMPTY):
            raise RuntimeError(f"descriptor queue is not empty before batch: status=0x{status:08x}")

        offset = 0
        segment_sizes: list[tuple[int, int]] = []
        for dest, payload_u8 in packed:
            nbytes = int(payload_u8.nbytes)
            self._batch_send_buf[offset:offset + nbytes] = payload_u8
            self.mmio.write(CSR_DESC_PUSH, self._descriptor_word(dest, nbytes))
            segment_sizes.append((dest, nbytes))
            offset += nbytes
        buf_view = self._batch_send_buf[:total_bytes]
        flush = getattr(buf_view, "flush", None) or getattr(self._batch_send_buf, "flush", None)
        if callable(flush):
            flush()
        setup_ms = (time.perf_counter() - setup_start) * 1000.0

        transfer_start = time.perf_counter()
        self.dma_send.transfer(buf_view)
        self.dma_send.wait()
        transfer_ms = (time.perf_counter() - transfer_start) * 1000.0
        if hasattr(self.mmio, "transfer_complete"):
            for dest, _ in segment_sizes:
                self.mmio.transfer_complete(dest)
        # The real FIFO is drained by the stream sink. Keep the mock status
        # consistent so subsequent batches exercise the same empty invariant.
        if isinstance(self.mmio, MockMMIO):
            self.mmio.regs[CSR_DESC_STATUS] = (
                DESC_STATUS_SUPPORTED | DESC_STATUS_ENABLED | DESC_STATUS_EMPTY
            )
        self._record_input_dma(segment_sizes, setup_ms, transfer_ms)

    def _pack_inband_stream(
        self,
        q_heads: np.ndarray,
        k_heads: np.ndarray,
        v_heads: np.ndarray,
        seq_len: int,
    ) -> tuple[np.ndarray, list[tuple[int, int]], float]:
        setup_start = time.perf_counter()
        offset = 0
        segments: list[tuple[int, int]] = []

        def append_segment(dest: int, payload: np.ndarray) -> None:
            nonlocal offset
            payload_u8 = fp32_to_bf16_u16(payload).reshape(-1).view(np.uint8)
            nbytes = int(payload_u8.nbytes)
            header = self._descriptor_word(dest, nbytes)
            wire_end = offset + 4 + nbytes
            if wire_end > self._stream_send_buf.nbytes:
                raise ValueError(
                    f"in-band input stream exceeds reusable buffer capacity "
                    f"{self._stream_send_buf.nbytes} bytes"
                )
            self._stream_send_buf[offset:offset + 4] = np.asarray(
                [header], dtype=np.uint32,
            ).view(np.uint8)
            offset += 4
            self._stream_send_buf[offset:offset + nbytes] = payload_u8
            offset += nbytes
            segments.append((dest, nbytes))

        q_tiles = (seq_len + TILE_Q - 1) // TILE_Q
        for group in range(N_KV_HEADS):
            append_segment(DEST_K_CACHE, k_heads[group, :seq_len, :])
            append_segment(DEST_V_CACHE, v_heads[group, :seq_len, :])
            for head in range(GQA_GROUP_SIZE):
                q_src = q_heads[group * GQA_GROUP_SIZE + head]
                for tile in range(q_tiles):
                    self._q_tile_words.fill(0)
                    lo = tile * TILE_Q
                    active = max(0, min(TILE_Q, seq_len - lo))
                    self._q_tile_words[:active, :] = q_src[lo:lo + TILE_Q, :]
                    append_segment(DEST_Q_BUF, self._q_tile_words)

        buf_view = self._stream_send_buf[:offset]
        flush = getattr(buf_view, "flush", None) or getattr(self._stream_send_buf, "flush", None)
        if callable(flush):
            flush()
        return buf_view, segments, (time.perf_counter() - setup_start) * 1000.0

    def _complete_mock_segments(self, segments: list[tuple[int, int]]) -> None:
        if hasattr(self.mmio, "transfer_complete"):
            for dest, _ in segments:
                self.mmio.transfer_complete(dest)

    def _wait_done_passive(self, timeout_ms: int | None = None) -> None:
        deadline = None if timeout_ms is None else time.monotonic() + timeout_ms / 1000.0
        while True:
            status = self.status()
            if status & (STATUS_ERROR | STATUS_STREAM_ERROR):
                code = self.mmio.read(CSR_ERROR_CODE) & 0xFF
                raise RuntimeError(f"accelerator error status=0x{status:08x}, code=0x{code:02x}")
            if status & STATUS_DONE:
                return
            if deadline is not None and time.monotonic() > deadline:
                raise TimeoutError("attention accelerator timed out in autonomous stream mode")
            if self._hw_ready and self._request_poll_sleep_s > 0:
                time.sleep(self._request_poll_sleep_s)

    def _q_tile_payload(
        self,
        req: int,
        q_heads: np.ndarray,
        seq_len: int,
    ) -> np.ndarray:
        group = (req >> 8) & 0x7
        head = (req >> 12) & 0x3
        tile = (req >> 16) & 0xFF
        q_tile = self._q_tile_words
        q_tile.fill(0)
        q_src = q_heads[group * GQA_GROUP_SIZE + head]
        lo = tile * TILE_Q
        q_tile[: max(0, min(TILE_Q, seq_len - lo)), :] = q_src[lo:lo + TILE_Q, :]
        return q_tile

    def _service_request(self, req: int, q_heads: np.ndarray, k_heads: np.ndarray, v_heads: np.ndarray, seq_len: int) -> None:
        if req & 1:
            group = (req >> 4) & 0x7
            segments = [
                (DEST_K_CACHE, k_heads[group, :seq_len, :]),
                (DEST_V_CACHE, v_heads[group, :seq_len, :]),
            ]
            if req & 2:
                segments.append((DEST_Q_BUF, self._q_tile_payload(req, q_heads, seq_len)))
            self._transfer_batch(segments)
        elif req & 2:
            self._transfer(DEST_Q_BUF, self._q_tile_payload(req, q_heads, seq_len))

    def start(self) -> None:
        if not (self.mmio.read(CSR_STATUS) & STATUS_START_READY):
            raise RuntimeError("accelerator is not ready to accept start")
        self.mmio.write(CSR_CTRL, CTRL_START)

    def status(self) -> int:
        return self.mmio.read(CSR_STATUS)

    def wait_done(self, q_heads: np.ndarray, k_heads: np.ndarray, v_heads: np.ndarray, seq_len: int, timeout_ms: int | None = None) -> None:
        deadline = None if timeout_ms is None else time.monotonic() + timeout_ms / 1000.0
        last_serviced_req: int | None = None
        while True:
            status = self.status()
            if status & (STATUS_ERROR | STATUS_STREAM_ERROR):
                code = self.mmio.read(CSR_ERROR_CODE) & 0xFF
                raise RuntimeError(f"accelerator error status=0x{status:08x}, code=0x{code:02x}")
            if status & STATUS_DONE:
                return
            if status & (STATUS_KV_LOAD_REQ | STATUS_Q_LOAD_REQ):
                req = self.mmio.read(CSR_LOAD_REQ)
                if req != last_serviced_req:
                    self._service_request(req, q_heads, k_heads, v_heads, seq_len)
                    last_serviced_req = req
                    # A completed DMA is immediately visible to the RTL. Poll
                    # again without imposing a fixed delay on every request.
                    continue
                if self.last_profile is not None:
                    self.last_profile.request_duplicate_polls += 1
            else:
                last_serviced_req = None
            if deadline is not None and time.monotonic() > deadline:
                raise TimeoutError("attention accelerator timed out while servicing load requests")
            if self._hw_ready and self._request_poll_sleep_s > 0:
                time.sleep(self._request_poll_sleep_s)
                if self.last_profile is not None:
                    self.last_profile.request_poll_sleeps += 1

    def readback_o(self, seq_len: int, out_buf: np.ndarray) -> np.ndarray:
        self.dma_recv.wait()
        invalidate = getattr(out_buf, "invalidate", None) or getattr(self._out_buf, "invalidate", None)
        if callable(invalidate):
            invalidate()
        nbytes = self.byte_counts(seq_len).o_bytes
        return np.frombuffer(out_buf[:nbytes].tobytes(), dtype=np.uint16).reshape(N_Q_HEADS, seq_len, HEAD_DIM)

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
        timeout_ms: int | None = None,
    ) -> np.ndarray:
        """Run one full transaction; returns raw head-major bf16 words."""
        if self._closed:
            raise RuntimeError("attention accelerator buffers have been released")
        attention_start = time.perf_counter()
        L = int(seq_len if seq_len is not None else q_heads.shape[1])
        self._validate_seq_len(L)
        expected_q = (N_Q_HEADS, L, HEAD_DIM)
        expected_kv = (N_KV_HEADS, L, HEAD_DIM)
        if q_heads.shape != expected_q or k_heads.shape != expected_kv or v_heads.shape != expected_kv:
            raise ValueError(f"expected Q={expected_q}, K/V={expected_kv}; got {q_heads.shape}, {k_heads.shape}, {v_heads.shape}")

        self.last_profile = RunProfile(
            timestamp_utc=datetime.now(timezone.utc).isoformat(),
            git_commit=self._git_hash,
            bitstream_sha256=self._bitstream_hash,
            clock_mhz=self._pl_clock_mhz,
            seq_len=L,
            causal=causal,
            q_pos_base=q_pos_base,
            kv_pos_base=kv_pos_base,
            request_poll_sleep_us=self._request_poll_sleep_us,
            prefetch_mode=self._requested_prefetch_mode,
            descriptor_queue_supported=self._descriptor_queue_supported,
            inband_command_supported=self._inband_command_supported,
        )

        pack_start = time.perf_counter()
        q_u16 = fp32_to_bf16_u16(q_heads)
        k_u16 = fp32_to_bf16_u16(k_heads)
        v_u16 = fp32_to_bf16_u16(v_heads)
        self.last_profile.input_pack_ms = (time.perf_counter() - pack_start) * 1000.0

        setup_start = time.perf_counter()
        self.configure(L, q_pos_base=q_pos_base, kv_pos_base=kv_pos_base, causal=causal)
        self.clear_status()
        self._prepare_input_transport()
        self.last_profile.descriptor_queue_enabled = self._descriptor_queue_enabled
        self.last_profile.inband_command_enabled = self._inband_command_enabled
        self.last_profile.input_transport = self._input_transport
        counts = self.byte_counts(L)
        if counts.o_bytes > DMA_MAX_TRANSFER_BYTES:
            raise ValueError(f"output DMA length {counts.o_bytes} exceeds {DMA_LENGTH_WIDTH}-bit DMA limit")
        self.mmio.write(CSR_RESULT_LEN, counts.o_bytes)
        self.last_profile.driver_setup_ms = (time.perf_counter() - setup_start) * 1000.0

        output_setup_start = time.perf_counter()
        out_buf = self._out_buf[:counts.o_bytes]
        self.dma_recv.transfer(out_buf)  # arm S2MM before source can emit
        self.last_profile.output_dma_setup_ms = (time.perf_counter() - output_setup_start) * 1000.0
        self.last_profile.output_dma_transfers = 1
        self.last_profile.output_dma_bytes = counts.o_bytes
        if hasattr(self.mmio, "prepare"):
            self.mmio.prepare(L)
        if self._inband_command_enabled:
            stream_buf, segments, stream_setup_ms = self._pack_inband_stream(
                q_u16, k_u16, v_u16, L,
            )
            transfer_start = time.perf_counter()
            self.dma_send.transfer(stream_buf)
            self.start()
            self.dma_send.wait()
            stream_transfer_ms = (time.perf_counter() - transfer_start) * 1000.0
            self._complete_mock_segments(segments)
            self._record_input_dma(segments, stream_setup_ms, stream_transfer_ms)
            protocol_bytes = 4 * len(segments)
            self.last_profile.input_dma_protocol_bytes = protocol_bytes
            self.last_profile.input_dma_wire_bytes += protocol_bytes
            self._wait_done_passive(timeout_ms=timeout_ms)
        else:
            self.start()
            service_start = time.perf_counter()
            self.wait_done(q_u16, k_u16, v_u16, L, timeout_ms=timeout_ms)
            self.last_profile.request_service_ms = (time.perf_counter() - service_start) * 1000.0

        output_transfer_start = time.perf_counter()
        result = self.readback_o(L, out_buf)
        self.last_profile.output_dma_transfer_ms = (time.perf_counter() - output_transfer_start) * 1000.0
        perf = self.read_perf()
        self.last_profile.pl_total_cycles = perf["cycles"]
        self.last_profile.pl_mac_cycles = perf["mac_cycles"]
        self.last_profile.pl_stall_cycles = perf["stall_cycles"]
        self.last_profile.pl_core_active_cycles_excluding_stalls = max(
            perf["cycles"] - perf["stall_cycles"], 0,
        )
        cycles_per_ms = self._pl_clock_mhz * 1000.0
        self.last_profile.pl_total_ms = perf["cycles"] / cycles_per_ms
        self.last_profile.pl_mac_ms = perf["mac_cycles"] / cycles_per_ms
        self.last_profile.pl_stall_ms = perf["stall_cycles"] / cycles_per_ms
        self.last_profile.pl_core_active_ms_excluding_stalls = (
            self.last_profile.pl_core_active_cycles_excluding_stalls / cycles_per_ms
        )
        self.last_profile.attention_total_ms = (time.perf_counter() - attention_start) * 1000.0
        return result

    def run_layer(self, hidden_states: np.ndarray, wq: np.ndarray, wk: np.ndarray, wv: np.ndarray,
                  rms_weight: np.ndarray | None = None, *, q_pos_base: int = 0,
                  kv_pos_base: int = 0, causal: bool = True, timeout_ms: int | None = None) -> np.ndarray:
        """Host QKV projection + optional RoPE, followed by FPGA attention."""
        try:
            from .host_attention import apply_rope_host, qkv_project, reshape_to_heads, rms_norm
        except ImportError:  # script execution from the sw/ directory
            from host_attention import apply_rope_host, qkv_project, reshape_to_heads, rms_norm
        layer_start = time.perf_counter()
        phase_start = time.perf_counter()
        x = hidden_states if rms_weight is None else rms_norm(hidden_states, rms_weight)
        rms_ms = (time.perf_counter() - phase_start) * 1000.0

        phase_start = time.perf_counter()
        q, k, v = qkv_project(x, wq, wk, wv)
        projection_ms = (time.perf_counter() - phase_start) * 1000.0

        phase_start = time.perf_counter()
        qh, kh, vh = reshape_to_heads(q, k, v)
        for group in range(N_KV_HEADS):
            for head in range(GQA_GROUP_SIZE):
                qh[group * GQA_GROUP_SIZE + head] = apply_rope_host(
                    qh[group * GQA_GROUP_SIZE + head], head_dim=HEAD_DIM,
                    position_base=q_pos_base)
            kh[group] = apply_rope_host(kh[group], head_dim=HEAD_DIM,
                                        position_base=kv_pos_base)
        rope_ms = (time.perf_counter() - phase_start) * 1000.0
        out_words = self.run_attention(qh, kh, vh, q_pos_base=q_pos_base, kv_pos_base=kv_pos_base, causal=causal, timeout_ms=timeout_ms)
        result = bf16_u16_to_fp32(out_words).transpose(1, 0, 2).reshape(hidden_states.shape[0], N_Q_HEADS * HEAD_DIM)
        if self.last_profile is not None:
            self.last_profile.host_rms_norm_ms = rms_ms
            self.last_profile.host_qkv_projection_ms = projection_ms
            self.last_profile.host_rope_ms = rope_ms
            self.last_profile.layer_total_ms = (time.perf_counter() - layer_start) * 1000.0
        return result


def _self_test() -> None:
    accel = AttentionAccelerator()
    assert not accel.hw_ready
    L = 16
    q = np.zeros((N_Q_HEADS, L, HEAD_DIM), dtype=np.uint16)
    k = np.zeros((N_KV_HEADS, L, HEAD_DIM), dtype=np.uint16)
    v = np.zeros((N_KV_HEADS, L, HEAD_DIM), dtype=np.uint16)
    out = accel.run_attention(q, k, v, seq_len=L)
    assert out.shape == (N_Q_HEADS, L, HEAD_DIM)
    assert len([x for x in accel.dma_send.trace if x[0] == "transfer"]) == N_Q_HEADS
    assert accel.last_profile is not None
    assert accel.last_profile.input_dma_descriptors == N_KV_HEADS * 2 + N_Q_HEADS
    assert accel.last_profile.input_dma_batched_transfers == N_KV_HEADS
    print("attn_driver request-service mock self-test PASSED")


if __name__ == "__main__":
    _self_test()
