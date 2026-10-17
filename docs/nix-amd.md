# Nix on AMD

This flake builds the C++ server with the retained HIP backend for `gfx1100`,
including the RX 7900 XTX. It does not run upstream's installer. Strata has no
Vulkan backend. Enabling llama.cpp's Vulkan backend would not port Strata's own
GPU kernels.

## Local weights

Download the pinned [Q4_K_XL file from the MTP repository](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/resolve/5bc3e238d916f48a861bac2f8a1990a0e9b7e98d/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf),
22.85 GB. That one file supplies both the main model and the draft head.

Copy `.env.template` to `.env` and set `STRATA_MODEL` and
`STRATA_PREPARED_DIR`. Build the server, prepare the packs once, then serve:

```sh
nix build .#strata --cores 4
nix run .#prepare-qwen36
nix run .#qwen36
```

Preparation verifies the GGUF's SHA-256 and runs this repository's pack tools.
It writes `pack/` and `mtp/` into the output directory without copying the weights
into the Nix store. Keep both the GGUF and the prepared directory for later runs.
Local preparation and serving never download model artifacts. All model inputs
must be provided explicitly; Nix still fetches pinned build dependencies.

Launchers read `.env` in the current directory. Use `STRATA_ENV_FILE=/path/to/file`
to select another file. It is trusted shell configuration, not an untrusted data
file. `.env` is Git-ignored; `.env.template` is explicitly included.
The template lists context, threading, address, KV type, and memory-cap settings.
`STRATA_RAM_CAP_GIB=8` bounds the expert RAM tier, not total process memory or
the filesystem page cache.
CLI flags override those settings, with engine options after `--`:

```sh
nix run .#qwen36 -- --ctx 65536 -- --kv int8
```

Both local commands also accept `MODEL.gguf PREPARED_DIR` as their first two
arguments to override the configured paths.

The example context is deliberately smaller than the model's maximum. Increase
it after checking the startup VRAM plan. The desktop also needs VRAM.
The program requires access to `/dev/kfd` and the GPU render node, with the
host's `amdgpu` driver loaded. ROCm userspace libraries come from Nix.

Test the API from another terminal:

```sh
curl --fail http://127.0.0.1:8080/health
curl --fail http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"local","messages":[{"role":"user","content":"What is 2 + 2?"}],"max_tokens":32,"reasoning_effort":"none"}'
```

## Configuration reference

The table lists launcher defaults when a value is unset or empty. Copying
`.env.template` also supplies the example model paths. The data directory is
`$XDG_DATA_HOME` when set, otherwise `$HOME/.local/share`.

| Variable | Default | Applies to | Meaning |
| --- | --- | --- | --- |
| `STRATA_ENV_FILE` | `.env` in the current directory | All launchers | Select a trusted Bash configuration file. An explicitly selected missing file is an error; a missing default `.env` is allowed. |
| `STRATA_MODEL` | Unset | Qwen3.6 local preparation and serving | Path to the pinned Q4_K_XL MTP GGUF. |
| `STRATA_PREPARED_DIR` | Data directory + `/unbiased-strata/qwen36` | Qwen3.6 local preparation and serving | Directory containing the generated `pack/` and `mtp/`. |
| `STRATA_CTX` | `32768` tokens | Qwen3.6 local and AIO serving | Requested context capacity, including prompt and response. |
| `STRATA_HOST` | `127.0.0.1` | Both models, including AIO | Bind address. Keep loopback unless you intend to expose the API to other machines. |
| `STRATA_PORT` | `8080` | Both models, including AIO | HTTP port. |
| `STRATA_KV` | `q4_0` | Both models, including AIO | KV cache format: `q4_0`, `int8`, or `fp16`. Larger formats need more memory. |
| `STRATA_THREADS` | Engine automatic sizing | Both models, including AIO | CPU thread count, passed as `--threads`. |
| `STRATA_VRAM_CAP_MIB` | Engine automatic sizing | Both models, including AIO | Emulate a smaller GPU, in MiB. This allocates a blocker; it does not free VRAM for desktop apps. Leave empty for normal use. |
| `STRATA_RAM_CAP_GIB` | Engine automatic sizing | Qwen3.6 local and AIO serving | Expert RAM-tier budget, in GiB. Not a total process or filesystem-cache limit. |
| `STRATA_QWEN38_MODEL` | Unset | Qwen3.8 local preparation and serving | First IQ3_XXS shard. The second must retain its matching filename beside it. |
| `STRATA_QWEN38_PREPARED_DIR` | Data directory + `/unbiased-strata/qwen38` | Qwen3.8 local preparation and serving | Directory containing generated `pack/`, `mtp/`, and `mtp-q2_0.gguf`. |
| `STRATA_QWEN38_MTP_SOURCE` | Unset; required | Qwen3.8 local preparation only | Explicit local directory containing `mtp-manifest.json` and the 31 raw BF16 `tensors/*.bin` files. Validated offline; never downloaded or modified. |
| `STRATA_QWEN38_CTX` | `8192` tokens | Qwen3.8 serving | Requested context capacity. Replaces `STRATA_CTX` for this launcher. |
| `STRATA_QWEN38_RAM_CAP_GIB` | `40` GiB | Qwen3.8 serving | Expert RAM-tier budget. Replaces `STRATA_RAM_CAP_GIB`, not the cgroup limit below. |
| `STRATA_QWEN38_MEMORY_MAX` | `48G` | Qwen3.8 serving | systemd `MemoryMax`, in systemd size syntax. `48G` means 48 GiB. Limits service-charged RAM and cache; exhausting unreclaimable memory can kill the service. |
| `STRATA_QWEN38_VRAM_RESERVE_MIB` | `4096` MiB | Qwen3.8 serving | GPU sizing headroom for later allocations and desktop apps. Increase it to reduce the expert cache. This is not a hard VRAM quota. |

