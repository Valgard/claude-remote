#!/usr/bin/env bats
load helpers

setup() {
  cr_setup
  source "$REPO_ROOT/lib/claude-remote-lib.sh"
  f="$BATS_TEST_TMPDIR/snap.tsv"
}
teardown() { cr_teardown; }

# One snapshot row: name pid start verdict reason session_id status last_cwd args
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }

@test "one session comes back with rewritten args under its label" {
  export FAKE_CLAUDE_ARGV_FILE="$BATS_TEST_TMPDIR/argv"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  row proj-11 11 /tmp ok "" S1 idle "" "--brief --name old --resume t" >"$f"
  run cr_restore_sessions "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wiederhergestellt: 1 von 1"* ]]
  [[ "$output" == *"Weggelassene Argumente:"* ]]
  [[ "$output" == *"  - proj-11: --name old --resume t"* ]]
  [ "$(cat "$FAKE_CLAUDE_ARGV_FILE")" = "--brief --resume S1" ]
  $CR_TMUX list-sessions -F '#{session_name}' | grep -q '^proj-[0-9]*$'
}

@test "two sessions with the same label both come back" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  {
    row proj-11 11 /tmp ok "" S1 idle "" ""
    row proj-12 12 /tmp ok "" S2 idle "" ""
  } >"$f"
  run cr_restore_sessions "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wiederhergestellt: 2 von 2"* ]]
  [ "$($CR_TMUX list-sessions -F '#{session_name}' | grep -c '^proj-[0-9]*$')" -eq 2 ]
}

@test "a missing start dir fails that row only" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  {
    row gone-11 11 /nonexistent ok "" S1 idle "" ""
    row proj-12 12 /tmp ok "" S2 idle "" ""
  } >"$f"
  run cr_restore_sessions "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Fehlgeschlagen:"* ]]
  [[ "$output" == *"  - gone-11: Startordner fehlt"* ]]
  [[ "$output" == *"Wiederhergestellt: 1 von 2"* ]]
  [ "$($CR_TMUX list-sessions -F '#{session_name}' | grep -c '^proj-[0-9]*$')" -eq 1 ]
}

@test "skip rows are ignored" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  {
    row skipme-5 5 /tmp skip "keine Session-Datei" "" "" "" ""
    row proj-12 12 /tmp ok "" S2 idle "" ""
  } >"$f"
  run cr_restore_sessions "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wiederhergestellt: 1 von 1"* ]]
  [[ "$output" != *"skipme"* ]]
}

@test "a session that exits at once is reported with the last line of its output" {
  export FAKE_CLAUDE_EXIT_LINES='noise from zshrc\nNo conversation found\n' CR_EXIT_DIR="$BATS_TEST_TMPDIR/exit"
  CR_RESTORE_SETTLE=3
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  row proj-11 11 /tmp ok "" S1 idle "" "" >"$f"
  run cr_restore_sessions "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"  - proj-11: beendete sich sofort: No conversation found"* ]]
  [[ "$output" == *"Wiederhergestellt: 0 von 1"* ]]
}

@test "a start path with space and comma restores there" {
  d="$BATS_TEST_TMPDIR/Feist, Raymond E"
  mkdir -p "$d"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  row proj-11 11 "$d" ok "" S1 idle "" "" >"$f"
  run cr_restore_sessions "$f"
  [ "$status" -eq 0 ]
  new="$($CR_TMUX list-sessions -F '#{session_name}' | grep '^proj-[0-9]*$')"
  [ "$($CR_TMUX display-message -p -t "$new" '#{pane_start_path}')" = "$(cd "$d" && pwd -P)" ] ||
    [ "$($CR_TMUX display-message -p -t "$new" '#{pane_start_path}')" = "$d" ]
}

