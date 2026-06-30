# Login-shell environment parity for claude-remote sessions

- **Date:** 2026-06-30
- **Status:** Proposed
- **Scope:** `lib/claude-remote-lib.sh` (`cr_launch`), `tests/`, `CLAUDE.md`

## Context / Problem

A claude-remote session (e.g. attached from an iPad over SSH) does **not** have the
same environment as a normal MacBook terminal. Environment variables the user
exports in `~/.zshrc` — secrets such as the Atlassian API token consumed by the
`mcp-atlassian` MCP server, and more generally anything their tools expect — never
reach `claude` or the MCP servers it spawns.

Two independent causes were diagnosed:

1. **Stripped env.** The shared tmux server is born by the `de.valgard.claude-remote-anchor`
   LaunchAgent in the launchd/Aqua context, which does not source `~/.zshrc`. The
   project already compensates *surgically* for this — `cr_augment_path` (PATH) and
   `cr_ensure_utf8_locale` (locale) — but nothing else.
2. **Direct-exec launch.** `cr_launch` runs `tmux new-session -d -- claude "$@"`,
   which bypasses tmux's `default-command "zsh -l"`. Every *other* pane in the user's
   tmux runs a login shell and inherits the full env; the claude pane is the single
   exception — deliberately, to keep `pane_pid == claude pid` for the abtop↔tmux join.

The user considers the iPad a trusted extension of themselves and expects parity with
a MacBook terminal. The "frozen at anchor birth" half of the problem is explicitly
out of scope here (a re-login / `kill-server` concern); this design addresses the
**stripped** half for newly launched sessions.

## Goals

- A session launched through claude-remote has the same environment as a fresh
  MacBook login+interactive terminal (full `~/.zshrc`).
- Preserve every existing invariant: `pane_pid == claude pid` (abtop join), the
  post-exit capture (`remain-on-exit` + `pane-died` hook), the keychain anchor.
- Keep the bats suite hermetic (no real `~/.zshrc`, no real `claude`, no tty hang).
- bash 3.2 compatible; clean under shellcheck + shfmt.

## Non-goals (YAGNI)

- Refreshing the environment of an **already-running** session (impossible — a live
  process's env is fixed; "want fresh env → relaunch").
- A picker "relaunch to refresh env" command (Scope B — deferrable, additive later).
- A `cr_augment_env` allowlist, LaunchAgent changes, or a snapshot-and-inject cache.
- Touching the anchor (`--ensure-anchor`) or `cr_reattach`.

## Decision

Launch `claude` **under a login+interactive zsh that immediately `exec`s the bare
binary**, gated by a new env seam `CR_LOGIN_SHELL` (default `1`). In `cr_launch`:

```sh
if [ "${CR_LOGIN_SHELL:-1}" = 1 ]; then
  $CR_TMUX new-session -d -s "$tmp" -- zsh -lic 'exec command claude "$@"' cr "$@"
else
  $CR_TMUX new-session -d -s "$tmp" -- claude "$@"     # current behaviour
fi
```

- `zsh -lic 'exec command claude "$@"' cr "$@"` — the `zsh -c` convention sets `$0=cr`
  and forwards `cr_launch`'s `"$@"` as `$1…`; inside the script `"$@"` expands to the
  same args. `exec command claude "$@"` runs the bare binary with the correct flags,
  **replacing** the zsh process so `pane_pid` stays the same PID.
- `command` bypasses the user's `claude` shell function (defined in `~/.zsh_aliases`,
  which itself calls `claude-remote` — invoking it would infinitely recurse). This is
  mandatory and matches today's exec-form behaviour.
- `-lic` = login+interactive → sources `~/.zshrc` exactly like iTerm → full env
  (~0.5 s on this machine, measured with a pty; the interactive part dominates,
  login files add ~0.04 s).
- `CR_LOGIN_SHELL` joins the existing `CR_TMUX`/`CR_ABTOP`/… seams. Default `1`
  (parity on); tests set `0`.

It is a **fixed** command form, not a dynamic array — plain `"$@"` expansion, so no
bash-3.2 empty-element-under-`set -u` pitfall, and the quoted `'exec command claude "$@"'`
segment stays one argv element naturally.

## Detailed design

### Why `exec` preserves both invariants

Both core invariants hinge on the single `exec`:

- **abtop join.** `cr_launch` captures `pane_pid` right after `new-session`. tmux spawns
  zsh with PID `P` → `pane_pid = P`; at capture time zsh is still sourcing `~/.zshrc`.
  `exec command claude` replaces the process **under the same PID** → `P` now runs
  claude. `display-message` returns `P` before and after; the `rename-session` to
  `<name>-P` is correct, and abtop later sees claude at `P`. A picker refresh firing
  inside the ~0.5 s window would simply not yet list `P` as a claude session — a
  benign, self-healing transient with no data effect.
