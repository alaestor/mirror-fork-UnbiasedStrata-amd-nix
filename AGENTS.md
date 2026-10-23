# Fork maintenance

Minimize the delta from upstream. Prefer upstream behavior and interfaces, keeping
fork-specific changes only where needed for AMD/Nix support or an explicit local
requirement. When upstream makes a fork-specific feature unnecessary, remove its
implementation, tests, and documentation rather than retaining a compatibility
shim without a concrete need. Keep changes scoped to the task at hand.

Update with `git fetch upstream` and `git merge upstream/main`, then run
`nix flake check`. Preserve published history; do not rebase or force-push unless
explicitly requested. Enable resolution reuse per checkout with
`git config --local rerere.enabled true`, and review reused resolutions.

Keep Nix packaging and launchers separate from upstream code. Minimize upstream
source and documentation edits, and propose broadly useful HIP fixes upstream.

Maintain the brief inventory at the bottom of README.md when changing upstream
files. Link each affected file, omit fork-only additions, and keep edits minimal
and narrow.
