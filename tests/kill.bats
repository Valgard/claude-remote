load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

# --- cr_kill_session -----------------------------------------------------------

@test "cr_kill_session terminates a running session" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  cr_make_session work >/dev/null
  run cr_kill_session work
  [ "$status" -eq 0 ]
  run $CR_TMUX has-session -t work
  [ "$status" -ne 0 ]
}

@test "cr_kill_session refuses to kill the keychain anchor" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  run cr_kill_session "$CR_ANCHOR"
  [ "$status" -ne 0 ]
  run $CR_TMUX has-session -t "$CR_ANCHOR"
  [ "$status" -eq 0 ] # the anchor must survive
}

@test "cr_kill_session removes the session's post-exit capture file" {
  export CR_EXIT_DIR="${BATS_TEST_TMPDIR}/exit"
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  cr_make_session work >/dev/null
  mkdir -p "$CR_EXIT_DIR"
  file="$(cr_exit_file work)"
  printf 'stale capture\n' >"$file"
  [ -f "$file" ]
  run cr_kill_session work
  [ "$status" -eq 0 ]
  [ ! -f "$file" ]
}

@test "cr_kill_session rejects an empty session argument" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_kill_session ""
  [ "$status" -ne 0 ]
}