- **Post-exit capture.** `cr_configure_exit_capture` arms the session *after* the
  rename, unchanged. Because `exec` replaced zsh, the pane process **is** claude;
  claude's exit is the pane's death → `pane-died` fires identically.

Without `exec` (`zsh -lic 'command claude'`) the zsh would remain the pane process:
`pane_pid` would be the zsh's (join broken) and claude's exit would return control to
zsh instead of killing the pane (capture timing broken). This is the mirror image of
the **forbidden** `claude "$@"; exec $SHELL` pattern (a shell *after* claude); here the
shell is *before* and is `exec`'d away.

### Testability

- `cr_setup` (`tests/helpers.bash`) exports `CR_LOGIN_SHELL=0`, so **all existing
  tests** take the direct-exec branch = today's behaviour → the `fake-claude` stub
  works, no real zsh, no tty hang. Zero regression, no existing test touched.
- New `launch.bats` cases use a small recording `CR_TMUX` stub (records the
  `new-session` argv, answers `display-message` with a fake PID) and assert:
  - `CR_LOGIN_SHELL=1` → argv is `zsh -lic 'exec command claude "$@"' cr <args>`.
  - `CR_LOGIN_SHELL=0` → argv is `claude <args>`.

The seam is simultaneously the production switch and the test isolation lever — the
same pattern as `CR_TMUX`/`CR_ABTOP`.

### PATH / locale reconciliation

`cr_augment_path` and `cr_ensure_utf8_locale` **stay** — they serve the picker/wrapper
process itself (which must find `tmux`/`abtop`/`jq`/`fzf` under the stripped SSH forced
command before any pane exists) and the anchor birth. The claude pane additionally
layers the full `~/.zshrc` env on top: tmux execs `zsh` (found via baseline `/bin` in
PATH), `~/.zshrc` sets the real PATH/locale, then `command claude` resolves the binary
from that real PATH.

This **strengthens** the consistency `cr_augment_path` was approximating: both a launch
from an un-stripped Mac shell and one from the stripped SSH picker now source `~/.zshrc`
in the pane, converging on the same binary. The careful "~/.local/bin before Homebrew"
ordering moves from `cr_augment_path` (an approximation) into `~/.zshrc` (the source of
truth). No removal, no conflict — just layering.

### Scope boundaries & edge cases

- **`cr_reattach`** and **`--ensure-anchor`/anchor** untouched. `CR_LOGIN_SHELL` only
  affects `cr_launch`'s claude pane. `default-command "zsh -l"` still applies only to
  the anchor's holding pane.
- **`--no-attach` wrapper** and the **picker's "＋ neue Session"** both go through
  `cr_launch` → inherit parity automatically. Detached panes still get a pty from tmux,
  so `zsh -lic` does not hang.
- **Picker "＋ neue Session" cwd:** runs in a `( cd … )` subshell, so the pane starts in
  the chosen project dir → `~/.zshrc`'s direnv hook loads that dir's `.envrc` (a desired
  bonus, matching Mac behaviour).
- **zsh missing / `~/.zshrc` errors:** the pane dies early → the existing pid guard in
  `cr_launch` ("could not determine claude pid") catches it; `-c` still execs claude on
  non-fatal rc errors.
- **Verified, this machine:** `~/.zshrc` has no tmux autostart (no pane hijack) and the
  `claude` function lives in `~/.zsh_aliases` (sourced by `~/.zshrc`), confirming
  `command claude` is required.

## Alternatives considered

- **Make the LaunchAgent / picker source the full zsh env at anchor birth.** Rejected:
  does not fix the frozen half; the anchor is the shared base for every remote session
  (max secret blast radius); launchd runs a binary not a shell; firing every 60 s.
- **`cr_augment_env` (client-side allowlist).** Viable for *non-secret* vars but places
  the value in the entire pane env (every subprocess sees it) and needs maintenance; for
  the motivating secret, narrower delivery is better. Kept as a future option, not now.
- **Snapshot-and-inject.** Reintroduces the staleness this design removes.
- **Dedicated launcher helper file (`libexec/cr-claude-launch`).** Adds a third installed
  executable + symlink/path handling to `install.sh`; relocates the `zsh -lic` logic
  without simplifying it.

## Documentation & test changes

- `CLAUDE.md`: add `CR_LOGIN_SHELL` to the "Env seams for testability" list; a paragraph
  in the launch/architecture section (wrapper form, `exec` preserving both invariants,
  PATH layering). Update the `cr_launch` lib comment ("no shell involved" → "shell
  sources env, then exec's away").
- `tests/`: `CR_LOGIN_SHELL=0` in `cr_setup`; new `launch.bats` cases per above.
- Project memory `anchor-server-env-stripped-frozen.md`: forward-pointer noting this
  redesign resolves the stripped env for newly launched sessions.

## Open questions

None outstanding — scope (A: new launches only) and latency tolerance (A: accept ~0.5 s)
confirmed.
