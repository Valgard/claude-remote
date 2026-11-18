#!/usr/bin/env bats
# The confirm/abort path of a restart: the dialogue (cr_restart_confirm) and the
# picker's __RESTART__ case driven through the numbered menu (stdout is not a tty
# under `run`). Every run stays on cr_setup's pins: an isolated tmux socket, and
# pgrep/launchctl replaced by recording stand-ins that print nothing, so even a
# wrong branch can signal nobody and kickstart nothing. Each here-string ends in q,
# and every read in the picker treats EOF as "no"/quit, so a run cannot hang.
load helpers

setup() {
  cr_setup
  source "$REPO_ROOT/lib/claude-remote-lib.sh"
  export CR_EXIT_DIR="$BATS_TEST_TMPDIR/exit"
  export CR_PGREP="$(stub pgrep "touch '$BATS_TEST_TMPDIR/pgrep.called'")"
  export CR_LAUNCHCTL="$(stub launchctl "touch '$BATS_TEST_TMPDIR/launchctl.called'")"
}
teardown() { cr_teardown; }

# Snapshot files left in CR_RESTART_DIR (the suite's per-test tmp dir).
snapshots() { find "$CR_RESTART_DIR" -maxdepth 1 -name 'claude-remote-restart-*'; }

# Make the pane process <pid> look like a restorable claude to the snapshot.
restorable() {
  printf 'claude --brief\n' >"$FAKE_PS_DIR/$1.args"
  printf 'Mon Nov 16 19:56:19 2026\n' >"$FAKE_PS_DIR/$1.lstart"
  printf '{"sessionId":"%s","kind":"interactive","status":"idle","procStart":"Mon Nov 16 19:56:19 2026"}' \
    "$2" >"$CR_SESSIONS_DIR/$1.json"
}

# How many times the numbered menu asked for a choice.
menu_reads() { grep -o 'Auswahl:' <<<"$output" | wc -l | tr -d ' '; }

# Nothing was stopped: same server, both sessions alive, neither stand-in ever ran.
nothing_stopped() {
  [ "$(cr_server_pid)" = "$1" ]
  $CR_TMUX has-session -t "=$CR_ANCHOR"
  $CR_TMUX has-session -t "=proj-1"
  [ ! -e "$BATS_TEST_TMPDIR/pgrep.called" ]
  [ ! -e "$BATS_TEST_TMPDIR/launchctl.called" ]
}

# --- the dialogue -------------------------------------------------------------

@test "confirm: anything but j declines and removes the snapshot" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  cr_make_session proj-1 >/dev/null
  snap="$(cr_restart_snapshot_file)"
  run cr_restart_confirm "$snap" <<<''
  [ "$status" -eq 1 ]
  [[ "$output" == *"Anchor und tmux-Server werden neu gestartet."* ]]
  [ -z "$(snapshots)" ]
}

@test "confirm: j on an unchanged set hands over a fresh snapshot" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  cr_make_session proj-1 >/dev/null
  snap="$(cr_restart_snapshot_file)"
  # Called directly, not via run: CR_RESTART_SNAP is the result.
  cr_restart_confirm "$snap" <<<'j' >"$BATS_TEST_TMPDIR/out"
  [ -f "$CR_RESTART_SNAP" ]
  [ "$CR_RESTART_SNAP" != "$snap" ]
  [ ! -e "$snap" ]
  [ "$(cut -f1 "$CR_RESTART_SNAP")" = proj-1 ]
  [ "$(grep -c 'Anchor und tmux-Server werden neu gestartet.' "$BATS_TEST_TMPDIR/out")" -eq 1 ]
}

@test "confirm: a set that changed while the user read is shown again and asked again" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  cr_make_session late-1 >/dev/null
  snap="$CR_RESTART_DIR/claude-remote-restart-first"
  printf 'gone-1\t1\t/tmp\tskip\tkein Claude-Prozess\t\t\t\t\n' >"$snap"
  run cr_restart_confirm "$snap" <<<$'j\nn'
  [ "$status" -eq 1 ]
  [[ "$output" == *"  - gone-1: kein Claude-Prozess"*"Die Sessions haben sich seit der Übersicht geändert:"*"  - late-1: kein Claude-Prozess"* ]]
  [ -z "$(snapshots)" ]
}

@test "confirm: a session that turned unrestorable while the user read is shown again" {
  # Same names, but proj-1 flips ok -> skip (its session file reads empty, as a torn
  # rewrite would): executing silently would kill it without having named it.
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  pid=$(cr_make_session proj-1)
  restorable "$pid" S1
  snap="$(cr_restart_snapshot_file)"
  [ "$(cut -f1,4 "$snap")" = $'proj-1\tok' ]
  : >"$CR_SESSIONS_DIR/$pid.json"
  run cr_restart_confirm "$snap" <<<$'j\nn'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Wiederherstellen: 1 von 1"*"Die Sessions haben sich seit der Übersicht geändert:"*"Wiederherstellen: 0 von 1"*"  - proj-1: Session-Datei unlesbar"* ]]
  [ -z "$(snapshots)" ]
}

