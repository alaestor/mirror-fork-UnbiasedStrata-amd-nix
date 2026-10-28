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
# Shared sampling overrides preserve zero and precede CLI overrides, never engine options.
unset STRATA_RAM_CAP_GIB
cat >> "$STRATA_ENV_FILE" <<'CONFIG'
STRATA_TEMPERATURE=0
STRATA_TOP_P=0.8
STRATA_TOP_K=20
STRATA_MIN_P=0
STRATA_PRESENCE_PENALTY=0
STRATA_REPEAT_PENALTY=1
CONFIG
load_strata_env
strata_configure_args --temp 0.6 -- --lookup 0
[[ ${strata_server_args[*]} == *'--temp 0 --top-p 0.8 --top-k 20 --min-p 0 --presence-penalty 0 --repeat-penalty 1'*'--temp 0.6' ]]
[[ ${strata_engine_args[*]} != *--temp* ]]
echo 'STRATA_TEMPERATURE=' >> "$STRATA_ENV_FILE"
load_strata_env
strata_configure_sampling
[[ ${strata_sampling_args[*]} != *--temp* ]]
# CLI config selection overrides the environment and preserves remaining arguments.
cat > "$work/alternate config.env" <<'CONFIG'
STRATA_QWEN38_MODEL='/models/alternate flash.gguf'
STRATA_QWEN38_CTX=2048
CONFIG
strata_parse_env_args '/models/explicit model.gguf' --env-file "$work/alternate config.env" '/packs/explicit pack' --ctx 1024 -- --env-file engine-value
[[ $STRATA_ENV_FILE == "$work/alternate config.env" ]]
[[ ${#strata_launch_args[@]} == 7 ]]
[[ ${strata_launch_args[0]} == '/models/explicit model.gguf' && ${strata_launch_args[1]} == '/packs/explicit pack' ]]
[[ ${strata_launch_args[5]} == --env-file && ${strata_launch_args[6]} == engine-value ]]
load_qwen38_env
[[ $STRATA_MODEL == '/models/alternate flash.gguf' && $STRATA_CTX == 2048 ]]
strata_parse_env_args --env-file="$work/config.env" --temp 0.6
[[ $STRATA_ENV_FILE == "$work/config.env" && ${strata_launch_args[*]} == '--temp 0.6' ]]
for form in missing empty equals option; do
  case $form in
    missing) args=(--env-file) ;;
    empty) args=(--env-file '') ;;
    equals) args=(--env-file=) ;;
    option) args=(--env-file --temp 0.6) ;;
  esac
  if strata_parse_env_args "${args[@]}" 2>/dev/null; then
    echo "invalid env-file form accepted: $form" >&2; exit 1
  fi
done
strata_parse_env_args --env-file "$work/missing.env"
if load_strata_env 2>/dev/null; then echo 'missing CLI config accepted' >&2; exit 1; fi
echo 'PASS: engine routing, images, sampling, config selection, invalid values/config'