@test "execute stops, restarts via the agent and restores" {
  export CR_LAUNCHCTL="$(stub launchctl '$CR_TMUX new-session -d -s _cr_anchor')"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  old=$(cr_server_pid)
  row proj-11 11 /tmp ok "" S1 idle "" "" >"$f"
  run cr_restart_execute "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wiederhergestellt: 1 von 1"* ]]
  [ "$(cr_server_pid)" != "$old" ]
  $CR_TMUX list-sessions -F '#{session_name}' | grep -q '^proj-[0-9]*$'
}

@test "execute reports the retry command when no server comes up" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  row proj-11 11 /tmp ok "" S1 idle "" "" >"$f"
  CR_ANCHOR_WAIT=1 run cr_restart_execute "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Anchor/Server kam nicht hoch."* ]]
  [[ "$output" == *"claude-remote-pick --restore $f"* ]]
}

@test "execute prints the snapshot and hint when a restore fails" {
  export CR_LAUNCHCTL="$(stub launchctl '$CR_TMUX new-session -d -s _cr_anchor')"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  row gone-11 11 /nonexistent ok "" S1 idle "" "" >"$f"
  run cr_restart_execute "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Snapshot: $f"* ]]
  [[ "$output" == *"claude-remote-pick --restore $f"* ]]
}

@test "--restore refuses without an anchor server" {
  row proj-11 11 /tmp ok "" S1 idle "" "" >"$f"
  run claude-remote-pick --restore "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Kein Anchor-Server läuft."* ]]
}

@test "--restore refuses when a session only begins with the anchor's name" {
  $CR_TMUX new-session -d -s "${CR_ANCHOR}_old"
  row proj-11 11 /tmp ok "" S1 idle "" "" >"$f"
  run claude-remote-pick --restore "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Kein Anchor-Server läuft."* ]]
}

@test "--restore restores into a running anchor server" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  row proj-11 11 /tmp ok "" S1 idle "" "" >"$f"
  run claude-remote-pick --restore "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wiederhergestellt: 1 von 1"* ]]
}

# A session file for <pid> naming <sid>; ps-stub answers lstart "$3" for that pid.
live_session() {
  printf '%s\n' "$3" >"$FAKE_PS_DIR/$1.lstart"
  printf '{"sessionId":"%s","kind":"interactive","status":"idle","procStart":"%s"}' \
    "$2" "$4" >"$CR_SESSIONS_DIR/$1.json"
}

@test "a session already held by a live process is not launched again" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  live_session 777 S1 "Thu Jan  1 00:00:00 2026" "Thu Jan  1 00:00:00 2026"
  {
    row proj-11 11 /tmp ok "" S1 idle "" ""
    row proj-12 12 /tmp ok "" S2 idle "" ""
  } >"$f"
  run cr_restore_sessions "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wiederhergestellt: 2 von 2"* ]]
  [[ "$output" == *"Bereits aktiv (nicht doppelt gestartet):"* ]]
  [[ "$output" == *"  - proj-11"* ]]
  [ "$($CR_TMUX list-sessions -F '#{session_name}' | grep -c '^proj-[0-9]*$')" -eq 1 ]
}

@test "a stale session file (start time differs) does not block the launch" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  live_session 777 S1 "Fri Jan  2 00:00:00 2026" "Thu Jan  1 00:00:00 2026"
  row proj-11 11 /tmp ok "" S1 idle "" "" >"$f"
  run cr_restore_sessions "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Bereits aktiv"* ]]
  $CR_TMUX list-sessions -F '#{session_name}' | grep -q '^proj-[0-9]*$'
}

@test "without an anchor server nothing is launched and no server is born" {
  {
    row proj-11 11 /tmp ok "" S1 idle "" ""
    row proj-12 12 /tmp ok "" S2 idle "" ""
  } >"$f"
  run cr_restore_sessions "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"  - proj-11: kein Anchor-Server"* ]]
  [[ "$output" == *"  - proj-12: kein Anchor-Server"* ]]
  [[ "$output" == *"Wiederhergestellt: 0 von 2"* ]]
  run $CR_TMUX list-sessions
  [ "$status" -ne 0 ]
}
