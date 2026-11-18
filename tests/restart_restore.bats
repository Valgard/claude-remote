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

@test "a row carrying a restricting flag is never launched without it" {
  # Defence in depth for a snapshot that marks such a row ok (older or hand-edited).
  export FAKE_CLAUDE_ARGV_FILE="$BATS_TEST_TMPDIR/argv"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  row proj-11 11 /tmp ok "" S1 idle "" "--brief --tools Read" >"$f"
  run cr_restore_sessions "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"  - proj-11: einschränkende Startoptionen (nicht sicher übertragbar)"* ]]
  [[ "$output" == *"Wiederhergestellt: 0 von 1"* ]]
  [ ! -e "$FAKE_CLAUDE_ARGV_FILE" ]
  [ "$($CR_TMUX list-sessions -F '#{session_name}' | grep -c '^proj-')" -eq 0 ]
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

@test "skip rows are not launched but named as not restorable" {
  # Every pane of the old server is named in the report: a skip row is gone after the
  # restart, so it must not vanish from the report either.
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  {
    row skipme-5 5 /tmp skip "keine Session-Datei" "" "" "" ""
    row proj-12 12 /tmp ok "" S2 idle "" ""
  } >"$f"
  run cr_restore_sessions "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wiederhergestellt: 1 von 1"* ]]
  [[ "$output" == *$'Nicht wiederherstellbar:\n  - skipme-5: keine Session-Datei'* ]]
  [ "$($CR_TMUX list-sessions -F '#{session_name}' | grep -c '^skipme-')" -eq 0 ]
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
  export CR_LAUNCHCTL="$(agent_stub '$CR_TMUX new-session -d -s _cr_anchor')"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  old=$(cr_server_pid)
  row proj-11 "$GONE" /tmp ok "" S1 idle "" "" >"$f"
  run cr_restart_execute "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wiederhergestellt: 1 von 1"* ]]
  [ "$(cr_server_pid)" != "$old" ]
  $CR_TMUX list-sessions -F '#{session_name}' | grep -q '^proj-[0-9]*$'
}

@test "execute refuses a missing or unreadable snapshot and stops nothing" {
  # Stopping without a usable snapshot would end every session with no way back.
  export CR_PGREP="$(stub pgrep "touch '$BATS_TEST_TMPDIR/pgrep.called'")"
  export CR_LAUNCHCTL="$(stub launchctl "touch '$BATS_TEST_TMPDIR/lc.called'")"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  cr_make_session proj-1 >/dev/null
  old=$(cr_server_pid)
  local missing="$BATS_TEST_TMPDIR/does-not-exist" locked="$BATS_TEST_TMPDIR/locked"
  row proj-1 "$GONE" /tmp ok "" S1 idle "" "" >"$locked"
  chmod 000 "$locked"
  for s in "$missing" "$locked"; do
    run cr_restart_execute "$s"
    [ "$status" -ne 0 ]
    [ "$output" = "Snapshot-Datei $s fehlt oder ist nicht lesbar – es wurde nichts beendet." ]
  done
  [ ! -e "$BATS_TEST_TMPDIR/pgrep.called" ]
  [ ! -e "$BATS_TEST_TMPDIR/lc.called" ]
  [ "$(cr_server_pid)" = "$old" ]
  $CR_TMUX has-session -t "=proj-1"
}

@test "an empty snapshot of a server holding only the anchor restarts anchor and server" {
  # The stale anchor instance is cured only by replacing it; with no session there is
  # nothing to lose, so an empty snapshot must not block that.
  export CR_PGREP="$(stub pgrep "touch '$BATS_TEST_TMPDIR/pgrep.called'")"
  export CR_LAUNCHCTL="$(agent_stub "touch '$BATS_TEST_TMPDIR/kick.called'; \$CR_TMUX new-session -d -s _cr_anchor")"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  old=$(cr_server_pid)
  : >"$f"
  run cr_restart_execute "$f"
  [ "$status" -eq 0 ]
  [ -e "$BATS_TEST_TMPDIR/pgrep.called" ]
  [ -e "$BATS_TEST_TMPDIR/kick.called" ]
  [ "$(cr_server_pid)" != "$old" ]
  $CR_TMUX has-session -t "=$CR_ANCHOR"
  [ "${lines[${#lines[@]} - 1]}" = "Keine Sessions wiederherzustellen." ]
  [[ "$output" != *"Stelle "* ]]
  [ "$(cat "$f.report")" = "Keine Sessions wiederherzustellen." ]
}

