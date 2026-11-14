#!/usr/bin/env bash
# Exercise build/preparation boundaries without ROCm, downloads, or model weights.
set -euo pipefail
builder=$(realpath "$(dirname "$0")/build-qwen38-opensuse.sh")
work=$(mktemp -d)
trap 'rm -r "$work"' EXIT
mkdir -p "$work/bin" "$work/repo/tools" "$work/repo/data" "$work/repo/nix" \
  "$work/repo/third_party/llama.cpp" "$work/repo/.venv/bin"
export CALL_LOG="$work/calls" CONFIGURE_EXIT=0 BUILD_EXIT=0 PACK_EXIT=0 GGUF_REV=gguf-tree
export VERIFY_EXIT=0 FETCH_EXIT=0
cat > "$work/bin/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *'rev-parse HEAD:gguf-py' ]]; then echo "$GGUF_REV"; fi
MOCK
cat > "$work/bin/cmake" <<'MOCK'
#!/usr/bin/env bash
printf 'cmake'; printf ' <%s>' "$@"; printf '\n'
if [[ "$1" == --build ]]; then exit "$BUILD_EXIT"; fi
exit "$CONFIGURE_EXIT"
MOCK
cat > "$work/bin/python3" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALL_LOG"
case "$1" in
  nix/verify-mtp-source.py) exit "$VERIFY_EXIT" ;;
  nix/mtp-fetch-pinned.py) exit "$FETCH_EXIT" ;;
  tools/iq_pack.py|tools/mtp_rt.py)
    tool=$1
    [[ "$tool" != tools/iq_pack.py ]] || { (( PACK_EXIT == 0 )) || exit "$PACK_EXIT"; }
    while [[ "$1" != --out ]]; do shift; done
    out=$2
    mkdir -p "$out"
    if [[ "$tool" == tools/iq_pack.py ]]; then
      for file in dense.bin index.txt native_experts.txt; do echo mock > "$out/$file"; done
    else
      for file in dense.bin dense.txt experts.bin; do echo mock > "$out/$file"; done
    fi
    ;;
esac
MOCK
cat > "$work/bin/ninja" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$work/bin/git" "$work/bin/cmake" "$work/bin/python3" "$work/bin/ninja"
cp "$work/bin/python3" "$work/repo/.venv/bin/python"
export PATH="$work/bin:$PATH"
cd "$work/repo"
touch flake.nix nix/qwen38-mtp-manifest.json
for input in iq_pack gguf_reader strata_tokenizer _paths mtp_pack mtp_rt unrelated; do
  echo "$input" > "tools/$input.py"
done
echo profile > data/expert-profile.bin
echo vocab > data/draft_vocab.bin
cat > .env <<'ENV'
MODEL='model with spaces-00001-of-00002.gguf'
MODEL_SHARD2='model with spaces-00002-of-00002.gguf'
BUILD_DIR='build with spaces'
PREPARED_DIR='packs with spaces'
ENV
run() {
  local expected=$1 actual=0
  shift
  : > "$CALL_LOG"
  bash "$builder" "$@" > "$work/out" 2>&1 || actual=$?
  if [[ "$actual" != "$expected" ]]; then
    cat "$work/out" >&2
    echo "Expected exit $expected, got $actual for: $*" >&2
    exit 1
  fi
}
output_has() { grep -Fq -- "$1" "$work/out"; }
called() { grep -Fq -- "$1" "$CALL_LOG"; }
not_called() {
  if called "$1"; then
    cat "$CALL_LOG" >&2
    echo "Unexpected preparation call: $1" >&2
    exit 1
  fi
}

# Help and invalid arguments need no repository, configuration, or dependencies.
cd "$work"
run 0 --help
run 2 --invalid
cd "$work/repo"

# Build-only requires neither models nor Python preparation and preserves packs.
mkdir -p 'packs with spaces/pack'
echo keep > 'packs with spaces/pack/sentinel'
run 0 --build-only --fresh
output_has 'cmake <--fresh> <-S> <.> <-B> <build with spaces>'
output_has 'Build complete'
[[ ! -s "$CALL_LOG" && $(cat 'packs with spaces/pack/sentinel') == keep ]]
export CONFIGURE_EXIT=1
run 1 --build-only
output_has 'rerun with --fresh'
export CONFIGURE_EXIT=0 BUILD_EXIT=7
run 7 --build-only
if output_has 'Build complete'; then exit 1; fi
export BUILD_EXIT=0
run 1
output_has 'Both model shards must exist'
touch 'model with spaces-00001-of-00002.gguf' 'model with spaces-00002-of-00002.gguf'

# Unrecognized and old completion markers are never silently trusted or removed.
for file in dense.bin index.txt native_experts.txt expert-profile.bin; do
  echo mock > "packs with spaces/pack/$file"
done
mkdir -p 'packs with spaces/mtp'
for file in dense.bin dense.txt experts.bin draft_vocab.bin; do
  echo mock > "packs with spaces/mtp/$file"
done
run 0
output_has 'WARNING: Reusing existing prepared files: packs with spaces/pack'
output_has 'runtime compatibility is not verified'
output_has 'If loading or inference fails'
[[ ! -s "$CALL_LOG" && ! -e 'packs with spaces/pack/.native-preparation' ]]
[[ $(cat 'packs with spaces/pack/sentinel') == keep ]]
echo old-fingerprint > 'packs with spaces/pack/.native-preparation'
run 0
output_has 'WARNING: Reusing existing prepared files: packs with spaces/pack'
[[ ! -s "$CALL_LOG" && $(cat 'packs with spaces/pack/.native-preparation') == old-fingerprint ]]
# The warning persists; reuse must not bless the old marker with a new fingerprint.
run 0
output_has 'WARNING: Reusing existing prepared files: packs with spaces/pack'
run 0 --build-only
[[ ! -s "$CALL_LOG" && $(cat 'packs with spaces/pack/.native-preparation') == old-fingerprint ]]
cat >> .env <<'ENV'
PREPARED_DIR='new packs'
ENV

