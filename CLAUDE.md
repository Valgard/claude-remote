# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A thin shell wrapper that makes interactive Claude Code sessions remotely attachable from another device (tested with an iPad over Blink Shell on the LAN). The only owned code is two stateless shell scripts plus a shared library; persistence, transport, auth, and metadata are delegated to existing tools (tmux, sshd, abtop, fzf). There is no daemon of our own.

Read `docs/specs/2026-06-15-claude-remote-design.md` for the full design rationale before making non-trivial changes.

## Commands

```bash
make test          # run the bats suite (tests/)
make lint          # shellcheck the two bins, the lib, and install.sh
make fmt           # shfmt -w -i 2 -ci  (2-space indent, switch-case indented)
make fmt-check     # shfmt diff check (CI-style, no write)

bats tests/join.bats              # run a single test file
bats -f "marks attachable" tests/ # run tests matching a name pattern
```

`shfmt -i 2 -ci` is the canonical format; every change to `bin/`, `lib/`, or `install.sh` must pass `make fmt-check` and `make lint` (the repo runs clean under shellcheck — keep it that way, with targeted `# shellcheck disable=` comments only where intentional, e.g. `SC2086` word-splitting on `$CR_TMUX`).

## Architecture

**Three source files, one library:**

- `lib/claude-remote-lib.sh` — every piece of real logic lives here as a `cr_*` function. Sourced by both bins **and** the tests, so logic is unit-testable without invoking the scripts end-to-end.
- `bin/claude-remote` — launch wrapper: parses `-l/--label`, `--no-attach`, `--`, then calls `cr_session_name` + `cr_launch`. `set -euo pipefail`.
- `bin/claude-remote-pick` — the picker: a redraw loop calling `cr_menu_lines` and one of the pick functions. Also the SSH forced-command entry point, and the `--ensure-anchor` entry point used by the install.sh LaunchAgent (see Keychain anchor below). `set -uo pipefail` (no `-e`: the attach/redraw loop must survive non-zero exits).

**The pid join (the core idea).** `cr_launch` runs `claude` *directly* as the tmux exec target (`tmux new-session -d -- claude "$@"`), so `pane_pid == claude pid`. That shared pid is the join key: `cr_abtop_sessions` emits one TSV row per Claude session keyed by pid, `cr_pane_map` emits `pane_pid<TAB>session_name` for every tmux pane, and `cr_join` matches them — rows with a pane become attachable `S` rows, the rest are counted into a single `N` (running but not under claude-remote, so not attachable). Launching via the exec form also bypasses the user's interactive `claude` zsh function (equivalent to `command claude`), avoiding infinite recursion.

**The display pipeline** (all stdin/stdout TSV, composable and individually testable):

```
cr_abtop_sessions ─┐
                   ├─> cr_join ─> S/N rows ─┬─> cr_format_rows ─> "session<TAB>display"
cr_pane_map ───────┘                        └─> cr_footnote     ─> "(N weitere …)" on stderr
                                  cr_menu_lines wraps the above; falls back to a raw
                                  `tmux list-sessions` when abtop is unavailable.
```

The first column of every menu line is the tmux session name (the attach key); the rest is human-facing display. `cr_format_rows` pads on *visible* length so ANSI colour (gated by `CR_COLOR=1`) doesn't break column alignment.

**Picker selection** returns a token, not a raw choice: a session name to attach, or `__NEW__` / `__QUIT__` / `__RELOAD__` / `__NONE__`. `cr_pick_fzf` (used when `fzf` exists and stdout is a tty) and `cr_pick_numbered` (fallback) both honour the same token contract, so the loop in `bin/claude-remote-pick` is UI-agnostic.

**Attach semantics.** `cr_launch` uses `exec tmux attach` (replaces the process) on direct launch, but the picker calls it inside a `( … )` subshell so the exec replaces only the subshell — the picker loop survives a detach and redraws. A plain attach in the loop (`$CR_TMUX attach`) is *not* exec'd for the same reason.

