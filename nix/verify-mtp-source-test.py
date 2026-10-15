"""Offline source validation must reject absent, corrupt, or altered inputs."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("validator", sys.argv.pop(1))
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)
pinned_manifest = Path(sys.argv.pop(1))
sys.path.insert(0, sys.argv.pop(1))
import mtp_fetch


class PinnedManifest(unittest.TestCase):
    def test_matches_upstream_pins(self):
        manifest = json.loads(pinned_manifest.read_text())
        self.assertEqual(len(manifest), 31)
        self.assertEqual({t["name"]: t["sha256"] for t in manifest}, mtp_fetch.SHA256)
        for tensor in manifest:
            self.assertEqual(tensor["file"], f'tensors/{tensor["name"]}.bin')
            self.assertEqual(tensor["bytes"], tensor["end"] - tensor["start"] + 1)


class SourceValidation(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "local source with spaces"
        (self.source / "tensors").mkdir(parents=True)
        self.tensor = self.source / "tensors/test.bin"
        self.tensor.write_bytes(b"test")
        manifest = [{"name": "test", "file": "tensors/test.bin", "bytes": 4,
                     "sha256": hashlib.sha256(b"test").hexdigest()}]
        self.pinned = self.root / "pinned.json"
        self.pinned.write_text(json.dumps(manifest))
        self.manifest = self.source / "mtp-manifest.json"
        self.manifest.write_text(self.pinned.read_text())

    def verify(self):
        # No network access or mutation, even with a read-only store source.
        with patch("socket.socket", side_effect=AssertionError("network access")):
            validator.verify(self.source, self.pinned)

    def test_valid(self):
        self.tensor.chmod(0o444)
        self.manifest.chmod(0o444)
        self.verify()
        self.assertEqual(sorted(p.name for p in self.source.iterdir()),
                         ["mtp-manifest.json", "tensors"])
        self.assertEqual(list((self.source / "tensors").iterdir()), [self.tensor])

    def test_missing_manifest(self):
        self.manifest.unlink()
        with self.assertRaises(FileNotFoundError):
            self.verify()

    def test_missing_tensor(self):
        self.tensor.unlink()
        with self.assertRaises(FileNotFoundError):
            self.verify()

    def test_corrupt_tensor(self):
        self.tensor.write_bytes(b"oops")
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            self.verify()

    def test_truncated_tensor(self):
        self.tensor.write_bytes(b"x")
        with self.assertRaisesRegex(ValueError, "size"):
            self.verify()

    def test_altered_manifest(self):
        self.manifest.write_text("[]")
        with self.assertRaisesRegex(ValueError, "manifest"):
            self.verify()


unittest.main()
