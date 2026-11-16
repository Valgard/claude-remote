#!/usr/bin/env bats
load helpers

setup() {
  cr_setup
  source "$REPO_ROOT/lib/claude-remote-lib.sh"
  f="$BATS_TEST_TMPDIR/snap.tsv"
}
teardown() {
  # Only ever our own stand-in; KILL so a failed assertion cannot leave it behind.
  [ -z "${standin:-}" ] || kill -KILL "$standin" 2>/dev/null || true
  cr_teardown
}

# One snapshot row: name pid start verdict reason session_id status last_cwd args
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }

# Old pane pid for rows that execute waits on: above every PID_MAX, so it can never
# name a live process (execute probes these pids with kill -0).
GONE=99999999

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

@test "a restored session that last worked elsewhere is listed with that directory" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  {
    row proj-11 11 /tmp ok "" S1 idle /tmp/.worktrees/x ""
    row gone-12 12 /nonexistent ok "" S2 idle /nonexistent/.worktrees/y ""
    row same-13 13 /tmp ok "" S3 idle "" ""
  } >"$f"
  run cr_restore_sessions "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *$'Arbeiteten zuletzt woanders (laufen jetzt im Startordner):\n  - proj-11 → /tmp/.worktrees/x'* ]]
  # Only restored rows: a failed one does not run anywhere, an undrifted one is not listed.
  [[ "$output" != *"gone-12 →"* ]]
  [[ "$output" != *"same-13 →"* ]]
}

@test "execute stops, restarts via the agent and restores" {
  export CR_LAUNCHCTL="$(stub launchctl '$CR_TMUX new-session -d -s _cr_anchor')"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  old=$(cr_server_pid)
  row proj-11 "$GONE" /tmp ok "" S1 idle "" "" >"$f"
  run cr_restart_execute "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wiederhergestellt: 1 von 1"* ]]
  [ "$(cr_server_pid)" != "$old" ]
  $CR_TMUX list-sessions -F '#{session_name}' | grep -q '^proj-[0-9]*$'
}

@test "execute names the snapshot and the retry before it stops anything" {
  # The launchctl pin births nothing, so the run ends at "kam nicht hoch"; what it
  # printed before the stop is what an interrupted restart leaves on the screen.
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  row proj-11 "$GONE" /tmp ok "" S1 idle "" "" >"$f"
  CR_ANCHOR_WAIT=1 run cr_restart_execute "$f"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "Snapshot: $f" ]
  [ "${lines[1]}" = "Wiederherstellen: claude-remote-pick --restore $f" ]
  [ "${lines[2]}" = "Beende Anchor und Server …" ]
  [ "${lines[3]}" = "Warte auf neuen Server (bis zu 1 s) …" ]
  [[ "${lines[4]}" == "Anchor/Server kam nicht hoch."* ]]
}

@test "execute announces the restore with the number of sessions" {
  export CR_LAUNCHCTL="$(stub launchctl '$CR_TMUX new-session -d -s _cr_anchor')"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  {
    row proj-11 "$GONE" /tmp ok "" S1 idle "" ""
    row proj-12 "$GONE" /tmp ok "" S2 idle "" ""
    row skip-13 "$GONE" /tmp skip "keine Session-Datei" "" "" "" ""
  } >"$f"
  run cr_restart_execute "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'Stelle 2 Sessions wieder her …\nWiederhergestellt: 2 von 2'* ]]
}

@test "execute reports the retry command when no server comes up" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  row proj-11 "$GONE" /tmp ok "" S1 idle "" "" >"$f"
  CR_ANCHOR_WAIT=1 run cr_restart_execute "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Anchor/Server kam nicht hoch."* ]]
  [[ "$output" == *"claude-remote-pick --restore $f"* ]]
}

@test "execute prints the snapshot and hint when the server cannot be stopped" {
  # A tmux whose kill-server does nothing: the server still answers afterwards.
  local real="$CR_TMUX"
  export CR_TMUX="$(stub tmux-nokill "[ \"\$1\" = kill-server ] && exit 0; exec $real \"\$@\"")"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  row proj-11 "$GONE" /tmp ok "" S1 idle "" "" >"$f"
  run cr_restart_execute "$f"
  export CR_TMUX="$real"
  [ "$status" -eq 1 ]
  [[ "$output" == *$'Server ließ sich nicht beenden.\nSnapshot: '"$f"$'\nWiederherstellen: claude-remote-pick --restore '"$f"* ]]
}

