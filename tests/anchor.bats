load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "cr_ensure_anchor creates the holding session when none exists" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_ensure_anchor
  [ "$status" -eq 0 ]
  run $CR_TMUX has-session -t "$CR_ANCHOR"
  [ "$status" -eq 0 ]
}

@test "cr_ensure_anchor is a no-op when a server is already running" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  cr_make_session work >/dev/null # a pre-existing server with a foreign session
  run cr_ensure_anchor
  [ "$status" -eq 0 ]
  run $CR_TMUX has-session -t "$CR_ANCHOR"
  [ "$status" -ne 0 ] # must NOT have planted the anchor into the existing server
}

@test "cr_ensure_anchor is idempotent (no second anchor session)" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  cr_ensure_anchor
  cr_ensure_anchor
  run bash -c "$CR_TMUX list-sessions -F '#{session_name}' | grep -c \"^${CR_ANCHOR}\$\""
  [ "$output" = "1" ]
}

@test "cr_menu_lines fallback hides the anchor holding session" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  export CR_ABTOP=/nonexistent # force the fallback (abtop unavailable)
  cr_ensure_anchor
  cr_make_session work >/dev/null # a real fake-claude session
  run cr_menu_lines
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'work'
  ! echo "$output" | grep -q "$CR_ANCHOR"
}
