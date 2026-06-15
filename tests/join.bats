load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "cr_join marks attachable sessions S and counts the rest N" {
  # pane map: pid 84717 is in tmux as session 'cr', 90001 is NOT.
  panemap="$(mktemp)"
  printf '84717\tcr\n' > "$panemap"
  # abtop rows: pid \t project \t status \t ctx \t model \t task
  abtop_rows="$(printf '84717\tclaude-remote\tExecuting\t49\topus\tdoing things\n90001\tdemo\tIdle\t12\tsonnet\t\n')"

  run bash -c "source '${REPO_ROOT}/lib/claude-remote-lib.sh'; printf '%s\n' \"\$1\" | cr_join \"\$2\"" _ "$abtop_rows" "$panemap"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == S$'\t'cr$'\t'84717$'\t'claude-remote$'\t'Executing$'\t'* ]]
  [[ "${lines[1]}" == N$'\t'1 ]]
}

@test "cr_join reports N=0 when all sessions are attachable" {
  panemap="$(mktemp)"
  printf '84717\tcr\n' > "$panemap"
  abtop_rows="$(printf '84717\tclaude-remote\tExecuting\t49\topus\tx\n')"
  run bash -c "source '${REPO_ROOT}/lib/claude-remote-lib.sh'; printf '%s\n' \"\$1\" | cr_join \"\$2\"" _ "$abtop_rows" "$panemap"
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == N$'\t'0 ]]
}
