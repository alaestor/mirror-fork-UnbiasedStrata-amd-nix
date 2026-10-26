#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1090
source "$1"
work=$(mktemp -d)
trap 'rm -r "$work"' EXIT
root=$work/cgroup
mkdir -p "$root/user/app/service"
echo memory > "$root/cgroup.controllers"
echo '0::/user/app/service' > "$work/membership"
check() { strata_check_memory_controller "$work/membership" "$root"; }
reject() {
  if check >"$work/out" 2>&1; then
    echo "Unexpected preflight success: $*" >&2
    exit 1
  fi
}
# A pids-only tree must fail before starting the engine.
reject 'missing controller'
grep -q 'missing or unreadable memory controller' "$work/out"
for group in user user/app user/app/service; do
  echo max > "$root/$group/memory.max"
  echo 0 > "$root/$group/memory.current"
done
# Unlimited ancestors and the special v2 root are valid.
check
echo 66571993088 > "$root/user/app/service/memory.max"
reject 'finite limit without memory.stat'
printf 'inactive_file 0\nfile_dirty 0\nfile_writeback 0\n' > "$root/user/app/service/memory.stat"
check
echo invalid > "$root/user/app/service/memory.current"
reject 'invalid current usage'
echo 0 > "$root/user/app/service/memory.current"
echo invalid > "$root/user/app/service/memory.max"
reject 'invalid memory limit'
echo 66571993088 > "$root/user/app/service/memory.max"
# Parent failures matter even when service files are present.
rm "$root/user/memory.current"
reject 'missing ancestor file'
echo 0 > "$root/user/memory.current"
printf 'inactive_file 0\nfile_dirty 0\n' > "$root/user/app/service/memory.stat"
reject 'missing required counter'
echo '1:memory:/user' > "$work/membership"
reject 'v1-only hierarchy'
echo '0::/' > "$work/membership"
check
echo 'PASS: memory preflight checks service, ancestors, counters, and v2 root'