Values assigned by the config file override inherited environment variables.
CLI arguments then override the generated engine/server defaults. Set
`STRATA_ENV_FILE` outside the file, for example:

```sh
STRATA_ENV_FILE=/path/to/strata.env nix run .#qwen38
nix run .#qwen38 -- --ctx 16384 --port 8081 -- --vram-reserve-mib 5120
```

Local preparation and serving accept two positional path overrides before any
flags. Preparation accepts no other arguments:

```sh
nix run .#prepare-qwen36 -- /models/model.gguf /models/qwen36-prepared
nix run .#qwen36 -- /models/model.gguf /models/qwen36-prepared --port 8081
```

Qwen3.8 uses the same syntax with shard 1 and its own prepared directory.
Both `-aio` launchers ignore configured model, draft-source, and pack paths,
using their bundled pinned artifacts instead. Their context, API, threading, KV,
and memory-tier settings still apply. Qwen3.6 launchers run in the foreground without the Qwen3.8
systemd memory policy.

Qwen3.8 always sets `MemorySwapMax=0`; there is no `.env` switch to enable
service swap. Other host processes can still swap under pressure. The transient
service has a fixed name, so only one `qwen38` launcher can run per user at once.
In a terminal, a PTY forwards Ctrl-C to the server. Redirected/noninteractive
runs use pipes instead; stop those explicitly with `systemctl --user stop strata-qwen38`.
Change settings and restart the launcher to apply them. Edit
`CMAKE_HIP_ARCHITECTURES` in `flake.nix` and rebuild to target a different GPU;
GPU architecture and build concurrency are not runtime `.env` options.

## All-in-one launchers

```sh
nix run .#qwen36-aio -- --ctx 32768 -- --kv q4_0
```

Or, for Flash-Next:

```sh
nix run .#qwen38-aio
```

For image input with the matching projector included:

```sh
nix run .#qwen36-aio-mm
nix run .#qwen38-aio-mm
```

The `-aio-mm` variants fetch a pinned, SHA-256-verified BF16 projector into the
Nix store, about 903 MB for Qwen3.6 or 908 MB for Qwen3.8. They reuse the ordinary
AIO weights and packs. The bundled projector overrides the optional local
projector environment setting; an explicit `--mmproj PATH` overrides the bundled
default. The configured image token limit still applies. No local projector
download or `.env` entry is required.

Only `-aio` and `-aio-mm` launchers automatically fetch model artifacts. They use nix-hug for
pinned GGUF downloads into the Nix store, prepare packs there, and start the
server. Qwen3.8 additionally fetches about 5.2 GB of pinned MTP tensor ranges
through a hash-checked fixed-output derivation. It inherits the local Qwen3.8
context, memory limit, swap policy, and GPU reserve settings.

A small adapter changes nix-hug v5's LFS payload fetches from evaluator fetches
to streaming Nix build jobs. The original evaluator fetch exhausted memory on
this host; that path is no longer used. Metadata still uses nix-hug's pinned
API and Git fetches. Download jobs and packing can still consume resources;
finish them before loading a model, and allow disk space for weights, packs,
intermediates, and temporary copies. Flash-Next's two GGUFs alone total 75.8 GB.

