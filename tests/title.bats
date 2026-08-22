load helpers

setup() {
  cr_setup   # exports an isolated CR_PROJECTS_DIR
  # Stand-in project dirs: <encoded-cwd>/<session-id>.jsonl
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

# A transcript carrying Claude Code's *generated* title instead of a /rename one.
make_ai_transcript() {
  local f="$1" title="$2"
  {
    printf '%s\n' '{"type":"user","message":{"role":"user"}}'
    printf '{"type":"ai-title","aiTitle":"%s"}\n' "$title"
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant"}}'
    printf '{"type":"ai-title","aiTitle":"%s"}\n' "$title"
  } > "$f"
}

# Same shape, but with a caller-chosen title.
make_transcript_named() {
  local f="$1" title="$2"
  {
    printf '%s\n' '{"type":"user","message":{"role":"user"}}'
    printf '{"type":"custom-title","customTitle":"%s"}\n' "$title"
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant"}}'
    printf '{"type":"custom-title","customTitle":"%s"}\n' "$title"
  } > "$f"
}

@test "cr_session_title returns the LAST title, not the first" {
  make_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-1.jsonl"
  run bash -c "source '$LIB'; cr_session_title '${CR_PROJECTS_DIR}/-Users-x-alpha/sid-1.jsonl'"
  [ "$status" -eq 0 ]
  [ "$output" = "aktueller-name" ]
}

@test "cr_session_title is empty for a transcript without any /rename" {
  printf '%s\n' '{"type":"user","message":{"role":"user"}}' > "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-2.jsonl"
  run bash -c "source '$LIB'; cr_session_title '${CR_PROJECTS_DIR}/-Users-x-alpha/sid-2.jsonl'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cr_session_title is empty (not an error) for a missing file" {
  run bash -c "source '$LIB'; cr_session_title '${CR_PROJECTS_DIR}/nope/nope.jsonl'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cr_session_title survives a title containing a tab or a newline" {
  printf '%s\n' '{"type":"custom-title","customTitle":"has\ttab and\nnewline"}' \
    > "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-3.jsonl"
  run bash -c "source '$LIB'; cr_session_title '${CR_PROJECTS_DIR}/-Users-x-alpha/sid-3.jsonl'"
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

@test "cr_session_title survives a transcript whose last line is still being written" {
  # A live session appends mid-line; both reversers treat the final newline as a
  # SEPARATOR, so that fragment is glued onto the previous line. If the title sits
  # there, the reversed first hit is unparsable — the second candidate covers it.
  {
    printf '%s\n' '{"type":"custom-title","customTitle":"aktueller-name"}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant"}}'
    printf '%s\n' '{"type":"custom-title","customTitle":"aktueller-name"}'
    printf '%s'   '{"type":"assistant","message":{"rol'
  } > "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-torn.jsonl"
  run bash -c "source '$LIB'; cr_session_title '${CR_PROJECTS_DIR}/-Users-x-alpha/sid-torn.jsonl'"
  [ "$status" -eq 0 ]
  [ "$output" = "aktueller-name" ]
}

@test "cr_session_title skips a line that only mentions the marker in a nested object" {
  {
    printf '%s\n' '{"type":"custom-title","customTitle":"der-echte"}'
    printf '%s\n' '{"type":"user","payload":{"type":"custom-title","x":1}}'
  } > "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-decoy.jsonl"
  run bash -c "source '$LIB'; cr_session_title '${CR_PROJECTS_DIR}/-Users-x-alpha/sid-decoy.jsonl'"
  [ "$status" -eq 0 ]
  [ "$output" = "der-echte" ]
}

@test "cr_session_title is empty (not an error) for an unreadable transcript" {
  f="${CR_PROJECTS_DIR}/-Users-x-alpha/sid-perm.jsonl"
  make_transcript "$f"; chmod 000 "$f"
  run bash -c "source '$LIB'; cr_session_title '$f'"
  chmod 644 "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cr_session_title keeps the title's words when flattening tabs and newlines" {
  printf '%s\n' '{"type":"custom-title","customTitle":"has\ttab and\nnewline"}' \
    > "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-flat.jsonl"
  run bash -c "source '$LIB'; cr_session_title '${CR_PROJECTS_DIR}/-Users-x-alpha/sid-flat.jsonl'"
  # replaced by spaces, not deleted
  [ "$output" = "has tab and newline" ]
}

@test "cr_session_file prefers the most recently written duplicate" {
  # A renamed/copied project dir leaves the same session id in two places; the
  # alphabetically first is the stale one.
  make_transcript_named "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-dup.jsonl" veraltet
  make_transcript_named "${CR_PROJECTS_DIR}/-Users-x-beta/sid-dup.jsonl" aktuell
  # explicit stamps: mtime has 1-second resolution, so two touches in the same
  # second would make the comparison meaningless
  touch -t 202001010000 "${CR_PROJECTS_DIR}/-Users-x-beta/sid-dup.jsonl"
  touch -t 202601010000 "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-dup.jsonl"
  run bash -c "source '$LIB'; cr_session_title \"\$(cr_session_file sid-dup)\""
  [ "$output" = "veraltet" ]   # alpha is newer, and alpha holds "veraltet"
  # …and the other way round, so it cannot pass on glob order alone
  touch -t 202601020000 "${CR_PROJECTS_DIR}/-Users-x-beta/sid-dup.jsonl"
  run bash -c "source '$LIB'; cr_session_title \"\$(cr_session_file sid-dup)\""
  [ "$output" = "aktuell" ]
}

@test "cr_resolve_titles gives each session in one project dir its own title" {
  # The case the whole feature exists for: two sessions, same directory.
  make_transcript_named "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-a.jsonl" titel-A
  make_transcript_named "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-b.jsonl" titel-B
  joined="$(printf 'S\td-1\t1\tp\tExecuting\t10\topus\tt\tsid-a\nS\td-2\t2\tp\tExecuting\t10\topus\tt\tsid-b\nN\t0\n')"
  run bash -c "source '$LIB'; printf '%s\n' \"\$1\" | cr_resolve_titles" _ "$joined"
  [[ "${lines[0]}" == *$'\t'"titel-A" ]]
  [[ "${lines[1]}" == *$'\t'"titel-B" ]]
}

@test "cr_resolve_titles does not leak a title onto a row without a transcript" {
  make_transcript_named "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-a.jsonl" titel-A
  joined="$(printf 'S\td-1\t1\tp\tExecuting\t10\topus\tt\tsid-a\nS\td-2\t2\tp\tExecuting\t10\topus\tt\tsid-fehlt\nN\t0\n')"
  run bash -c "source '$LIB'; printf '%s\n' \"\$1\" | cr_resolve_titles" _ "$joined"
  [[ "${lines[0]}" == *$'\t'"titel-A" ]]
  [[ "${lines[1]}" == *$'\t' ]]
}

@test "cr_resolve_titles degrades to the project when abtop reports no session id" {
  joined="$(printf 'S\td-1\t1\tproj\tExecuting\t10\topus\tt\t\nN\t0\n')"
  run bash -c "source '$LIB'; printf '%s\n' \"\$1\" | cr_resolve_titles | cr_format_rows" _ "$joined"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"proj #1"* ]]
}

@test "cr_reverse_lines uses CR_TAC when it resolves" {
  printf '#!/usr/bin/env bash\necho FROM_TAC\n' > "${BATS_TEST_TMPDIR}/mytac"
  chmod +x "${BATS_TEST_TMPDIR}/mytac"
  run bash -c "export CR_TAC='${BATS_TEST_TMPDIR}/mytac'; source '$LIB'; cr_reverse_lines /dev/null"
  [ "$output" = "FROM_TAC" ]
}

@test "cr_session_title falls back to the generated ai-title" {
  make_ai_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-ai.jsonl" "Generierter Titel"
  run bash -c "source '$LIB'; cr_session_title '${CR_PROJECTS_DIR}/-Users-x-alpha/sid-ai.jsonl'"
  [ "$status" -eq 0 ]
  [ "$output" = "Generierter Titel" ]
}

@test "cr_session_title prefers /rename over the generated title" {
  # The order that actually occurs: Claude generates a title, the user renames
  # later, and further ai-title lines may still follow — so the custom one is NOT
  # necessarily the last title line in the file.
  {
    printf '%s\n' '{"type":"ai-title","aiTitle":"Generierter Titel"}'
    printf '%s\n' '{"type":"custom-title","customTitle":"Mein Name"}'
    printf '%s\n' '{"type":"ai-title","aiTitle":"Generierter Titel"}'
  } > "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-both.jsonl"
  run bash -c "source '$LIB'; cr_session_title '${CR_PROJECTS_DIR}/-Users-x-alpha/sid-both.jsonl'"
  [ "$status" -eq 0 ]
  [ "$output" = "Mein Name" ]
}

@test "cr_session_title takes the newest /rename when several exist" {
  {
    printf '%s\n' '{"type":"custom-title","customTitle":"alt"}'
    printf '%s\n' '{"type":"ai-title","aiTitle":"generiert"}'
    printf '%s\n' '{"type":"custom-title","customTitle":"aktuell"}'
  } > "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-many.jsonl"
  run bash -c "source '$LIB'; cr_session_title '${CR_PROJECTS_DIR}/-Users-x-alpha/sid-many.jsonl'"
  [ "$output" = "aktuell" ]
}

@test "cr_session_title survives a torn last line on an ai-title transcript" {
  {
    printf '%s\n' '{"type":"ai-title","aiTitle":"Generierter Titel"}'
    printf '%s\n' '{"type":"user"}'
    printf '%s\n' '{"type":"ai-title","aiTitle":"Generierter Titel"}'
    printf '%s'   '{"type":"assistant","message":{"rol'
  } > "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-aitorn.jsonl"
  run bash -c "source '$LIB'; cr_session_title '${CR_PROJECTS_DIR}/-Users-x-alpha/sid-aitorn.jsonl'"
  [ "$output" = "Generierter Titel" ]
}

@test "cr_menu_lines shows the generated title when there is no /rename" {
  pid="$(cr_make_session live2)"
  sid="sid-ai-e2e"
  make_ai_transcript "${CR_PROJECTS_DIR}/-Users-x-beta/${sid}.jsonl" "MSM offene Aufgaben"
  fixture="${BATS_TEST_TMPDIR}/abtop2.json"
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
  [[ "$output" == *"MSM offene Aufgaben #${pid}"* ]]
  [[ "$output" != *"liveproj"* ]]
}

@test "cr_session_title keeps /rename even with three generated titles after it" {
  # Pins the -m4 window. Claude Code appends the two kinds as per-turn pairs ending
  # on the ai-title, so in practice exactly one ai-title follows the last custom-title
  # — this fixture spends the whole budget, so shrinking the limit breaks the test
  # rather than silently showing the generated name for a session the user renamed.
  {
    printf '%s\n' '{"type":"custom-title","customTitle":"Mein Name"}'
    printf '%s\n' '{"type":"ai-title","aiTitle":"Generiert"}'
    printf '%s\n' '{"type":"ai-title","aiTitle":"Generiert"}'
    printf '%s\n' '{"type":"ai-title","aiTitle":"Generiert"}'
  } > "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-window.jsonl"
  run bash -c "source '$LIB'; cr_session_title '${CR_PROJECTS_DIR}/-Users-x-alpha/sid-window.jsonl'"
  [ "$output" = "Mein Name" ]
}

@test "cr_session_title ignores a non-string title instead of losing both kinds" {
  # jq aborts the whole program on a type error, so an unusable customTitle used to
  # take the ai-title fallback down with it — indistinguishable from "no title set".
  for bad in 42 true null '{"a":1}' '[]' '""'; do
    {
      printf '%s\n' '{"type":"ai-title","aiTitle":"Fallback"}'
      printf '{"type":"custom-title","customTitle":%s}\n' "$bad"
    } > "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-bad.jsonl"
    run bash -c "source '$LIB'; cr_session_title '${CR_PROJECTS_DIR}/-Users-x-alpha/sid-bad.jsonl'"
    [ "$output" = "Fallback" ] || { echo "customTitle=$bad gave '$output'"; return 1; }
  done
}

@test "cr_session_title strips control characters, not just tabs and newlines" {
  # An ESC would otherwise reach cr_format_rows, where vislen counts it as a visible
  # character and vistrunc could cut inside the escape sequence.
  python3 -c "
import json, sys
sys.stdout.write(json.dumps({'type':'custom-title','customTitle':'rot'+chr(27)+'[31mX'+chr(27)+'[0mende'}, separators=(',', ':')) + '\n')" \
    > "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-esc.jsonl"
  run bash -c "source '$LIB'; cr_session_title '${CR_PROJECTS_DIR}/-Users-x-alpha/sid-esc.jsonl'"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" = "rot [31mX [0mende" ]
}
