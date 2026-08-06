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
# Pass terminal focus in/out events through to the running program; Claude Code's
# full-screen TUI relies on them and warns when tmux swallows them (default: off).
cr_ensure_line "$TMUX_CONF" 'set -g focus-events on'
# Prefix+S toggles the status line (claude-remote hides it per session for Claude's
# full-screen TUI; this lets you bring it back to glance at the session name/clock).
cr_ensure_line "$TMUX_CONF" 'bind-key S set-option status'
# Swallow Ctrl+Z in Claude panes (see cr_tmux_ctrl_z_line): with no shell parent
# there is no way back from a suspend, and Claude cannot rebind the key itself.
# cr_tmux_ctrl_z_state decides — never overwrite a C-z binding the user wrote,
# and say so rather than leaving them to believe they are covered.
case "$(cr_tmux_ctrl_z_state "$TMUX_CONF")" in
  ours) ;; # already installed (or hand-written in the multi-line form)
  foreign)
    echo "ℹ️  Eigene C-z-Bindung in ${TMUX_CONF} gefunden — claude-remote lässt sie unverändert."
    echo "    Der Ctrl+Z-Schutz für Claude-Panes ist damit NICHT aktiv."
    ;;
  *)
    # Bare assignment, not a substitution in argument position: only this form
    # lets `set -e` catch a failing cr_tmux_ctrl_z_line (otherwise the empty
    # result would be appended silently, once per install run).
    CTRL_Z_LINE="$(cr_tmux_ctrl_z_line)"
    cr_ensure_line "$TMUX_CONF" "$CTRL_Z_LINE"
    # tmux reads its config only when the server is born, and this project keeps
    # one server alive for weeks via the anchor LaunchAgent — so without this
    # hint the user would believe the net is up while the running server has
    # never seen the binding.
    # shellcheck disable=SC2086
    if $CR_TMUX list-sessions >/dev/null 2>&1; then
      echo "ℹ️  tmux läuft bereits — die neue Zeile greift dort erst nach:"
      echo "    tmux source-file ${TMUX_CONF}   (Sessions bleiben erhalten)"
    fi
    ;;
esac

# Native Local Network anchor (macOS): a persistent, ad-hoc-signed .app launched via
# LaunchServices (open) births the tmux anchor and stays alive as its supervisor, so its
# Local Network grant covers every tmux child; it also subsumes the keychain anchor.
# build-once gates only the expensive clang compile (keeps the ad-hoc cdhash stable so
# the one-time grant persists); the Info.plist copy and ad-hoc re-sign run every install
# (deterministic cdhash → grant survives; self-heals a prior codesign failure). Degrades
# to the script anchor (keychain still works; LAN stays blocked) when the compiler is
# unavailable.
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
    fi
    codesign -s - --force "$APP_DIR"
    AGENT_PROG_A="/usr/bin/open"
    AGENT_PROG_B="$APP_DIR"
  else
    echo "ℹ️  ${CR_CLANG:-clang} not found — using the script anchor (Local Network stays blocked)."
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
