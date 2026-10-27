#!/usr/bin/env bash
set -euo pipefail
helper=$(realpath "$1")
work=$(mktemp -d)
trap 'rm -r "$work"' EXIT
mkdir -p "$work/bin"
export SERVICE_CALLS="$work/calls" SERVICE_LOAD=not-found SERVICE_STATE=inactive
export SERVICE_QUERY_EXIT=0 SERVICE_RUN_EXIT=0 SERVICE_STOP_EXIT=0
cat > "$work/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' systemctl "$@" >> "$SERVICE_CALLS"
case "$*" in
  *' show '*)
    printf 'LoadState=%s\nActiveState=%s\n' "$SERVICE_LOAD" "$SERVICE_STATE"
    exit "$SERVICE_QUERY_EXIT" ;;
  *' stop '*) exit "$SERVICE_STOP_EXIT" ;;
  *' status '*) exit 3 ;;
  *) exit 98 ;;
esac
MOCK
cat > "$work/bin/nix" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' nix "mode=$STRATA_SERVICE_MODE" "$@" >> "$SERVICE_CALLS"
MOCK
cat > "$work/bin/systemd-run" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' systemd-run "$@" >> "$SERVICE_CALLS"
exit "$SERVICE_RUN_EXIT"
MOCK
cat > "$work/bin/journalctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' journalctl "$@" >> "$SERVICE_CALLS"
MOCK
for mock in systemctl nix systemd-run journalctl; do
  # Generated executables must also work in a Nix sandbox without /usr/bin/env.
  sed -i "1c\\#!$(command -v bash)" "$work/bin/$mock"
done
touch "$work/bin/nix-store"
chmod +x "$work/bin/systemctl" "$work/bin/nix" "$work/bin/systemd-run" "$work/bin/journalctl" "$work/bin/nix-store"
export PATH="$work/bin:$PATH"
cd "$work"
# Controls must not read config or require a model.
echo 'exit 99' > .env
run() {
  local expected=$1 actual=0
  shift
  : > "$SERVICE_CALLS"
  bash -euo pipefail -c 'source "$1"; shift; "$@"' _ "$helper" "$@" > "$work/out" 2>&1 || actual=$?
  if [[ $actual != "$expected" ]]; then
    cat "$work/out" >&2
    echo "Expected exit $expected, got $actual for $*" >&2
    exit 1
  fi
}
has() {
  if ! grep -Fxq -- "$1" "$SERVICE_CALLS"; then
    echo "Missing argument: $1" >&2
    cat "$SERVICE_CALLS" >&2
    exit 1
  fi
}
absent() {
  if grep -Fxq -- "$1" "$SERVICE_CALLS"; then
    echo "Unexpected argument: $1" >&2
    exit 1
  fi
}
for family in qwen36 qwen38; do
  foreground_service=false
  if [[ $family == qwen38 ]]; then foreground_service=true; fi
  for variant in "$family" "$family-aio" "$family-aio-mm"; do
    dispatch=(strata_service_dispatch "strata-$family.service" "$foreground_service" "flake#legacyPackages.x86_64-linux.$variant")
    export SERVICE_LOAD=not-found SERVICE_STATE=inactive SERVICE_QUERY_EXIT=0
    run 0 "${dispatch[@]}" start '/model path.gguf' --port 8123 -- --lookup 0
    has nix
    has mode=start
    has "flake#legacyPackages.x86_64-linux.$variant"
    has '/model path.gguf'
    has --lookup
    run 0 "${dispatch[@]}" stop
    absent stop
    absent nix
    run 3 "${dispatch[@]}" status
    has status
    absent nix
    run 0 "${dispatch[@]}" logs
    has journalctl
    has --follow
    absent nix
    run 2 "${dispatch[@]}" stop extra
    absent systemctl
    export SERVICE_LOAD=loaded SERVICE_STATE=active
    run 0 "${dispatch[@]}" start
    absent nix
    export SERVICE_STATE=deactivating
    run 1 "${dispatch[@]}" start
    absent nix
    export SERVICE_STATE=inactive
    run 1 "${dispatch[@]}" start
    grep -Fq 'fg %N' "$work/out"
    absent nix
    run 0 "${dispatch[@]}" stop
    has stop
    export SERVICE_STOP_EXIT=7
    run 7 "${dispatch[@]}" stop
    export SERVICE_STOP_EXIT=0 SERVICE_LOAD=not-found SERVICE_QUERY_EXIT=1
    run 0 "${dispatch[@]}" start
    has nix
    export SERVICE_LOAD=loaded
    run 1 "${dispatch[@]}" start
    absent nix
    export SERVICE_QUERY_EXIT=0 SERVICE_LOAD=not-found
    # Inherited mode must not change a foreground invocation.
    export STRATA_SERVICE_MODE=start
    run 0 "${dispatch[@]}" '/model path.gguf'
    has mode=foreground
    if [[ $family == qwen36 ]]; then absent systemctl; else has systemctl; fi
  done
done
export STRATA_SERVICE_MODE=start STRATA_SERVICE_ROOT=/nix/store/test-launcher
run 0 strata_service_run strata-qwen38.service -p MemoryMax=48G -p MemorySwapMax=0 /bin/server 'model path.gguf'
for arg in --collect --service-type=exec StandardInput=null StandardOutput=journal StandardError=journal MemoryMax=48G MemorySwapMax=0 'model path.gguf'; do has "$arg"; done
absent --wait
absent --pty
has RuntimeDirectory=strata-qwen38.service
has "ExecStartPre=$work/bin/nix-store --add-root \"${XDG_RUNTIME_DIR:-/run/user/$UID}/strata-qwen38.service/closure\" --indirect --realise /nix/store/test-launcher"
run 0 strata_service_run strata-qwen36.service /bin/server
absent MemoryMax=48G
absent MemorySwapMax=0
run 0 strata_service_or_exec strata-qwen36.service /bin/server
has --collect
absent MemoryMax=48G
export SERVICE_RUN_EXIT=17
run 17 strata_service_run strata-qwen38.service /bin/server
if grep -Fq 'Server started.' "$work/out"; then exit 1; fi
export SERVICE_RUN_EXIT=0 STRATA_SERVICE_MODE=foreground
run 0 strata_service_run strata-qwen38.service /bin/server
for arg in --wait --pty --pipe --quiet; do has "$arg"; done
absent StandardOutput=journal
run 0 strata_service_or_exec strata-qwen36.service "$work/bin/systemd-run" direct-server
has direct-server
absent --collect
absent systemctl
printf '%s\n' 'PASS: Nix lifecycle dispatch, argument routing, and service policies'
