"""Validate user-supplied MTP inputs offline without modifying their files."""
import hashlib
import json
from pathlib import Path
import sys


def verify(source, pinned_manifest):
    source = Path(source)
    expected = json.loads(Path(pinned_manifest).read_text())
    actual = json.loads((source / "mtp-manifest.json").read_text())
    if actual != expected:
        raise ValueError("MTP manifest differs from the pinned checkpoint manifest")
    for tensor in expected:
        path = source / tensor["file"]
        if path.stat().st_size != tensor["bytes"]:
            raise ValueError(f"MTP tensor size mismatch: {path}")
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if digest != tensor["sha256"]:
            raise ValueError(f"MTP tensor SHA-256 mismatch: {path}")


if __name__ == "__main__":
    try:
        verify(*sys.argv[1:])
    except (OSError, ValueError) as error:
        sys.exit(str(error))
    print("Verified all pinned MTP tensors (offline)")
