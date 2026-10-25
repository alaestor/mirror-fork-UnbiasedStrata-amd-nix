#!/usr/bin/env bash
# Run from the repository root. All configured paths are relative to $PWD.
set -euo pipefail

MODEL=Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf
MODEL_SHARD2=Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00002-of-00002.gguf
BUILD_DIR=build-gfx1201
PREPARED_DIR=packs/qwen38
MTP_SOURCE=mtp/qwen38-source
VENV=.venv
JOBS=4
LLAMA_REV=385445fad49e42fa718b5e1f71668f35b7a08559

die() { echo "$*" >&2; exit 1; }
[[ -f flake.nix && -f nix/qwen38-mtp-manifest.json ]] || die 'Run from the repository root.'
for command in git cmake ninja python3 sha256sum flock; do
  command -v "$command" >/dev/null || die "Missing command: $command"
done
python3 -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ required"'
mkdir -p "$BUILD_DIR"
exec 9>"$BUILD_DIR/native-preparation.lock"
flock -n 9 || die 'Another build/preparation is running.'

# Validate before compiling or downloading. Recheck on every run.
printf '%s  %s\n' \
  219ea929900dfa9ef091f3aa473fdba6874b65fcb36526d7d851ac9e95856d15 "$MODEL" \
  316b46f3a2dbd68c900f43136ab9449f9dcc3725dfd8c794847c204bc161e113 "$MODEL_SHARD2" |
  sha256sum --check
[[ "$MODEL_SHARD2" == "${MODEL%-00001-of-00002.gguf}-00002-of-00002.gguf" ]] ||
  die 'Keep the original shard filenames together in one directory.'

if [[ -e third_party/llama.cpp/.git ]]; then
  [[ -z $(git -C third_party/llama.cpp status --porcelain) ]] || die 'llama.cpp has local changes; refusing submodule update.'
fi
git submodule update --init third_party/llama.cpp
[[ -z $(git -C third_party/llama.cpp status --porcelain) ]] || die 'llama.cpp has local changes; refusing checkout.'
if ! git -C third_party/llama.cpp cat-file -e "$LLAMA_REV^{commit}" 2>/dev/null; then
  git -C third_party/llama.cpp fetch origin "$LLAMA_REV"
fi
git -C third_party/llama.cpp checkout --detach "$LLAMA_REV"
cmake -S . -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DSTRATA_ENABLE_HIP=ON -DSTRATA_ENABLE_CUDA=OFF \
  -DSTRATA_BUILD_TESTS=OFF -DSTRATA_PORTABLE=ON \
  -DCMAKE_HIP_ARCHITECTURES=gfx1201 -DBUILD_SHARED_LIBS=OFF
cmake --build "$BUILD_DIR" --target unbiased-strata strata strata-poly strata-device native_expert_parity --parallel "$JOBS"

if [[ ! -x "$VENV/bin/python" ]]; then python3 -m venv "$VENV"; fi
PYTHON="$PWD/$VENV/bin/python"
"$PYTHON" -m pip install 'numpy>=2.2.6' regex pyyaml tqdm requests
export STRATA_GGUF_PY="$PWD/third_party/llama.cpp/gguf-py"

# Bind completed outputs to the source, tools, and model location. Refuse stale
# outputs rather than deleting or silently reusing them. Use a new directory
# after source changes. Failed stages leave their temporary directory for review.
mkdir -p "$PREPARED_DIR"
fingerprint=$(
  { printf '%s\n' "$PWD/$MODEL" "$LLAMA_REV";
    sha256sum tools/*.py data/expert-profile.bin data/draft_vocab.bin \
      nix/qwen38-mtp-manifest.json nix/mtp-fetch-pinned.py nix/verify-mtp-source.py;
  } | sha256sum
)
stage() {
  local name=$1 target="$PREPARED_DIR/$1" temporary
  shift
  if [[ -e "$target" ]]; then
    [[ -f "$target/.native-preparation" ]] &&
      [[ $(cat "$target/.native-preparation") == "$fingerprint" ]] ||
      die "Unrecognized or stale output: $target. Set PREPARED_DIR to a new directory."
    echo "Already prepared: $target"
    return
  fi
  temporary=$(mktemp -d "$PREPARED_DIR/.${name}.XXXXXXXX")
  "$@" "$temporary"
  printf '%s\n' "$fingerprint" > "$temporary/.native-preparation"
  mv -T -- "$temporary" "$target"
}
pack_model() {
  "$PYTHON" tools/iq_pack.py --gguf "$MODEL" --out "$1"
  cp data/expert-profile.bin "$1/expert-profile.bin"
}
pack_mtp() {
  "$PYTHON" tools/mtp_pack.py --src "$MTP_SOURCE" --experts q2_0 --out "$1/mtp-q2_0.gguf"
  "$PYTHON" tools/mtp_rt.py --gguf "$1/mtp-q2_0.gguf" --out "$1"
  cp data/draft_vocab.bin "$1/draft_vocab.bin"
}
stage pack pack_model
if ! "$PYTHON" nix/verify-mtp-source.py "$MTP_SOURCE" nix/qwen38-mtp-manifest.json; then
  "$PYTHON" nix/mtp-fetch-pinned.py "$PWD/tools" fetch --out "$MTP_SOURCE"
  "$PYTHON" nix/verify-mtp-source.py "$MTP_SOURCE" nix/qwen38-mtp-manifest.json
fi
stage mtp pack_mtp
echo "Ready: $BUILD_DIR/unbiased-strata; --pack $PREPARED_DIR/pack --mtp $PREPARED_DIR/mtp"
