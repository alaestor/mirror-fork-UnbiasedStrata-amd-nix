# Fork maintenance

Prefer upstream behavior and interfaces. Keep fork changes scoped to AMD support,
packaging, or an explicit local requirement. When upstream replaces a fork
feature, remove its implementation, tests, and docs unless a concrete need
remains.

Keep Nix packaging and launchers in `flake.nix` and `nix/`, and native openSUSE
scripts and setup docs in `packaging/`. Keep edits to inherited code small and
propose broadly useful HIP fixes upstream. When changing an upstream file,
update the [inventory in README.md](README.md#edits-to-upstream-files). Link the
affected file; omit fork-only additions.

When syncing with upstream, run `git fetch upstream` and
`git merge upstream/main`, then run `nix flake check`. Preserve published
history; do not rebase or force-push unless asked. Enable resolution reuse per
checkout with `git config --local rerere.enabled true` and review reused
resolutions. For launcher changes, run the relevant tests in `nix/` and
`packaging/`. Say when a change has not been tested on real hardware.

Keep setup in [packaging/README.md](packaging/README.md) and failure recovery in
[packaging/TROUBLESHOOT.md](packaging/TROUBLESHOOT.md). For Inkling, keep Niko's
engine separate and use the same checked source pin on both platforms. Fetch
sources before building; neither compilation nor launch should fetch
dependencies or weights.

## User configuration

`.env` is the user's default configuration in the working directory. Keep
shareable examples in the tracked [`.env.template`](.env.template); never
overwrite a user's config or commit it.

Treat configuration files as trusted Bash. Name local presets `.env-<preset>`.
Where supported, select one with `--env-file PATH` or `STRATA_ENV_FILE`; the CLI
takes precedence. The selected file replaces `.env`. Never discover or layer
presets automatically. The native Qwen3.8 scripts read only `.env`.
