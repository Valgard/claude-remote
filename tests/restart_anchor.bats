#!/usr/bin/env bats
load helpers

setup() {
  cr_setup
  source "$REPO_ROOT/lib/claude-remote-lib.sh"
}
teardown() {
  # KILL, not TERM: the "ignore" stand-in survives TERM. Only ever our own pids.
  local p
  for p in ${sup:-} ${foreign:-} ${lookalike:-}; do
    kill -KILL "$p" 2>/dev/null || true
  done
  cr_teardown
}

@test "cr_setup never points at the real pgrep or launchctl" {
  [ "$CR_PGREP" = true ]
  [ "$CR_LAUNCHCTL" = true ]
}

# Supervisor stand-in: a bash script (so its trap can run tmux) that loops on short
# sleeps and touches $BATS_TEST_TMPDIR/ready AFTER installing its trap. $1 = TERM
# behaviour: "record" notes whether the suite's server is still up when TERM arrives
# (into $2) and exits; "ignore" notes each TERM into $2 and carries on.
make_supervisor() {
  local f="$BATS_TEST_TMPDIR/supervisor.sh" ready="$BATS_TEST_TMPDIR/ready"
  if [ "$1" = record ]; then
    printf '%s\n' '#!/usr/bin/env bash' \
      "trap '$CR_TMUX has-session -t _cr_anchor 2>/dev/null && echo alive >\"$2\" || echo dead >\"$2\"; exit 0' TERM"
  else
    printf '%s\n' '#!/usr/bin/env bash' "trap 'echo ignored >>\"$2\"' TERM"
  fi >"$f"
  printf '%s\n' "touch \"$ready\"" 'while :; do sleep 1; done' >>"$f"
  chmod +x "$f"
  printf '%s\n' "$f"
}

# The stand-in's command line as `ps -o args=` shows the real supervisor (the app stub
# execs the script, whose `#!/usr/bin/env bash` turns it into `bash <path> <flag>`).
supervisor_args() {
  printf '%s\n' "bash $REPO_ROOT/bin/claude-remote-pick --supervise-anchor" >"$FAKE_PS_DIR/$1.args"
}

# Block (max 5 s) until the stand-in has installed its trap.
wait_ready() {
  local i=0
  while [ ! -e "$BATS_TEST_TMPDIR/ready" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$BATS_TEST_TMPDIR/ready" ]
}

@test "stop signals the supervisor while the server still runs, then kills the server" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  "$(make_supervisor record "$BATS_TEST_TMPDIR/order")" 3>&- &
  sup=$!
  supervisor_args "$sup"
  wait_ready
  export CR_PGREP="$(stub pgrep "echo $sup")"
  run cr_stop_anchor_and_server
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/order")" = alive ]
  run kill -0 "$sup"
  [ "$status" -ne 0 ]
  run $CR_TMUX list-sessions
  [ "$status" -ne 0 ]
}

@test "stop escalates to KILL for a supervisor that ignores TERM" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  "$(make_supervisor ignore "$BATS_TEST_TMPDIR/termlog")" 3>&- &
  sup=$!
  supervisor_args "$sup"
  wait_ready
  export CR_PGREP="$(stub pgrep "echo $sup")"
  run cr_stop_anchor_and_server
  [ "$status" -eq 0 ]
  # TERM was delivered and survived (the handler ran), so only KILL can have ended it.
  grep -q ignored "$BATS_TEST_TMPDIR/termlog"
  run kill -0 "$sup"
  [ "$status" -ne 0 ]
  run $CR_TMUX list-sessions
  [ "$status" -ne 0 ]
}

@test "stop never signals a process that merely mentions the supervisor" {
  # pgrep -f matches a substring: a grep over a log, or a pgrep/watch typed into a
  # terminal, carries the very string. Only a command line ENDING in
  # <dir>/claude-remote-pick --supervise-anchor is the supervisor.
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  sleep 300 3>&- &
  foreign=$!
  sleep 300 3>&- &
  lookalike=$!
  printf '%s\n' "grep claude-remote-pick --supervise-anchor /var/log/system.log" >"$FAKE_PS_DIR/$foreign.args"
  printf '%s\n' "pgrep -f claude-remote-pick --supervise-anchor" >"$FAKE_PS_DIR/$lookalike.args"
  export CR_PGREP="$(stub pgrep "echo $foreign; echo $lookalike")"
  run cr_stop_anchor_and_server
  [ "$status" -eq 0 ]
  run kill -0 "$foreign"
  [ "$status" -eq 0 ]
  run kill -0 "$lookalike"
  [ "$status" -eq 0 ]
  run $CR_TMUX list-sessions
  [ "$status" -ne 0 ]
}

@test "stop still kills the server when pgrep finds no supervisor" {
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
  export CR_PGREP="$(stub pgrep 'exit 1')"
  run cr_stop_anchor_and_server
  [ "$status" -eq 0 ]
  run $CR_TMUX list-sessions
  [ "$status" -ne 0 ]
}

@test "start kickstarts the agent label and waits for a new server" {
  export CR_LAUNCHCTL="$(stub launchctl 'printf "%s\n" "$*" >"$BATS_TEST_TMPDIR/lc.argv"; $CR_TMUX new-session -d -s _cr_anchor')"
  run cr_start_anchor 1
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/lc.argv")" = "kickstart -k gui/$(id -u)/de.valgard.claude-remote-anchor" ]
}

@test "start reports a failed kickstart and still waits for the agent's own start" {
  # The agent is loaded (the restart checked it first), so its interval can still birth
  # the anchor; the failure is named, not swallowed, and the wait goes on.
  export CR_LAUNCHCTL="$(stub launchctl 'echo "Bootstrap failed: 5: Input/output error" >&2
$CR_TMUX new-session -d -s _cr_anchor
exit 37')"
  run cr_start_anchor 1
  [ "$status" -eq 0 ]
  [ "$output" = "launchctl kickstart fehlgeschlagen (Exit 37): Bootstrap failed: 5: Input/output error" ]
}

@test "start gives up after CR_ANCHOR_WAIT when no server appears" {
  CR_ANCHOR_WAIT=1 run cr_start_anchor 1
  [ "$status" -eq 1 ]
}

@test "start does not accept a session whose name merely begins with the anchor's" {
  # tmux resolves `-t name` by prefix when there is no exact match.
  export CR_LAUNCHCTL="$(stub launchctl '$CR_TMUX new-session -d -s _cr_anchor_old')"
  CR_ANCHOR_WAIT=1 run cr_start_anchor 1
  [ "$status" -eq 1 ]
}
