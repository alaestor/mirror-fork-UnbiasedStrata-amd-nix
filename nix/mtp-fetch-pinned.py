"""Run the repository's range fetcher without revision fallback or overrides."""
import sys

sys.path.insert(0, sys.argv.pop(1))
import mtp_fetch as fetcher  # noqa: E402

fetcher.REVISION = fetcher.PINNED_REVISION
fetcher.REPO = (
    "https://huggingface.co/Qwen/Qwen3.8-Flash-Next/resolve/"
    + fetcher.PINNED_REVISION + "/"
)
fetcher.PINNED = fetcher.REPO
fetcher.resolve_repo = lambda: fetcher.REPO
fetcher.main()
