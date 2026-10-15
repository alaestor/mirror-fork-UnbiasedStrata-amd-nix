# UnbiasedStrata on Nix + AMD

A personal fork of [robertkarl/UnbiasedStrata](https://github.com/robertkarl/UnbiasedStrata), which combines [Strata](https://github.com/Niko1221/Strata)'s inference engine with a C++ OpenAI-style API server and llama.cpp's tokenizer and chat templates. Strata places model experts across GPU memory, host RAM, and file-backed storage.

This fork packages that engine for AMD through HIP in a Nix flake, with support for gfx1100 (AMD 7900 XTX) and option model downloads via the "all-in-one" packages. The Qwen3.6 port, Flash-Next support, MTP drafting, and memory-tiering logic are inherited from UnbiasedStrata.

## What this fork adds

- A Nix flake with pinned llama.cpp sources and model checksums. Builds use at most four jobs and do not invoke the upstream Strata's imparative installer.

- A working HIP build of the combined API server, targeting `gfx1100`. CMake skips optional HIP tools and tests whose sources are absent in this fork.

- Local-weight preparation and launchers for Qwen3.6-35B-A3B Q4_K_XL MTP and Qwen3.8-Flash-Next IQ3_XXS; these use manually downloaded GGUFs outside the Nix store.

- Explicit `qwen36-aio` and `qwen38-aio` launchers using nix-hug, storing weights and prepared packs in the Nix store. Ordinary builds and checks do not fetch model weights.

- Trusted `.env` configuration, with separate paths and sizing for each model.

- A systemd Flash-Next launcher with a memory limit, service swap disabled, and configurable GPU headroom for use along side desktop applications.

- Launcher and pinned-fetch tests, plus GPU expert diagnostics that distinguish FP16 signed-zero differences from actual weight mismatches.

## Requirements and tested scope

This flake targets Linux x86-64, AVX2 CPUs, and AMD `gfx1100`. Other GPU architectures need a different `CMAKE_HIP_ARCHITECTURES` and a rebuild.

The host needs the `amdgpu` driver, as well as permission to access `/dev/kfd` and the GPU render node. Nix supplies ROCm userspace libraries. Flash-Next additionally requires a working systemd user manager to limit ram consumption. NVMe storage helps with loading and model pages that do not remain in RAM.

The AMD path is HIP/ROCm. NVIDIA builds, other GPUs, vision, and multi-GPU operation are outside this fork's tested Nix configuration. Refer to [UnbiasedStrata](https://github.com/robertkarl/UnbiasedStrata#readme) for its native build instructions and broader feature documentation.

Both models have run on an RX 7900 XTX with 24 GiB VRAM and a 64 GB host. Text-only, warm, out-of-the-box: I clocked decode at ~180tps with qwen36 and ~22tps with qwen38 (with sufficient headroom for other applications: limited to 20G vram + 48G ram).

## Setup

From this checkout:

```sh
# Preserve an existing configuration.
test -e .env || cp .env.template .env
nix build .#strata --cores 4
```

Edit `.env` to point at your downloaded model files. It is Git-ignored;
[`.env.template`](.env.template) is tracked. The launchers source this file as
Bash, so only use a config you trust. Nix fetches the pinned llama.cpp source
for the build; there is no need to run the upstream installer.

### Qwen3.6-35B-A3B

Download the pinned **Q4_K_XL file from the MTP repository** linked in the
[local-weight guide](docs/nix-amd.md#local-weights), about 22.85 GB. This single
GGUF supplies both the model and draft head. Set `STRATA_MODEL` in `.env`, then:

```sh
nix run .#prepare-qwen36
nix run .#qwen36
```

Preparation verifies the checksum and writes packs to `STRATA_PREPARED_DIR`.
Keep the GGUF and packs. Preparation is needed once, not on every start.
The default context is 32768 tokens. This launcher runs in the foreground;
stop it with Ctrl-C before switching models.

### Qwen3.8-Flash-Next

Download **both IQ3_XXS shards** linked in the
[Flash-Next guide](docs/nix-amd.md#flash-next-experiment), about 75.8 GB combined.
Keep their original filenames in the same directory. Set
`STRATA_QWEN38_MODEL` to the first shard and `STRATA_QWEN38_MTP_SOURCE` to
your local raw BF16 draft-tensor directory (see the guide), then:

```sh
nix run .#prepare-qwen38
nix run .#qwen38
```

Preparation verifies both shards and all supplied draft tensors, then builds
the packs locally. It never downloads missing inputs. Local preparation requires
an explicitly supplied manifest and 31 raw BF16 tensors; use `qwen38-aio` if you
want automatic acquisition instead. Existing prepared packs remain usable
without re-preparing.

The default context is 8192 tokens. Ctrl-C stops the server when launched in a
terminal; for redirected runs, stop it with `systemctl --user stop strata-qwen38`.
The transient `strata-qwen38` user service
limits charged RAM and cache to 48 GiB and disables its swap use. The separate
40 GiB engine RAM-tier setting is not a total memory limit. Other host processes
can still swap under pressure.

`STRATA_QWEN38_VRAM_RESERVE_MIB=4096` reduces the GPU expert cache to leave room
for later allocations and desktop apps. This is sizing headroom, not a hard
VRAM quota. Do not use `STRATA_VRAM_CAP_MIB` for desktop headroom: that engine
option allocates a blocker rather than leaving the memory free.

```sh
systemctl --user show strata-qwen38 -p MemoryCurrent -p MemoryPeak -p MemorySwapCurrent
systemctl --user stop strata-qwen38
```

### Configuration and API

The [configuration reference](docs/nix-amd.md#configuration-reference) covers
every variable, default, unit, and override rule. CLI options override generated
defaults; engine options go after a second `--`:

```sh
nix run .#qwen38 -- --ctx 16384 --port 8081 -- --vram-reserve-mib 5120
```

Both launchers default to `http://127.0.0.1:8080`:

```sh
curl --fail http://127.0.0.1:8080/health
curl --fail http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"local","messages":[{"role":"user","content":"What is 2 + 2?"}],"max_tokens":32,"reasoning_effort":"none"}'
```

For streaming, reasoning, tool calls, and other API details, see the
[upstream usage documentation](https://github.com/robertkarl/UnbiasedStrata#run).
Each server serves one loaded model; the request's `model` field does not switch it.

### Optional all-in-one downloads

```sh
nix run .#qwen36-aio
# Or:
nix run .#qwen38-aio
```

Only `-aio` launchers automatically download model artifacts. They use nix-hug
for pinned GGUFs and prepare packs in the Nix store. Qwen3.8 also fetches the
pinned MTP tensors through a fixed-output derivation and keeps the same RAM,
swap, and GPU-reserve policy as the local launcher. Both ignore configured local
model and pack paths; other runtime settings still apply.

A nix-hug adapter streams large payloads through Nix build jobs instead of
buffering them in the evaluator. Allow ample disk space for weights, packs,
and temporary copies. Ordinary builds and checks do not fetch model artifacts;
Nix still downloads build dependencies as needed.

## Validation

```sh
nix flake check --cores 4
nix run .#check-gpu
```

Flake checks cover the package build, frontend, launcher configuration, and
pinned MTP fetch behavior. GPU diagnostics require a real GPU and run outside
the Nix sandbox. Both models passed regular and streaming chat smoke tests.
Interactive use on the test host reported about 190 tokens/s for Qwen3.6 and
22 tokens/s for Flash-Next, with MTP enabled. These are observations, not
controlled benchmarks. Prompt length, routing, cache warmth, and desktop GPU
use affect performance.

## Upstream references and license

See [robertkarl/UnbiasedStrata](https://github.com/robertkarl/UnbiasedStrata)
for engine architecture, supported model constraints, native build instructions,
and API behavior. [UPSTREAM.md](UPSTREAM.md) records inherited source provenance
and prepared-artifact hashes. Historical upstream and Qwen3.6 port notes remain
in `docs/`; their NVIDIA measurements and requirements are not AMD guarantees.

The engine is the work of Niko1221 and the Strata contributors; UnbiasedStrata
provides the C++ server and model integration inherited here. Code is MIT; see
[LICENSE](LICENSE). Model weights have their own licenses.
