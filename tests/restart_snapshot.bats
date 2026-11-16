load helpers

setup() {
  cr_setup
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  LSTART='Mon Nov 16 19:56:19 2026'
}
teardown() { cr_teardown; }

# mk <name> <start-dir> <args> <session_id> [kind]: start a session, fake its ps output
# and session file; echoes the pane pid.
mk() {
  local pid
  $CR_TMUX new-session -d -s "$1" -c "$2" -- claude >/dev/null
  pid="$($CR_TMUX display-message -p -t "$1" '#{pane_pid}')"
  printf 'claude %s\n' "$3" >"$FAKE_PS_DIR/$pid.args"
  printf '%s\n' "$LSTART" >"$FAKE_PS_DIR/$pid.lstart"
  printf '{"sessionId":"%s","kind":"%s","status":"idle","procStart":"%s"}' \
    "$4" "${5:-interactive}" "$LSTART" >"$CR_SESSIONS_DIR/$pid.json"
  echo "$pid"
}

@test "a healthy session is ok with its id, status and args" {
  mk proj-1 /tmp "--brief --resume t" S1
  run cr_restart_snapshot
  [ "$status" -eq 0 ]
  [ "$(cut -f4,6,7,9 <<<"$output")" = $'ok\tS1\tidle\t--brief --resume t' ]
}

@test "the anchor session is never listed" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  mk proj-1 /tmp "" S1
  run cr_restart_snapshot
  [ "$(wc -l <<<"$output")" -eq 1 ]
  [ "$(cut -f1 <<<"$output")" = proj-1 ]
}

@test "a stale session file for a reused pid is not restorable" {
  pid=$(mk proj-1 /tmp "" S1)
  printf 'Thu Jan  1 00:00:00 2026\n' >"$FAKE_PS_DIR/$pid.lstart"
  run cr_restart_snapshot
  [ "$(cut -f4,5 <<<"$output")" = $'skip\tSession-Datei gehört zu einem anderen Prozess' ]
}

@test "a missing session file is skipped" {
  pid=$(mk proj-1 /tmp "" S1)
  rm "$CR_SESSIONS_DIR/$pid.json"
  run cr_restart_snapshot
  [ "$(cut -f4,5 <<<"$output")" = $'skip\tkeine Session-Datei' ]
}

@test "a garbage session file is skipped" {
  pid=$(mk proj-1 /tmp "" S1)
  printf 'not json' >"$CR_SESSIONS_DIR/$pid.json"
  run cr_restart_snapshot
  [ "$(cut -f4,5 <<<"$output")" = $'skip\tSession-Datei unlesbar' ]
}

@test "a non-claude pane is skipped" {
  pid=$(mk proj-1 /tmp "" S1)
  printf 'sleep 600\n' >"$FAKE_PS_DIR/$pid.args"
  run cr_restart_snapshot
  [ "$(cut -f4,5 <<<"$output")" = $'skip\tkein Claude-Prozess' ]
}

@test "a non-interactive kind is skipped" {
  mk proj-1 /tmp "" S1 headless
  run cr_restart_snapshot
  [ "$(cut -f4,5 <<<"$output")" = $'skip\tkeine interaktive Session' ]
}

@test "an empty session id is skipped" {
  mk proj-1 /tmp "" ""
  run cr_restart_snapshot
  [ "$(cut -f4,5 <<<"$output")" = $'skip\tkeine Session-ID' ]
}

@test "a start path with space and comma survives" {
  d="$BATS_TEST_TMPDIR/Feist, Raymond E"
  mkdir -p "$d"
  mk feist-1 "$d" "" S1
  run cr_restart_snapshot
  [ "$(cut -f3 <<<"$output")" = "$d" ]
}

@test "a session that last worked in a worktree carries that directory" {
  mk proj-1 /tmp "" S1
  mkdir -p "$CR_PROJECTS_DIR/-tmp"
  printf '{"cwd":"/tmp/.worktrees/x","type":"user"}\n' >"$CR_PROJECTS_DIR/-tmp/S1.jsonl"
  run cr_restart_snapshot
  [ "$(cut -f8 <<<"$output")" = /tmp/.worktrees/x ]
}

@test "a last cwd equal to the start path is left empty" {
  d="$(cd /tmp && pwd -P)"
  mk proj-1 "$d" "" S1
  mkdir -p "$CR_PROJECTS_DIR/-tmp"
  printf '{"cwd":"%s","type":"user"}\n' "$d" >"$CR_PROJECTS_DIR/-tmp/S1.jsonl"
  run cr_restart_snapshot
  [ "$(cut -f8 <<<"$output")" = "" ]
}

@test "no server: returns 1" {
  run cr_restart_snapshot
  [ "$status" -eq 1 ]
}
