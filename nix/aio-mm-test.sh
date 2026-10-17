#!/usr/bin/env bash
set -euo pipefail

# The wrappers use the real configuration parser but no model or GPU.
for model in qwen36 qwen38; do
  wrapper=$1
  shift
  export STRATA_MMPROJ='/ignored/local projector.gguf'
  export STRATA_QWEN38_MMPROJ='/ignored/flash projector.gguf'
  mapfile -t args < <("$wrapper")
  [[ ${args[-5]} == --mmproj && ${args[-4]} == "/models/$model BF16.gguf" ]]
  [[ ${args[-3]} == ENGINE && ${args[-2]} == --kv && ${args[-1]} == q4_0 ]]

  mapfile -t args < <("$wrapper" --mmproj '/override/custom BF16.gguf' --vision-tokens 256 -- --kv int8)
  [[ ${args[-9]} == --mmproj && ${args[-8]} == '/override/custom BF16.gguf' ]]
  [[ ${args[-7]} == --vision-tokens && ${args[-6]} == 256 ]]
  [[ ${args[-5]} == ENGINE && ${args[-2]} == --kv && ${args[-1]} == int8 ]]
done
echo 'PASS: bundled projectors, environment precedence, CLI overrides, engine arguments'