@test "confirm: a title that changed while the user read does not ask again" {
  # Only (name, verdict) decide whether the user saw what will be killed; a title can
  # change at any time (an ai-title regenerated, a /rename) without changing that.
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  pid=$(cr_make_session proj-1)
  restorable "$pid" S1
  $CR_TMUX select-pane -t proj-1 -T $'\xe2\x9c\xb3 alter_titel'
  snap="$(cr_restart_snapshot_file)"
  [ "$(cut -f1,4,10 "$snap")" = $'proj-1\tok\talter_titel' ]
  $CR_TMUX select-pane -t proj-1 -T $'\xe2\x9c\xb3 neuer_titel'
  # Called directly, not via run: a second question would read EOF, decline, and
  # return 1, which fails the test here.
  cr_restart_confirm "$snap" <<<'j' >"$BATS_TEST_TMPDIR/out"
  [ "$(cut -f10 "$CR_RESTART_SNAP")" = neuer_titel ]
  [ "$(grep -c 'geändert' "$BATS_TEST_TMPDIR/out")" -eq 0 ]
}

@test "confirm: a changed set confirmed again runs with the new snapshot" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  cr_make_session late-1 >/dev/null
  snap="$CR_RESTART_DIR/claude-remote-restart-first"
  printf 'gone-1\t1\t/tmp\tskip\tkein Claude-Prozess\t\t\t\t\n' >"$snap"
  cr_restart_confirm "$snap" <<<$'j\nj' >"$BATS_TEST_TMPDIR/out"
  [ "$(cut -f1 "$CR_RESTART_SNAP")" = late-1 ]
  [ ! -e "$snap" ]
  [ "$(snapshots)" = "$CR_RESTART_SNAP" ]
}

# --- the picker loop ------------------------------------------------------------

@test "picker: s then n shows the summary and stops nothing" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  pid=$(cr_make_session proj-1)
  restorable "$pid" S1
  server=$(cr_server_pid)
  run env -u TMUX claude-remote-pick <<<$'s\nn\nq'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Anchor und tmux-Server werden neu gestartet."* ]]
  [[ "$output" == *"Wiederherstellen: 1 von 1 Sessions"* ]]
  [[ "$output" != *"Beende Anchor und Server"* ]]
  [ "$(menu_reads)" -eq 2 ]
  nothing_stopped "$server"
  [ -z "$(snapshots)" ]
}

@test "picker: s, j, Enter restarts through the agent and shows the report" {
  # The agent stand-in births the new anchor on the suite's socket; FAKE_PS_LIVE makes
  # the old pane process vanish from ps once kill-server has ended it, as it would.
  export FAKE_PS_LIVE=1
  export CR_LAUNCHCTL="$(agent_stub "touch '$BATS_TEST_TMPDIR/launchctl.called'; $CR_TMUX new-session -d -s _cr_anchor")"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  pid=$(cr_make_session proj-1)
  restorable "$pid" S1
  old=$(cr_server_pid)
  run env -u TMUX claude-remote-pick <<<$'s\nj\n\nq'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wiederherstellen: 1 von 1 Sessions"* ]]
  [[ "$output" == *"Snapshot: $CR_RESTART_DIR/claude-remote-restart-"* ]]
  [[ "$output" == *"Beende Anchor und Server …"* ]]
  [[ "$output" == *"Wiederhergestellt: 1 von 1"* ]]
  [ "$(menu_reads)" -eq 2 ]
  [ -e "$BATS_TEST_TMPDIR/pgrep.called" ]
  [ -e "$BATS_TEST_TMPDIR/launchctl.called" ]
  [ "$(cr_server_pid)" != "$old" ]
  $CR_TMUX has-session -t "=$CR_ANCHOR"
  $CR_TMUX list-sessions -F '#{session_name}' | grep -q '^proj-[0-9]*$'
}

@test "picker: started inside a foreign tmux, the restart acts on the claude-remote server only" {
  # Production shape: CR_TMUX without -L, so $TMUX would redirect every plain tmux call
  # to the foreign server the picker runs in. The guard checks the default server, so
  # the whole restart must act on that one too, and the foreign server must survive.
  cr_prod_setup
  local prod="tmux -f /dev/null" foreign="tmux -f /dev/null -L foreign_$$" fsock old
  $prod new-session -d -s _cr_anchor
  cr_prod_fence $prod
  $foreign new-session -d -s keep
  cr_prod_fence $foreign
  fsock="$($foreign display-message -p '#{socket_path}')"
  pid="$($prod new-session -d -P -F '#{pane_pid}' -s proj-1 -- claude)"
  restorable "$pid" S1
  old="$($prod display-message -p '#{pid}')"
  export FAKE_PS_LIVE=1
  export CR_LAUNCHCTL="$(agent_stub "$prod new-session -d -s _cr_anchor")"
  run env TMUX="$fsock,1,0" CR_TMUX="$prod" claude-remote-pick <<<$'s\nj\n\nq'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wiederhergestellt: 1 von 1"* ]]
  $foreign has-session -t "=keep"
  [ "$($foreign list-sessions -F '#{session_name}' | grep -c '^proj-')" -eq 0 ]
  [ "$($prod display-message -p '#{pid}')" != "$old" ]
  $prod list-sessions -F '#{session_name}' | grep -q '^proj-[0-9]*$'
  # The loop goes on with the caller's TMUX again: the redrawn menu is the foreign one.
  [[ "${output##*Claude-Sessions:}" == *"1) keep"* ]]
}

