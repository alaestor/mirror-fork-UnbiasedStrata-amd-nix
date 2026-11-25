#!/usr/bin/env bash
set -euo pipefail

common=$(realpath -- "${1:?launcher-common.sh}")
launcher=$(realpath -- "${2:?launch.sh}")
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cd -- "$work"
unset STRATA_ENV_FILE STRATA_HOST STRATA_PORT STRATA_CTX
unset STRATA_INKLING_MODEL STRATA_INKLING_CTX STRATA_INKLING_DRAFT STRATA_INKLING_VRAM_RESERVE_MIB

printf '#!%s\n' "$BASH" > front
cat >> front <<'STUB'
[[ ${LLAMA_ARG_OFFLINE:-} == 1 ]] || exit 1
printf '%s\n' "$@"
STUB
chmod +x front
touch 'model file.gguf' draft.safetensors
cat > .env <<'ENV'
STRATA_INKLING_MODEL="$PWD/model file.gguf"
STRATA_INKLING_CTX=38912
STRATA_CTX=163840
ENV

run() (
  # shellcheck disable=SC2034
  inkling_frontend="$PWD/front"
  # shellcheck disable=SC2034
  inkling_engine="$PWD/front"
  # shellcheck disable=SC1090
  source "$common"
  # shellcheck disable=SC1090
  source "$launcher"
)

run > actual
printf '%s\n' --engine "$PWD/front" -m "$PWD/model file.gguf" --alias inkling-2-mini \
  --host 127.0.0.1 --port 8080 -- --native "$PWD/model file.gguf" --max-context 38912 \
  --parallel 1 --vram-reserve-mib 4096 > expected
diff -u expected actual

cat > 'other profile' <<'ENV'
STRATA_INKLING_MODEL="$PWD/model file.gguf"
STRATA_INKLING_DRAFT="$PWD/draft.safetensors"
STRATA_HOST=localhost
STRATA_INKLING_VRAM_RESERVE_MIB=2048
ENV
run --env-file 'other profile' --temp 0 -- --max-context 8192 --draft dspark > actual
printf '%s\n' --engine "$PWD/front" -m "$PWD/model file.gguf" --alias inkling-2-mini \
  --host localhost --port 8080 --temp 0 -- --native "$PWD/model file.gguf" --max-context 4096 \
  --parallel 1 --vram-reserve-mib 2048 --dspark "$PWD/draft.safetensors" --max-context 8192 --draft dspark > expected
diff -u expected actual

fails_with() {
  local expected=$1
  shift
  if (run "$@") > actual 2>&1; then
    echo "Unexpected launch success: $*" >&2
    exit 1
  fi
  grep -Fq "$expected" actual || { cat actual >&2; exit 1; }
}
fails_with 'Cannot read configuration' --env-file missing
mv -- draft.safetensors unavailable
fails_with 'STRATA_INKLING_DRAFT' --env-file 'other profile'
mv -- 'model file.gguf' unavailable.gguf
fails_with 'STRATA_INKLING_MODEL'
