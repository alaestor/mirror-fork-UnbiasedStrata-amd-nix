# Native openSUSE build and preparation

[build-qwen38-opensuse.sh](build-qwen38-opensuse.sh) builds the HIP engines and
API server for `gfx1201`, then prepares Qwen3.8-Flash-Next IQ3_XXS and its MTP
draft head. It does not require Nix, install system packages, or start the server.
This native workflow has not yet been validated end to end on openSUSE.

## Requirements

The intended host is openSUSE Tumbleweed with an AVX2 CPU and an RX 9070 XT.
The AMD kernel driver must expose `/dev/kfd` and a GPU render node to your user.
Python 3.11 or newer is required for preparation.

Install the build dependencies, reviewing the proposed transaction first:

```sh
sudo zypper refresh
sudo zypper install --dry-run \
  git cmake ninja gcc-c++ hipcc rocm-hip-devel \
  hipblas-devel rocblas-devel hipblaslt-devel python3 python3-pip
```

Repeat the install without `--dry-run` if the transaction is acceptable. The
script also needs `flock` and `sha256sum`, normally supplied by util-linux and
coreutils. Python must support `python3 -m venv` and pip inside that environment.

Network access is required for llama.cpp, Python dependencies, and the pinned
MTP tensors. Preparation uses CPU and disk, not the GPU. Allow substantial free
space beyond the roughly 75.8 GB model download for raw MTP tensors,
intermediate files, prepared packs, and compilation.

## Build and prepare

Clone this fork and enter its root directory:

```sh
git clone https://git.0x04.cc/alaestor/fork-UnbiasedStrata-amd-nix.git
cd fork-UnbiasedStrata-amd-nix
```

