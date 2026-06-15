load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "cr_pane_map emits pane_pid<TAB>session for each session" {
  pid="$(cr_make_session demo)"
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_pane_map
  [ "$status" -eq 0 ]
  [[ "$output" == "${pid}"$'\t'demo ]]
}

@test "cr_pane_map is empty when no sessions exist" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_pane_map
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
