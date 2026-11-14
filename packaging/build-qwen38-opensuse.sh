#!/usr/bin/env bash
# Run from the repository root. All configured paths are relative to $PWD.
set -euo pipefail

build_only=0
fresh=()
usage() {
  cat <<'HELP'
Usage: bash packaging/build-qwen38-opensuse.sh [--build-only] [--fresh]
  --build-only  Compile engines and server without model files or preparation.
  --fresh       Reset CMake's cache, for example after moving the checkout.
                Keeps prepared packs, model files, and other build outputs.
  --help        Show this help.
Settings are read from the repository's trusted .env file.
HELP
}
for arg in "$@"; do
  case "$arg" in
    --build-only) build_only=1 ;;
    --fresh) fresh=(--fresh) ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

MODEL=Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf
MODEL_SHARD2=Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00002-of-00002.gguf
BUILD_DIR=build-gfx1201
PREPARED_DIR=packs/qwen38
MTP_SOURCE=mtp/qwen38-source
VENV=.venv
JOBS=4
LLAMA_REV=385445fad49e42fa718b5e1f71668f35b7a08559
COMPAT_BF16=0

die() { echo "$*" >&2; exit 1; }
[[ -f flake.nix && -f nix/qwen38-mtp-manifest.json ]] || die 'Run from the repository root.'
# Like the serving launchers, this sources trusted shell code, not dotenv data.
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi
for command in git cmake ninja flock; do
  command -v "$command" >/dev/null || die "Missing command: $command"
done
if (( ! build_only )); then
  [[ "$COMPAT_BF16" == 0 || "$COMPAT_BF16" == 1 ]] || die 'COMPAT_BF16 must be 0 or 1.'
  for command in python3 sha256sum stat realpath; do
    command -v "$command" >/dev/null || die "Missing command: $command"
  done
  python3 -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ required"'
fi
mkdir -p "$BUILD_DIR"
exec 9>"$BUILD_DIR/native-preparation.lock"
flock -n 9 || die 'Another build/preparation is running.'

# Check paths without reading the multi-gigabyte model shards.
if (( ! build_only )); then
  [[ -f "$MODEL" && -f "$MODEL_SHARD2" ]] || die 'Both model shards must exist. Use --build-only to compile without preparing models.'
  [[ "$MODEL_SHARD2" == "${MODEL%-00001-of-00002.gguf}-00002-of-00002.gguf" ]] ||
    die 'Keep the original shard filenames together in one directory.'
fi

if [[ -e third_party/llama.cpp/.git ]]; then
  [[ -z $(git -C third_party/llama.cpp status --porcelain) ]] || die 'llama.cpp has local changes; refusing submodule update.'
fi
git submodule update --init third_party/llama.cpp
[[ -z $(git -C third_party/llama.cpp status --porcelain) ]] || die 'llama.cpp has local changes; refusing checkout.'
if ! git -C third_party/llama.cpp cat-file -e "$LLAMA_REV^{commit}" 2>/dev/null; then
  git -C third_party/llama.cpp fetch origin "$LLAMA_REV"
fi
git -C third_party/llama.cpp checkout --detach "$LLAMA_REV"
if ! cmake "${fresh[@]}" -S . -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DSTRATA_ENABLE_HIP=ON -DSTRATA_ENABLE_CUDA=OFF \
  -DSTRATA_BUILD_TESTS=OFF -DSTRATA_PORTABLE=ON \
  -DCMAKE_HIP_ARCHITECTURES=gfx1201 -DBUILD_SHARED_LIBS=OFF; then
  die 'CMake configuration failed. If this checkout moved, rerun with --fresh to reset the CMake cache without deleting packs. Use --build-only to skip preparation.'
fi
cmake --build "$BUILD_DIR" --target unbiased-strata strata strata-poly strata-device native_expert_parity --parallel "$JOBS"
echo "Build complete: $BUILD_DIR. Existing packs have not been changed."
if (( build_only )); then exit 0; fi

if [[ ! -x "$VENV/bin/python" ]]; then python3 -m venv "$VENV"; fi
PYTHON="$PWD/$VENV/bin/python"
"$PYTHON" -m pip install 'numpy>=2.2.6' regex pyyaml tqdm requests
export STRATA_GGUF_PY="$PWD/third_party/llama.cpp/gguf-py"

# Fingerprint only each stage's inputs. Model metadata avoids rereading huge
# shards; paths relative to the checkout allow moving the whole tree unchanged.
# Failed stages leave their temporary directory for review.
mkdir -p "$PREPARED_DIR"
gguf_revision=$(git -C third_party/llama.cpp rev-parse HEAD:gguf-py)
pack_fingerprint=$(
  { printf '%s\n' native-pack-v2 "$gguf_revision" "$COMPAT_BF16";
    for shard in "$MODEL" "$MODEL_SHARD2"; do
      realpath --relative-to="$PWD" -- "$shard"
      TZ=UTC stat -L --printf='%s %y\n' -- "$shard"
    done
    sha256sum tools/iq_pack.py tools/gguf_reader.py tools/strata_tokenizer.py \
      tools/_paths.py data/expert-profile.bin;
  } | sha256sum
)
mtp_fingerprint=$(
  { printf '%s\n' native-mtp-v2 "$gguf_revision";
    sha256sum tools/mtp_pack.py tools/mtp_rt.py tools/_paths.py \
      data/draft_vocab.bin nix/qwen38-mtp-manifest.json;
  } | sha256sum
)
stage() {
  local name=$1 fingerprint=$2 target="$PREPARED_DIR/$1" temporary
  shift 2
  if [[ -e "$target" ]]; then
    [[ -f "$target/.native-preparation" ]] &&
      [[ $(cat "$target/.native-preparation") == "$fingerprint" ]] ||
      die "Preparation inputs changed or completion marker is unrecognized: $target. Existing packs were kept. Use --build-only to rebuild engines without preparing packs, or set PREPARED_DIR in .env to a fresh directory to regenerate."
    echo "Already prepared: $target"
    return
  fi
  temporary=$(mktemp -d "$PREPARED_DIR/.${name}.XXXXXXXX")
  "$@" "$temporary"
  printf '%s\n' "$fingerprint" > "$temporary/.native-preparation"
  mv -T -- "$temporary" "$target"
}
pack_model() {
  local args=()
  if [[ "$COMPAT_BF16" == 1 ]]; then args+=(--compat-bf16); fi
  "$PYTHON" tools/iq_pack.py --gguf "$MODEL" --out "$1" "${args[@]}"
  cp data/expert-profile.bin "$1/expert-profile.bin"
}
pack_mtp() {
  "$PYTHON" tools/mtp_pack.py --src "$MTP_SOURCE" --experts q2_0 --out "$1/mtp-q2_0.gguf"
  "$PYTHON" tools/mtp_rt.py --gguf "$1/mtp-q2_0.gguf" --out "$1"
  cp data/draft_vocab.bin "$1/draft_vocab.bin"
}
stage pack "$pack_fingerprint" pack_model
if ! "$PYTHON" nix/verify-mtp-source.py "$MTP_SOURCE" nix/qwen38-mtp-manifest.json; then
  "$PYTHON" nix/mtp-fetch-pinned.py "$PWD/tools" fetch --out "$MTP_SOURCE"
  "$PYTHON" nix/verify-mtp-source.py "$MTP_SOURCE" nix/qwen38-mtp-manifest.json
fi
stage mtp "$mtp_fingerprint" pack_mtp
echo "Ready: $BUILD_DIR/unbiased-strata; --pack $PREPARED_DIR/pack --mtp $PREPARED_DIR/mtp"