**Keychain anchor (macOS).** A tmux server's launchd bootstrap namespace is fixed at birth and inherited by every pane. If the picker births the server from inside the iPad's SSH forced command (no server running yet), it lands in the `Background` domain, where Claude Code's login-keychain write (OAuth token refresh) fails with `errSecInteractionNotAllowed (-25308)` — there is no SecurityAgent route outside the GUI (`Aqua`) session. `cr_ensure_anchor` fixes this by birthing a hidden holding session (`CR_ANCHOR`, default `_cr_anchor`) *only when no server runs yet* (a no-op otherwise — never disturb a server it didn't birth). `install.sh` installs a per-user `LaunchAgent` (`de.valgard.claude-remote-anchor`, `LimitLoadToSessionType=Aqua`, `RunAtLoad` + `StartInterval=CR_ANCHOR_INTERVAL`, default 60s) that runs `claude-remote-pick --ensure-anchor` at GUI login and periodically (self-healing: re-establishes an `Aqua` server within one interval; the anchor session is hidden from the picker via `cr_menu_lines`). Only the *server birth* is anchored, never the `-- claude` pane command, so `pane_pid == claude pid` stays intact. A long-lived `CLAUDE_CODE_OAUTH_TOKEN` (which would bypass the keychain) was rejected because the user switches Team↔Max plans by re-login: Claude Code's macOS credential store is the login keychain (last in an auth-precedence chain — earlier tiers like `ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN` bypass it; there is no flag to disable the keychain on macOS), so native keychain OAuth must stay. Only meaningful while logged into the Mac GUI (the keychain is unreachable otherwise).

## Conventions that matter

- **Env seams for testability:** all external-tool access goes through `CR_TMUX` (default `tmux`), `CR_ABTOP` (default `abtop`), `CR_SSH_PORT` (default `22`), `CR_ANCHOR` (default `_cr_anchor`, the keychain-anchor holding session). Never call `tmux`/`abtop` directly in `lib/` — go through the variable. Tests override these to point at an isolated `tmux -L <socket>` server and stub binaries (`tests/fixtures/abtop-stub`, `tests/fixtures/fake-claude`), so the suite never touches the user's real sessions.
- **Symlink-safe sourcing:** both bins resolve `BASH_SOURCE` through symlinks before sourcing the lib, because `install.sh` symlinks them into `~/.local/bin` while the lib stays next to the real script. Preserve this loop when editing the script headers.
- **Stripped PATH:** `cr_augment_path` appends Homebrew / local bin dirs to `PATH` so `abtop`/`tmux`/`jq`/`fzf`/`claude` resolve under an SSH forced command (whose PATH is minimal). It *appends* (never prepends) so existing PATH entries keep priority.
- **Idempotent installer:** `install.sh` must be re-runnable after a pull. Line appends to `~/.tmux.conf` go through `cr_ensure_line` (present-check + newline-safe append) — never a bare `>>`.
- **User-facing strings are German; code, comments, and docs are English.** Match the existing mix (menu prompts, footnotes, and warnings in German; everything else English).
- **bash 3.2 compatibility:** macOS ships bash 3.2. Avoid injecting empty array elements under `set -u` (see the `pick_args` guard in `bin/claude-remote-pick`).

## Tests

bats-core suite under `tests/`, one file per concern (`join`, `render`, `pane_map`, `name`, `fallback`, `pick`, `launch`, `install`, `path`, `sshd`, `abtop_parse`, `anchor`). Each sources `tests/helpers.bash` via `load helpers`:

- `cr_setup` / `cr_teardown` — isolated tmux server (unique `-L` socket per test), stub `abtop` and `claude` on PATH.
- `cr_make_session <name>` — start a fake-claude session and echo its `pane_pid`.

Most tests source a single `cr_*` function and feed it TSV on stdin, asserting on stdout — match that style (small, function-level, no real network or real Claude) when adding coverage.
