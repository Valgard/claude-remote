load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "claude-remote creates a tmux session named <base>-<pane_pid>" {
  cd /tmp
  # Run launch in no-attach mode so the test is non-interactive.
  run claude-remote --no-attach -l proj
  [ "$status" -eq 0 ]
  # exactly one session, name proj-<digits>
  run bash -c "${CR_TMUX} list-sessions -F '#{session_name}'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^proj-[0-9]+$ ]]
}

@test "the pid in the session name equals the pane_pid" {
  cd /tmp
  run claude-remote --no-attach -l proj
  [ "$status" -eq 0 ]
  local sess pane_pid name_pid
  sess="$(${CR_TMUX} list-sessions -F '#{session_name}')"
  pane_pid="$(${CR_TMUX} display-message -p -t "$sess" '#{pane_pid}')"
  name_pid="${sess##*-}"
  [ "$pane_pid" = "$name_pid" ]
}

@test "claude-remote passes through claude args after --" {
  cd /tmp
  argv_file="$(mktemp)"
  FAKE_CLAUDE_ARGV_FILE="$argv_file" run claude-remote --no-attach -l proj -- --brief --model opus
  [ "$status" -eq 0 ]
  run cat "$argv_file"
  [ "$output" = "--brief --model opus" ]
}

@test "claude-remote errors clearly when -l has no argument" {
  cd /tmp
  run claude-remote -l
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires an argument"* ]]
}

@test "cr_launch does not crash without a -- separator under set -u" {
  cd /tmp
  run bash -c "set -u; source '${REPO_ROOT}/lib/claude-remote-lib.sh'; cr_launch foo 0 0"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^foo-[0-9]+$ ]]
}

@test "claude-remote resolves its lib when invoked via a symlink (install scenario)" {
  cd /tmp
  linkdir="$(mktemp -d)"
  ln -s "${REPO_ROOT}/bin/claude-remote" "${linkdir}/claude-remote"
  run "${linkdir}/claude-remote" --no-attach -l linktest
  [ "$status" -eq 0 ]
  run bash -c "${CR_TMUX} list-sessions -F '#{session_name}'"
  [[ "$output" =~ ^linktest-[0-9]+$ ]]
}

@test "claude-remote hides the tmux status line for its sessions" {
  cd /tmp
  run claude-remote --no-attach -l statustest
  [ "$status" -eq 0 ]
  sess="$(${CR_TMUX} list-sessions -F '#{session_name}')"
  run bash -c "${CR_TMUX} show-options -t '$sess' status"
  [[ "$output" == *"off"* ]]
}

# A recording tmux stub: logs the new-session argv (one element per line) and
# answers display-message with a fixed pid, so we can assert the exact command
# cr_launch constructs without a real tmux server or a real ~/.zshrc.
_cr_make_tmux_stub() {
  local stub="$1" rec="$2"
  cat >"$stub" <<EOF
#!/usr/bin/env bash
case "\$1" in
  new-session) shift; printf '%s\n' "\$@" >>"$rec" ;;
  display-message) echo 4242 ;;
esac
exit 0
EOF
  chmod +x "$stub"
}

@test "cr_launch wraps claude in a login shell when CR_LOGIN_SHELL=1" {
  cd /tmp
  local stub="${BATS_TEST_TMPDIR}/tmux-stub" rec="${BATS_TEST_TMPDIR}/argv"
  _cr_make_tmux_stub "$stub" "$rec"
  run env CR_TMUX="$stub" CR_LOGIN_SHELL=1 \
      CR_EXIT_DIR="${BATS_TEST_TMPDIR}/exit" \
      bash -c "set -uo pipefail; source '${REPO_ROOT}/lib/claude-remote-lib.sh'; cr_launch proj 0 0 -- --brief"
  [ "$status" -eq 0 ]
  # the wrapper script is exactly ONE argv element and hands over to claude last;
  # what runs before the exec is pinned by the login-shell behaviour tests below
  [ "$(grep -cE '(^|; )exec command claude "\$@"$' "$rec")" -eq 1 ]
  grep -qx 'zsh' "$rec"
  grep -qx -- '-lic' "$rec"
  grep -qx 'cr' "$rec"
  grep -qx -- '--brief' "$rec"
  # no bare `claude` element on its own line in the login-shell form
  run grep -qx 'claude' "$rec"
  [ "$status" -ne 0 ]
}

