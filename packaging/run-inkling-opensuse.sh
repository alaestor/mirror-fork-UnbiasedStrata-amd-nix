#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
inkling_frontend="$repo/build-inkling-hip/frontend/unbiased-strata"
inkling_engine="$repo/build-inkling-hip/engine/strata-inkling"
# shellcheck source=nix/launcher-common.sh
source "$repo/nix/launcher-common.sh"
# shellcheck source=packaging/inkling/launch.sh
source "$repo/packaging/inkling/launch.sh"
