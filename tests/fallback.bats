load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "--list shows abtop-enriched rows for attachable sessions" {
  pid="$(cr_make_session proj)"
  # Build an abtop fixture whose pid matches the live pane pid.
  fixture="$(mktemp)"
  cat > "$fixture" <<JSON
{ "sessions": [ { "agent_cli":"claude","pid":${pid},"project_name":"proj","status":"Idle","model":"opus","context_percent":7,"current_task":"hello" } ] }
JSON
  export ABTOP_FIXTURE="$fixture"
  run claude-remote-pick --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"proj"* ]]
  [[ "$output" == *"Idle"* ]]
  [[ "$output" == *"hello"* ]]
}

@test "--list is empty when abtop reports no claude sessions" {
  fixture="$(mktemp)"; printf '{ "sessions": [] }' > "$fixture"
  export ABTOP_FIXTURE="$fixture"
  run claude-remote-pick --list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--list falls back to tmux session names when abtop fails" {
  cr_make_session standalone >/dev/null
  unset ABTOP_FIXTURE   # abtop stub now exits 1
  run claude-remote-pick --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"standalone"* ]]
  [[ "$output" == *"(abtop nicht verfügbar"* ]]
}
