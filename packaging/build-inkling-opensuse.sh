#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: ${0##*/} [--fetch-sources]"
  echo "Fetch the pinned sources explicitly, or build offline from existing inputs."
}

fetch=0
case ${1:-} in
  --fetch-sources) fetch=1; shift ;;
  --help|-h) usage; exit 0 ;;
esac
if (( $# )); then usage >&2; exit 2; fi

die() { echo "$*" >&2; exit 1; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$repo"
build="$repo/build-inkling-hip"
mkdir -p -- "$build"
exec 9>"$build/build.lock"
flock -n 9 || die "Another Inkling build is running."
pin=packaging/inkling/source.json
hash=$(jq -er '.sha256' "$pin")
[[ "$hash" =~ ^[0-9a-f]{64}$ ]] || die "Invalid SHA-256 in $pin."
archive="$build/strata-$hash.tar.gz"
src="$build/source-$hash"
llama=third_party/llama.cpp
llama_rev=$(git rev-parse "HEAD:$llama")

if (( fetch )); then
  if [[ ! -e "$archive" ]]; then
    temp=$(mktemp "$build/download.XXXXXXXX")
    trap 'rm -f -- "$temp"' EXIT
    url=$(jq -er '.url' "$pin")
    curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
      --output "$temp" "$url"
    printf '%s  %s\n' "$hash" "$temp" | sha256sum --check
    mv -T -- "$temp" "$archive"
    trap - EXIT
  fi
  if [[ ! -e "$llama/.git" ]]; then
    git submodule update --init -- "$llama"
  fi
fi

[[ -f "$archive" ]] || die "Missing $archive. Run ${0##*/} --fetch-sources."
printf '%s  %s\n' "$hash" "$archive" | sha256sum --check
[[ -e "$llama/.git" && $(git -C "$llama" rev-parse HEAD) == "$llama_rev" ]] ||
  die "Initialize or update $llama to the revision recorded by this checkout."
[[ -z $(git -C "$llama" status --porcelain) ]] || die "$llama has local changes."
if (( fetch )); then exit 0; fi

if [[ ! -d "$src" ]]; then
  temp=$(mktemp -d "$build/source.XXXXXXXX")
  tar --extract --gzip --file "$archive" --directory "$temp" --strip-components=1
  mv -T -- "$temp" "$src"
fi

jobs=${STRATA_INKLING_JOBS:-4}
arch=${STRATA_INKLING_HIP_ARCH:-gfx1100}
hip_cxx=${STRATA_INKLING_HIP_CXX:-hipcc}
hip_cxx=$(command -v "$hip_cxx") || die "Install hipcc or set STRATA_INKLING_HIP_CXX."
[[ "$arch" =~ ^gfx[0-9a-f]+$ ]] || die "STRATA_INKLING_HIP_ARCH must be one gfx architecture."
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die "STRATA_INKLING_JOBS must be a positive integer."

cmake -S "$src/engine/src/inkling2" -B "$build/engine" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DSTRATA_ENABLE_HIP=ON \
  -DSTRATA_HIP_ARCHS="$arch" -DSTRATA_HIP_CXX="$hip_cxx"
cmake --build "$build/engine" --target strata-inkling --parallel "$jobs"
"$build/engine/strata-inkling" --version

cmake -S "$repo" -B "$build/frontend" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DSTRATA_ENABLE_HIP=OFF -DSTRATA_ENABLE_CUDA=OFF -DSTRATA_BUILD_IK2=OFF \
  -DSTRATA_BUILD_TESTS=OFF -DSTRATA_PORTABLE=ON -DBUILD_SHARED_LIBS=OFF
cmake --build "$build/frontend" --target unbiased-strata --parallel "$jobs"
