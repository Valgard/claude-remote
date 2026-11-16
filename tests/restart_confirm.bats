#!/usr/bin/env bats
# The confirm/abort path of a restart: the dialogue (cr_restart_confirm).
load helpers

setup() {
  cr_setup
  source "$REPO_ROOT/lib/claude-remote-lib.sh"
}
teardown() { cr_teardown; }

# Snapshot files left in CR_RESTART_DIR (the suite's per-test tmp dir).
snapshots() { find "$CR_RESTART_DIR" -maxdepth 1 -name 'claude-remote-restart-*'; }

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
