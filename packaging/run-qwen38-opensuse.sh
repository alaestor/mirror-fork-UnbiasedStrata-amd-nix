#!/usr/bin/env bash
# Run from the repository root. Only source a .env you trust.
set -euo pipefail
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
for value in "$CONTEXT" "$RAM_BUDGET_GIB" "$VRAM_RESERVE_MIB" "$PORT"; do
  [[ "$value" =~ ^[0-9]+$ ]] || { echo 'Sizes and port must be nonnegative integers.' >&2; exit 1; }
done
[[ -f "$MODEL" && -d "$PREPARED_DIR/pack" && -d "$PREPARED_DIR/mtp" ]] || {
  echo 'Model or prepared packs missing; run packaging/build-qwen38-opensuse.sh first.' >&2
  exit 1
}
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
exec systemd-run --user --wait --pty --collect \
  --unit=strata-qwen38 --working-directory="$PWD" \
  -p "MemoryMax=$MEMORY_MAX" -p MemorySwapMax=0 \
  bash "$PWD/nix/memory-preflight.sh" \
  "$PWD/$BUILD_DIR/unbiased-strata" --engine "$PWD/$BUILD_DIR/strata" \
  --model "$PWD/$MODEL" --host "$HOST" --port "$PORT" -- \
  --native "$PWD/$MODEL" --pack "$PWD/$PREPARED_DIR/pack" --mtp "$PWD/$PREPARED_DIR/mtp" \
  --expert-profile "$PWD/$PREPARED_DIR/pack/expert-profile.bin" \
  --max-context "$CONTEXT" --kv q4_0 --resident-budget-gib "$RAM_BUDGET_GIB" \
  --expert-cache auto --prefill auto --spec 4 --resident-experts \
  --ple-io mmap --vram-reserve-mib "$VRAM_RESERVE_MIB"