The AIO launchers defer model evaluation until they run. Building the default
package or running `nix flake check` does not fetch model artifacts. The actual
model-bearing derivations live under `legacyPackages`; building a `qwen*-aio` or `qwen*-aio-mm`
package itself only builds a small launcher.

## Reproducibility and scope

`flake.lock` pins Nix dependencies. llama.cpp is pinned to the same commit as
the submodule, with a fixed source hash. The model revision is
`5bc3e238d916f48a861bac2f8a1990a0e9b7e98d`, with SHA-256
`55983c5a75a1ab969824077b3bb3de4146e82a9234072b48ad4e8f92ad3fe9f1`.
The server itself does not fetch code or weights.

Compilation is capped at four jobs and respects lower `--cores` settings.
Finish builds and pack preparation before loading the model.
The package targets Linux x86-64, AVX2 CPUs, and `gfx1100` only. Other Radeon
architectures require a build with a matching `CMAKE_HIP_ARCHITECTURES`.
Image input is opt-in through `--mmproj`; see the Qwen3.8 instructions below.

### Qwen3.6 image configuration

Use Qwen3.6's own [BF16 projector](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/blob/5bc3e238d916f48a861bac2f8a1990a0e9b7e98d/mmproj-BF16.gguf),
about 903 MB. Set these values in `.env` and run `nix run .#qwen36`:

```sh
STRATA_MMPROJ="$HOME/Downloads/Qwen3.6-35B-A3B-vision-mmproj-BF16.gguf"
STRATA_VISION_TOKENS=1024
```

The projector is BF16, independent of the language model's quantization.
Qwen3.6's projector produces 2048-wide embeddings; Qwen3.8's produces 2560-wide
embeddings, so they are not interchangeable. The image request format and CPU
encoding limits described below apply to both models. Qwen3.8 uses its separate
`STRATA_QWEN38_MMPROJ` setting and does not inherit Qwen3.6's projector.

## Flash-Next experiment

The local `prepare-qwen38` and `qwen38` commands use separate
`STRATA_QWEN38_*` settings in `.env.template`. Existing Qwen3.6 paths and sizing
remain unchanged. Host, port, threading, and KV settings are shared.

Download both IQ3_XXS shards from the [pinned model revision](https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/tree/ed59f92082b1e93c0e96d60a8b11aab089b52f09/IQ3_XXS),
keep them beside each other, and set `STRATA_QWEN38_MODEL` to shard 1. Together
they occupy about 75.8 GB. Stop any running model before loading this one.

```sh
nix run .#prepare-qwen38
nix run .#qwen38
```

### Qwen3.8 image input

The existing engine supports this model's image embeddings and rotary positions.
Download the matching [BF16 vision projector](https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/blob/ed59f92082b1e93c0e96d60a8b11aab089b52f09/mmproj-Qwen3.8-Flash-Next-BF16.gguf)
separately, about 908 MB, and set these values in `.env`:

```sh
STRATA_QWEN38_MMPROJ="/models/mmproj-Qwen3.8-Flash-Next-BF16.gguf"
STRATA_QWEN38_VISION_TOKENS=1024
```

Then run `nix run .#qwen38` as usual. Alternatively, pass
`--mmproj /path/to/projector.gguf --vision-tokens 1024` to `qwen38` or
`qwen38-aio`. CLI options override the configuration. These launchers do not download
the projector automatically; `qwen38-aio-mm` includes it instead. Leaving
`STRATA_QWEN38_MMPROJ` empty keeps the ordinary launchers in text-only
serving. The encoder runs on the CPU, so allow extra host memory within the
service's memory limit and expect image preprocessing latency. The image token
limit is per image, accepts 16..4096, and consumes the model's context budget.

Send images to `/v1/chat/completions` as OpenAI-style content parts:

```json
{
  "messages": [{
    "role": "user",
    "content": [
      {"type": "text", "text": "Describe this image."},
      {"type": "image_url", "image_url": {"url": "data:image/png;base64,BASE64_BYTES"}}
    ]
  }],
  "max_tokens": 256
}
```

Replace `BASE64_BYTES` with the encoded image. Only base64 data URLs are accepted,
not remote URLs or local file paths. Supported formats are PNG, JPEG, BMP and GIF,
with at most 32 images per request. `/v1/models` lists `image` in
`input_modalities` when the projector is loaded.

