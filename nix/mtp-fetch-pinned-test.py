"""Check that packaging cannot inherit an endpoint or revision fallback."""
import runpy
import sys
import types
from unittest.mock import patch

wrapper = sys.argv[1]
fetcher = types.ModuleType("mtp_fetch")
fetcher.PINNED_REVISION = "test-immutable-revision"
fetcher.REVISION = "main"
fetcher.REPO = "https://untrusted.invalid/resolve/main/"
fetcher.PINNED = "https://untrusted.invalid/resolve/pin/"
fetcher.resolve_repo = lambda: "fallback"


def main():
    expected = "https://huggingface.co/Qwen/Qwen3.8-Flash-Next/resolve/test-immutable-revision/"
    assert fetcher.REVISION == fetcher.PINNED_REVISION
    assert fetcher.REPO == fetcher.PINNED == expected
    assert fetcher.resolve_repo() == expected
    assert sys.argv[1:] == ["fetch", "--out", "a directory with spaces"]


fetcher.main = main
with patch.dict(sys.modules, mtp_fetch=fetcher):
    sys.argv = ["mtp-fetch-pinned.py", "tools", "fetch", "--out", "a directory with spaces"]
    runpy.run_path(wrapper, run_name="__main__")
print("PASS: immutable revision, official endpoint, no fallback, argument forwarding")
