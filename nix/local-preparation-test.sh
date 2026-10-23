#!/usr/bin/env bash
set -euo pipefail
prepare38=$1
work=$(mktemp -d)
cd "$work"
# An explicit empty configuration prevents inheriting a developer's .env.
touch config.env
export STRATA_ENV_FILE="$work/config.env"
unset STRATA_MODEL STRATA_QWEN38_MODEL STRATA_QWEN38_MTP_SOURCE
expect_failure() {
  local status=0
  "$@" >stdout 2>stderr || status=$?
  if [[ $status == 0 ]]; then
    echo "Unexpected preparation success: $*" >&2
    exit 1
  fi
}
expect_failure "$prepare38"
grep -q 'STRATA_QWEN38_MTP_SOURCE' stderr
# Explicit model arguments must not enable implicit MTP acquisition.
expect_failure "$prepare38" '/missing/local shard.gguf' "$work/output"
grep -q 'STRATA_QWEN38_MTP_SOURCE' stderr
[[ ! -e $work/output ]]
export STRATA_QWEN38_MTP_SOURCE="$work/absent draft source"
expect_failure "$prepare38" '/missing/local shard.gguf' "$work/output"
grep -q 'mtp-manifest.json' stderr
[[ ! -e $STRATA_QWEN38_MTP_SOURCE && ! -e $work/output ]]
echo 'PASS: local preparation requires explicit inputs and never acquires missing artifacts'
