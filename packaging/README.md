# Native openSUSE builds

Run these commands from the checkout root on openSUSE Tumbleweed. No Nix is
required. Your user needs access to `/dev/kfd` and the GPU render node.

- [Qwen3.8 Flash-Next with HIP](#qwen38-flash-next-with-hip)
- [Inkling 2 Mini with native HIP](#inkling-2-mini-with-native-hip)
- [Troubleshooting](TROUBLESHOOT.md)

Both launchers read the Git-ignored `.env` by default. Use only trusted Bash
files. Inkling also accepts `--env-file PATH` or `STRATA_ENV_FILE` to replace
`.env` for one run. Qwen3.8's native scripts read only `.env` and use their own
settings below.

## Qwen3.8 Flash-Next with HIP

The build targets the RX 9070 XT (`gfx1201`) and an AVX2 CPU. The launcher
requires a systemd user manager. Use CMake 3.24 or newer and Python 3.11 or
newer with `venv` and pip. Review the package transaction, then repeat without
`--dry-run`:

```sh
sudo zypper install --dry-run \
  git cmake ninja gcc-c++ hipcc rocm-hip-devel \
  hipblas-devel rocblas-devel hipblaslt-devel python3 python3-pip
```

Download both [pinned IQ3_XXS shards](../docs/nix-amd.md#flash-next-experiment)
into `models/` and keep their original filenames. Allow disk space for the
build, prepared packs, and raw MTP tensors. Set the shard paths in `.env`:

```sh
MODEL=models/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf
MODEL_SHARD2=models/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00002-of-00002.gguf
```

```sh
bash packaging/build-qwen38-opensuse.sh
./build-gfx1201/strata-device
bash packaging/run-qwen38-opensuse.sh
```

Allow network access for initial Qwen3.8 preparation. The builder checks out
the pinned llama.cpp revision, installs Python dependencies in `.venv/` as
needed, and verifies the pinned MTP tensors. Reruns reuse packs under
`packs/qwen38/`; keep the original GGUFs in place. Use `--build-only` to compile
without checking or preparing packs. Set a distinct `PREPARED_DIR` per model.
See the [DavidAU IQ3_S settings](TROUBLESHOOT.md#davidau-abliterated-iq3_s)
for the alternate quant.

`CONTEXT` defaults to 8192 tokens. `RAM_BUDGET_GIB` sets the engine's resident
memory budget (40 GiB); `MEMORY_MAX` caps the service (48 GiB, no swap);
`VRAM_RESERVE_MIB` sets GPU sizing headroom (4096 MiB). `HOST` and `PORT` default to
`127.0.0.1:8080`. See [sampling defaults](../docs/nix-amd.md#sampling-defaults)
for overrides.

Ctrl-C stops the foreground server. To run it as a detached user service,
use the same user for each command, without sudo:

```sh
bash packaging/run-qwen38-opensuse.sh start
bash packaging/run-qwen38-opensuse.sh status
bash packaging/run-qwen38-opensuse.sh logs
bash packaging/run-qwen38-opensuse.sh stop
```

Use `stop` then `start` to apply changed settings. Check API readiness with
`curl --fail http://127.0.0.1:8080/health`. See the
[API example](../README.md#configuration-and-api) for a chat request.

## Inkling 2 Mini with native HIP

Install the build tools. Review the package transaction, then repeat without
`--dry-run`:

```sh
sudo zypper install --dry-run git curl jq cmake ninja gcc-c++ hipcc rocm-hip-devel
```

Set `STRATA_INKLING_MODEL` to a local GGUF in `.env`. See the
[Inkling guide](../docs/inkling.md) for compatible weights, context, and drafting.

```sh
packaging/build-inkling-opensuse.sh --fetch-sources
packaging/build-inkling-opensuse.sh
packaging/run-inkling-opensuse.sh
```

Only `--fetch-sources` fetches dependencies. It checks
[Niko's source archive](inkling/source.json) against its SHA-256 pin and
initializes the pinned llama.cpp submodule if needed. The build uses those
local sources and the installed compiler and ROCm libraries. Neither build
nor launch downloads weights or drafts.

The build targets `gfx1100` and writes to `build-inkling-hip/`. Set
`STRATA_INKLING_HIP_ARCH` for a different target or `STRATA_INKLING_HIP_CXX` for
a compiler other than `hipcc`. To enforce an offline build after staging sources,
run the builder in a network namespace on a host that allows it:

```sh
unshare --user --map-current-user --net -- packaging/build-inkling-opensuse.sh
```
