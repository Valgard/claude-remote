# Native Local Network access via a persistent grantable anchor app

**Date:** 2026-07-05
**Status:** Design approved; implementation pending.

## Context / Problem

claude-remote sessions run under a tmux server that is born by a LaunchAgent which
runs a short-lived script (`claude-remote-pick --ensure-anchor`). Homebrew binaries
(`git`, `curl`, `tea`, `uv`) invoked from those sessions cannot reach the LAN Forgejo
host `bragi` (`http://bragi:3000`): macOS **Local Network Privacy (LNP)** silently
drops the connection (`No route to host`, ~3 ms). The gateway and the public internet
remain reachable — the block is LAN-peer specific.

**Root cause.** LNP attributes LAN access to the *responsible process*. For a
claude-remote command that is the **tmux server**, which is not a grantable identity, so
its children's LAN peers are silently denied. Apple-signed binaries (`ssh`,
`/usr/bin/curl`, `nc`) and loopback (127.0.0.1) are exempt.

**Why the previous approach failed.** `make sign-tmux` (embed an `Info.plist` and
ad-hoc sign the tmux binary) is a dead end: a tmux server double-forks + `setsid`s and
reparents to launchd, so it is never a *live, LaunchServices-tracked app instance* — and
an LN grant only attaches to such an instance. No prompt ever appears, regardless of
bundling or signing. This was re-confirmed against the production anchor (no prompt).

**Empirical basis (5-spike series, 2026-07-05, ad-hoc-signed throwaway apps).**

| Spike | Setup | Result |
|-------|-------|--------|
| v1 | `.app` stays alive, `curl` is its direct child | Prompt appeared; `200` after Allow |
| v2 | Launcher `.app` starts tmux, then **exits immediately** | `000` (no live launcher) |
| v3/v4 | **Bundled** tmux (binary carries bundle id), via `open`, client exits | **No prompt**, `000` |
| v5 | Launcher `.app` starts tmux **and stays alive ~65 s** | Prompt appeared; `000 → 200` (14×) with a **bare** Homebrew tmux |

The discriminator is not bundling or signature class (v5 used a bare Homebrew tmux and an
ad-hoc app). It is: **the responsible-pid of the daemonized tmux must point at a live,
LaunchServices-tracked, grantable app.** v2 failed only because its launcher exited.

## Goal (Definition of Done)

A fresh session (iPad/picker or local) reaches bragi natively — git **and** HTTP tools
(`curl`/`tea`/`uv`) — after a **one-time** "Allow", persisting across reboots/re-logins
with **no re-clicking**.

## Decision

Replace the script-based anchor with a **persistent, ad-hoc-signed `.app`** that is
launched via LaunchServices (`open`), **births** the tmux anchor server, and **stays
alive** as its supervisor. The LN grant attaches to this live app; granting it once
covers every tmux child. The app **subsumes the existing keychain anchor** — both the
keychain (Aqua bootstrap namespace) and LN (live grantable responsible process) require
the server to be born by a live Aqua process, which a LaunchServices-launched app is.

Signing: ad-hoc, built once (identity stays stable across installs so the grant
persists). No Developer ID, no bundled tmux, no root, no tunnel.

## Design

### Components

1. **`~/Applications/ClaudeRemoteAnchor.app` (new).** LaunchServices-grantable bundle.
   - `Contents/Info.plist`: `CFBundleIdentifier = de.valgard.claude-remote-anchor`,
     `CFBundleExecutable = <stub>`, `LSUIElement = true` (background agent, no Dock icon).
   - `Contents/MacOS/<stub>`: a minimal compiled C program whose only job is
     `exec` of `claude-remote-pick --supervise-anchor`. The absolute path to
     `claude-remote-pick` is baked in at build time (`-DCRP_PATH=…`) so the binary — and
     thus its ad-hoc cdhash — is stable.

2. **`--supervise-anchor` mode (new)** in `bin/claude-remote-pick`. Calls
   `cr_ensure_anchor` (births the server only if none is running), then enters a thin
   forever loop: `while true; do cr_ensure_anchor; sleep "$CR_ANCHOR_INTERVAL"; done`.
   Staying alive holds the responsible-pid anchor; the periodic re-ensure is self-healing
   (if the server dies while the app lives, the next tick re-births it under the live app,
   so it stays grantable). `cr_ensure_anchor` itself is unchanged.