@test "an empty snapshot of a server that holds sessions is refused and stops nothing" {
  # The snapshot write failed: executing it would end proj-1 without a way back.
  export CR_PGREP="$(stub pgrep "touch '$BATS_TEST_TMPDIR/pgrep.called'")"
  export CR_LAUNCHCTL="$(stub launchctl "touch '$BATS_TEST_TMPDIR/lc.called'")"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  cr_make_session proj-1 >/dev/null
  old=$(cr_server_pid)
  : >"$f"
  run cr_restart_execute "$f"
  [ "$status" -ne 0 ]
  [ "$output" = "Snapshot-Datei $f ist leer, der Server hat aber Sessions – es wurde nichts beendet." ]
  [ ! -e "$BATS_TEST_TMPDIR/pgrep.called" ]
  [ ! -e "$BATS_TEST_TMPDIR/lc.called" ]
  [ "$(cr_server_pid)" = "$old" ]
  $CR_TMUX has-session -t "=proj-1"
}

@test "execute asks launchctl for the agent before it kickstarts it" {
  export CR_LAUNCHCTL="$(stub launchctl 'printf "%s\n" "$*" >>"$BATS_TEST_TMPDIR/lc.argv"
[ "$1" = print ] && exit 0
$CR_TMUX new-session -d -s _cr_anchor')"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  row proj-11 "$GONE" /tmp ok "" S1 idle "" "" >"$f"
  run cr_restart_execute "$f"
  [ "$status" -eq 0 ]
  local agent="gui/$(id -u)/de.valgard.claude-remote-anchor"
  [ "$(cat "$BATS_TEST_TMPDIR/lc.argv")" = "print $agent"$'\n'"kickstart -k $agent" ]
}

