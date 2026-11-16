# Shared bats helpers. Source from each .bats file: `load helpers`.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
export CR_REPO="$REPO_ROOT"

cr_setup() {
  # Isolated tmux server — never touches the user's real sessions. `-L` isolates
  # the *sessions*, `-f /dev/null` the *config*: without it every test server
  # sources the developer's ~/.tmux.conf, so results depend on the host machine
  # and an assertion can pass on the user's own settings instead of ours.
  CR_SOCKET="cr_test_${BATS_SUITE_TEST_NUMBER}_$$"
  export CR_TMUX="tmux -f /dev/null -L ${CR_SOCKET}"
  export CR_ABTOP="${REPO_ROOT}/tests/fixtures/abtop-stub"
  # Isolate the transcript lookup too: without this, any test driving cr_menu_lines
  # probes the developer's real ~/.claude/projects (~100 dirs). Harmless only as long
  # as no fixture carries a session_id — pin it here rather than per test file.
  export CR_PROJECTS_DIR="${BATS_TEST_TMPDIR}/projects"
  mkdir -p "$CR_PROJECTS_DIR"
  # Session files and `ps` for the restart readers: a sessions dir plus a ps stub that
  # serves canned answers from $FAKE_PS_DIR/<pid>.{args,lstart}.
  export CR_SESSIONS_DIR="${BATS_TEST_TMPDIR}/sessions" CR_PS="${REPO_ROOT}/tests/fixtures/ps-stub" FAKE_PS_DIR="${BATS_TEST_TMPDIR}/ps"
  mkdir -p "$CR_SESSIONS_DIR" "$FAKE_PS_DIR"
  # Pin the launch seam to direct exec so the suite never sources the real
  # ~/.zshrc (CR_LOGIN_SHELL=1 would run `zsh -lic` in the pane). Hermetic.
  export CR_LOGIN_SHELL=0
  # Never reach the real anchor: pgrep/launchctl are pinned to `true`; tests that need a
  # working one install a `stub`. CR_ANCHOR_WAIT keeps the give-up path short.
  export CR_PGREP=true CR_LAUNCHCTL=true CR_ANCHOR_WAIT=2
  # Restart state (snapshot dir) stays in the test's tmp dir; the post-launch settle
  # is 1 s so the restore tests stay quick.
  export CR_RESTART_DIR="$BATS_TEST_TMPDIR" CR_RESTORE_SETTLE=1
  # Inject a stub named `claude` ahead of the real one on PATH. The isolated
  # tmux server started below inherits this PATH and resolves `claude` to the stub.
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_BIN"
  ln -sf "${REPO_ROOT}/tests/fixtures/fake-claude" "${STUB_BIN}/claude"
  export PATH="${STUB_BIN}:${REPO_ROOT}/bin:${PATH}"
}

cr_teardown() {
  # Production-shape servers first: it unsets TMUX_TMPDIR, which would otherwise
  # relocate the -L socket below and miss a server started before cr_prod_setup.
  cr_prod_teardown
  ${CR_TMUX} kill-server 2>/dev/null || true
}

# --- production-shape tests ------------------------------------------------------
# A "production-shape" test drives a tmux WITHOUT -L/-S, as the real CR_TMUX=tmux does.
# Such a tmux resolves its socket from $TMUX when that is set, else from TMUX_TMPDIR —
# and these tests run inside panes of the user's real server, whose socket $TMUX names.
# The only isolation is TMUX_TMPDIR plus an unset TMUX, so it is checked, not trusted.

# cr_prod_setup: isolate the default socket under a fresh short dir in /tmp (the bats
# tmp path exceeds the macOS unix-socket path limit) and unset TMUX. TMUX_TMPDIR is
# the physical path, because tmux reports its socket with symlinks resolved.
cr_prod_setup() {
  unset TMUX
  CR_PROD_TMPDIR="$(mktemp -d /tmp/crtd.XXXXXX)"
  [ -d "$CR_PROD_TMPDIR" ] || return 1
  TMUX_TMPDIR="$(cd "$CR_PROD_TMPDIR" && pwd -P)"
  export TMUX_TMPDIR
}

# cr_prod_fence <tmux command…>: fail unless TMUX_TMPDIR is set, TMUX is unset, and the
# socket of the server that command reaches lies under TMUX_TMPDIR. Call it after
# starting a server and BEFORE any kill-server or restart action.
cr_prod_fence() {
  local sock
  if [ -z "${TMUX_TMPDIR:-}" ] || [ -n "${TMUX:-}" ]; then
    echo "fence: TMUX_TMPDIR must be set and TMUX unset" >&2
    return 1
  fi
  if ! sock="$("$@" display-message -p '#{socket_path}' 2>/dev/null)"; then
    echo "fence: no server behind '$*'" >&2
    return 1
  fi
  case $sock in
    "$TMUX_TMPDIR"/*) return 0 ;;
  esac
  echo "fence: '$*' reaches $sock, outside $TMUX_TMPDIR" >&2
  return 1
}

# cr_prod_teardown: end every server whose socket lies under the test's TMUX_TMPDIR,
# addressed by that socket (-S) and never through the default lookup, then remove the
# dir. A no-op for tests that never called cr_prod_setup.
cr_prod_teardown() {
  [ -n "${CR_PROD_TMPDIR:-}" ] || return 0
  local sock
  if [ -n "${TMUX_TMPDIR:-}" ] && [ -d "$TMUX_TMPDIR" ]; then
    find "$TMUX_TMPDIR" -type s | while IFS= read -r sock; do
      tmux -S "$sock" kill-server 2>/dev/null || true
    done
  fi
  rm -rf "$CR_PROD_TMPDIR"
  unset CR_PROD_TMPDIR TMUX_TMPDIR
}

# Start an isolated tmux session running the fake-claude stub.
# Usage: cr_make_session <session-name>  -> echoes the pane_pid
cr_make_session() {
  local name="$1"
  ${CR_TMUX} new-session -d -s "$name" -- claude >/dev/null
  ${CR_TMUX} display-message -p -t "$name" '#{pane_pid}'
}

# Write an executable stub into the per-test bin dir and echo its path.
# Usage: export CR_PGREP="$(stub pgrep 'echo 12345')"
# Bodies run as child processes: the lib's unexported CR_ANCHOR is empty there, so
# spell the anchor name literally (_cr_anchor). CR_TMUX is exported by cr_setup.
stub() {
  local path="${STUB_BIN}/$1"
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$path"
  chmod +x "$path"
  printf '%s\n' "$path"
}

# agent_stub <body>: a launchctl stand-in whose `print` succeeds (the agent is loaded,
# so the restart's preflight passes) and whose other calls (the kickstart) run <body>.
agent_stub() {
  stub launchctl "[ \"\$1\" = print ] && exit 0
$1"
}