3. **LaunchAgent (changed)**, written by `install.sh`. `ProgramArguments` change from
   `[claude-remote-pick, --ensure-anchor]` to `[/usr/bin/open, <bundle-path>]` (install.sh writes the absolute,
   `$HOME`-expanded bundle path; `~/Applications/ClaudeRemoteAnchor.app` is shown for
   brevity — a plist does not expand `~`).
   `RunAtLoad`, `StartInterval`, `LimitLoadToSessionType=Aqua` stay. `open` (not a direct
   exec of the stub) is mandatory: LaunchServices tracking is what makes the app grantable.
   `StartInterval` (not launchd `KeepAlive`) is the keep-alive: `open` returns immediately,
   so a periodic idempotent `open` relaunches a dead app without busy-looping.

4. **`install.sh` (changed).** Build + ad-hoc-sign the stub into the bundle
   (**build-once**: only when the binary is missing or its source is newer, so the cdhash
   stays constant and the grant survives re-runs), then write the new LaunchAgent. If
   `clang` is unavailable, degrade gracefully: keep the old script anchor (keychain still
   works; LN stays blocked) and print a hint. No hard failure.

5. **sign-tmux (removed)** — see "Retirement" below.

### Lifecycle / data flow

1. GUI login (Aqua) → LaunchAgent `RunAtLoad` → `open ClaudeRemoteAnchor.app`.
2. LaunchServices launches the app as a **tracked instance** (responsible = the app) →
   stub `exec`s `claude-remote-pick --supervise-anchor`.
3. No server yet (fresh login) → `cr_ensure_anchor` births `tmux new-session -d -s
   _cr_anchor`. The server's responsible-pid points at the live app.
4. Supervisor loops → app stays alive → attribution holds.
5. First LAN call from any session under the server (git-over-http / curl / tea / uv) →
   attributed to the live app → **one-time prompt "ClaudeRemoteAnchor" → Allow**.
6. Thereafter every child reaches bragi. The grant is on the app's bundle identity
   (ad-hoc cdhash kept stable via build-once) → survives reboots/re-logins with no
   re-clicking.
7. Keep-alive: `StartInterval` periodically re-fires `open` (no-op if alive; relaunch if
   dead). Self-heal: if the *server* dies while the app lives, the next loop tick
   re-births it under the live app.

**Activation (one-time).** The currently running server was not born by the app and
cannot be adopted retroactively. Activation happens at the next re-login, or a deliberate
`tmux kill-server` when no session matters.

**Relationship to ssh-insteadOf.** Unchanged; git keeps flowing over exempt `ssh`. The
app grant additionally covers non-git HTTP (curl/tea/uv) natively — the gap insteadOf
does not close. They coexist without conflict.

### Error handling & edge cases

- **App dies while the server runs:** the server's responsible-pid points at a dead
  process → falls back to the ungrantable tmux → LAN breaks for existing sessions. A
  relaunched app does **not** adopt the pre-existing server (`cr_ensure_anchor` no-ops) →
  grant restored only at the next re-birth (re-login / `kill-server`). Mitigation: the
  supervisor is trivial (an `exec` plus a `sleep` loop) so it effectively never crashes;
  this is the same "takes effect at next clean login" property the current anchor has.
- **Server already running when the app starts:** `cr_ensure_anchor` no-ops → the app
  supervises but is not the birther → not grantable. Expected (activation requires a
  clean birth).
- **`brew upgrade tmux`:** now irrelevant — the grant is on the app, not the tmux binary.
  This removes the old sign-tmux regression vector.
- **No `clang`:** graceful degrade to the old script anchor plus a hint.
- **Rollback:** revert `install.sh`, restore the `--ensure-anchor` LaunchAgent, remove
  the app. ssh-insteadOf + Apple-`curl` remain as fallbacks.

### Open verification points

