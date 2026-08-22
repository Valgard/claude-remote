load helpers

setup() {
  cr_setup
  # Stand-in for ~/.claude/projects: <encoded-cwd>/<session-id>.jsonl
  export CR_PROJECTS_DIR="${BATS_TEST_TMPDIR}/projects"
  mkdir -p "${CR_PROJECTS_DIR}/-Users-x-alpha" "${CR_PROJECTS_DIR}/-Users-x-beta"
}
teardown() { cr_teardown; }

LIB="${REPO_ROOT}/lib/claude-remote-lib.sh"

# A transcript with three custom-title lines: Claude Code re-appends the title on
# every turn, so the LAST one is the current title.
make_transcript() {
  local f="$1"
  {
    printf '%s\n' '{"type":"user","message":{"role":"user"}}'
    printf '%s\n' '{"type":"custom-title","customTitle":"erster-name"}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant"}}'
    printf '%s\n' '{"type":"custom-title","customTitle":"zweiter-name"}'
    printf '%s\n' '{"type":"custom-title","customTitle":"aktueller-name"}'
    printf '%s\n' '{"type":"user","message":{"role":"user"}}'
  } > "$f"
}

@test "cr_custom_title returns the LAST title, not the first" {
  make_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-1.jsonl"
  run bash -c "source '$LIB'; cr_custom_title '${CR_PROJECTS_DIR}/-Users-x-alpha/sid-1.jsonl'"
  [ "$status" -eq 0 ]
  [ "$output" = "aktueller-name" ]
}

@test "cr_custom_title is empty for a transcript without any /rename" {
  printf '%s\n' '{"type":"user","message":{"role":"user"}}' > "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-2.jsonl"
  run bash -c "source '$LIB'; cr_custom_title '${CR_PROJECTS_DIR}/-Users-x-alpha/sid-2.jsonl'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cr_custom_title is empty (not an error) for a missing file" {
  run bash -c "source '$LIB'; cr_custom_title '${CR_PROJECTS_DIR}/nope/nope.jsonl'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cr_custom_title survives a title containing a tab or a newline" {
  printf '%s\n' '{"type":"custom-title","customTitle":"has\ttab and\nnewline"}' \
    > "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-3.jsonl"
  run bash -c "source '$LIB'; cr_custom_title '${CR_PROJECTS_DIR}/-Users-x-alpha/sid-3.jsonl'"
  [ "$status" -eq 0 ]
  # flattened to a single TSV-safe line
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" != *$'\t'* ]]
}

@test "cr_session_file locates a transcript by session id across project dirs" {
  make_transcript "${CR_PROJECTS_DIR}/-Users-x-beta/sid-9.jsonl"
  run bash -c "source '$LIB'; cr_session_file sid-9"
  [ "$status" -eq 0 ]
  [ "$output" = "${CR_PROJECTS_DIR}/-Users-x-beta/sid-9.jsonl" ]
}

@test "cr_session_file is empty for an unknown session id" {
  run bash -c "source '$LIB'; cr_session_file sid-does-not-exist"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cr_resolve_titles appends the title to S rows and leaves N rows alone" {
  make_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-7.jsonl"
  joined="$(printf 'S\tdemo-5\t5\tdemo\tExecuting\t10\topus\ttask\tsid-7\nN\t2\n')"
  run bash -c "source '$LIB'; printf '%s\n' \"\$1\" | cr_resolve_titles" _ "$joined"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'S\tdemo-5\t5\tdemo\tExecuting\t10\topus\ttask\tsid-7\taktueller-name')" ]
  [ "${lines[1]}" = "$(printf 'N\t2')" ]
}

@test "cr_resolve_titles appends an empty column when no title is set" {
  printf '%s\n' '{"type":"user"}' > "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-8.jsonl"
  joined="$(printf 'S\tdemo-5\t5\tdemo\tExecuting\t10\topus\ttask\tsid-8\nN\t0\n')"
  run bash -c "source '$LIB'; printf '%s\n' \"\$1\" | cr_resolve_titles" _ "$joined"
  [ "$status" -eq 0 ]
  # trailing empty field: the row still has the title column, it is just empty
  [ "${lines[0]}" = "$(printf 'S\tdemo-5\t5\tdemo\tExecuting\t10\topus\ttask\tsid-8\t')" ]
}

@test "cr_format_rows prefers the /rename title over abtop's project" {
  joined="$(printf 'S\tcore_keeper-67681\t67681\tcore_keeper\tExecuting\t44\topus\ttask\tsid\tpixaki-adapter\nN\t0\n')"
  run bash -c "source '$LIB'; printf '%s\n' \"\$1\" | cr_format_rows" _ "$joined"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"pixaki-adapter #67681"* ]]
  [[ "${lines[0]}" != *"core_keeper #67681"* ]]
  # the attach key is untouched
  [ "${lines[0]%%$'\t'*}" = "core_keeper-67681" ]
}

@test "cr_format_rows falls back to project when the title column is empty" {
  joined="$(printf 'S\tcore_keeper-64023\t64023\tdrill-in-row-model\tExecuting\t33\topus\ttask\tsid\t\nN\t0\n')"
  run bash -c "source '$LIB'; printf '%s\n' \"\$1\" | cr_format_rows" _ "$joined"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"drill-in-row-model #64023"* ]]
}

@test "cr_abtop_sessions emits the session id as its last column" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  export ABTOP_FIXTURE="${REPO_ROOT}/tests/fixtures/abtop-sample.json"
  run cr_abtop_sessions
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *$'\t'"sess-84717" ]]
  [[ "${lines[1]}" == *$'\t'"sess-90001" ]]
}

@test "cr_menu_lines shows the /rename title end to end" {
  pid="$(cr_make_session live)"
  sid="sid-e2e"
  make_transcript "${CR_PROJECTS_DIR}/-Users-x-beta/${sid}.jsonl"
  fixture="${BATS_TEST_TMPDIR}/abtop.json"
  cat > "$fixture" <<JSON
{ "sessions": [
  { "agent_cli":"claude","pid":${pid},"session_id":"${sid}","project_name":"liveproj",
    "status":"Idle","model":"opus","context_percent":5,"current_task":"alive" }
] }
JSON
  export ABTOP_FIXTURE="$fixture"
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_menu_lines
  [ "$status" -eq 0 ]
  [[ "$output" == *"aktueller-name #${pid}"* ]]
  [[ "$output" != *"liveproj"* ]]
  [ "${lines[0]%%$'\t'*}" = "live" ]
}

@test "cr_reverse_lines falls back to BSD tail -r when tac is absent" {
  printf 'eins\nzwei\ndrei\n' > "${BATS_TEST_TMPDIR}/x"
  # CR_TAC points at nothing resolvable, so the BSD fallback branch is what runs.
  run bash -c "export CR_TAC=cr-no-such-tac; source '$LIB'; cr_reverse_lines '${BATS_TEST_TMPDIR}/x'"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "drei" ]
  [ "${lines[2]}" = "eins" ]
}

@test "cr_custom_title emits the title once, not twice, on the fallback path" {
  # Regression guard: `tac || tail -r` would read the SIGPIPE from our early-exiting
  # reader as a failure and run the second tool as well, printing the title twice.
  make_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-p.jsonl"
  run bash -c "export CR_TAC=cr-no-such-tac; source '$LIB'; cr_custom_title '${CR_PROJECTS_DIR}/-Users-x-alpha/sid-p.jsonl'"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" = "aktueller-name" ]
}
