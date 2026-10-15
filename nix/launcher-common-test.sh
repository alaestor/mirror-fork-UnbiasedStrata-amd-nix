#!/usr/bin/env bash
set -euo pipefail
source "$1"
unset STRATA_ENV_FILE STRATA_MODEL STRATA_PREPARED_DIR STRATA_CTX STRATA_HOST STRATA_PORT
unset STRATA_KV STRATA_THREADS STRATA_VRAM_CAP_MIB STRATA_RAM_CAP_GIB
work=$(mktemp -d)
cd "$work"
load_strata_env
[[ -z $STRATA_MODEL ]]
[[ $STRATA_PREPARED_DIR == */unbiased-strata/qwen36 ]]
strata_configure_args
[[ ${strata_server_args[*]} == '--ctx 32768 --host 127.0.0.1 --port 8080' ]]
[[ ${strata_engine_args[*]} == '--kv q4_0' ]]
cat > .env <<'CONFIG'
STRATA_MODEL='/models/a model.gguf'
STRATA_PREPARED_DIR='/models/prepared packs'
STRATA_CTX=65536
STRATA_THREADS=4
STRATA_VRAM_CAP_MIB=18000
STRATA_RAM_CAP_GIB=8
CONFIG
load_strata_env
[[ $STRATA_MODEL == '/models/a model.gguf' ]]
[[ $STRATA_PREPARED_DIR == '/models/prepared packs' ]]
strata_configure_args --ctx 8192 -- --kv int8 --prompt-cache 2
[[ ${strata_server_args[*]} == '--ctx 65536 --host 127.0.0.1 --port 8080 --threads 4 --vram-cap 18000 --ram-cap 8 --ctx 8192' ]]
[[ ${strata_engine_args[*]} == '--kv q4_0 --kv int8 --prompt-cache 2' ]]
strata_configure_args --mmproj '/models/projector with spaces.gguf'
[[ ${strata_server_args[-1]} == '/models/projector with spaces.gguf' ]]
STRATA_ENV_FILE=missing.env
if load_strata_env 2>/dev/null; then
  echo 'Missing explicit configuration was accepted' >&2
  exit 1
fi
STRATA_ENV_FILE=$work/.env
load_strata_env
[[ $STRATA_CTX == 65536 ]]
unset STRATA_QWEN38_MODEL STRATA_QWEN38_PREPARED_DIR STRATA_QWEN38_CTX STRATA_QWEN38_RAM_CAP_GIB
load_qwen38_env
[[ -z $STRATA_MODEL ]]
[[ $STRATA_PREPARED_DIR == */unbiased-strata/qwen38 ]]
[[ $STRATA_CTX == 8192 && $STRATA_RAM_CAP_GIB == 40 ]]
STRATA_QWEN38_MODEL='/models/flash next.gguf'
STRATA_QWEN38_PREPARED_DIR='/models/flash packs'
STRATA_QWEN38_CTX=16384
STRATA_QWEN38_RAM_CAP_GIB=32
load_qwen38_env
[[ $STRATA_MODEL == '/models/flash next.gguf' ]]
[[ $STRATA_PREPARED_DIR == '/models/flash packs' ]]
strata_configure_args --ctx 4096 -- --resident-experts --ple-io mmap
[[ ${strata_server_args[*]} == '--ctx 16384 --host 127.0.0.1 --port 8080 --threads 4 --vram-cap 18000 --ram-cap 32 --ctx 4096' ]]
[[ ${strata_engine_args[*]} == '--kv q4_0 --resident-experts --ple-io mmap' ]]
echo 'PASS: configuration, spaces, CLI overrides, engine arguments, missing config'
