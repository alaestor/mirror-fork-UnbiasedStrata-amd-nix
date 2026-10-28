#!/usr/bin/env bash
set -euo pipefail
work=$(mktemp -d)
trap 'rm -r "$work"' EXIT
export STRATA_ENV_FILE="$work/config.env"
touch "$STRATA_ENV_FILE"
unset STRATA_VRAM_CAP_MIB STRATA_RAM_CAP_GIB STRATA_THREADS STRATA_CTX STRATA_KV
for model in qwen36 qwen38; do
  wrapper=$1
  shift
  export STRATA_MMPROJ='/ignored/local projector.gguf'
  export STRATA_QWEN38_MMPROJ='/ignored/flash projector.gguf'
  mapfile -t args < <("$wrapper")
  joined=" ${args[*]} "
  [[ $joined == *" --mmproj /models/$model BF16.gguf "* ]]
  if [[ $model == qwen38 ]]; then
    [[ $joined == *' --kv q4_0 --resident-budget-gib 40 --vision '* ]]
  else
    [[ $joined == *' --kv q8_0 '* ]]
  fi
  mapfile -t args < <("$wrapper" --mmproj '/override/custom BF16.gguf' --image-max-tokens 256 -- --lookup 0)
  joined=" ${args[*]} "
  [[ $joined == *' --mmproj /override/custom BF16.gguf --image-max-tokens 256 '* ]]
  [[ $joined == *' --lookup 0 ' ]]
  # Wrappers prepend projector flags; config selection must still reach the loader.
  printf 'STRATA_PORT=8129\n' > "$work/alternate config.env"
  mapfile -t args < <("$wrapper" --env-file "$work/alternate config.env")
  joined=" ${args[*]} "
  [[ $joined == *' --port 8129 '* && $joined != *--env-file* ]]
done
echo 'PASS: bundled projectors, CLI precedence, engine arguments'
