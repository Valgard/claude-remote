# ADR-001: Login-shell environment parity for claude-remote sessions

- Status: accepted
- Date: 2026-06-30

## Context and Problem Statement

claude-remote sessions (e.g. attached from an iPad over SSH) did not inherit the user's interactive shell environment. Variables exported in `~/.zshrc` — notably secrets such as the Atlassian API token consumed by the `mcp-atlassian` MCP server — never reached `claude` or the MCP servers it spawns. Two causes:

1. **Stripped env** — the shared tmux server is born by the keychain-anchor LaunchAgent in the launchd/Aqua context, which never sources `~/.zshrc`.
2. **Direct-exec launch** — `cr_launch` ran `claude` directly as the tmux exec target (`tmux new-session -d -- claude "$@"`), bypassing tmux's `default-command "zsh -l"` to keep `pane_pid == claude pid` for the abtop join. The claude pane was thus the one pane in the user's tmux that never got a login shell.

This decision addresses the *stripped* half for newly launched sessions. The *frozen* half (the long-lived anchor server's own base env) is out of scope.

## Decision Drivers

- A remote session should have the same environment as a MacBook terminal (the iPad is a trusted self-extension).
- The abtop↔tmux join (`pane_pid == claude pid`), the `pane-died` post-exit capture, and the keychain anchor must remain intact.
- The bats suite must stay hermetic (no real `~/.zshrc`, no real claude, no tty hang).
- bash 3.2 + shellcheck + shfmt clean; public repo.

## Considered Options

1. Launch claude under a login+interactive zsh that `exec`s the bare binary, gated by a `CR_LOGIN_SHELL` seam.
2. Make the keychain-anchor LaunchAgent / picker `--ensure-anchor` source the full zsh env at server birth.
3. A client-side `cr_augment_env` allowlist (re-export selected vars, like `cr_augment_path`).
4. Snapshot-and-inject the env once and cache it.
5. A dedicated launcher helper file (`libexec/cr-claude-launch`).

## Decision Outcome

Chosen: **Option 1**. `cr_launch` runs `zsh -lic 'exec command claude "$@"' cr "$@"` when `CR_LOGIN_SHELL` is unset or `1` (the default), and the legacy `-- claude "$@"` when `0`.

- The pane has a tty (tmux), so `zsh -lic` sources `~/.zshrc` exactly like iTerm (~0.5 s, measured with a pty).
- The inner `exec` replaces the shell in place under the same pid → `pane_pid == claude pid` and the `pane-died` capture are preserved. This is the mirror image of the forbidden `claude "$@"; exec $SHELL` pattern (a shell *after* claude): here the shell runs *before* and is `exec`'d away.
- `command` bypasses the user's `claude` shell function (which calls `claude-remote` — invoking it would recurse).
- `CR_LOGIN_SHELL=0` keeps the legacy direct exec; `cr_setup` pins it so the existing bats suite is untouched, and new recording-stub tests assert the constructed argv for both branches.

### Consequences

- **Good:** newly launched sessions get full `~/.zshrc` parity — secrets/MCP tokens included — regardless of launch context (terminal, picker, SSH). The pane's PATH/locale layer on top of `cr_augment_path`/`cr_ensure_utf8_locale` (which still serve the picker process and the anchor birth); the load-bearing `claude` binary resolves from the `~/.zshrc` PATH, converging the stripped-SSH and un-stripped-Mac launch contexts. (The `zsh` binary itself is still resolved from the inherited/baseline PATH *before* `~/.zshrc` runs, so that one hop does not converge — an extreme edge case the early-exit pid guard covers.)
- **Good:** the direnv hook in `~/.zshrc` runs in the pane, so a session started in a project dir automatically picks up its `.envrc`.
- **Cost:** ~0.5 s per new session — one-time, invisible against Claude's own multi-second startup.
- **Accepted risk:** the full `~/.zshrc` env, including all secrets, is present in every remote session's pane (and its subprocesses). Acceptable under the trusted-self-extension threat model.
- **Unchanged:** the *frozen* anchor-server env (token rotation still needs a re-login / `kill-server`); a running session's env is fixed.

Rejected: **2** — doesn't fix the frozen half, fragile interactive-zsh-in-launchd (no tty), fires every 60 s, maximum secret blast radius across all sessions. **3** — viable for non-secret vars but broadcasts a secret into the entire pane env; kept as a future option for a non-secret env class. **4** — reintroduces the staleness this removes. **5** — a third installed executable plus symlink/path handling, without simplifying the `zsh -lic` logic.

## More Information

Raw design spec (deleted in this commit per the spec→ADR distillation; retrieve from git history, hash-free):

```
git show "$(git rev-list -1 HEAD -- docs/specs/2026-06-30-claude-remote-login-shell-env-design.md)^:docs/specs/2026-06-30-claude-remote-login-shell-env-design.md"
```
