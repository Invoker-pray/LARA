import json
import tempfile
import unittest
from pathlib import Path

from sw.clear_pynq_cache import (
    METADATA_FILE,
    STATE_FILE,
    clear_cache,
    inspect_cache,
    xbutil_device_ready,
)


class ClearPynqCacheTest(unittest.TestCase):
    def test_missing_cached_bitstream_is_stale_and_removed(self):
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp)
            (state_dir / STATE_FILE).write_text(
                json.dumps({"bitfile_name": str(state_dir / "missing.bit")}),
                encoding="utf-8",
            )
            (state_dir / METADATA_FILE).write_bytes(b"cache")
            stale, reason = inspect_cache(state_dir, None)
            self.assertTrue(stale)
            self.assertIn("no longer exists", reason)
            self.assertEqual(len(clear_cache(state_dir)), 2)
            self.assertFalse((state_dir / STATE_FILE).exists())
            self.assertFalse((state_dir / METADATA_FILE).exists())

    def test_matching_cache_is_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp)
            bitstream = state_dir / "current.bit"
            bitstream.write_bytes(b"bitstream")
            (state_dir / STATE_FILE).write_text(
                json.dumps({"bitfile_name": str(bitstream)}), encoding="utf-8"
            )
            (state_dir / METADATA_FILE).write_bytes(b"cache")
            stale, reason = inspect_cache(state_dir, bitstream.resolve())
            self.assertFalse(stale)
            self.assertIn("cache is valid", reason)

    def test_different_requested_bitstream_is_stale(self):
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp)
            old_bitstream = state_dir / "old.bit"
            new_bitstream = state_dir / "new.bit"
            old_bitstream.write_bytes(b"old")
            new_bitstream.write_bytes(b"new")
            (state_dir / STATE_FILE).write_text(
                json.dumps({"bitfile_name": str(old_bitstream)}), encoding="utf-8"
            )
            (state_dir / METADATA_FILE).write_bytes(b"cache")
            stale, reason = inspect_cache(state_dir, new_bitstream.resolve())
            self.assertTrue(stale)
            self.assertIn("differs", reason)

    def test_orphaned_metadata_is_stale(self):
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp)
            (state_dir / METADATA_FILE).write_bytes(b"cache")
            stale, reason = inspect_cache(state_dir, None)
            self.assertTrue(stale)
            self.assertIn("orphaned", reason)

    def test_xbutil_table_ready_parser(self):
        output = """Devices present
BDF : Shell Device Ready*
[0000:00:00.0] : edge Yes
"""
        self.assertTrue(xbutil_device_ready(output))

    def test_xbutil_rejects_not_ready(self):
        self.assertFalse(xbutil_device_ready("[0000:00:00.0] : edge No\n"))


if __name__ == "__main__":
    unittest.main()
