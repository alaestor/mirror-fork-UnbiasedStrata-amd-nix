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
LLAMA_REV=
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
  for command in sha256sum stat realpath; do
    command -v "$command" >/dev/null || die "Missing command: $command"
  done
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
if [[ -n "$LLAMA_REV" ]]; then
  if ! git -C third_party/llama.cpp cat-file -e "$LLAMA_REV^{commit}" 2>/dev/null; then
    git -C third_party/llama.cpp fetch origin "$LLAMA_REV"
  fi
  git -C third_party/llama.cpp checkout --detach "$LLAMA_REV"
fi
if ! cmake "${fresh[@]}" -S . -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DSTRATA_ENABLE_HIP=ON -DSTRATA_ENABLE_CUDA=OFF \
  -DSTRATA_BUILD_TESTS=OFF -DSTRATA_PORTABLE=ON \
  -DCMAKE_HIP_ARCHITECTURES=gfx1201 -DBUILD_SHARED_LIBS=OFF; then
  die 'CMake configuration failed. If this checkout moved, rerun with --fresh to reset the CMake cache without deleting packs. Use --build-only to skip preparation.'
fi
cmake --build "$BUILD_DIR" --target unbiased-strata strata strata-poly strata-device native_expert_parity --parallel "$JOBS"
echo "Build complete: $BUILD_DIR. Existing packs have not been changed."
if (( build_only )); then exit 0; fi

python_ready=0
prepare_python() {
  if (( python_ready )); then return; fi
  command -v python3 >/dev/null || die 'Missing command: python3 (needed to prepare missing packs)'
  python3 -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ required"'
  if [[ ! -x "$VENV/bin/python" ]]; then python3 -m venv "$VENV"; fi
  PYTHON="$PWD/$VENV/bin/python"
  "$PYTHON" -m pip install 'numpy>=2.2.6' regex pyyaml tqdm requests
  python_ready=1
}
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
reused_unverified=0
stage() {
  local name=$1 fingerprint=$2 target="$PREPARED_DIR/$1" temporary required
  local -a required_files
  shift 2
  if [[ -e "$target" ]]; then
    case "$name" in
      pack) required_files=(dense.bin index.txt native_experts.txt expert-profile.bin) ;;
      mtp) required_files=(dense.bin dense.txt experts.bin draft_vocab.bin) ;;
    esac
    for required in "${required_files[@]}"; do
      [[ -f "$target/$required" && -s "$target/$required" ]] || die "Prepared output missing or empty: $target/$required. Existing files were kept. Set PREPARED_DIR in .env to a fresh directory and rerun to regenerate, or use --build-only to compile without preparation checks."
    done
    if [[ -f "$target/.native-preparation" ]] &&
       [[ $(cat "$target/.native-preparation") == "$fingerprint" ]]; then
      echo "Already prepared: $target"
    else
      reused_unverified=1
      cat >&2 <<EOF

WARNING: Reusing existing prepared files: $target
Preparation inputs changed, or the completion marker is missing or unrecognized.
This does not prove the pack is broken, but compatibility is not verified and
problems may only appear at runtime. Files and completion markers were kept unchanged.
If loading or inference fails, set PREPARED_DIR in .env to a fresh directory and
rerun this script to regenerate packs from your model files. Keep the originals
until the new packs work; do not delete model weights or raw MTP inputs.

EOF
    fi
    return
  fi
  prepare_python
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
  if ! "$PYTHON" nix/verify-mtp-source.py "$MTP_SOURCE" nix/qwen38-mtp-manifest.json; then
    "$PYTHON" nix/mtp-fetch-pinned.py "$PWD/tools" fetch --out "$MTP_SOURCE"
    "$PYTHON" nix/verify-mtp-source.py "$MTP_SOURCE" nix/qwen38-mtp-manifest.json
  fi
  "$PYTHON" tools/mtp_pack.py --src "$MTP_SOURCE" --experts q2_0 --out "$1/mtp-q2_0.gguf"
  "$PYTHON" tools/mtp_rt.py --gguf "$1/mtp-q2_0.gguf" --out "$1"
  cp data/draft_vocab.bin "$1/draft_vocab.bin"
}
stage pack "$pack_fingerprint" pack_model
stage mtp "$mtp_fingerprint" pack_mtp
if (( reused_unverified )); then
  echo 'Build/preparation finished with warnings: existing packs were reused; runtime compatibility is not verified.' >&2
fi
echo "Launch inputs: $BUILD_DIR/unbiased-strata; --pack $PREPARED_DIR/pack --mtp $PREPARED_DIR/mtp"