Download both pinned IQ3_XXS model shards described in the
[Flash-Next guide](../docs/nix-amd.md#flash-next-experiment). Put them in the
repository root with these names:

```text
Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf
Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00002-of-00002.gguf
```

Alternatively, edit `MODEL` and `MODEL_SHARD2` at the top of the script to point
into `models/`, which Git already ignores. Root-level GGUFs are not ignored;
do not stage them. Preserve the original shard basenames and keep both files
in one directory.

Run from the repository root:

```sh
bash packaging/build-qwen38-opensuse.sh
```

All configured paths are relative to the working directory, not the script's
directory. Other settings at the top control build and output directories,
the virtual environment, and parallel build jobs. The script verifies both
model hashes before compiling or downloading.

### Configure with .env

The script sources `.env` from the repository root after setting its defaults.
Only use a file you trust: it executes as Bash. Existing serving variables such
as `STRATA_QWEN38_MODEL` do not configure this build script; use `MODEL` and the
other names defined at its top. Keep configured paths relative to the repository
root. `.env` is already Git-ignored.

For the experimental DavidAU abliterated IQ3_S variant, put these settings in
`.env`, keeping both shards in `models/`:

```sh
MODEL=models/Qwen3.8-Flash-Next-GSQ-RCO-abliterated-IQ3_S-00001-of-00002.gguf
MODEL_SHARD2=models/Qwen3.8-Flash-Next-GSQ-RCO-abliterated-IQ3_S-00002-of-00002.gguf
MODEL_SHA256=78706315c2fe912777c006b4ae18be1024c9f4353bd25d33b8a306c9c55f9e34
MODEL_SHARD2_SHA256=316b46f3a2dbd68c900f43136ab9449f9dcc3725dfd8c794847c204bc161e113
PREPARED_DIR=packs/qwen38-abliterated-iq3-s
COMPAT_BF16=1
CONTEXT=8192
RAM_BUDGET_GIB=40
MEMORY_MAX=48G
VRAM_RESERVE_MIB=4096
```

These hashes come from the Hugging Face file metadata at
[revision b1b82c3](https://huggingface.co/DavidAU/Qwen3.8-Flash-Next-Abliterated-Uncensored-Turbo-Brilliance-50x-Reasoning-Instruct-GSQ-RCO-GGUF/tree/b1b82c36770c826c41e1874f250228048cdb3f5c).
They establish file identity, not engine support. `COMPAT_BF16=1` enables the
packer's existing conversion path for quantized dense tensors, including PLE
keys it cannot retain natively. Conversion changes rounding. Preparation,
inference quality, and compatibility with the original model's MTP head remain
unvalidated for this variant. The script still fetches the original pinned MTP
tensors, not a variant-specific draft head. The larger variant also needs more
storage than the default IQ3_XXS model.

Launch with `bash packaging/run-qwen38-opensuse.sh` from the repository root to
read these paths and sizing settings from `.env`. `CONTEXT` is in tokens,
`RAM_BUDGET_GIB` is the engine's resident-memory budget in GiB, `MEMORY_MAX` is
the systemd service limit, and `VRAM_RESERVE_MIB` is GPU sizing headroom in MiB.
The launcher also accepts `HOST` and `PORT` in `.env`, defaulting to
`127.0.0.1:8080`. These sizes are inherited defaults, not validated settings for
the 16 GiB card or this variant. Reducing context may help with GPU memory
pressure. Changing sizing settings does not require preparing the packs again.

The explicit launch command below is an alternative that does not read `.env`.

The script pins llama.cpp to the revision used by the flake and refuses local
changes in that submodule. It installs Python dependencies in `.venv/` without
changing system Python. CMake must discover ROCm's `clang++` as its HIP compiler,
not the `hipcc` wrapper. If discovery fails, inspect the configure error before
changing compiler paths.

The GGUFs do not contain the MTP head. The script downloads only the required
tensor ranges from a pinned BF16 checkpoint, verifies them against the tracked
manifest, quantizes the draft experts to Q2_0, and creates runtime packs.

Default outputs are:

| Path | Contents |
| --- | --- |
| `build-gfx1201/` | API server, engines, and GPU diagnostics |
| `packs/qwen38/pack/` | Model pack and expert profile |
| `packs/qwen38/mtp/` | MTP runtime pack, draft vocabulary, and intermediate GGUF |
| `mtp/qwen38-source/` | Downloaded raw MTP tensors |
| `.venv/` | Preparation dependencies |

Keep the original GGUF shards in place. The prepared model pack still uses them.

## Reruns and failures

Rerunning the same command verifies the model hashes, performs an incremental
build, checks Python dependencies, and verifies downloaded MTP tensors. Valid
MTP inputs do not need another download. Completed preparation stages are
skipped using completion markers tied to the tools, pinned source, and model
location. The markers do not verify every prepared output's contents.

If the source or model location changes, the script refuses stale packs rather
than overwriting them. Set `PREPARED_DIR` to a fresh directory and rerun. Use a
fresh directory for damaged packs too.

Failed preparation stages leave hidden temporary directories beneath
`PREPARED_DIR` for inspection. Reruns create a new temporary directory; they do
not automatically delete the previous one. Only one instance using the same
build directory may run at a time. Do not run instances sharing preparation
paths with different build directories.

## Check the GPU and launch

From the repository root, first run:

```sh
./build-gfx1201/strata-device
for pair in q4_K/q5_1 q5_K/q5_1 q6_K/q5_1; do
  ./build-gfx1201/native_expert_parity --synthetic "$pair" || break
done
```

Resolve any diagnostic failure before launching. With the default paths:

```sh
systemd-run --user --wait --pty --collect \
  --unit=strata-qwen38 --working-directory="$PWD" \
  -p MemoryMax=48G -p MemorySwapMax=0 \
  "$PWD/build-gfx1201/unbiased-strata" \
  --engine "$PWD/build-gfx1201/strata" \
  --model "$PWD/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf" \
  --host 127.0.0.1 --port 8080 -- \
  --native "$PWD/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf" \
  --pack "$PWD/packs/qwen38/pack" --mtp "$PWD/packs/qwen38/mtp" \
  --expert-profile "$PWD/packs/qwen38/pack/expert-profile.bin" \
  --max-context 8192 --kv q4_0 --resident-budget-gib 40 \
  --expert-cache auto --prefill auto --spec 4 --resident-experts \
  --ple-io mmap --vram-reserve-mib 4096
```

Update paths if you changed the script's settings. This command does not load
`.env`. It requires a working systemd user manager. The 48 GiB service limit
includes charged cache and disables service swap; the 40 GiB engine budget is
not a total process memory limit. GPU reserve is sizing headroom, not a hard
VRAM quota. These defaults come from the Nix launcher tested on a 24 GiB card;
they have not been validated on the RX 9070 XT's 16 GiB VRAM.

Check readiness from another terminal:

```sh
curl --fail http://127.0.0.1:8080/health
```

Stop with Ctrl-C or `systemctl --user stop strata-qwen38`. See the
[main README](../README.md#configuration-and-api) for an API request example.
