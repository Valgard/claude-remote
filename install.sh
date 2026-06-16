#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/claude-remote-lib.sh disable=SC1091
. "${HERE}/lib/claude-remote-lib.sh"
BIN_DIR="${HOME}/.local/bin"
mkdir -p "$BIN_DIR"
ln -sf "${HERE}/bin/claude-remote" "${BIN_DIR}/claude-remote"
ln -sf "${HERE}/bin/claude-remote-pick" "${BIN_DIR}/claude-remote-pick"

# tmux: size the window to the most recently active client, so the Mac is not
# permanently shrunk to the iPad's smaller resolution while both are attached —
# it resizes back as soon as the Mac is the active client again. aggressive-resize
# helps older size modes. cr_ensure_line is newline-safe and idempotent.
TMUX_CONF="${HOME}/.tmux.conf"
cr_ensure_line "$TMUX_CONF" 'setw -g aggressive-resize on'
cr_ensure_line "$TMUX_CONF" 'set -g window-size latest'
# Prefix+S toggles the status line (claude-remote hides it per session for Claude's
# full-screen TUI; this lets you bring it back to glance at the session name/clock).
cr_ensure_line "$TMUX_CONF" 'bind-key S set-option status'

cat <<EOF
Installed claude-remote and claude-remote-pick to ${BIN_DIR}.

1) Wrap your existing claude() zsh function so it launches via claude-remote:

   claude() {
     local git_root=\$(git rev-parse --show-toplevel 2>/dev/null)
     if [[ -n "\$git_root" ]]; then
       (cd "\$git_root" && claude-remote -- --allow-dangerously-skip-permissions --brief "\$@")
     else
       claude-remote -- --allow-dangerously-skip-permissions --brief "\$@"
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
