# Native openSUSE build and preparation

[build-qwen38-opensuse.sh](build-qwen38-opensuse.sh) builds the HIP engines and
API server for `gfx1201`, then prepares Qwen3.8-Flash-Next IQ3_XXS and its MTP
draft head. It does not require Nix, install system packages, or start the server.
Confirmed working on openSUSE with a Radeon RX 9070 XT AORUS E 16G and
64 GB of RAM, with a reported decode rate of 46 tokens/s using DavidAU's
`Qwen3.8-Flash-Next-GSQ-RCO-abliterated-IQ3_S` quant. This is a user-reported
result, not a controlled benchmark or a guarantee for other settings.

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
the virtual environment, and parallel build jobs. The script checks that both
model shards exist; it does not hash their contents.

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
PREPARED_DIR=packs/qwen38-abliterated-iq3-s
COMPAT_BF16=1
CONTEXT=8192
RAM_BUDGET_GIB=40
MEMORY_MAX=48G
VRAM_RESERVE_MIB=4096
```

`COMPAT_BF16=1` enables the
packer's existing conversion path for quantized dense tensors, including PLE
keys it cannot retain natively. Conversion changes rounding. The reported
working configuration does not establish inference quality or compatibility
with the original model's MTP head. The script still fetches the original pinned MTP
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

### Sampling

The server uses Qwen3.8's model-card defaults, including for derivatives that
retain its GGUF architecture metadata. The native launcher accepts the same
`STRATA_TEMPERATURE`, `STRATA_TOP_P`, `STRATA_TOP_K`, `STRATA_MIN_P`,
`STRATA_PRESENCE_PENALTY`, and `STRATA_REPEAT_PENALTY` `.env` overrides as Nix.
Leave a variable unset or empty to use the preset; zero is an explicit override.
Per-request settings take precedence. See [sampling defaults](../docs/nix-amd.md#sampling-defaults)
for the presets, thinking-mode selection, and request fields. Rebuild the API
server to get this policy, then restart it after changing `.env`.

### Headless and SSH sessions

The launcher requires a systemd user manager, but no desktop or lingering.
Connect directly over SSH as the intended user rather than through `su` or
`sudo -u`. A normal SSH login with PAM/systemd session integration should
provide the user manager and runtime directory.

The launcher discovers an existing user runtime directory and bus when SSH has
not set `XDG_RUNTIME_DIR` or `DBUS_SESSION_BUS_ADDRESS`. It preserves nonempty
values and refuses to launch if it cannot reach the user manager, rather than
dropping the memory and swap limits. It does not change host configuration.

If it fails, collect these diagnostics from a fresh, direct SSH login before
changing host configuration:

```sh
id
printf 'XDG_RUNTIME_DIR=%s\nDBUS_SESSION_BUS_ADDRESS=%s\n' "${XDG_RUNTIME_DIR:-}" "${DBUS_SESSION_BUS_ADDRESS:-}"
loginctl session-status
loginctl show-user "$(id -un)" -p State -p Linger -p RuntimePath
sudo /usr/sbin/sshd -T | grep -i '^usepam '
sudo systemctl status "user@$(id -u).service" "user-runtime-dir@$(id -u).service"
sudo journalctl -b -u "user@$(id -u).service" --no-pager -n 80
```

An administrator should use the results to check the effective SSH PAM setting,
the PAM session stack's systemd integration, and any user-manager startup
failure. Missing environment variables alone do not identify the cause. Do not
create the runtime directory or bus by hand, or blindly edit PAM configuration.
After fixing login-session setup, reconnect and rerun the launcher.

Enable lingering only if you deliberately want the account's user manager and
services to run without logged-in sessions. `sudo loginctl enable-linger
<login-name>` enables it; `sudo loginctl disable-linger <login-name>` undoes it.
Lingering changes account-wide logout behavior: the user manager and its
services can survive the last logout, so logging back in may reuse their
environment rather than start fresh.

For manual `systemctl --user` commands or the explicit launch command below,
an SSH shell missing these variables can use the following after the user
manager has started:

```sh
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
systemctl --user status
```

The launcher exports these variables only in its own process; it cannot update
the calling shell. Lingering also does not make the foreground launcher survive
an SSH disconnect. Use a persistent terminal such as `tmux` if needed.

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

Rerunning the same command performs an incremental build, checks Python
dependencies, and verifies downloaded MTP tensors. Valid
MTP inputs do not need another download. Completed preparation stages are
skipped using completion markers tied to the tools, pinned source, and model
location. The markers do not verify model contents or every prepared output.
If you replace a model at the same path, use a fresh `PREPARED_DIR`.
Removing model hashes changes existing completion fingerprints; use a fresh
`PREPARED_DIR` if an older pack is reported as stale.

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

Resolve any diagnostic failure before launching. From the repository root, use
the launcher to load your trusted `.env` and run in the foreground:

```sh
bash packaging/run-qwen38-opensuse.sh
```

Ctrl-C stops the foreground server. Do not append `&`; use `start` for a
detached service instead:

```sh
bash packaging/run-qwen38-opensuse.sh start
bash packaging/run-qwen38-opensuse.sh status
bash packaging/run-qwen38-opensuse.sh logs
bash packaging/run-qwen38-opensuse.sh stop
```

`start` returns after systemd starts the process, not after model loading or API
readiness. It keeps the same memory limits as the foreground launcher, disconnects
standard input, and sends output to the user journal. Ctrl-C during `logs` stops
following the journal without stopping the server. `status` shows service state
and recent logs; it does not probe API readiness. Use the health request below.
`logs` includes previous runs of this unit.

Only one instance runs per user. The `strata-qwen38.service` name is shared with
the Nix Qwen3.8 launcher, so these commands also control an instance started
through Nix. Repeating `start` while active reports that it is already running;
`stop` waits for shutdown and succeeds if already stopped.
Use `stop` followed by `start` to apply changed settings. Control commands do not
load `.env` or require the model, prepared packs, or build artifacts, and can run
from another directory when invoked with the script's full path. Run all commands
as the same user, without `sudo`.

If an earlier launch with `&` leaves the unit loaded after stopping the server,
run `jobs -l` in the original shell. Use `fg %N` for the suspended launcher job,
then let it exit or press Ctrl-C before retrying. `reset-failed` alone does not
release a reference held by a suspended launcher. Do not delete the transient
unit file or switch to unique names to bypass this condition.

A detached service does not guarantee survival after the last logout. See
[Headless and SSH sessions](#headless-and-ssh-sessions) for user-manager lifetime.

For a manual foreground launch with the default paths:

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

## Memory controller setup

Both the openSUSE launcher and Nix Qwen3.8 launcher check cgroup memory files
inside the service before loading weights. They refuse startup if the service
or an ancestor lacks the files needed for resident RAM detection. A configured
`MemoryMax` alone does not prove that the limit is enforced.

On affected openSUSE hosts, only the `pids` controller was enabled for user
services. The engine then reported `cannot determine available memory`, built
no resident expert copy, and fell back to file-cache reads. The preflight check
detects this condition instead of silently accepting slower startup behavior.

Stop Strata before changing accounting:

```sh
systemctl --user stop strata-qwen38.service
```

Enable persistent accounting on the parent units. Replace `1000` with your
numeric user ID from `id -u` if different:

```sh
sudo systemctl set-property user.slice MemoryAccounting=yes
sudo systemctl set-property user-1000.slice MemoryAccounting=yes
sudo systemctl set-property user@1000.service MemoryAccounting=yes
systemctl --user daemon-reexec
systemctl --user set-property app.slice MemoryAccounting=yes
```

These commands persist across reboots. They do not grant privileges or impose
new limits on other applications, but they enable accounting for user services
and add bookkeeping overhead. The launcher's memory and swap limits now take
effect: reaching the memory ceiling can trigger an in-service OOM kill. Leave
room for the OS and other applications; a 62 GiB ceiling on a 64 GB machine is
not a reservation and provides little guaranteed headroom.

Relaunch Strata, then verify in another terminal:

```sh
systemctl --user --no-pager show strata-qwen38.service -p MemoryCurrent -p MemoryMax
cg=$(systemctl --user show strata-qwen38.service -p ControlGroup --value)
cat "/sys/fs/cgroup$cg/memory.max" "/sys/fs/cgroup$cg/memory.current"
```

Both files must exist and report numbers. Check the engine's `resident RAM mode`
line to confirm the resident copy was built; service memory includes file cache
and is not a measurement of resident expert bytes alone. The launchers never
change host accounting settings automatically.
