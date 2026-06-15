load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "cr_session_name uses label when given" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_session_name "refactor"
  [ "$status" -eq 0 ]
  [ "$output" = "refactor" ]
}

@test "cr_session_name falls back to basename of cwd" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  cd /tmp
  run cr_session_name ""
  [ "$status" -eq 0 ]
  [ "$output" = "tmp" ]
}

@test "cr_session_name sanitizes characters tmux dislikes" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_session_name "feature/login.v2"
  [ "$status" -eq 0 ]
  [ "$output" = "feature_login_v2" ]
}