@test "execute prints the snapshot and hint when a restore fails" {
  export CR_LAUNCHCTL="$(stub launchctl '$CR_TMUX new-session -d -s _cr_anchor')"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  row gone-11 "$GONE" /nonexistent ok "" S1 idle "" "" >"$f"
  run cr_restart_execute "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *$'  - gone-11: Startordner fehlt\nSnapshot: '"$f"$'\nWiederherstellen: claude-remote-pick --restore '"$f"* ]]
}

@test "execute ignores INT and HUP while it runs, then restores the caller's traps" {
  # The agent stand-in interrupts its caller mid-restart, as Ctrl-C or a dropped SSH
  # channel would. Without the ignore, HUP ends the shell and INT runs the trap. It
  # births the server first, so teardown finds it even when the caller dies early.
  export CR_LAUNCHCTL="$(stub launchctl '$CR_TMUX new-session -d -s _cr_anchor; kill -INT $PPID; kill -HUP $PPID')"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  row proj-11 "$GONE" /tmp ok "" S1 idle "" "" >"$f"
  run bash -c "source '$REPO_ROOT/lib/claude-remote-lib.sh'
    trap 'touch \"$BATS_TEST_TMPDIR/int-fired\"' INT
    cr_restart_execute '$f'
    echo \"rc=\$?\"
    echo \"int=[\$(trap -p INT)]\"
    echo \"hup=[\$(trap -p HUP)]\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wiederhergestellt: 1 von 1"* ]]
  [[ "$output" == *"rc=0"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/int-fired" ]
  [[ "$output" == *"int=[trap -- 'touch \"$BATS_TEST_TMPDIR/int-fired\"' SIGINT]"* ]]
  [[ "$output" == *"hup=[]"* ]]
}

# A session file for <pid> naming <sid>; ps-stub answers lstart "$3" for that pid.
live_session() {
  printf '%s\n' "$3" >"$FAKE_PS_DIR/$1.lstart"
  printf '{"sessionId":"%s","kind":"interactive","status":"idle","procStart":"%s"}' \
    "$2" "$4" >"$CR_SESSIONS_DIR/$1.json"
}

@test "a row whose own old process still runs fails instead of counting as active" {
  # After kill-server the old claude may still be exiting (or outlive its pty); it
  # dies outside any server, so it must not be reported as restored.
  export FAKE_PS_LIVE=1
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  sleep 300 3>&- &
  standin=$!
  live_session "$standin" S1 "Thu Jan  1 00:00:00 2026" "Thu Jan  1 00:00:00 2026"
  row proj-11 "$standin" /tmp ok "" S1 idle "" "" >"$f"
  run cr_restore_sessions "$f"
  [ "$status" -ne 0 ]
  [[ "$output" == *"  - proj-11: alter Prozess läuft noch (pid $standin)"* ]]
  [[ "$output" == *"Wiederhergestellt: 0 von 1"* ]]
  [[ "$output" != *"Bereits aktiv"* ]]
  run $CR_TMUX list-sessions -F '#{session_name}'
  [[ "$output" != *proj-* ]]
}

@test "execute waits for the old processes to exit, then restores them" {
  export FAKE_PS_LIVE=1
  export CR_LAUNCHCTL="$(stub launchctl '$CR_TMUX new-session -d -s _cr_anchor')"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  # The old claude takes ~2 s to exit after its server is gone.
  sleep 2 3>&- &
  standin=$!
  live_session "$standin" S1 "Thu Jan  1 00:00:00 2026" "Thu Jan  1 00:00:00 2026"
  row proj-11 "$standin" /tmp ok "" S1 idle "" "" >"$f"
  run cr_restart_execute "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wiederhergestellt: 1 von 1"* ]]
  [[ "$output" != *"Bereits aktiv"* ]]
  [[ "$output" != *"alter Prozess"* ]]
  $CR_TMUX list-sessions -F '#{session_name}' | grep -q '^proj-[0-9]*$'
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
