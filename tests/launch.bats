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
  # the wrapper script is exactly ONE argv element (whole-line, fixed-string)
  grep -qFx 'exec command claude "$@"' "$rec"
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
