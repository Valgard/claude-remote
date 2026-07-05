# ADR-002: Native macOS Local Network access via a persistent grantable anchor app

- Status: accepted
- Date: 2026-07-06

## Context and Problem Statement

claude-remote sessions run under a tmux server born by the anchor LaunchAgent. Homebrew binaries (`git`, `curl`, `tea`, `uv`) invoked from those sessions cannot reach the LAN Forgejo host (`http://bragi:3000`): macOS Local Network Privacy (LNP) silently drops the connection (`No route to host`, ~3 ms) while the gateway and public internet stay reachable.

LNP attributes LAN access to the *responsible process* — for claude-remote that is the tmux server, which is not a grantable identity, so its children's LAN peers are silently denied. Apple-signed binaries (`ssh`, `/usr/bin/curl`, `nc`) and loopback are exempt; git already worked via a global `ssh`-`insteadOf` rule, but HTTP/API tools had no native path. The previous `sign-tmux` approach (embed an `Info.plist` and ad-hoc sign the tmux binary) never produced a grant.

## Decision Drivers

- A fresh session must reach the LAN host natively — git **and** HTTP tools (curl/tea/uv) — after a one-time "Allow", persisting across reboots with no re-clicking.
- Must keep login-keychain access, which requires the user's GUI (Aqua) session — this rules out root.
- Survive `brew upgrade tmux`; minimal footprint; bash 3.2 + shellcheck + shfmt clean; public repo.

## Considered Options

1. `sign-tmux`: embed an `Info.plist` and ad-hoc sign the tmux binary.
2. root LaunchDaemon (root-running code is LNP-exempt).
3. Bundle the tmux binary itself as a `.app`.
4. Exempt-transport only: `ssh` loopback tunnel and/or Apple `/usr/bin/curl` for HTTP.
5. A persistent, ad-hoc-signed launcher `.app` that births + supervises the tmux anchor and stays alive.

## Decision Outcome

Chosen: **Option 5**. `install.sh` builds and ad-hoc-signs `~/Applications/ClaudeRemoteAnchor.app` — a tiny C stub that `exec`s `claude-remote-pick --supervise-anchor` — and the anchor LaunchAgent launches it via `open`. Because the app is a live, LaunchServices-tracked, grantable responsible process that births and supervises the tmux server, a one-time Local Network grant covers every session's children. The grant lives on the app's bundle identity (ad-hoc cdhash kept stable by build-once: only the compile is gated, while the `Info.plist` copy and re-sign run every install), so it survives `brew upgrade tmux` and reboots. The app subsumes the keychain anchor (the server is still born in the Aqua session). git keeps flowing over `ssh`-`insteadOf`, independently. `--supervise-anchor` stays alive as the supervisor; the compiler-absent case degrades to the old `--ensure-anchor` script anchor (keychain still works; LAN stays blocked). `sign-tmux` is removed.

### Consequences

- **Good:** native LAN for all tools; the grant survives tmux upgrades and reboots (it is on the app, not the tmux binary); unifies the keychain and Local Network anchor into one mechanism; no root, no Developer ID, no tunnel, no Synology SSH change.
- **Cost:** a compiled stub, a `.app`, and a build step in an otherwise shell-only repo; the app must stay alive (a crash loses the grant until the anchor is re-born); activation needs a one-time anchor restart (re-login or `tmux kill-server`).

### Confirmation

Five ad-hoc-signed spikes isolated the mechanism: a live launcher `.app` whose child makes the LAN call is grantable (HTTP 200 after "Allow"); a launcher that exits immediately, or a bundled tmux that daemonizes away, is not — so the responsible process must remain the live, LaunchServices-tracked app. Spike 6a confirmed the real deployment path (LaunchAgent → `open` → `LSUIElement` app → daemonized tmux → Homebrew `curl`) reaches the LAN host. The bats suite covers the shell/build logic (`cr_anchor_plist`, `cr_anchor_app_needs_build`, `--supervise-anchor` self-heal, `sign-tmux` retirement); the macOS grant itself is verified manually (bats cannot trigger it). Reboot-durability follows from the grant living on the stable bundle identity and is verified at first activation.

Rejected:

- **1** — a daemonized tmux (double-fork + `setsid`) is never a live LaunchServices-tracked app instance, so it cannot be granted regardless of signing or bundling.
- **2** — a root daemon cannot reach the user's login keychain (GUI-session-bound); exempt-via-root and keychain-via-user are mutually exclusive in one process, and a root tmux would also make `claude` run as root by UID inheritance.
- **3** — the tmux binary still daemonizes away from the LaunchServices instance → no grant.
- **4** — works, but the tunnel needs Synology admin SSH enabled plus a persistent tunnel; Apple `/usr/bin/curl` covers API calls but not the `tea` CLI; neither is native.

## More Information

Raw design spec (deleted in this commit per the spec→ADR distillation; retrieve from git history, hash-free):

```
git show "$(git rev-list -1 HEAD -- docs/specs/2026-07-05-native-lan-anchor-app-design.md)^:docs/specs/2026-07-05-native-lan-anchor-app-design.md"
```
