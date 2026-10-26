#!/usr/bin/env bash
# Run from the repository root. Only source a .env you trust.
set -euo pipefail
MODEL=Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf
BUILD_DIR=build-gfx1201
PREPARED_DIR=packs/qwen38
CONTEXT=8192
RAM_BUDGET_GIB=40
MEMORY_MAX=48G
VRAM_RESERVE_MIB=4096
HOST=127.0.0.1
PORT=8080
[[ -f flake.nix ]] || { echo 'Run from the repository root.' >&2; exit 1; }
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi
for value in "$CONTEXT" "$RAM_BUDGET_GIB" "$VRAM_RESERVE_MIB" "$PORT"; do
  [[ "$value" =~ ^[0-9]+$ ]] || { echo 'Sizes and port must be nonnegative integers.' >&2; exit 1; }
done
[[ -f "$MODEL" && -d "$PREPARED_DIR/pack" && -d "$PREPARED_DIR/mtp" ]] || {
  echo 'Model or prepared packs missing; run packaging/build-qwen38-opensuse.sh first.' >&2
  exit 1
}
exec systemd-run --user --wait --pty --collect \
  --unit=strata-qwen38 --working-directory="$PWD" \
  -p "MemoryMax=$MEMORY_MAX" -p MemorySwapMax=0 \
  bash "$PWD/nix/memory-preflight.sh" \
  "$PWD/$BUILD_DIR/unbiased-strata" --engine "$PWD/$BUILD_DIR/strata" \
  --model "$PWD/$MODEL" --host "$HOST" --port "$PORT" -- \
  --native "$PWD/$MODEL" --pack "$PWD/$PREPARED_DIR/pack" --mtp "$PWD/$PREPARED_DIR/mtp" \
  --expert-profile "$PWD/$PREPARED_DIR/pack/expert-profile.bin" \
  --max-context "$CONTEXT" --kv q4_0 --resident-budget-gib "$RAM_BUDGET_GIB" \
  --expert-cache auto --prefill auto --spec 4 --resident-experts \
  --ple-io mmap --vram-reserve-mib "$VRAM_RESERVE_MIB"
