# Shared by the packaged launchers. .env is trusted shell configuration.
load_strata_env() {
  local env_file=${STRATA_ENV_FILE:-.env}
  if [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    source "$env_file"
  elif [[ -n ${STRATA_ENV_FILE:-} ]]; then
    echo "Configuration file does not exist: $env_file" >&2
    return 1
  fi
  STRATA_MODEL=${STRATA_MODEL:-}
  STRATA_PREPARED_DIR=${STRATA_PREPARED_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/unbiased-strata/qwen36}
}

load_qwen38_env() {
  load_strata_env
  STRATA_MODEL=${STRATA_QWEN38_MODEL:-}
  STRATA_PREPARED_DIR=${STRATA_QWEN38_PREPARED_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/unbiased-strata/qwen38}
  STRATA_CTX=${STRATA_QWEN38_CTX:-8192}
  STRATA_RAM_CAP_GIB=${STRATA_QWEN38_RAM_CAP_GIB:-40}
}

strata_configure_args() {
  strata_server_args=(
    --ctx "${STRATA_CTX:-32768}"
    --host "${STRATA_HOST:-127.0.0.1}"
    --port "${STRATA_PORT:-8080}"
  )
  strata_engine_args=(--kv "${STRATA_KV:-q4_0}")
  if [[ -n ${STRATA_THREADS:-} ]]; then
    strata_server_args+=(--threads "$STRATA_THREADS")
  fi
  if [[ -n ${STRATA_VRAM_CAP_MIB:-} ]]; then
    strata_server_args+=(--vram-cap "$STRATA_VRAM_CAP_MIB")
  fi
  if [[ -n ${STRATA_RAM_CAP_GIB:-} ]]; then
    strata_server_args+=(--ram-cap "$STRATA_RAM_CAP_GIB")
  fi
  local engine=false arg
  for arg in "$@"; do
    if [[ "$arg" == -- && "$engine" == false ]]; then
      engine=true
    elif [[ "$engine" == true ]]; then
      strata_engine_args+=("$arg")
    else
      strata_server_args+=("$arg")
    fi
  done
}
