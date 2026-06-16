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
  run bash -c "set -u; source '${REPO_ROOT}/lib/claude-remote-lib.sh'; cr_launch foo 0"
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
