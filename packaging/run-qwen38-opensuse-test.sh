#!/usr/bin/env bash
# Exercise the public CLI without a GPU, model, or real user manager.
set -euo pipefail
launcher=$(realpath "$(dirname "$0")/run-qwen38-opensuse.sh")
work=$(mktemp -d)
trap 'rm -r "$work"' EXIT
mkdir -p "$work/bin" "$work/repo/packs with spaces/pack" "$work/repo/packs with spaces/mtp" "$work/elsewhere"
export CALL_LOG="$work/calls"
export UNIT_LOAD=not-found UNIT_STATE=inactive QUERY_EXIT=0 RUN_EXIT=0 STOP_EXIT=0 MANAGER_EXIT=0
cat > "$work/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' systemctl "$@" >> "$CALL_LOG"
case "$*" in
  *show-environment*) exit "$MANAGER_EXIT" ;;
  *'show strata-qwen38.service'*)
    printf 'LoadState=%s\nActiveState=%s\n' "$UNIT_LOAD" "$UNIT_STATE"
    exit "$QUERY_EXIT"
    ;;
  *'stop strata-qwen38.service'*) exit "$STOP_EXIT" ;;
  *'status strata-qwen38.service'*) echo 'mock status and recent logs'; exit 3 ;;
  *) echo "Unexpected systemctl call: $*" >&2; exit 98 ;;
esac
MOCK
cat > "$work/bin/systemd-run" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' systemd-run "$@" >> "$CALL_LOG"
exit "$RUN_EXIT"
MOCK
cat > "$work/bin/journalctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' journalctl "$@" >> "$CALL_LOG"
MOCK
chmod +x "$work/bin/systemctl" "$work/bin/systemd-run" "$work/bin/journalctl"
export PATH="$work/bin:$PATH"
touch "$work/repo/flake.nix" "$work/repo/model shard.gguf"
cat > "$work/repo/.env" <<'ENV'
MODEL='model shard.gguf'
PREPARED_DIR='packs with spaces'
PORT=8123
MEMORY_MAX=42G
STRATA_TEMPERATURE=0
STRATA_TOP_P=0.8
STRATA_TOP_K=20
STRATA_MIN_P=0
STRATA_PRESENCE_PENALTY=0
STRATA_REPEAT_PENALTY=1
ENV
cd "$work/repo"
run() {
  local expected=$1 actual=0
  shift
  : > "$CALL_LOG"
  bash "$launcher" "$@" > "$work/out" 2>&1 || actual=$?
  if [[ $actual != "$expected" ]]; then
    cat "$work/out" >&2
    echo "Expected exit $expected, got $actual for: $*" >&2
    exit 1
  fi
}
has_arg() { grep -Fxq -- "$1" "$CALL_LOG"; }
no_arg() { ! has_arg "$1"; }
output_has() { grep -Fq -- "$1" "$work/out"; }

# Detached start preserves resource limits and quoted paths, without a relay.
run 0 start
for arg in --user --collect --unit=strata-qwen38.service --service-type=exec \
  StandardInput=null StandardOutput=journal StandardError=journal \
  MemoryMax=42G MemorySwapMax=0 "$PWD/model shard.gguf" "$PWD/packs with spaces/pack"; do
  has_arg "$arg"
done
no_arg --pty
for flag in --temp --top-p --top-k --min-p --presence-penalty --repeat-penalty; do
  has_arg "$flag"
done
# Sampling flags belong to the frontend, before the engine separator; zeros survive.
sed -n '/--temp/,/^--$/p' "$CALL_LOG" > "$work/sampling"
printf '%s\n' --temp 0 --top-p 0.8 --top-k 20 --min-p 0 --presence-penalty 0 --repeat-penalty 1 -- > "$work/expected-sampling"
diff -u "$work/expected-sampling" "$work/sampling"
no_arg --wait
output_has 'http://127.0.0.1:8123'
output_has 'API readiness is not yet confirmed'

# No command retains terminal and wait semantics, including its exit status.
run 0
has_arg --pty
has_arg --wait
has_arg MemorySwapMax=0
no_arg StandardOutput=journal
export RUN_EXIT=17
run 17
run 17 start
if output_has 'Server started.'; then exit 1; fi
export RUN_EXIT=0

# Errors and duplicate launches must never start another instance.
run 2 invalid
no_arg systemd-run
run 2 start extra
run 0 --help
export MANAGER_EXIT=1
run 1 start
no_arg systemd-run
export MANAGER_EXIT=0 QUERY_EXIT=1 UNIT_LOAD=loaded
run 1 start
no_arg systemd-run
export QUERY_EXIT=0 UNIT_LOAD=loaded UNIT_STATE=active
run 0 start
output_has 'Already running'
no_arg systemd-run
export UNIT_STATE=activating
run 0 start
no_arg systemd-run
export UNIT_STATE=deactivating
run 1 start
output_has 'Server is stopping'
export UNIT_STATE=inactive
run 1 start
output_has 'fg %N'
no_arg systemd-run
export UNIT_STATE=failed
run 1 start
no_arg systemd-run

# Controls work outside the checkout without sourcing an untrusted/broken .env.
cd "$work/elsewhere"
echo 'exit 99' > .env
run 0 stop
has_arg stop
export STOP_EXIT=7
run 7 stop
if output_has 'Server stopped.'; then exit 1; fi
export STOP_EXIT=0 UNIT_LOAD=not-found UNIT_STATE=inactive QUERY_EXIT=1
run 0 stop
no_arg stop
run 3 status
has_arg status
output_has 'Service state is not API readiness'
run 0 logs
has_arg journalctl
has_arg --follow
has_arg --unit=strata-qwen38.service

# A missing unit may yield nonzero from systemctl show; starting still works.
cd "$work/repo"
run 0 start
has_arg systemd-run
# Empty/unset sampling settings leave model-card selection to the frontend.
cat > .env <<'ENV'
MODEL='model shard.gguf'
PREPARED_DIR='packs with spaces'
STRATA_TEMPERATURE=
ENV
run 0 start
for flag in --temp --top-p --top-k --min-p --presence-penalty --repeat-penalty; do
  no_arg "$flag"
done
rm "$work/repo/model shard.gguf"
run 1 start
output_has 'Model or prepared packs missing'
no_arg systemd-run
printf '%s\n' 'PASS: openSUSE launcher lifecycle and failure handling'