# First preparation runs both stages; unchanged reruns skip both.
run 0
called tools/iq_pack.py
called tools/mtp_pack.py
run 0
not_called tools/iq_pack.py
not_called tools/mtp_pack.py
[[ ! -s "$CALL_LOG" ]]
if output_has 'WARNING:'; then exit 1; fi

# Unrelated tools and engine-only llama.cpp revisions do not invalidate packs.
echo changed >> tools/unrelated.py
echo LLAMA_REV=new-engine-commit >> .env
run 0
not_called tools/iq_pack.py
not_called tools/mtp_pack.py

# Moving the whole checkout preserves fingerprints, including paths with spaces.
cd "$work"
mv repo 'moved repo'
cd 'moved repo'
run 0 --fresh
not_called tools/iq_pack.py
not_called tools/mtp_pack.py

# Changed inputs warn and reuse without rewriting markers or downloading inputs.
pack_marker=$(cat 'new packs/pack/.native-preparation')
mtp_marker=$(cat 'new packs/mtp/.native-preparation')
echo changed >> tools/iq_pack.py
run 0
output_has 'WARNING: Reusing existing prepared files: new packs/pack'
if output_has 'WARNING: Reusing existing prepared files: new packs/mtp'; then exit 1; fi
[[ ! -s "$CALL_LOG" && $(cat 'new packs/pack/.native-preparation') == "$pack_marker" ]]
mv 'new packs/pack' 'new packs/saved-pack'
run 0
called tools/iq_pack.py
not_called tools/mtp_pack.py

# MTP-only changes warn only for MTP, and leave it untouched until regeneration.
echo changed >> data/draft_vocab.bin
run 0
output_has 'WARNING: Reusing existing prepared files: new packs/mtp'
if output_has 'WARNING: Reusing existing prepared files: new packs/pack'; then exit 1; fi
[[ ! -s "$CALL_LOG" && $(cat 'new packs/mtp/.native-preparation') == "$mtp_marker" ]]
not_called tools/iq_pack.py
mv 'new packs/mtp' 'new packs/saved-mtp'
run 0
not_called tools/iq_pack.py
called tools/mtp_pack.py

# Replacing model contents at the same path is detected without hashing weights.
echo replacement >> 'model with spaces-00002-of-00002.gguf'
run 0
output_has 'WARNING: Reusing existing prepared files: new packs/pack'
[[ ! -s "$CALL_LOG" ]]
mv 'new packs/pack' 'new packs/previous-pack'

# A failed packer never publishes a completion marker or a successful target.
export PACK_EXIT=9
run 9
[[ ! -e 'new packs/pack' && -d 'new packs/saved-pack' ]]
export PACK_EXIT=0
run 0
called tools/iq_pack.py
not_called tools/mtp_pack.py

# Conversion settings affect only the model stage; build-only ignores them.
echo COMPAT_BF16=invalid >> .env
run 0 --build-only
run 1
output_has 'COMPAT_BF16 must be 0 or 1'
echo COMPAT_BF16=1 >> .env
run 0
output_has 'WARNING: Reusing existing prepared files: new packs/pack'
[[ ! -s "$CALL_LOG" ]]
mv 'new packs/pack' 'new packs/pre-conversion-pack'
run 0
called --compat-bf16
not_called tools/mtp_pack.py

# A gguf-py change invalidates both stages, unlike an engine-only revision.
export GGUF_REV=new-gguf-tree
run 0
output_has 'WARNING: Reusing existing prepared files: new packs/pack'
output_has 'WARNING: Reusing existing prepared files: new packs/mtp'
[[ ! -s "$CALL_LOG" ]]
mv 'new packs/pack' 'new packs/pre-gguf-pack'
run 0
called tools/iq_pack.py
output_has 'WARNING: Reusing existing prepared files: new packs/mtp'
mv 'new packs/mtp' 'new packs/pre-gguf-mtp'
run 0
not_called tools/iq_pack.py
called tools/mtp_pack.py
# Missing/empty required outputs are actual failures, not uncertain fingerprints.
mv 'new packs/pack/index.txt' 'new packs/pack/saved-index.txt'
run 1
output_has 'Prepared output missing or empty: new packs/pack/index.txt'
[[ ! -s "$CALL_LOG" && -f 'new packs/pack/saved-index.txt' ]]
mv 'new packs/pack/saved-index.txt' 'new packs/pack/index.txt'
: > 'new packs/mtp/dense.txt'
run 1
output_has 'Prepared output missing or empty: new packs/mtp/dense.txt'
[[ ! -s "$CALL_LOG" ]]
mv 'new packs/mtp' 'new packs/incomplete-mtp'

# MTP acquisition failures still stop preparation without replacing old files.
export VERIFY_EXIT=1 FETCH_EXIT=8
run 8
called nix/mtp-fetch-pinned.py
[[ ! -e 'new packs/mtp' && -d 'new packs/incomplete-mtp' ]]
printf '%s\n' 'PASS: openSUSE build recovery and stage-specific preparation'
