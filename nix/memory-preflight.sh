#!/usr/bin/env bash
# Run inside the service, before loading weights. Arguments to the function are
# fixture paths for tests; launchers always use the real kernel interfaces.
strata_check_memory_controller() {
  local membership=${1:-/proc/self/cgroup} root=${2:-/sys/fs/cgroup}
  local hierarchy controllers group path='' limit current key value rest
  while IFS=: read -r hierarchy controllers group; do
    if [[ $hierarchy == 0 && -z $controllers ]]; then
      path=$root${group%/}
      break
    fi
  done < "$membership"
  if [[ -z $path ]]; then
    echo 'Strata requires cgroup v2 memory control for safe resident RAM and service limits.' >&2
    return 1
  fi
  while :; do
    if [[ $path == "$root" && ! -e $path/memory.max && -r $path/cgroup.controllers ]]; then
      break # The cgroup v2 root has no memory.max/current.
    fi
    if [[ ! -r $path/memory.max || ! -r $path/memory.current ]] ||
       ! read -r limit < "$path/memory.max" ||
       ! read -r current < "$path/memory.current" ||
       [[ ! $current =~ ^[0-9]+$ || ( $limit != max && ! $limit =~ ^[0-9]+$ ) ]]; then
      echo "Strata: missing or unreadable memory controller files in $path." >&2
      echo 'Enable memory accounting on the parent user slices and app.slice; refresh the user manager with systemctl --user daemon-reexec. See packaging/README.md (Memory controller setup).' >&2
      return 1
    fi
    if [[ $limit != max ]]; then
      local inactive='' dirty='' writeback=''
      if [[ -r $path/memory.stat ]]; then
        while read -r key value rest; do
          case $key in
            inactive_file) inactive=$value ;;
            file_dirty) dirty=$value ;;
            file_writeback) writeback=$value ;;
          esac
        done < "$path/memory.stat"
      fi
      if [[ ! $inactive =~ ^[0-9]+$ || ! $dirty =~ ^[0-9]+$ || ! $writeback =~ ^[0-9]+$ ]]; then
        echo "Strata: missing memory.stat counters in $path; resident RAM detection would fail." >&2
        return 1
      fi
    fi
    [[ $path == "$root" ]] && break
    path=${path%/*}
    # /proc/self/cgroup supplies an absolute path within this mount.
    [[ $path == "$root" || $path == "$root/"* ]] || return 1
  done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  set -euo pipefail
  strata_check_memory_controller
  exec "$@"
fi
