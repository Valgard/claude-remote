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
  # Where tmux puts that socket, recorded while TMUX_TMPDIR is still the one the server
  # will use (cr_prod_setup moves it, cr_prod_teardown unsets it). And the tmux the
  # teardowns end servers with, resolved before the stub dir goes onto PATH below.
  CR_SOCKET_FILE="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/${CR_SOCKET}"
  CR_REAL_TMUX="$(command -v tmux)"
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
  # The direnv limits start from their defaults, whatever the developer's shell set.
  export CR_LOGIN_SHELL=0
  unset CR_DIRENV_TIMEOUT CR_DIRENV_HOLD
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
  cr_prod_teardown
  # The -L server goes by the socket path and the tmux cr_setup recorded, never through
  # CR_TMUX, which may still name a stand-in that a failed test did not restore. A server
  # that survives keeps bats' fd 3 open and hangs the run. tmux leaves its socket file
  # behind when the server exits (tmux 3.8, after kill-server and a natural exit alike),
  # so the file is deleted here, but only once nothing accepts on it any more: deleting
  # a live server's socket would leave that server out of reach of -L and -S alike, so
  # a survivor fails the test instead. A -L server started after cr_prod_setup lives
  # under that dir and went with cr_prod_teardown above.
  [ -S "${CR_SOCKET_FILE:-}" ] || return 0
  "$CR_REAL_TMUX" -S "$CR_SOCKET_FILE" kill-server 2>/dev/null || true
  local tries=0
  while cr_socket_live "$CR_SOCKET_FILE" && [ "$tries" -lt 25 ]; do
    sleep 0.2
    tries=$((tries + 1))
  done
  if cr_socket_live "$CR_SOCKET_FILE"; then
    echo "cr_teardown: a server still accepts on $CR_SOCKET_FILE; socket kept" >&2
    return 1
  fi
  rm -f "$CR_SOCKET_FILE"
}

# cr_socket_live <path>: true while a server accepts connections on <path>. A plain
# connect, not a tmux command, so it also answers for a server of another tmux version.
# (`nc -z -U` cannot stand in: it fails against a live socket too, measured on macOS.)
cr_socket_live() {
  /usr/bin/perl -MIO::Socket::UNIX -e 'exit(IO::Socket::UNIX->new(Peer => $ARGV[0]) ? 0 : 1)' "$1"
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
      "${CR_REAL_TMUX:-tmux}" -S "$sock" kill-server 2>/dev/null || true
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

# --- login-shell launches ----------------------------------------------------------
# cr_login_shell_env: run the CR_LOGIN_SHELL=1 launch for real, against a ZDOTDIR of
# the test's own, so zsh reads OUR startup files and never the developer's. Its
# .zshenv turns GLOBAL_RCS off, which is not optional: macOS' /etc/zprofile runs
# path_helper, and that moves /usr/local/bin (where a real `claude` may live) ahead of
# the stub dir. It cannot keep out /etc/zshenv, which zsh reads before anything else,
# so the stub dir is put first again right after. Any DIRENV_* state of the shell
# that ran bats is dropped, or direnv in the pane would set out to unload it.
# direnv itself is sandboxed even where no test hooks it, because the pane script
# asks `direnv status` whenever no hook is defined: a config dir with an empty
# direnvrc (without one direnv falls back to ~/.direnvrc) and an empty whitelist, a
# data dir of the test's own, so the developer's allow list is never read, written
# or `direnv allow`ed. TMPDIR and CR_EXIT_DIR keep the pane's error file and exit
# capture out of the developer's temp dir. The isolated server is born by the first
# new-session, so it and its panes inherit all of this. Tests append to
# $ZDOTDIR/.zshrc themselves.
cr_login_shell_env() {
  ZDOTDIR="${BATS_TEST_TMPDIR}/zdot"
  mkdir -p "$ZDOTDIR"
  {
    echo 'unsetopt GLOBAL_RCS'
    # shellcheck disable=SC2016 # expanded by the pane's zsh, not here
    printf 'path=(%q $path)\n' "$STUB_BIN"
  } >"${ZDOTDIR}/.zshenv"
  : >"${ZDOTDIR}/.zshrc"
  unset DIRENV_DIR DIRENV_FILE DIRENV_DIFF DIRENV_WATCHES
  export DIRENV_CONFIG="${BATS_TEST_TMPDIR}/direnv-config" XDG_DATA_HOME="${BATS_TEST_TMPDIR}/xdg-data"
  mkdir -p "$DIRENV_CONFIG" "$XDG_DATA_HOME"
  : >"${DIRENV_CONFIG}/direnvrc"
  cr_direnv_allow
  export TMPDIR="${BATS_TEST_TMPDIR}/tmp" CR_EXIT_DIR="${BATS_TEST_TMPDIR}/exit"
  mkdir -p "$TMPDIR"
  export ZDOTDIR CR_LOGIN_SHELL=1 FAKE_CLAUDE_ENV_FILE="${BATS_TEST_TMPDIR}/claude-env"
}

# cr_direnv_allow <dir>…: the sandbox's whitelist allows exactly the .envrc in each
# given dir, and nothing else (none given: everything is blocked). direnv compares
# resolved paths, hence pwd -P.
cr_direnv_allow() {
  local d
  {
    printf '[whitelist]\nexact = [\n'
    for d in "$@"; do printf '  "%s/.envrc",\n' "$(cd "$d" && pwd -P)"; done
    printf ']\n'
  } >"${DIRENV_CONFIG}/direnv.toml"
}

# cr_await <seconds> <command…>: poll until the command succeeds.
cr_await() {
  local i n=$(($1 * 10))
  shift
  for ((i = 0; i < n; i++)); do
    "$@" && return 0
    sleep 0.1
  done
  echo "timed out waiting for: $*" >&2
  return 1
}

# cr_await_claude_env [seconds]: the pane runs asynchronously to cr_launch; wait (5 s
# by default) for fake-claude to report from inside it.
cr_await_claude_env() { cr_await "${1:-5}" test -f "$FAKE_CLAUDE_ENV_FILE"; }

# cr_launch_in <dir> [claude args…]: a detached claude-remote launch from <dir>; the
# session name it prints lands in $sess.
cr_launch_in() {
  local dir="$1"
  shift
  sess="$(cd "$dir" && claude-remote --no-attach -l direnv -- "$@")"
}

# cr_direnv_option: what the pane script reported for $sess (ok, or the problem).
cr_direnv_option() {
  ${CR_TMUX} display-message -p -t "$sess" '#{@cr_direnv}'
}

# cr_direnv_sandbox <dir>…: the real direnv in the sandbox cr_login_shell_env set
# up, allowing the .envrc in each given dir (cr_direnv_allow), and hooked into the
# ZDOTDIR's .zshrc the way a user's ~/.zshrc does. Skips the test when direnv is not
# installed.
cr_direnv_sandbox() {
  command -v direnv >/dev/null || skip "direnv is not installed"
  cr_direnv_allow "$@"
  # shellcheck disable=SC2016 # expanded by the pane's zsh, not here
  echo 'eval "$(direnv hook zsh)"' >>"${ZDOTDIR}/.zshrc"
}

# cr_pane_text <session>: everything the session's pane has printed, blank lines
# dropped and wrapped lines joined, so an assertion cannot depend on where the pane
# width happened to break a long path.
cr_pane_text() {
  ${CR_TMUX} capture-pane -p -J -S - -E - -t "$1" | grep -v '^$'
}
