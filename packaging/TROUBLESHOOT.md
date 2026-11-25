# Troubleshooting native openSUSE builds

See the [setup guide](README.md) for package lists and launch commands.

## Qwen38 build and pack failures

- **CMake cache points to a previous checkout.** Run
  `bash packaging/build-qwen38-opensuse.sh --fresh --build-only`.
  This resets the CMake cache, not the build directory, models, or packs.
- **CMake cannot find the HIP compiler.** Check the configure error. CMake
  needs ROCm's `clang++`, not the `hipcc` wrapper.
- **llama.cpp has local changes.** The builder refuses to update a dirty
  submodule. Review the changes before cleaning or moving them.
- **A pack marker is missing or stale.** The builder warns and reuses the
  existing pack. The checks track preparation inputs and file metadata; they
  do not hash model contents or certify compatibility.
- **A pack is missing required files or fails at runtime.** Stop the server,
  set `PREPARED_DIR` to a new directory, and rerun without `--build-only`.
  Keep the old pack until the new one works. Keep the original GGUF shards and
  raw MTP tensors in `mtp/qwen38-source/`.

Failed preparation leaves a hidden staging directory under `PREPARED_DIR` for
inspection; reruns do not delete it. Do not run builders with different
`BUILD_DIR` values against the same preparation paths.

## Qwen38 GPU diagnostics

Verify access to `/dev/kfd` and the GPU render node, then check the device and
synthetic expert parity before launching:

```sh
./build-gfx1201/strata-device
for pair in q4_K/q5_1 q5_K/q5_1 q6_K/q5_1; do
  ./build-gfx1201/native_expert_parity --synthetic "$pair" || break
done
```

Use your configured `BUILD_DIR` if it differs from the default.

## Headless and SSH sessions

Log in directly as the serving user, rather than through `su` or `sudo -u`.
The launcher can discover an existing user bus, but it refuses to launch
without a working systemd user manager. No desktop is required.

If a fresh SSH login still fails, collect:

```sh
id
printf 'XDG_RUNTIME_DIR=%s\nDBUS_SESSION_BUS_ADDRESS=%s\n' "${XDG_RUNTIME_DIR:-}" "${DBUS_SESSION_BUS_ADDRESS:-}"
loginctl session-status
loginctl show-user "$(id -un)" -p State -p Linger -p RuntimePath
sudo /usr/sbin/sshd -T | grep -i '^usepam '
sudo systemctl status "user@$(id -u).service" "user-runtime-dir@$(id -u).service"
sudo journalctl -b -u "user@$(id -u).service" --no-pager -n 80
```

Ask an administrator to check SSH's effective PAM settings and user-manager
startup. Do not create the runtime directory or bus by hand. If the manager
is already running but manual `systemctl --user` commands cannot see it, set
these in the calling shell:

```sh
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
systemctl --user status
```

Detached services may stop at the last logout. Enable lingering only if you
want the account's user services to run without a login session:
`sudo loginctl enable-linger <login-name>`. Undo it with
`sudo loginctl disable-linger <login-name>`. For a foreground session that
survives SSH disconnects, use a terminal multiplexer such as `tmux`.

## Qwen38 service won't restart

The Nix and openSUSE launchers share `strata-qwen38.service`. Use the launcher
as the same user that started it. Once the service has stopped, retry
`start`. If an earlier backgrounded launcher left a suspended job holding
the unit, run `jobs -l` in the original shell, bring it back with `fg %N`,
then let it exit or press Ctrl-C. `reset-failed` alone won't release it.

## Memory controller setup

Both Qwen38 launchers check the service's cgroup memory files before loading
weights. `MemoryMax` alone does not prove accounting is active.

If preflight reports missing memory files, stop Strata. As the serving user,
run the following with administrator approval. These changes persist across
reboots and enable accounting for other user services too.

```sh
systemctl --user stop strata-qwen38.service
uid=$(id -u)
sudo systemctl set-property user.slice MemoryAccounting=yes
sudo systemctl set-property "user-$uid.slice" MemoryAccounting=yes
sudo systemctl set-property "user@$uid.service" MemoryAccounting=yes
systemctl --user daemon-reexec
systemctl --user set-property app.slice MemoryAccounting=yes
```

After relaunching, verify:

```sh
systemctl --user show strata-qwen38.service -p MemoryCurrent -p MemoryMax
cg=$(systemctl --user show strata-qwen38.service -p ControlGroup --value)
cat "/sys/fs/cgroup$cg/memory.max" "/sys/fs/cgroup$cg/memory.current"
```

Both files should report numeric values. Check the engine's `resident RAM mode`
log to confirm it built the resident expert copy. The service limit also counts
charged file cache; it is not the engine's expert budget. Leave memory for the
OS and other applications because hitting the service ceiling can kill it.

## Qwen38 sampling is slower than before

The [model-card sampling defaults](../docs/nix-amd.md#sampling-defaults) can
be slower. To use the previous llama.cpp defaults, add the settings below to
`.env` and restart. Per-request settings still take precedence.

```sh
STRATA_TEMPERATURE=0.8
STRATA_TOP_P=0.95
STRATA_TOP_K=40
STRATA_MIN_P=0.05
STRATA_PRESENCE_PENALTY=0
STRATA_REPEAT_PENALTY=1
```

## DavidAU abliterated IQ3_S

Use a separate preparation directory and enable the packer's BF16 conversion:

```sh
MODEL=models/Qwen3.8-Flash-Next-GSQ-RCO-abliterated-IQ3_S-00001-of-00002.gguf
MODEL_SHARD2=models/Qwen3.8-Flash-Next-GSQ-RCO-abliterated-IQ3_S-00002-of-00002.gguf
PREPARED_DIR=packs/qwen38-abliterated-iq3-s
COMPAT_BF16=1
```

Conversion changes rounding. The builder still uses the original pinned MTP
head; compatibility and inference quality are not established for this variant.

## Inkling build or startup failures

- **Missing source archive or uninitialized submodule.** Run
  `packaging/build-inkling-opensuse.sh --fetch-sources`. If llama.cpp is already
  initialized at a different revision, review local changes before updating it.
- **HIP compiler not found.** Install `hipcc` or set
  `STRATA_INKLING_HIP_CXX` to the ROCm compiler.
- **The engine cannot allocate GPU memory.** Reduce `STRATA_INKLING_CTX` or
  free VRAM used by other applications. See the [Inkling guide](../docs/inkling.md).
