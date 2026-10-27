#!/usr/bin/env bash
# Run starts from the repository root. Only source a .env you trust.
set -euo pipefail
usage() {
  echo 'Usage: bash packaging/run-qwen38-opensuse.sh [start|stop|status|logs]'
  echo 'No command: foreground. start: detached. logs: follow journal; Ctrl-C leaves server running.'
}
command=${1:-foreground}
if (( $# > 1 )); then
  usage >&2
  exit 2
fi
case "$command" in
  -h|--help) usage; exit 0 ;;
  foreground|start|stop|status|logs) ;;
  *) usage >&2; exit 2 ;;
esac
unit=strata-qwen38.service
# SSH shells may not inherit the user manager's environment. Only discover an
# existing runtime directory/bus; creating them requires host administration.
if [[ -z ${XDG_RUNTIME_DIR:-} && -d /run/user/$UID && -O /run/user/$UID ]]; then
  export XDG_RUNTIME_DIR="/run/user/$UID"
fi
if [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} && -n ${XDG_RUNTIME_DIR:-} && -S $XDG_RUNTIME_DIR/bus ]]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi
if ! systemctl --user show-environment >/dev/null; then
  cat >&2 <<'EOF'
Cannot connect to the systemd user manager. A desktop is not required.
Use a direct SSH login as the intended user, not a switched-user shell.
If that still fails, ask an administrator to inspect the SSH/PAM session
and user-manager status. Lingering is not required for a normal SSH session.
See packaging/README.md under "Headless and SSH sessions".
Refusing to launch without the systemd memory and swap limits.
EOF
  exit 1
fi
# Control commands do not depend on the checkout, model files, or .env.
case "$command" in
  logs) exec journalctl --user --unit="$unit" --follow ;;
  status)
    echo 'Service state is not API readiness. Query the configured /health endpoint to check readiness.'
    exec systemctl --user --no-pager --full status "$unit"
    ;;
esac
# Missing transient units are normal after collection. Other query errors must
# not be mistaken for an absent service.
if ! unit_info=$(systemctl --user show "$unit" -p LoadState -p ActiveState); then
  if [[ $unit_info != *'LoadState=not-found'* ]]; then
    exit 1
  fi
fi
load_state=
active_state=
while IFS='=' read -r key value; do
  case "$key" in
    LoadState) load_state=$value ;;
    ActiveState) active_state=$value ;;
  esac
done <<< "$unit_info"
if [[ -z $load_state || -z $active_state ]]; then
  echo 'Cannot determine service state.' >&2
  exit 1
fi
if [[ $command == stop ]]; then
  if [[ $load_state != not-found ]]; then
    systemctl --user stop "$unit"
  fi
  echo 'Server stopped.'
  exit 0
fi
case "$active_state" in
  active|activating|reloading)
    echo 'Already running. Use status or logs to inspect it; stop before starting again.'
    exit 0
    ;;
  deactivating)
    echo 'Server is stopping. Wait for shutdown before starting again.' >&2
    exit 1
    ;;
esac
if [[ $load_state != not-found ]]; then
  cat >&2 <<'EOF'
The unit is still loaded although the server is not running.
The previous launcher may still be suspended. In its original shell, run
`jobs -l`, then `fg %N` for that launcher. Let it exit, or press Ctrl-C.
If no launcher remains, inspect `systemctl --user status strata-qwen38.service`.
EOF
  exit 1
fi
MODEL=Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf
BUILD_DIR=build-gfx1201
PREPARED_DIR=packs/qwen38
CONTEXT=8192
RAM_BUDGET_GIB=40
MEMORY_MAX=48G
VRAM_RESERVE_MIB=4096
HOST=127.0.0.1
PORT=8080
[[ -f flake.nix ]] || { echo 'Run from the repository root.' >&2; exit 1; }
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi
# shellcheck source=nix/launcher-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../nix/launcher-common.sh"
strata_configure_sampling
for value in "$CONTEXT" "$RAM_BUDGET_GIB" "$VRAM_RESERVE_MIB" "$PORT"; do
  [[ "$value" =~ ^[0-9]+$ ]] || { echo 'Sizes and port must be nonnegative integers.' >&2; exit 1; }
done
[[ -f "$MODEL" && -d "$PREPARED_DIR/pack" && -d "$PREPARED_DIR/mtp" ]] || {
  echo 'Model or prepared packs missing; run packaging/build-qwen38-opensuse.sh first.' >&2
  exit 1
}
run_args=(--user --collect --unit="$unit" --working-directory="$PWD"
  -p "MemoryMax=$MEMORY_MAX" -p MemorySwapMax=0)
if [[ $command == start ]]; then
  # No terminal relay or waiting client: systemd owns the detached process.
  run_args+=(--service-type=exec -p StandardInput=null
    -p StandardOutput=journal -p StandardError=journal)
else
  run_args+=(--wait --pty)
fi
server_args=(bash "$PWD/nix/memory-preflight.sh"
  "$PWD/$BUILD_DIR/unbiased-strata" --engine "$PWD/$BUILD_DIR/strata"
  --model "$PWD/$MODEL" --host "$HOST" --port "$PORT" "${strata_sampling_args[@]}" --
  --native "$PWD/$MODEL" --pack "$PWD/$PREPARED_DIR/pack" --mtp "$PWD/$PREPARED_DIR/mtp"
  --expert-profile "$PWD/$PREPARED_DIR/pack/expert-profile.bin"
  --max-context "$CONTEXT" --kv q4_0 --resident-budget-gib "$RAM_BUDGET_GIB"
  --expert-cache auto --prefill auto --spec 4 --resident-experts
  --ple-io mmap --vram-reserve-mib "$VRAM_RESERVE_MIB")
if [[ $command == foreground ]]; then
  exec systemd-run "${run_args[@]}" "${server_args[@]}"
fi
systemd-run "${run_args[@]}" "${server_args[@]}"
cat <<EOF
Server started. Model loading may take several minutes; API readiness is not yet confirmed.
URL: http://$HOST:$PORT
Logs: bash packaging/run-qwen38-opensuse.sh logs
Stop: bash packaging/run-qwen38-opensuse.sh stop
EOF
