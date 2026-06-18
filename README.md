# claude-remote

A thin shell wrapper that makes interactive [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions remotely attachable from another device — tested with an iPad running [Blink Shell](https://blink.sh) over the local network.

See the full design rationale: [docs/superpowers/specs/2026-06-15-claude-remote-design.md](docs/superpowers/specs/2026-06-15-claude-remote-design.md)

---

## What it does

`claude-remote` launches Claude Code inside a named tmux session so that any SSH client on the same network can attach, detach, and resume the session without interrupting it. A companion picker (`claude-remote-pick`) lists all running Claude sessions (enriched with project name, status, context %, and model via `abtop`) and lets you attach to one — locally or over SSH.

The only code we own is two stateless shell scripts. Everything else is handled by existing infrastructure:

| Concern | Tool | Role |
|---|---|---|
| Session persistence & attach/detach | **tmux** | Keeps Claude alive; transports the terminal |
| Remote transport & authentication | **sshd** | Carries the SSH connection; enforces key auth |
| Session metadata (status, context, model) | **abtop** | Reads Claude's state file and exposes it as JSON |
| Picker UI (optional) | **fzf** | Fuzzy session selection when present; falls back to a numbered menu |
| Own code | `bin/claude-remote`, `bin/claude-remote-pick` | Stateless glue scripts |

No long-running daemon of our own. We start nothing that does not already exist.

---

## Requirements

**Runtime:**

- [tmux](https://github.com/tmux/tmux) `>= 3.0`
- [jq](https://jqlang.github.io/jq/)
- [abtop](https://github.com/anthropics/abtop) (Claude Code session metadata; the picker falls back gracefully if unavailable)

**Optional:**

- [fzf](https://github.com/junegunn/fzf) — when installed and the picker runs on a terminal, it is used for fuzzy session selection; otherwise the picker falls back to a plain numbered menu

**Development only:**

- [bats-core](https://github.com/bats-core/bats-core) — test runner
- [shellcheck](https://www.shellcheck.net/) — shell linter
- [shfmt](https://github.com/mvdan/sh) — shell formatter

---

## Install

```bash
git clone <this-repo> ~/tools/claude-remote
cd ~/tools/claude-remote
./install.sh
```

`install.sh` is **idempotent**: it can be run again after pulling updates without side-effects.

What it does:

1. Creates `~/.local/bin/` if missing.
2. Symlinks `bin/claude-remote` and `bin/claude-remote-pick` into `~/.local/bin/`.
3. Appends three tmux options to `~/.tmux.conf` if not already present:
   - `setw -g aggressive-resize on` and `set -g window-size latest` — size the window to the most recently active client, so the Mac is not permanently shrunk to a smaller iPad screen while both are attached (it resizes back as soon as the Mac is active again).
   - `bind-key S set-option status` — `Prefix+S` toggles the status line. `claude-remote` hides the status line per session (Claude's full-screen TUI uses the whole height); this lets you bring it back to glance at the session name or clock.
4. Prints setup instructions (see below).

Make sure `~/.local/bin` is in your `PATH`.

---

## Setup

After running the installer, follow the printed instructions:

### 1 — Wrap your `claude` shell function

Add this to your shell config (`~/.zshrc`, `~/.bashrc`, …):

```zsh
claude() {
  local git_root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [[ -n "$git_root" ]]; then
    (cd "$git_root" && claude-remote -- --allow-dangerously-skip-permissions --brief "$@")
  else
    claude-remote -- --allow-dangerously-skip-permissions --brief "$@"
  fi
}
```

This ensures every `claude` invocation on your Mac lands inside a named tmux session. Flags after `--` are forwarded verbatim to Claude Code.

### 2 — Restrict the iPad SSH key

Generate a dedicated key on the iPad (in Blink: `ssh-keygen -t ed25519`), then add it to `~/.ssh/authorized_keys` on the Mac as a single line:

```
command="/Users/you/.local/bin/claude-remote-pick",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA... ipad
```

Replace the key fingerprint and the path with the actual values printed by `install.sh`.

### 3 — Connect from the iPad

In Blink, connect to `macbook.local` (Bonjour/mDNS, resolved automatically on the local network — home Wi-Fi or iPhone hotspot). No VPN needed for the core use case.

```
ssh macbook.local
```

The picker opens immediately; select a session to attach.

---

## Usage

### `claude-remote`

```
claude-remote [-l|--label LABEL] [--no-attach] [-- CLAUDE_ARGS...]
```

Launches Claude Code in a fresh, named tmux session and attaches to it.

| Flag | Description |
|---|---|
| `-l LABEL` / `--label LABEL` | Session name prefix. Defaults to the basename of `$PWD`. |
| `--no-attach` | Create the session but do not attach (prints the session name). |
| `--` | Everything after this is forwarded to `claude` as-is. |

The session is named `<label>-<claude-pid>`. Each invocation always starts a **new** session — use the picker to re-attach to an existing one.

**Example:**

```bash
# In a project directory:
claude-remote -l myproject -- --verbose
# → starts tmux session "myproject-<pid>", attaches immediately
```

### `claude-remote-pick`

```
claude-remote-pick [--list]
```

Lists running Claude sessions and lets you attach to one.

- `--list` — prints the menu non-interactively (one `session<TAB>display` line per session) and exits. Useful for scripting or debugging. The non-attachable footnote, if any, is written to stderr (not stdout).
- Without flags — interactive picker. If `fzf` is installed and the picker runs on a terminal, sessions are chosen via fuzzy search (Enter attaches, `Ctrl-R` refreshes the list, `ESC` quits); otherwise a numbered menu is shown (select a number to attach, `r` refreshes, `q` quits). Either way, a `＋ neue Session` entry starts a new session (prompts for a directory). Refreshing re-queries `abtop`/`tmux` so newly started or exited sessions show up without leaving the picker.

The display columns when `abtop` is available — a status glyph, the session name
with its `#pid` (so a `-l` label shows through and same-project sessions stay
distinct), the context-window %, the shortened model, and the current task:

```
  ► claude-remote #40787    49% opus   refactor the picker
  ◐ salesbuddy #56281       93% sonnet waiting for input
  ○ core_keeper #9           5% —      idle here
```

Glyphs: `►` executing/thinking · `◐` waiting · `○` idle. On a terminal the glyph
and context-% are colour-coded (green/yellow/red); `--list` output stays plain for
scripting. Falls back to a plain `tmux list-sessions` output if `abtop` is not
installed or produces no output.

**Works locally and over SSH.** When invoked via the restricted `command=` key, SSH closes automatically when the user presses `q` (the picker exits → SSH session ends).

---

## Remote access

| Layer | Detail |
|---|---|
| Discovery | `macbook.local` — Bonjour/mDNS, no config needed on the same network |
| Auth | SSH key (`~/.ssh/authorized_keys`), restricted via `command=` |
| Entry point | `claude-remote-pick` — lists sessions, lets you attach |
| After attach | Full tmux session; `Ctrl-b d` detaches, returns to picker |

### Security note

The `command=` restriction in `authorized_keys` restricts the **entry point** to `claude-remote-pick`. However, once you select a session and attach to it, you have full interactive access to that tmux session. **Treat the iPad SSH key as a full-access login key, not a sandbox.**

---

## Environment seams

These variables let you substitute the real tools in tests or advanced configurations:

| Variable | Default | Purpose |
|---|---|---|
| `CR_TMUX` | `tmux` | tmux command (override in tests with a stub) |
| `CR_ABTOP` | `abtop` | abtop command (override to test fallback path) |

`claude` is resolved from `PATH` at launch time; there is no env seam for it.

---

## Development

```bash
make test       # run bats test suite (19 tests)
make lint       # shellcheck all shell files
make fmt        # format with shfmt (writes in place)
make fmt-check  # check formatting without writing
```

Tests live in `tests/`. Fixtures and helper stubs are in `tests/fixtures/` and `tests/helpers.bash`.

---

## Manual Acceptance

The following checks require a live TTY, a running tmux server, or the iPad. They cannot be automated in the bats suite and must be verified manually before each release.

1. **Basic launch and session naming**
   Run `claude-remote -l demo` inside any git repo. Confirm Claude starts and the terminal is attached. In a second terminal: `tmux ls` → the list contains a session named `demo-<pid>`.

2. **Detach and picker metadata**
   Detach with `Ctrl-b d`. Run `claude-remote-pick`. Confirm the `demo` session appears with abtop metadata columns (status, context %, model). Press `q` to exit the picker.

3. **Remote attach from iPad**
   Connect from the iPad: `ssh macbook.local` (using the restricted key). Confirm the picker menu appears immediately. Select the `demo` session → confirm attachment. Press `Ctrl-b d` → confirm you land back in the picker. Press `q` → confirm the SSH connection closes.

4. **Non-attachable session footnote**
   Start a bare `claude` invocation (not through the wrapper — e.g., run `claude` directly without `claude-remote`). Run `claude-remote-pick`. Confirm this session does **not** appear as a selectable entry but shows up in the non-attachable footnote line at the bottom of the menu.

5. **abtop fallback**
   Temporarily rename the `abtop` binary (e.g., `mv $(which abtop) $(which abtop).bak`). Run `claude-remote-pick`. Confirm sessions are still listed via the tmux fallback and the fallback notice is shown. Restore the binary afterwards.