These are empirically unconfirmed and MUST be checked first — against a test socket and a
throwaway app (the v5 methodology) — before the real anchor is switched:

1. **`open` from a LaunchAgent context** yields a grantable tracked instance, the same way
   interactive `open` did in v5. *(The central integration risk.)*
2. **`LSUIElement = true`** does not suppress the LN prompt. (v5 did not set it.) Fallback:
   drop the flag.
3. The grant **survives an app relaunch** (does the responsible-pid resolve by bundle
   identity, which a same-bundle relaunch satisfies, or by live PID, which it does not?).
   Determines how severe "app dies" really is.
4. The grant **survives a deliberate stub rebuild** (same bundle id, new cdhash).

### Testing

**Automatable (bats, following the existing `tmux -L` isolated-socket + stub conventions):**
- `supervise.bats` (new, after `anchor.bats`): run `--supervise-anchor` with a short
  `CR_ANCHOR_INTERVAL` in the background against a test socket → assert the anchor session
  appears; `kill-session` → assert the next tick re-births it (self-heal); kill the
  supervisor.
- `install.bats` (extended): the new LaunchAgent contains `open …/ClaudeRemoteAnchor.app`
  (not `--ensure-anchor`); build-once decision (a second run without a source change does
  not rebuild/re-sign → stable cdhash); `clang`-missing degradation.
- Retirement negatives: `make sign-tmux` target gone, `bin/cr-sign-tmux` gone, `install.sh`
  and docs no longer reference it.
- `make fmt-check` + `make lint` (shellcheck) stay green for all changed shell files.

**Manual (macOS GUI, un-automatable):** the four verification points plus the actual
grant → `200`, per the v5 procedure — as a manual checklist: (a) throwaway app against a
test socket, (b) the `open`-from-LaunchAgent variant, (c) the real anchor at activation.
bats cannot trigger an LN grant.

The C stub is trivial enough (a single `exec`) that it is covered by the end-to-end manual
run; optionally a tiny bats check that it compiles and forwards the right `argv`.

### Retirement of sign-tmux

- **Delete:** `bin/cr-sign-tmux`; the `sign-tmux` target and its `.PHONY` entry in the
  `Makefile`, and `cr-sign-tmux` from the `lint` target's shellcheck list; the "Local
  Network privacy hint" block in `install.sh` (the app anchor is now the LN mechanism).
- **Rewrite (docs, English):** the "Local Network privacy (macOS)" section and the `make
  sign-tmux` command entry in `CLAUDE.md`, and the equivalent section in `README.md`, to
  describe the persistent-app anchor and record that sign-tmux was a dead end.
- **Not needed:** any old `<tmux>.cr-orig` backup — the installed tmux is already the
  unpatched Homebrew build; there is no active patch to revert.

## Consequences

**Positive.** Native LAN for all tools; grant survives tmux upgrades (it is on the app,
not tmux) and reboots; unifies the keychain and LN anchor into one mechanism; no root, no
Developer ID, no tunnel, no Synology SSH change.

**Negative / risks.** Adds a compiled stub, a `.app`, and a build step to an otherwise
shell-only repo; the app must stay alive (a crash loses the grant until re-birth);
activation needs a one-time anchor restart (re-login / `kill-server`); the four verify
points are unconfirmed until the pre-switch spike.

## Alternatives considered (rejected)

- **sign-tmux** (embed Info.plist + ad-hoc sign tmux): dead end — a daemonized tmux is
  never a tracked app instance.
- **root LaunchDaemon** (LNP-exempt): breaks login-keychain access, which needs the GUI
  user session; exempt-via-root and keychain-via-user are mutually exclusive in one
  process. A root tmux would also make claude run as root by UID inheritance.
- **Bundle the tmux binary itself:** still daemonizes away from the LaunchServices
  instance → no grant (v3/v4).
- **ssh loopback tunnel for HTTP:** works, but requires enabling Synology admin SSH (only
  the Forgejo git port :222 is open, with a restricted shell), plus a persistent tunnel;
  not native.
- **Apple `/usr/bin/curl` for API calls:** a zero-setup fallback, but not the `tea` CLI
  and not a general native path.
