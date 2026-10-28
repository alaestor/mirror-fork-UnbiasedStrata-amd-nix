---
include_toc: true
---

# UnbiasedStrata on Nix + AMD

A personal fork of [robertkarl/UnbiasedStrata](https://github.com/robertkarl/UnbiasedStrata), which combines [Strata](https://github.com/Niko1221/Strata)'s inference engine with a C++ OpenAI-style API server and llama.cpp's tokenizer and chat templates. Strata places model experts across GPU memory, host RAM, and file-backed storage.

This fork packages that engine for AMD through HIP in a Nix flake, with support for gfx1100 (AMD 7900 XTX) and option model downloads via the "all-in-one" packages. The model implementations and memory-tiering logic are inherited from UnbiasedStrata.

## Requirements and tested scope

This flake targets Linux x86-64, AVX2 CPUs, and AMD `gfx1100`. Other GPU architectures need a different `CMAKE_HIP_ARCHITECTURES` and a rebuild.

The host needs the `amdgpu` driver, as well as permission to access `/dev/kfd` and the GPU render node. Nix supplies ROCm userspace libraries. Flash-Next additionally requires a working systemd user manager to limit ram consumption. NVMe storage helps with loading and model pages that do not remain in RAM.

The AMD path is HIP/ROCm. Both models support image input with their matching CPU vision projectors; see [image setup](docs/nix-amd.md#qwen36-image-configuration) and [request format](docs/nix-amd.md#qwen38-image-input). Audio is unsupported. NVIDIA builds, other GPUs, and multi-GPU operation are outside this fork's tested Nix configuration. Refer to [UnbiasedStrata](https://github.com/robertkarl/UnbiasedStrata#readme) for its native build instructions and broader feature documentation.

Both models have run on an RX 7900 XTX with 24 GiB VRAM and a 64 GB host.
After the upstream 2 update, local tests reported approximately **128 tps
for Qwen3.6** and **47 tps for Flash-Next**. These are informal observations,
not controlled benchmarks: results will vary with host and platform.

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
nix run .#qwen36
```

No preparation is needed: the engine reads the GGUF directly.
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
For detached serving, use `nix run .#qwen38 -- start` instead of appending `&`.
The same app accepts `stop`, `status`, and `logs`; these commands also work with
`qwen36` and both families' AIO variants. See [detached serving](docs/nix-amd.md#detached-serving)
for lifecycle behavior, readiness checks, and Qwen3.6 differences.
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

Qwen3.8 now uses [model-card sampling defaults](docs/nix-amd.md#sampling-defaults),
which may be slower than the previous llama.cpp defaults. To restore the old
values, put these overrides in `.env` and restart the server:

```sh
STRATA_TEMPERATURE=0.8
STRATA_TOP_P=0.95
STRATA_TOP_K=40
STRATA_MIN_P=0.05
STRATA_PRESENCE_PENALTY=0
STRATA_REPEAT_PENALTY=1
```

Per-request sampling settings still take precedence.

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
# Include the matching BF16 vision projector:
nix run .#qwen36-aio-mm
nix run .#qwen38-aio-mm
```

Only `-aio` and `-aio-mm` launchers automatically download model artifacts.
They use nix-hug for pinned GGUFs. Qwen3.8 prepares packs in the Nix store and fetches the
pinned MTP tensors through a fixed-output derivation and keeps the same RAM,
swap, and GPU-reserve policy as the local launcher. Both ignore configured local
model and pack paths; other runtime settings still apply.

The `-aio-mm` variants enable image input with the matching BF16 projector,
about 0.9 GB extra, reusing the ordinary AIO weights and packs. No projector
configuration is needed; `--mmproj PATH` overrides the bundled default.
See [image request format](docs/nix-amd.md#qwen38-image-input).

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
the Nix sandbox. Before the upstream 2 migration, both models passed regular and streaming chat smoke tests.
Both models have also been tested locally since the update, with the throughput
reported above. Prompt length, routing, cache warmth, and desktop GPU use affect
performance. Vision has not been revalidated since the update.

# Upstream

## References and license

See [robertkarl/UnbiasedStrata](https://github.com/robertkarl/UnbiasedStrata)
for engine architecture, supported model constraints, native build instructions,
and API behavior. [UPSTREAM.md](UPSTREAM.md) records inherited source provenance
and prepared-artifact hashes. Historical upstream and Qwen3.6 port notes remain
in `docs/`; their NVIDIA measurements and requirements are not AMD guarantees.

The engine is the work of Niko1221 and the Strata contributors; UnbiasedStrata
provides the C++ server and model integration inherited here. Code is MIT; see
[LICENSE](LICENSE). Model weights have their own licenses.

## What this fork adds

- A Nix flake with pinned llama.cpp sources and model downloads. Builds use at most four jobs and do not invoke the upstream Strata's imparative installer.

- A HIP build of the API server and separate engines, targeting `gfx1100`. CMake skips optional HIP tools and tests whose sources are absent in this fork.

- Local-weight launchers for Qwen3.6-35B-A3B Q4_K_XL and Qwen3.8-Flash-Next IQ3_XXS; these use manually downloaded GGUFs outside the Nix store. Flash-Next preparation verifies its inputs.

- Explicit `qwen36-aio` and `qwen38-aio` launchers using nix-hug, storing weights and Flash-Next's prepared packs in the Nix store. Ordinary builds and checks do not fetch model weights.

- Trusted `.env` configuration, with separate paths and sizing for each model.

- A systemd Flash-Next launcher with a memory limit, service swap disabled, and configurable GPU headroom for use along side desktop applications.

- Launcher and pinned-fetch tests, plus GPU expert diagnostics that distinguish FP16 signed-zero differences from actual weight mismatches.

## Usage of python

UnbiasedStrata's "No Python, no installer" promise still holds for building and running the standalone engine. The `strata`, `qwen36`, and `qwen38` packages do not require Python or invoke model preparation. The serving launchers expect existing GGUFs; Flash-Next also needs prepared packs.

This fork also exposes the inherited Python model-packing tools through the explicit `prepare-qwen38` command and the optional `-aio` flows. Flash-Next preparation requires Python and its packing dependencies; Nix supplies them without a manual Python installation. Python is used for preparation, not inference.

The default development shell and preparation/fetch checks also include Python. Those development dependencies do not become standalone runtime dependencies.


## Edits to upstream files

- [CMakeLists.txt](CMakeLists.txt): guard absent optional HIP sources, link strata-poly's HIP MMQ target to hipBLAS, and build sampling tests.
- [Makefile](Makefile): run sampling policy and HTTP regression tests.
- [Frontend entry point](frontend/main.cpp): preserve explicit presence-penalty overrides.
- [Frontend context](frontend/strata_context.cpp) and [interface](frontend/strata_context.hpp): select model-card sampling defaults with server and request overrides.
- [Fake engine](frontend/tests/fake-engine.py): capture engine requests for sampling regression tests.
- [GPU parity diagnostic](src/kernels/native_expert_parity.cpp): report FP16 signed-zero differences separately from weight mismatches.
- [.gitignore](.gitignore): ignore local `.env` and Nix result links.
- [README.md](README.md): document this fork's AMD/Nix workflows, serving lifecycle, sampling overrides, and tested scope.