Audio input and audio generation are not supported. The official
[model configuration](https://huggingface.co/Qwen/Qwen3.8-Flash-Next/blob/de4b8e4d43b917e7706784d8bb445c9af86a3540/config.json)
defines a vision encoder and text decoder, with no audio encoder or decoder.
The server accepts text and images only. Speech would require a separate
speech-to-text or text-to-speech model; an audio projector cannot add that
capability to this checkpoint. Video requests are also unsupported by this server.

### Local preparation and memory limits

Local preparation also requires `STRATA_QWEN38_MTP_SOURCE`: an explicitly
provided local directory with `mtp-manifest.json` and all 31 raw BF16 tensors
under `tensors/`. These are the draft head from the
[official pinned checkpoint](https://huggingface.co/Qwen/Qwen3.8-Flash-Next/tree/de4b8e4d43b917e7706784d8bb445c9af86a3540),
not extra tensors in the IQ3_XXS GGUF shards. The expected names, shapes, byte
ranges, and SHA-256 values are in [`nix/qwen38-mtp-manifest.json`](../nix/qwen38-mtp-manifest.json).
Supply that manifest and the corresponding tensor bytes yourself, or reuse
an existing local `mtp-bf16/` directory. A full BF16 checkpoint is not accepted
directly by this preparation command. If you want automatic acquisition instead,
use `qwen38-aio`.

```sh
# In .env, for an existing local extraction:
STRATA_QWEN38_MTP_SOURCE="/models/qwen38/mtp-bf16"
```

Preparation checks the manifest and every tensor hash offline before hashing
the GGUF shards or writing packs. Missing or corrupt inputs are errors, never
reasons to download. It then verifies both GGUFs, builds the native pack, and
quantizes the supplied draft head locally. Source tensors are read-only;
generated files stay in `STRATA_QWEN38_PREPARED_DIR`. Serving uses only the
GGUF shards and generated packs; it does not need the raw tensors.

The launcher requires a working systemd user manager. It runs a transient service
named `strata-qwen38`, with `MemoryMax=48G` and `MemorySwapMax=0`. This limits
cgroup-charged memory, including file cache, without changing host swap settings.
`STRATA_QWEN38_MEMORY_MAX` changes the total limit. The independent
`STRATA_QWEN38_RAM_CAP_GIB=40` setting bounds the engine's expert tier, leaving
room for other allocations. The initial context is 8192 tokens.
`STRATA_QWEN38_VRAM_RESERVE_MIB=4096` leaves room in the GPU sizing plan for
later engine allocations and the desktop. Actual free VRAM will be lower than
this reserve. This uses `--vram-reserve-mib`, not `--vram-cap`, whose blocker
allocation would still consume VRAM needed by the desktop.

The engine uses `--resident-experts --ple-io mmap`: experts that fit stay resident,
while remaining model pages and the n-gram table are file-backed. Uncached pages
come from the model files, not swap. Pinned pages cannot be swapped. Cold and warm
requests may have very different speeds when the working set exceeds RAM.

Inspect or stop the service from another terminal:

```sh
systemctl --user show strata-qwen38 -p MemoryCurrent -p MemoryPeak -p MemorySwapCurrent -p MemoryMax -p MemorySwapMax
systemctl --user stop strata-qwen38
```

The RX 7900 XTX smoke test passed at these defaults. Nonstreaming and streaming
chat completed, with short paragraph responses reporting 30.3 tokens/s and
42.9 tokens/s on a repeat request, with MTP enabled. These are short tests,
not representative benchmarks. The engine held 9147 experts in VRAM and
28.46 GiB of expert copies in pinned RAM. Expert counters recorded no file
reads during generation, though the file-backed n-gram table still uses the
filesystem cache. Service memory reached the 48 GiB limit, including cache,
with zero service swap. Total GPU use was about 21.6 GiB during these tests,
including other applications. Leave desktop headroom when changing the reserve.

## Checks

```sh
nix build .#checks.x86_64-linux.frontend
nix build .#checks.x86_64-linux.launcher-config
nix build .#checks.x86_64-linux.local-preparation
nix run .#check-gpu
```

The GPU diagnostic checks device detection and the three expert-type pairs used
by Q4_K_XL. It reports FP16 signed-zero differences separately. Nonzero FP16
values must still match exactly. These synthetic checks do not replace testing
actual model responses.

Local inference passed on an RX 7900 XTX with a 32768-token context, `q4_0` KV,
and an 8 GiB expert-RAM cap. Both nonstreaming and streaming chat requests
completed with coherent responses. All 10240 experts fit in VRAM, with about
2220 MiB free after loading. A short 111-token response reported 176 tokens/s
with MTP. This is a smoke test, not a representative benchmark.

The general GPU suite is not enabled. This fork removed upstream's HIP test
sources. GPU checks need a real GPU and cannot run in a normal Nix build sandbox.
