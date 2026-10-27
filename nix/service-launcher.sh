# shellcheck shell=bash
# Lifecycle dispatch stays outside engine/model closures and never loads .env.
strata_service_dispatch() {
  local unit=$1 foreground_service=$2 target=$3
  shift 3
  local action=foreground
  case ${1:-} in
    start|stop|status|logs) action=$1; shift ;;
  esac
  case $action in
    stop|status|logs)
      if (( $# )); then
        echo "$action takes no arguments." >&2
        return 2
      fi
      ;;
  esac
  case $action in
    status)
      echo 'Service state is not API readiness. Query the configured /health endpoint to check readiness.'
      exec systemctl --user --no-pager --full status "$unit"
      ;;
    logs) exec journalctl --user --unit="$unit" --follow ;;
  esac
  # Qwen3.6 foreground mode remains a direct process, without a user manager.
  if [[ $action != foreground || $foreground_service == true ]]; then
    local info load_state='' active_state='' key value
    if ! info=$(systemctl --user show "$unit" -p LoadState -p ActiveState); then
      if [[ $info != *'LoadState=not-found'* ]]; then
        echo 'Cannot query the systemd user manager. Use the same login user, without sudo.' >&2
        return 1
      fi
    fi
    while IFS='=' read -r key value; do
      case $key in
        LoadState) load_state=$value ;;
        ActiveState) active_state=$value ;;
      esac
    done <<< "$info"
    if [[ -z $load_state || -z $active_state ]]; then
      echo 'Cannot determine service state.' >&2
      return 1
    fi
    if [[ $action == stop ]]; then
      if [[ $load_state != not-found ]]; then
        systemctl --user stop "$unit" || return
      fi
      echo 'Server stopped.'
      return 0
    fi
    case $active_state in
      active|activating|reloading)
        echo 'Already running. Use status or logs to inspect it; stop before starting again.'
        return 0
        ;;
      deactivating)
        echo 'Server is stopping. Wait for shutdown before starting again.' >&2
        return 1
        ;;
    esac
    if [[ $load_state != not-found ]]; then
      cat >&2 <<EOF
$unit is still loaded although the server is not running.
The previous launcher may still be suspended. In its original shell, run
\`jobs -l\`, then \`fg %N\` for that launcher. Let it exit, or press Ctrl-C.
If no launcher remains, inspect \`systemctl --user status $unit\`.
EOF
      return 1
    fi
  fi
  # An internal mode flag survives the lazy nix run boundary. The dispatcher
  # always resets it, so an inherited value cannot change the default mode.
  export STRATA_SERVICE_MODE=$action
  unset STRATA_SERVICE_ROOT
  exec nix run "$target" -- "$@"
}

# Qwen3.6 retains direct foreground execution without a systemd policy.
strata_service_or_exec() {
  if [[ ${STRATA_SERVICE_MODE:-foreground} == start ]]; then
    strata_service_run "$@"
  else
    shift # unit name
    exec "$@"
  fi
}

# Called only by the resolved server launcher, after loading trusted config.
# The caller supplies policy properties separately from the server command.
strata_service_run() {
  local unit=$1
  shift
  local -a options=(--user --collect --unit="$unit" --working-directory="$PWD")
  if [[ ${STRATA_SERVICE_MODE:-foreground} == start ]]; then
    # A detached nix run exits before the server does. Keep the complete AIO/MM
    # launcher closure rooted until systemd removes this runtime directory.
    local nix_store root_path="${XDG_RUNTIME_DIR:-/run/user/$UID}/$unit/closure"
    nix_store=$(command -v nix-store) || return
    options+=(--service-type=exec -p StandardInput=null
      -p StandardOutput=journal -p StandardError=journal
      -p "RuntimeDirectory=$unit"
      -p "ExecStartPre=$nix_store --add-root \"$root_path\" --indirect --realise ${STRATA_SERVICE_ROOT:?Missing service closure}")
    systemd-run "${options[@]}" "$@" || return
    echo 'Server started. Model loading may take several minutes; API readiness is not yet confirmed.'
    echo "Logs: journalctl --user -u $unit -f"
    echo "Stop: systemctl --user stop $unit"
  else
    # Select a PTY in a terminal, pipes for redirected/noninteractive runs.
    exec systemd-run "${options[@]}" --wait --pty --pipe --quiet "$@"
  fi
}