@test "picker: s, j on a server holding only the anchor restarts it" {
  # Both snapshots are empty: the re-check must not ask again, and execute must run.
  export CR_LAUNCHCTL="$(agent_stub "touch '$BATS_TEST_TMPDIR/launchctl.called'; $CR_TMUX new-session -d -s _cr_anchor")"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  old=$(cr_server_pid)
  run env -u TMUX claude-remote-pick <<<$'s\nj\n\nq'
  [ "$status" -eq 0 ]
  # The plain line comes with the question, i.e. before execute prints anything (read -p
  # shows its prompt only on a terminal, so the [j/N] itself is not in the output).
  [[ "$output" == *"Keine Sessions – nur Anchor und tmux-Server werden neu gestartet."*"Snapshot: "* ]]
  [[ "$output" != *"geändert"* ]]
  [[ "$output" == *"Beende Anchor und Server …"*"Keine Sessions wiederherzustellen."* ]]
  [ "$(menu_reads)" -eq 2 ]
  [ -e "$BATS_TEST_TMPDIR/pgrep.called" ]
  [ -e "$BATS_TEST_TMPDIR/launchctl.called" ]
  [ "$(cr_server_pid)" != "$old" ]
  $CR_TMUX has-session -t "=$CR_ANCHOR"
}

@test "picker: a fresh snapshot that fails after j stops nothing" {
  # cr_restart_confirm returns 2 and leaves CR_RESTART_SNAP empty; only rc 0 may reach
  # cr_restart_execute. A mktemp that fails the SECOND restart snapshot (the re-check
  # after "j") drives that path; the loop's own `mktemp -d` passes through.
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  cr_make_session proj-1 >/dev/null
  server=$(cr_server_pid)
  local mt="$BATS_TEST_TMPDIR/mt"
  mkdir -p "$mt"
  printf '%s\n' '#!/usr/bin/env bash' \
    "case \"\$*\" in *claude-remote-restart-*) c='$BATS_TEST_TMPDIR/mt.n'; [ -e \"\$c\" ] && exit 1; : >\"\$c\" ;; esac" \
    'exec /usr/bin/mktemp "$@"' >"$mt/mktemp"
  chmod +x "$mt/mktemp"
  run env -u TMUX PATH="$mt:$PATH" claude-remote-pick <<<$'s\nj\n\nq'
  [ "$status" -eq 0 ]
  [ -e "$BATS_TEST_TMPDIR/mt.n" ]
  [[ "$output" == *"Snapshot-Datei in $CR_RESTART_DIR konnte nicht geschrieben werden – es wurde nichts beendet."* ]]
  # Only the snapshot failure refused: cr_restart_execute, whose refusal of the empty
  # path ends the same way, never ran. Counted, so it holds whatever its wording.
  [ "$(grep -c 'es wurde nichts beendet' <<<"$output")" -eq 1 ]
  [ "$(menu_reads)" -eq 2 ]
  nothing_stopped "$server"
  [ -z "$(snapshots)" ]
}

@test "picker: inside the server it would restart, it refuses and stops nothing" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  cr_make_session proj-1 >/dev/null
  sock="$($CR_TMUX display-message -p '#{socket_path}')"
  server=$(cr_server_pid)
  run env TMUX="$sock,1,0" claude-remote-pick <<<$'s\n\nq'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Neustart geht nicht aus einer Session dieses Servers"* ]]
  [[ "$output" != *"Anchor und tmux-Server werden neu gestartet."* ]]
  [ "$(menu_reads)" -eq 2 ]
  nothing_stopped "$server"
  [ -z "$(snapshots)" ]
}

@test "picker: an unusable snapshot dir is named as the cause and stops nothing" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  cr_make_session proj-1 >/dev/null
  server=$(cr_server_pid)
  run env -u TMUX CR_RESTART_DIR="$BATS_TEST_TMPDIR/missing" claude-remote-pick <<<$'s\n\nq'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Snapshot-Datei in $BATS_TEST_TMPDIR/missing konnte nicht geschrieben werden"* ]]
  [[ "$output" != *"Kein tmux-Server läuft."* ]]
  [ "$(menu_reads)" -eq 2 ]
  nothing_stopped "$server"
}

@test "picker: without a server it says so and births none" {
  run env -u TMUX claude-remote-pick <<<$'s\n\nq'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Kein tmux-Server läuft."* ]]
  [ "$(menu_reads)" -eq 2 ]
  run $CR_TMUX list-sessions
  [ "$status" -ne 0 ]
  [ -z "$(snapshots)" ]
}