@test "cr_launch execs claude directly when CR_LOGIN_SHELL=0" {
  cd /tmp
  local stub="${BATS_TEST_TMPDIR}/tmux-stub" rec="${BATS_TEST_TMPDIR}/argv"
  _cr_make_tmux_stub "$stub" "$rec"
  run env CR_TMUX="$stub" CR_LOGIN_SHELL=0 \
      CR_EXIT_DIR="${BATS_TEST_TMPDIR}/exit" \
      bash -c "set -uo pipefail; source '${REPO_ROOT}/lib/claude-remote-lib.sh'; cr_launch proj 0 0 -- --brief"
  [ "$status" -eq 0 ]
  grep -qx 'claude' "$rec"
  grep -qx -- '--brief' "$rec"
  run grep -qx 'zsh' "$rec"
  [ "$status" -ne 0 ]
}

# The login-shell launch for real, against a ZDOTDIR of our own: zsh reads OUR
# .zshrc, never the developer's. GLOBAL_RCS off keeps /etc/z* out as well, which
# is not optional: macOS' /etc/zprofile runs path_helper, and that moves
# /usr/local/bin — where a real `claude` may be installed — ahead of the stub dir.
# The isolated server is born by the first new-session, so it and its panes
# inherit these exports.
_cr_login_shell_env() {
  ZDOTDIR="${BATS_TEST_TMPDIR}/zdot"
  mkdir -p "$ZDOTDIR"
  echo 'unsetopt GLOBAL_RCS' >"${ZDOTDIR}/.zshenv"
  : >"${ZDOTDIR}/.zshrc"
  export ZDOTDIR CR_LOGIN_SHELL=1 FAKE_CLAUDE_ENV_FILE="${BATS_TEST_TMPDIR}/claude-env"
}

# The pane runs asynchronously to cr_launch; wait up to 5 s for the stub's report.
_cr_await_claude_env() {
  local i
  for i in $(seq 50); do
    [ -f "$FAKE_CLAUDE_ENV_FILE" ] && return 0
    sleep 0.1
  done
  echo "fake-claude never reported from the pane" >&2
  return 1
}

@test "a login-shell launch loads direnv for the start directory before claude starts" {
  _cr_login_shell_env
  # Stand-in for the function `eval "$(direnv hook zsh)"` defines in ~/.zshrc. zsh
  # only calls it before a prompt or after a cd, and `zsh -c` reaches neither, so
  # it runs only if the launch fires it. It records where it ran.
  echo '_direnv_hook() { export CR_DIRENV_PROBE="${PWD:A}"; }' >"${ZDOTDIR}/.zshrc"
  cd /tmp
  run claude-remote --no-attach -l direnv
  [ "$status" -eq 0 ]
  _cr_await_claude_env
  grep -qx "CR_DIRENV_PROBE=$(cd /tmp && pwd -P)" "$FAKE_CLAUDE_ENV_FILE"
}

@test "a login-shell launch that loads direnv still leaves claude as the pane process" {
  _cr_login_shell_env
  # The TRAPEXIT is what makes this test bite: zsh execs the last command of a
  # `-c` script implicitly, so a launch that lost its `exec` would keep the pid
  # anyway — unless an exit trap obliges zsh to outlive it, as a ~/.zshrc may.
  printf '%s\n' '_direnv_hook() { export CR_DIRENV_PROBE=1; }' 'TRAPEXIT() { :; }' >"${ZDOTDIR}/.zshrc"
  cd /tmp
  run claude-remote --no-attach -l pid
  [ "$status" -eq 0 ]
  _cr_await_claude_env
  local sess pane_pid
  sess="$(${CR_TMUX} list-sessions -F '#{session_name}')"
  pane_pid="$(${CR_TMUX} display-message -p -t "$sess" '#{pane_pid}')"
  grep -qx "FAKE_CLAUDE_PID=${pane_pid}" "$FAKE_CLAUDE_ENV_FILE"
  [ "${sess##*-}" = "$pane_pid" ]
}

@test "a login-shell launch without a direnv hook starts claude without an error" {
  _cr_login_shell_env
  cd /tmp
  run claude-remote --no-attach -l nohook
  [ "$status" -eq 0 ]
  _cr_await_claude_env
  local sess
  sess="$(${CR_TMUX} list-sessions -F '#{session_name}')"
  # an unguarded call would leave `command not found: _direnv_hook` in the pane
  run bash -c "${CR_TMUX} capture-pane -p -S - -E - -t '$sess'"
  [ "$status" -eq 0 ]
  [[ "$output" != *_direnv_hook* ]]
}
