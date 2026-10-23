#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=nix/launcher-common.sh
source "$1"
work=$(mktemp -d)
trap 'rm -r "$work"' EXIT
cd "$work"
export STRATA_ENV_FILE="$work/config.env"
touch "$STRATA_ENV_FILE"
unset STRATA_CTX STRATA_KV STRATA_THREADS STRATA_VRAM_CAP_MIB STRATA_RAM_CAP_GIB STRATA_MMPROJ
load_strata_env
strata_configure_args
[[ ${strata_server_args[*]} == '--host 127.0.0.1 --port 8080' ]]
[[ ${strata_engine_args[*]} == '--max-context 32768 --kv q8_0' ]]
# Explicit KV formats are passed through, not silently remapped.
STRATA_KV=q4_0
strata_configure_args
[[ ${strata_engine_args[*]} == '--max-context 32768 --kv q4_0' ]]
unset STRATA_KV
STRATA_MMPROJ='/models/a projector.gguf'
strata_configure_args --ctx 8192 --image-max-tokens 256 -- --lookup 0
[[ ${strata_server_args[*]} == '--host 127.0.0.1 --port 8080 --mmproj /models/a projector.gguf --image-max-tokens 1024 --image-max-tokens 256' ]]
[[ ${strata_engine_args[*]} == '--max-context 32768 --kv q8_0 --max-context 8192 --lookup 0' ]]
STRATA_VRAM_CAP_MIB=18000
if strata_configure_args 2>/dev/null; then echo 'obsolete cap accepted' >&2; exit 1; fi
unset STRATA_VRAM_CAP_MIB
STRATA_RAM_CAP_GIB=8
if strata_configure_args 2>/dev/null; then echo 'obsolete RAM cap accepted' >&2; exit 1; fi
unset STRATA_RAM_CAP_GIB
for flag in --ctx --mmproj --image-max-tokens; do
  if strata_configure_args "$flag" 2>/dev/null; then echo "missing $flag value accepted" >&2; exit 1; fi
done
STRATA_ENV_FILE="$work/missing.env"
if load_strata_env 2>/dev/null; then echo 'missing config accepted' >&2; exit 1; fi
STRATA_ENV_FILE="$work/config.env"
STRATA_QWEN38_MODEL='/models/flash next.gguf'
STRATA_QWEN38_MMPROJ='/models/flash projector.gguf'
STRATA_THREADS=4
load_qwen38_env
strata_configure_args --mmproj '/override/projector.gguf' -- --ple-io mmap
[[ $STRATA_MODEL == '/models/flash next.gguf' ]]
[[ ${strata_server_args[*]} == '--host 127.0.0.1 --port 8080 --mmproj /models/flash projector.gguf --image-max-tokens 1024 --threads 4 --mmproj /override/projector.gguf' ]]
[[ ${strata_engine_args[*]} == '--max-context 8192 --kv q4_0 --resident-budget-gib 40 --vision --pool-workers 4 --vision --ple-io mmap' ]]
STRATA_KV=q4_0
STRATA_QWEN38_MMPROJ=
load_qwen38_env
strata_configure_args --ctx=2048 --mmproj='/pictures/a b.gguf' --image-max-tokens=128
[[ ${strata_server_args[*]} == '--host 127.0.0.1 --port 8080 --threads 4 --mmproj=/pictures/a b.gguf --image-max-tokens=128' ]]
[[ ${strata_engine_args[*]} == '--max-context 8192 --kv q4_0 --resident-budget-gib 40 --pool-workers 4 --max-context 2048 --vision' ]]
# The trusted config overrides inherited variables and preserves paths with spaces.
cat > "$STRATA_ENV_FILE" <<'CONFIG'
STRATA_MODEL='/models/local model.gguf'
STRATA_CTX=4096
CONFIG
STRATA_MODEL=/ignored.gguf
load_strata_env
[[ $STRATA_MODEL == '/models/local model.gguf' && $STRATA_CTX == 4096 ]]
echo 'PASS: engine routing, images, unsupported caps, missing values/config'