@test "execute refuses and stops nothing when the anchor agent is not loaded" {
  # Without the agent nothing could ever birth the new server, so this must be found
  # out before the stop, not after every session is gone.
  export CR_PGREP="$(stub pgrep "touch '$BATS_TEST_TMPDIR/pgrep.called'")"
  export CR_LAUNCHCTL="$(stub launchctl "if [ \"\$1\" = print ]; then echo 'Could not find service \"de.valgard.claude-remote-anchor\" in domain for user gui: 501' >&2; exit 113; fi
touch '$BATS_TEST_TMPDIR/kick.called'")"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  cr_make_session proj-1 >/dev/null
  old=$(cr_server_pid)
  row proj-11 "$GONE" /tmp ok "" S1 idle "" "" >"$f"
  run cr_restart_execute "$f"
  [ "$status" -ne 0 ]
  [[ "$output" == *"LaunchAgent de.valgard.claude-remote-anchor"*"es wurde nichts beendet"* ]]
  [[ "$output" == *'Could not find service "de.valgard.claude-remote-anchor"'* ]]
  [[ "$output" != *"Beende Anchor und Server"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/pgrep.called" ]
  [ ! -e "$BATS_TEST_TMPDIR/kick.called" ]
  [ "$(cr_server_pid)" = "$old" ]
  $CR_TMUX has-session -t "=proj-1"
}

@test "execute reports a failed kickstart with its exit code and error" {
  export CR_LAUNCHCTL="$(agent_stub 'echo "Bootstrap failed: 5: Input/output error" >&2; exit 37')"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  row proj-11 "$GONE" /tmp ok "" S1 idle "" "" >"$f"
  CR_ANCHOR_WAIT=1 run cr_restart_execute "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"launchctl kickstart fehlgeschlagen (Exit 37): Bootstrap failed: 5: Input/output error"* ]]
  [[ "$output" == *"Anchor/Server kam nicht hoch."* ]]
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
  [ "${lines[2]}" = "Bericht: $f.report" ]
  [ "${lines[3]}" = "Beende Anchor und Server …" ]
  [ "${lines[4]}" = "Warte auf neuen Server (bis zu 1 s) …" ]
  [[ "${lines[5]}" == "Anchor/Server kam nicht hoch."* ]]
}

@test "execute keeps the report in a private file next to the snapshot" {
  # A dropped SSH channel takes the screen with it; the file keeps what came back.
  export CR_LAUNCHCTL="$(agent_stub '$CR_TMUX new-session -d -s _cr_anchor')"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  {
    row proj-11 "$GONE" /tmp ok "" S1 idle "" ""
    row gone-12 "$GONE" /nonexistent ok "" S2 idle "" ""
  } >"$f"
  run cr_restart_execute "$f"
  [ "$status" -eq 1 ]
  [ -n "$(find "$f.report" -perm 600)" ]
  [ "$(head -n 1 "$f.report")" = "Wiederhergestellt: 1 von 2" ]
  grep -qx '  - gone-12: Startordner fehlt' "$f.report"
  [[ "$output" == *$'Wiederhergestellt: 1 von 2\nFehlgeschlagen:\n  - gone-12: Startordner fehlt'* ]]
}

@test "a run that ends before the restore says why in the report file" {
  export CR_LAUNCHCTL="$(agent_stub 'echo "Bootstrap failed: 5: Input/output error" >&2; exit 37')"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  row proj-11 "$GONE" /tmp ok "" S1 idle "" "" >"$f"
  CR_ANCHOR_WAIT=1 run cr_restart_execute "$f"
  [ "$status" -eq 1 ]
  grep -qx 'launchctl kickstart fehlgeschlagen (Exit 37): Bootstrap failed: 5: Input/output error' "$f.report"
  grep -q '^Anchor/Server kam nicht hoch\.' "$f.report"
}

@test "execute never writes its report through a file someone else put there" {
  # Over SSH the snapshot lives in the shared /tmp, so <snapshot>.report could be
  # planted as a link while the user reads the summary.
  export CR_LAUNCHCTL="$(agent_stub '$CR_TMUX new-session -d -s _cr_anchor')"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  printf 'keep me\n' >"$BATS_TEST_TMPDIR/victim"
  ln -s "$BATS_TEST_TMPDIR/victim" "$f.report"
  row proj-11 "$GONE" /tmp ok "" S1 idle "" "" >"$f"
  run cr_restart_execute "$f"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/victim")" = "keep me" ]
  [[ "$output" == *"Bericht-Datei $f.report ließ sich nicht anlegen – der Bericht erscheint nur hier."* ]]
  [[ "$output" == *"Wiederhergestellt: 1 von 1"* ]]
}

@test "execute announces the restore with the number of sessions" {
  export CR_LAUNCHCTL="$(agent_stub '$CR_TMUX new-session -d -s _cr_anchor')"
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
  grep -qx 'Server ließ sich nicht beenden.' "$f.report"
}

@test "execute prints the snapshot and hint when a restore fails" {
  export CR_LAUNCHCTL="$(agent_stub '$CR_TMUX new-session -d -s _cr_anchor')"
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
  # The caller is addressed by the pid it recorded, not by $PPID: the kickstart runs
  # inside a command substitution, whose subshell would be the parent instead.
  export CR_LAUNCHCTL="$(agent_stub '$CR_TMUX new-session -d -s _cr_anchor
caller=$(cat "$BATS_TEST_TMPDIR/caller.pid")
kill -INT "$caller"; kill -HUP "$caller"')"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  row proj-11 "$GONE" /tmp ok "" S1 idle "" "" >"$f"
  run bash -c "echo \$\$ >'$BATS_TEST_TMPDIR/caller.pid'
    source '$REPO_ROOT/lib/claude-remote-lib.sh'
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
  export CR_LAUNCHCTL="$(agent_stub '$CR_TMUX new-session -d -s _cr_anchor')"
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

@test "--restore with an empty snapshot says there is nothing to restore" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  : >"$f"
  run claude-remote-pick --restore "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "Keine Sessions wiederherzustellen." ]
}

@test "--restore inside a foreign tmux restores into the claude-remote server" {
  # Production shape: without -L, $TMUX would send the anchor check and every launch
  # to the foreign server this shell runs in.
  cr_prod_setup
  local prod="tmux -f /dev/null" foreign="tmux -f /dev/null -L foreign_$$" fsock
  $prod new-session -d -s _cr_anchor
  cr_prod_fence $prod
  $foreign new-session -d -s keep
  cr_prod_fence $foreign
  fsock="$($foreign display-message -p '#{socket_path}')"
  row proj-11 11 /tmp ok "" S1 idle "" "" >"$f"
  run env TMUX="$fsock,1,0" CR_TMUX="$prod" claude-remote-pick --restore "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wiederhergestellt: 1 von 1"* ]]
  $prod list-sessions -F '#{session_name}' | grep -q '^proj-[0-9]*$'
  [ "$($foreign list-sessions -F '#{session_name}' | grep -c '^proj-')" -eq 0 ]
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

@test "an anchor lost after the first launch fails every later row and births no server" {
  # A tmux wrapper kills the server right after the first row's rename-session, i.e.
  # once that row is launched. Checking the anchor only before the first launch would
  # let row 2's new-session birth a fresh server outside the anchor.
  export CR_EXIT_DIR="$BATS_TEST_TMPDIR/exit"
  local real="$CR_TMUX" marker="$BATS_TEST_TMPDIR/killed"
  export CR_TMUX="$(stub tmux-dies "$real \"\$@\"
rc=\$?
if [ \"\$1\" = rename-session ] && [ ! -e '$marker' ]; then : >'$marker'; $real kill-server; fi
exit \$rc")"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  {
    row proj-11 11 /tmp ok "" S1 idle "" ""
    row proj-12 12 /tmp ok "" S2 idle "" ""
    row proj-13 13 /tmp ok "" S3 idle "" ""
  } >"$f"
  run cr_restore_sessions "$f"
  export CR_TMUX="$real"
  [ "$status" -eq 1 ]
  [ -e "$marker" ]
  [[ "$output" == *"Wiederhergestellt: 0 von 3"* ]]
  [[ "$output" == *"  - proj-11: beendete sich sofort"* ]]
  [[ "$output" == *"  - proj-12: kein Anchor-Server"* ]]
  [[ "$output" == *"  - proj-13: kein Anchor-Server"* ]]
  run $CR_TMUX list-sessions
  [ "$status" -ne 0 ]
}
