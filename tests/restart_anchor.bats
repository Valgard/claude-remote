#!/usr/bin/env bats
load helpers

setup() {
  cr_setup
  source "$REPO_ROOT/lib/claude-remote-lib.sh"
}
teardown() {
  [ -z "${sup:-}" ] || kill "$sup" 2>/dev/null || true
  cr_teardown
}

@test "cr_setup never points at the real pgrep or launchctl" {
  [ "$CR_PGREP" = true ]
  [ "$CR_LAUNCHCTL" = true ]
}

@test "stop ends the supervisor first, then the server" {
  sleep 300 3>&- &
  sup=$!
  export CR_PGREP="$(stub pgrep "echo $sup")"
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  run cr_stop_anchor_and_server
  [ "$status" -eq 0 ]
  run kill -0 "$sup"
  [ "$status" -ne 0 ]
  run $CR_TMUX list-sessions
  [ "$status" -ne 0 ]
}

@test "start kickstarts the agent label and waits for a new server" {
  export CR_LAUNCHCTL="$(stub launchctl 'printf "%s\n" "$*" >"$BATS_TEST_TMPDIR/lc.argv"; $CR_TMUX new-session -d -s _cr_anchor')"
  run cr_start_anchor 1
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/lc.argv")" = "kickstart gui/$(id -u)/de.valgard.claude-remote-anchor" ]
}

@test "start gives up after CR_ANCHOR_WAIT when no server appears" {
  CR_ANCHOR_WAIT=1 run cr_start_anchor 1
  [ "$status" -eq 1 ]
}
