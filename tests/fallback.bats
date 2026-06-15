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

@test "--list lists the live session and counts the bogus one in the footnote" {
  pid="$(cr_make_session live)"
  fixture="$(mktemp)"
  cat > "$fixture" <<JSON
{ "sessions": [
  { "agent_cli":"claude","pid":${pid},"project_name":"liveproj","status":"Idle","model":"opus","context_percent":5,"current_task":"alive" },
  { "agent_cli":"claude","pid":999999,"project_name":"ghostproj","status":"Idle","model":"opus","context_percent":3,"current_task":"gone" }
] }
JSON
  export ABTOP_FIXTURE="$fixture"
  run claude-remote-pick --list
  [ "$status" -eq 0 ]
  # the live session is selectable
  [[ "$output" == *"liveproj"* ]]
  # the bogus (non-attachable) session is NOT shown as a selectable row
  [[ "$output" != *"ghostproj"* ]]
  # exactly one non-attachable session reported in the footnote
  [[ "$output" == *"1 weitere"* ]]
}
