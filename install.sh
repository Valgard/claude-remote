#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/claude-remote-lib.sh disable=SC1091
. "${HERE}/lib/claude-remote-lib.sh"
BIN_DIR="${HOME}/.local/bin"
mkdir -p "$BIN_DIR"
ln -sf "${HERE}/bin/claude-remote" "${BIN_DIR}/claude-remote"
ln -sf "${HERE}/bin/claude-remote-pick" "${BIN_DIR}/claude-remote-pick"
ln -sf "${HERE}/bin/cr-sign-tmux" "${BIN_DIR}/cr-sign-tmux"

# tmux: size the window to the most recently active client, so the Mac is not
# permanently shrunk to the iPad's smaller resolution while both are attached —
# it resizes back as soon as the Mac is the active client again. aggressive-resize
# helps older size modes. cr_ensure_line is newline-safe and idempotent.
TMUX_CONF="${HOME}/.tmux.conf"
cr_ensure_line "$TMUX_CONF" 'setw -g aggressive-resize on'
cr_ensure_line "$TMUX_CONF" 'set -g window-size latest'
# Pass terminal focus in/out events through to the running program; Claude Code's
# full-screen TUI relies on them and warns when tmux swallows them (default: off).
cr_ensure_line "$TMUX_CONF" 'set -g focus-events on'
# Prefix+S toggles the status line (claude-remote hides it per session for Claude's
# full-screen TUI; this lets you bring it back to glance at the session name/clock).
cr_ensure_line "$TMUX_CONF" 'bind-key S set-option status'

# Native Local Network anchor (macOS): a persistent, ad-hoc-signed .app launched via
# LaunchServices (open) births the tmux anchor and stays alive as its supervisor, so its
# Local Network grant covers every tmux child; it also subsumes the keychain anchor.
# build-once keeps the ad-hoc cdhash (and thus the one-time grant) stable. Degrades to the
# script anchor (keychain still works; LAN stays blocked) when the compiler is unavailable.
if command -v launchctl >/dev/null 2>&1; then
  AGENT_LABEL="de.valgard.claude-remote-anchor"
  AGENT_DIR="${HOME}/Library/LaunchAgents"
  AGENT_PLIST="${AGENT_DIR}/${AGENT_LABEL}.plist"
  AGENT_INTERVAL="${CR_ANCHOR_INTERVAL:-60}"
  APP_DIR="${HOME}/Applications/ClaudeRemoteAnchor.app"
  STUB_SRC="${HERE}/anchor-app/cr-anchor-stub.c"
  STUB_BIN="${APP_DIR}/Contents/MacOS/cr-anchor-stub"

  if command -v "${CR_CLANG:-clang}" >/dev/null 2>&1; then
    mkdir -p "${APP_DIR}/Contents/MacOS"
    cp -f "${HERE}/anchor-app/Info.plist" "${APP_DIR}/Contents/Info.plist"
    if cr_anchor_app_needs_build "$STUB_SRC" "$STUB_BIN"; then
      "${CR_CLANG:-clang}" -O2 -DCRP_PATH="\"${BIN_DIR}/claude-remote-pick\"" -o "$STUB_BIN" "$STUB_SRC"
      codesign -s - --force "$APP_DIR"
    fi
    AGENT_PROG_A="/usr/bin/open"
    AGENT_PROG_B="$APP_DIR"
  else
    echo "ℹ️  clang not found — using the script anchor (Local Network stays blocked)."
    AGENT_PROG_A="${BIN_DIR}/claude-remote-pick"
    AGENT_PROG_B="--ensure-anchor"
  fi

  mkdir -p "$AGENT_DIR"
  cr_anchor_plist "$AGENT_LABEL" "$AGENT_PROG_A" "$AGENT_PROG_B" "$AGENT_INTERVAL" >"$AGENT_PLIST"
  launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
fi

cat <<EOF
Installed claude-remote and claude-remote-pick to ${BIN_DIR}.

1) Wrap your existing claude() zsh function so it launches via claude-remote:

   claude() {
     local git_root=\$(git rev-parse --show-toplevel 2>/dev/null)
     if [[ -n "\$git_root" ]]; then
       (cd "\$git_root" && claude-remote -- "\$@")
     else
       claude-remote -- "\$@"
     fi
   }

2) Give the iPad its own SSH key and restrict it to the picker in
   ~/.ssh/authorized_keys (ONE line):

   command="${BIN_DIR}/claude-remote-pick",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA... ipad

   SECURITY: tmux attach grants full interactive access. Treat this key like a
   login key — it is NOT a sandbox.

3) In Blink, connect to:  macbook.local   (Bonjour/mDNS over your local network)
EOF

# Transport prerequisite: warn (do not enable) if sshd is off, otherwise the
# iPad cannot connect. Enabling Remote Login needs sudo and is a deliberate act.
if ! cr_sshd_running; then
  cat <<'EOF'

⚠️  Remote Login (sshd) is currently OFF — the iPad cannot connect yet.
    Enable it once:  sudo systemsetup -setremotelogin on
EOF
fi

# Local Network privacy hint (macOS): Homebrew's tmux carries no Info.plist, so
# macOS silently blocks LAN access from picker-born sessions (e.g. a git remote on
# the LAN) while public internet still works. --check is read-only (no rebuild);
# only surface the opt-in fix when tmux is not yet patched.
if command -v tmux >/dev/null 2>&1 && ! "${BIN_DIR}/cr-sign-tmux" --check >/dev/null 2>&1; then
  cat <<'EOF'

ℹ️  Need LAN access (e.g. a git remote on your local network) from picker
    sessions? macOS Local Network privacy blocks Homebrew's tmux. Fix it once:
        make sign-tmux     # rebuild + ad-hoc sign tmux, then run: tmux kill-server
EOF
fi
