# Inkling 2 Mini on AMD HIP

This package runs the [native Strata Inkling engine](https://github.com/Niko1221/Strata/releases/tag/v0.2.21)
behind the UnbiasedStrata HTTP front end. llama.cpp supplies the tokenizer and
chat template; it does not run inference. Both builds use the same
[checked source pin](../packaging/inkling/source.json) for Niko's standalone
engine. They don't run the upstream installer, install Python dependencies, or
fetch model weights.

The launcher covers text chat on x86-64 Linux. It takes a GGUF, not a
`.strata` pack or a directory of safetensors. Nix builds for `gfx1100`
such as the RX 7900 XTX. The openSUSE build accepts a different HIP target
through `STRATA_INKLING_HIP_ARCH`; that does not imply hardware validation.

## Use local weights

Choose one Inkling 2 Mini GGUF:

- [Unsloth UD-Q4_K_M](https://huggingface.co/unsloth/Inkling-2-Mini-GGUF/blob/8078d149286eec7193795413b9e0643da6d11fa1/Inkling-2-Mini-UD-Q4_K_M.gguf) (16.61 GB), a quantization of the original weights.
- [AtomicChat AD-Q4_K](https://huggingface.co/AtomicChat/Inkling-2-Mini-Uncensored-GGUF/blob/40886ab636cabb4decf4998224f790b462ab048e/Inkling-2-Mini-Uncensored-AD-Q4_K.gguf) (16.53 GB), a quantization of AtomicChat's modified weights.

From the checkout root, add the model path and optional context size to your
trusted `.env`:

```sh
STRATA_INKLING_MODEL="$HOME/Downloads/Inkling-2-Mini-Uncensored-AD-Q4_K.gguf"
STRATA_INKLING_CTX=38912
```

The context defaults to 4,096 tokens and does not inherit `STRATA_CTX`.
If the engine runs out of VRAM, try a smaller context or close other GPU-heavy
applications. The pinned HIP expert planner does not use
`STRATA_INKLING_VRAM_RESERVE_MIB` to size its expert budget.

For Nix, run `nix run .#inkling`. Build just the engine with
`nix build .#strata-inkling-hip`. For native openSUSE, follow the
[build instructions](../packaging/README.md#inkling-2-mini-with-native-hip),
then run `packaging/run-inkling-opensuse.sh`. Both select `.env` by default
and accept `--env-file PATH`. For Nix, put the arguments after `nix run .#inkling --`.

The server runs in the foreground at `127.0.0.1:8080` unless you change
`STRATA_HOST` or `STRATA_PORT`. Use Ctrl-C to stop it. Options after the
launcher's own `--` go to the engine. For example, this overrides the configured
context and disables drafting:

```sh
nix run .#inkling -- -- --max-context 8192 --draft off
```

Check readiness with `curl --fail http://127.0.0.1:8080/health`.

## Optional DSpark draft

Benchmark your own prompts with drafting enabled and with `--draft off`.
On an RX 7900 XTX with stock UD-Q4_K_M, a mixed reasoning, Rust, and prose
prompt at two seeds per setting decoded at 77.0 tokens/s without drafting,
74.3 with the original MTP head, and 73.2 with the older Q8_0 head.

For drafting, download Thinking Machines' original
[`mtp.safetensors`](https://huggingface.co/thinkingmachines/Inkling-2-Mini/blob/c9d028302cd0f035fdf8e7e91f089a4ce94d2195/mtp.safetensors)
(636 MB). Save it as `Inkling-2-Mini-mtp.safetensors` and add its path to
`.env`:

```sh
STRATA_INKLING_DRAFT="$HOME/Downloads/Inkling-2-Mini-mtp.safetensors"
```

The pinned file's SHA-256 is
`7c3b651317f01f73bcf4e1dceba66ef8b7e1a1eac6bc171e882e690a4b10a1d2`.
The [older Unsloth Q8_0 drafter](https://huggingface.co/unsloth/Inkling-2-Mini-GGUF/blob/8078d149286eec7193795413b9e0643da6d11fa1/dspark-Inkling-2-Mini-Q8_0_Old.gguf)
(402 MB) is an alternative. Upstream Strata Inkling 0.1.67 does not support
Unsloth's newer llama.cpp-layout DSpark GGUF. It warns and runs without
drafting, so check startup logs before comparing speeds. The old
`STRATA_INKLING_DSPARK_MODEL` variable is not used.

No server process downloads missing weights or drafts. To run an already built
Nix launcher without contacting substituters or source servers, build first
with `nix build .#inkling`, then invoke `./result/bin/inkling` directly.
