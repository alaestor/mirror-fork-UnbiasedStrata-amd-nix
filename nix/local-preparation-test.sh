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
# The explicit config is selected before validating positional preparation inputs.
cat > 'alternate config.env' <<'CONFIG'
STRATA_QWEN38_MODEL='/missing/alternate shard.gguf'
STRATA_QWEN38_MTP_SOURCE='/missing/alternate draft'
CONFIG
expect_failure "$prepare38" --env-file "$work/alternate config.env"
grep -q '/missing/alternate draft' stderr
expect_failure "$prepare38" --env-file
grep -q -- '--env-file requires' stderr
expect_failure "$prepare38" --env-file "$work/missing.env"
grep -q 'Configuration file does not exist' stderr
echo 'PASS: local preparation requires explicit inputs and never acquires missing artifacts'
