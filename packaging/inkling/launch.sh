# shellcheck shell=bash
# Shared by the Nix and openSUSE launchers.
strata_parse_env_args "$@"
# shellcheck disable=SC2154
set -- "${strata_launch_args[@]}"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  echo "Usage: ${0##*/} [--env-file PATH] [front-end options] [-- engine options]"
  exit 0
fi

env_file=${STRATA_ENV_FILE:-.env}
if [[ -f "$env_file" && -r "$env_file" ]]; then
  [[ "$env_file" == /* ]] || env_file=./$env_file
  # shellcheck disable=SC1090
  source "$env_file"
elif [[ -n ${STRATA_ENV_FILE:-} || -e "$env_file" || -L "$env_file" ]]; then
  echo "Cannot read configuration file: $env_file" >&2
  exit 1
fi

model=${STRATA_INKLING_MODEL:-}
if [[ "$model" != *.gguf || ! -f "$model" || ! -r "$model" ]]; then
  echo "Set STRATA_INKLING_MODEL to a readable Inkling 2 Mini GGUF." >&2
  exit 1
fi

# shellcheck disable=SC2154
if [[ ! -x "$inkling_frontend" || ! -x "$inkling_engine" ]]; then
  echo "Missing Inkling build. Run packaging/build-inkling-opensuse.sh first." >&2
  exit 1
fi

front_args=()
engine_args=()
while (( $# )); do
  if [[ "$1" == -- ]]; then
    shift
    engine_args=("$@")
    break
  fi
  front_args+=("$1")
  shift
done

draft_args=()
if [[ -n ${STRATA_INKLING_DRAFT:-} ]]; then
  if [[ ! -f "$STRATA_INKLING_DRAFT" || ! -r "$STRATA_INKLING_DRAFT" ]]; then
    echo "STRATA_INKLING_DRAFT must point to a readable native Strata drafter." >&2
    exit 1
  fi
  draft_args=(--dspark "$STRATA_INKLING_DRAFT")
fi

# The front end uses only the supplied local model. Keep llama.cpp offline.
export LLAMA_ARG_OFFLINE=1

exec "$inkling_frontend" --engine "$inkling_engine" -m "$model" --alias inkling-2-mini \
  --host "${STRATA_HOST:-127.0.0.1}" --port "${STRATA_PORT:-8080}" "${front_args[@]}" -- \
  --native "$model" --max-context "${STRATA_INKLING_CTX:-4096}" --parallel 1 \
  --vram-reserve-mib "${STRATA_INKLING_VRAM_RESERVE_MIB:-4096}" \
  "${draft_args[@]}" "${engine_args[@]}"
