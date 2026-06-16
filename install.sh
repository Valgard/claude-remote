#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/claude-remote-lib.sh disable=SC1091
. "${HERE}/lib/claude-remote-lib.sh"
BIN_DIR="${HOME}/.local/bin"
mkdir -p "$BIN_DIR"
ln -sf "${HERE}/bin/claude-remote" "${BIN_DIR}/claude-remote"
ln -sf "${HERE}/bin/claude-remote-pick" "${BIN_DIR}/claude-remote-pick"

# tmux: let the active client drive the size when multiple clients attach.
# cr_ensure_line is newline-safe and idempotent (won't merge onto a no-newline
# last line, won't duplicate on re-run).
TMUX_CONF="${HOME}/.tmux.conf"
cr_ensure_line "$TMUX_CONF" 'setw -g aggressive-resize on'

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
