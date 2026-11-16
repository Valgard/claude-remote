load helpers

setup() {
  cr_setup
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
}
teardown() { cr_teardown; }

@test "session record reads id, kind, status and start" {
  printf '{"sessionId":"S1","kind":"interactive","status":"busy","procStart":"Mon Nov 16 19:56:19 2026"}' >"$CR_SESSIONS_DIR/111.json"
  run cr_session_record 111
  [ "$output" = $'S1\tinteractive\tbusy\tMon Nov 16 19:56:19 2026' ]
}

@test "session record: missing file returns 1, garbage returns 2" {
  run cr_session_record 999
  [ "$status" -eq 1 ]
  printf 'not json' >"$CR_SESSIONS_DIR/112.json"
  run cr_session_record 112
  [ "$status" -eq 2 ]
}

@test "start-time match tolerates day padding, rejects another start" {
  printf 'Tue Oct  6 15:44:51 2026\n' >"$FAKE_PS_DIR/7.lstart"
  cr_proc_start_matches 7 "Tue Oct 6 15:44:51 2026"
  run cr_proc_start_matches 7 "Tue Oct 6 15:44:52 2026"
  [ "$status" -ne 0 ]
}

@test "claude args drop argv0; a non-claude process returns 1" {
  printf 'claude --brief --resume x\n' >"$FAKE_PS_DIR/8.args"
  [ "$(cr_proc_claude_args 8)" = "--brief --resume x" ]
  printf '/bin/zsh -l\n' >"$FAKE_PS_DIR/9.args"
  run cr_proc_claude_args 9
  [ "$status" -eq 1 ]
}

@test "last cwd is the newest record's, a torn line is skipped" {
  f="$BATS_TEST_TMPDIR/t.jsonl"
  printf '%s\n' '{"cwd":"/a"}' '{"cwd":"/b/.worktrees/x"}' '{"cwd":"/tor' >"$f"
  [ "$(cr_last_cwd "$f")" = "/b/.worktrees/x" ]
}

@test "last cwd: a torn last line without newline costs one candidate, not the answer" {
  # The reversers glue the unterminated fragment onto the previous line, so that line
  # is lost (as in cr_session_title); the next-older record still answers.
  f="$BATS_TEST_TMPDIR/t.jsonl"
  printf '%s\n' '{"cwd":"/a"}' '{"cwd":"/b/.worktrees/x"}' >"$f"
  printf '{"cwd":"/tor' >>"$f"
  [ "$(cr_last_cwd "$f")" = "/a" ]
}
