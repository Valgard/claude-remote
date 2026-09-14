load helpers

setup() {
  cr_setup # exports an isolated CR_PROJECTS_DIR and CR_TMUX
  mkdir -p "${CR_PROJECTS_DIR}/-Users-x-alpha"
  MAP="${BATS_TEST_TMPDIR}/titles"
}
teardown() { cr_teardown; }

LIB="${REPO_ROOT}/lib/claude-remote-lib.sh"

# The prefix Claude Code puts in front of the terminal title (U+2733 + space).
# Spelled as bytes so the fixture cannot drift with this file's encoding — and
# pinned against the library's own default by a test below, so a typo in either
# copy names the guilty side instead of failing every prefix test at once.
PFX=$'\xe2\x9c\xb3 '

# A transcript carrying a /rename title, shaped like the real append-only file.
make_titled_transcript() {
  local f="$1" title="$2"
  {
    printf '%s\n' '{"type":"user","message":{"role":"user"}}'
    printf '{"type":"custom-title","customTitle":"%s"}\n' "$title"
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant"}}'
    printf '{"type":"custom-title","customTitle":"%s"}\n' "$title"
  } >"$f"
}

# One joined S row: S <session> <pid> <project> <status> <ctx> <model> <task> <session_id>
s_row() {
  printf 'S\t%s\t%s\talpha\tWaiting\t42\tclaude-opus-5\twaiting\t%s\n' "$1" "$2" "$3"
}

# Drive cr_resolve_titles over caller-supplied rows (one row per argument). With a
# map path, without one if the first argument is empty — keeps the `run` form
# readable instead of re-exporting functions into a `bash -c`.
# Each row is re-terminated here on purpose: `$(s_row …)` strips the trailing
# newline, and a `while read` loop never sees an unterminated final line.
resolve_rows() {
  local mapfile="$1" r
  shift
  # Mirrors cr_resolve_titles' own arity gate: an empty first argument means "call
  # it with no argument", never "call it with an empty path" — otherwise the
  # helper would paper over exactly the distinction a test below pins.
  for r in "$@"; do printf '%s\n' "$r"; done |
    if [ -n "$mapfile" ]; then cr_resolve_titles "$mapfile"; else cr_resolve_titles; fi
}

# The title column is the last field of a row.
title_of() { printf '%s' "${1##*$'\t'}"; }

@test "the test prefix and the library default are the same bytes" {
  # Guard for every prefix test below: if these two literals ever drift apart,
  # this test says which side is wrong instead of reddening the whole file.
  source "$LIB"
  [ "$PFX" = "$CR_TITLE_PREFIX" ]
}

@test "cr_pane_title_clean returns the title behind Claude Code's status prefix" {
  source "$LIB"
  cr_pane_title_clean "${PFX}mein_projekt"
  [ "$CR_PANE_TITLE" = "mein_projekt" ]
}

@test "cr_pane_title_clean keeps spaces and punctuation inside the title" {
  source "$LIB"
  cr_pane_title_clean "${PFX}Titel mit Leerzeichen #42 und Zeichen"
  [ "$CR_PANE_TITLE" = "Titel mit Leerzeichen #42 und Zeichen" ]
}

@test "cr_pane_title_clean reports no title for the untitled placeholder" {
  source "$LIB"
  run cr_pane_title_clean "${PFX}Claude Code"
  [ "$status" -eq 0 ] # rejection is not an error — callers branch on emptiness
  cr_pane_title_clean "${PFX}Claude Code"
  [ "$CR_PANE_TITLE" = "" ]
}

@test "cr_pane_title_clean reports no title when Claude Code did not set one" {
  # A pane whose TUI has not taken over the title yet still carries the terminal
  # default (the hostname) — never a session title.
  source "$LIB"
  run cr_pane_title_clean "hostname.local"
  [ "$status" -eq 0 ]
  cr_pane_title_clean "hostname.local"
  [ "$CR_PANE_TITLE" = "" ]
}

@test "cr_pane_title_clean reports no title for a bare prefix" {
  source "$LIB"
  run cr_pane_title_clean "${PFX}"
  [ "$status" -eq 0 ]
  cr_pane_title_clean "${PFX}"
  [ "$CR_PANE_TITLE" = "" ]
}

@test "cr_pane_title_clean clears a stale result from a previous call" {
  # The out-variable is shared state; a rejected title must not leave the
  # previous row's answer standing, or one pane's name leaks onto the next row.
  source "$LIB"
  cr_pane_title_clean "${PFX}erster"
  cr_pane_title_clean "hostname.local"
  [ "$CR_PANE_TITLE" = "" ]
}

@test "cr_pane_title_clean honours a redefined CR_TITLE_PREFIX" {
  # CLAUDE.md sells the seams as the release-free repair path if Claude Code
  # changes its format. Untested, that promise is just prose.
  CR_TITLE_PREFIX='>> '
  source "$LIB"
  cr_pane_title_clean ">> mein_titel"
  [ "$CR_PANE_TITLE" = "mein_titel" ]
}

@test "cr_pane_title_clean honours a redefined CR_TITLE_PLACEHOLDER" {
  CR_TITLE_PLACEHOLDER='Untitled Session'
  source "$LIB"
  cr_pane_title_clean "${PFX}Untitled Session"
  [ "$CR_PANE_TITLE" = "" ]
  cr_pane_title_clean "${PFX}Claude Code"
  [ "$CR_PANE_TITLE" = "Claude Code" ] # no longer the placeholder
}

@test "cr_pane_titles maps each pane pid to its raw pane title" {
  source "$LIB"
  pid="$(cr_make_session alpha-1)"
  # shellcheck disable=SC2086
  $CR_TMUX select-pane -t alpha-1 -T "${PFX}gesetzter_titel"
  run cr_pane_titles
  [ "$status" -eq 0 ]
  [ "$output" = "${pid}"$'\t'"${PFX}gesetzter_titel" ]
}

@test "cr_pane_titles reaches panes across session boundaries" {
  # Pins the `-a` in list-panes. Without it tmux reports only the *current*
  # session's panes, every other session loses its pane title, and the picker
  # falls wordlessly back into the reported bug — with a one-session test green.
  source "$LIB"
  pid1="$(cr_make_session alpha-1)"
  pid2="$(cr_make_session beta-2)"
  # shellcheck disable=SC2086
  $CR_TMUX select-pane -t alpha-1 -T "${PFX}titel_eins"
  # shellcheck disable=SC2086
  $CR_TMUX select-pane -t beta-2 -T "${PFX}titel_zwei"
  run cr_pane_titles
  [[ "$output" == *"${pid1}"$'\t'"${PFX}titel_eins"* ]]
  [[ "$output" == *"${pid2}"$'\t'"${PFX}titel_zwei"* ]]
}

@test "cr_resolve_titles prefers the pane title over the transcript" {
  source "$LIB"
  make_titled_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-1.jsonl" "aus-transkript"
  # Guard: the transcript tier must actually have an answer here, or "prefers"
  # is unproven — the test would pass against an implementation with no tier 2.
  [ "$(cr_session_title "$(cr_session_file sid-1)")" = "aus-transkript" ]
  printf '%s\t%s\n' 4242 "${PFX}aus-pane" >"$MAP"

  run resolve_rows "$MAP" "$(s_row alpha-4242 4242 sid-1)"
  [ "$status" -eq 0 ]
  [ "$(title_of "$output")" = "aus-pane" ]
}

@test "cr_resolve_titles falls back to the transcript when the pane shows the placeholder" {
  source "$LIB"
  make_titled_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-1.jsonl" "aus-transkript"
  printf '%s\t%s\n' 4242 "${PFX}Claude Code" >"$MAP"

  run resolve_rows "$MAP" "$(s_row alpha-4242 4242 sid-1)"
  [ "$(title_of "$output")" = "aus-transkript" ]
}

@test "cr_resolve_titles falls back to the transcript for a pid absent from the map" {
  source "$LIB"
  make_titled_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-1.jsonl" "aus-transkript"
  printf '%s\t%s\n' 9999 "${PFX}fremd" >"$MAP"

  run resolve_rows "$MAP" "$(s_row alpha-4242 4242 sid-1)"
  [ "$(title_of "$output")" = "aus-transkript" ]
}

@test "cr_resolve_titles resolves every row, not just the first" {
  # The loop carries `map` across rows. A refactor that consumed it (assigning the
  # stripped tail back to `map`) would resolve row 1 correctly and every later row
  # from the transcript — invisible to any single-row test.
  source "$LIB"
  make_titled_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-a.jsonl" "transkript-a"
  make_titled_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-b.jsonl" "transkript-b"
  {
    printf '%s\t%s\n' 4242 "${PFX}pane-a"
    printf '%s\t%s\n' 4343 "${PFX}pane-b"
  } >"$MAP"

  run resolve_rows "$MAP" "$(s_row alpha-4242 4242 sid-a)" "$(s_row alpha-4343 4343 sid-b)"
  [ "$status" -eq 0 ]
  [ "$(title_of "${lines[0]}")" = "pane-a" ]
  [ "$(title_of "${lines[1]}")" = "pane-b" ]
}

@test "cr_resolve_titles never matches a pid that is only a prefix of another" {
  # 424 must not pick up 4242's title. Both rows run in ONE pass so the test
  # cannot pass by ignoring the map altogether: 4242 has to resolve from the pane
  # while 424 falls to its transcript.
  source "$LIB"
  make_titled_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-lang.jsonl" "transkript-lang"
  make_titled_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-kurz.jsonl" "transkript-kurz"
  printf '%s\t%s\n' 4242 "${PFX}nur-fuer-4242" >"$MAP"

  run resolve_rows "$MAP" "$(s_row alpha-4242 4242 sid-lang)" "$(s_row alpha-424 424 sid-kurz)"
  [ "$(title_of "${lines[0]}")" = "nur-fuer-4242" ]
  [ "$(title_of "${lines[1]}")" = "transkript-kurz" ]
}

@test "cr_resolve_titles without a map behaves exactly as before" {
  source "$LIB"
  make_titled_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-1.jsonl" "aus-transkript"

  run resolve_rows "" "$(s_row alpha-4242 4242 sid-1)"
  [ "$(title_of "$output")" = "aus-transkript" ]
}

@test "cr_resolve_titles warns when it was handed a map file it cannot use" {
  # A mistyped path is a programming error, not "skip tier 1". Without a word on
  # stderr the fix is simply inactive, and its only symptom is the original bug
  # returning — in a version that was announced as fixing it.
  source "$LIB"
  make_titled_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-1.jsonl" "aus-transkript"
  run bash -c "source '$LIB'; printf 'S\tal\t4242\tp\tW\t1\tm\tt\tsid-1\n' | cr_resolve_titles '${BATS_TEST_TMPDIR}/gibt-es-nicht' 2>&1 >/dev/null"
  [[ "$output" == *"gibt-es-nicht"* ]]
}

@test "cr_resolve_titles warns when the map path is a directory, not a file" {
  # -r alone passes for a directory, and bash's $(<dir) then fails without a
  # single byte on stderr — the quietest possible way to lose the whole tier.
  source "$LIB"
  make_titled_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-1.jsonl" "aus-transkript"
  mkdir -p "${BATS_TEST_TMPDIR}/ein-verzeichnis"
  run bash -c "source '$LIB'; printf 'S\tal\t4242\tp\tW\t1\tm\tt\tsid-1\n' | cr_resolve_titles '${BATS_TEST_TMPDIR}/ein-verzeichnis' 2>&1 >/dev/null"
  [[ "$output" == *"ein-verzeichnis"* ]]
}

@test "cr_resolve_titles warns when handed an empty string as the map path" {
  # `cr_resolve_titles "$(build_map)"` with a failed substitution passes "". That
  # is a caller error, not the no-argument form — telling them apart needs arity,
  # not emptiness, or tier 1 disappears silently.
  source "$LIB"
  make_titled_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-1.jsonl" "aus-transkript"
  run bash -c "source '$LIB'; printf 'S\tal\t4242\tp\tW\t1\tm\tt\tsid-1\n' | cr_resolve_titles '' 2>&1 >/dev/null"
  [ -n "$output" ]
}

@test "cr_resolve_titles stays silent when no map was asked for" {
  # The no-argument form is a supported contract (the pre-2026-09 behaviour), not
  # an error — warning here would cry wolf on every abtop-less fallback.
  source "$LIB"
  make_titled_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-1.jsonl" "aus-transkript"
  run bash -c "source '$LIB'; printf 'S\tal\t4242\tp\tW\t1\tm\tt\tsid-1\n' | cr_resolve_titles 2>&1 >/dev/null"
  [ -z "$output" ]
}

@test "cr_resolve_titles accepts a process substitution as its map" {
  # How cr_menu_lines actually calls it. /dev/fd/N is a pipe, so a `-f` test would
  # reject it and silently disable tier 1 in production while file-based tests
  # stayed green.
  source "$LIB"
  make_titled_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-1.jsonl" "aus-transkript"
  run bash -c "source '$LIB'; printf 'S\tal\t4242\tp\tW\t1\tm\tt\tsid-1\n' | cr_resolve_titles <(printf '4242\t${PFX}aus-pane\n')"
  [ "$(title_of "$output")" = "aus-pane" ]
}

@test "cr_resolve_titles still degrades to the transcript after warning" {
  # Loud, but not fatal: the picker must still render.
  source "$LIB"
  make_titled_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-1.jsonl" "aus-transkript"
  run bash -c "source '$LIB'; printf 'S\tal\t4242\tp\tW\t1\tm\tt\tsid-1\n' | cr_resolve_titles '${BATS_TEST_TMPDIR}/gibt-es-nicht' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$(title_of "$output")" = "aus-transkript" ]
}

@test "cr_resolve_titles tolerates an empty map file" {
  source "$LIB"
  make_titled_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-1.jsonl" "aus-transkript"
  : >"$MAP"

  run resolve_rows "$MAP" "$(s_row alpha-4242 4242 sid-1)"
  [ "$status" -eq 0 ]
  [ "$(title_of "$output")" = "aus-transkript" ]
}

@test "the picker shows the pane's own title when abtop points at a foreign session" {
  # The reported bug: a second Claude session ran in the same project directory
  # (one cross-session message is enough), wrote the more recent transcript, and
  # abtop handed its session_id to this pid. The transcript lookup then resolves
  # a *different* session's name. The pane title cannot be wrong that way.
  source "$LIB"
  pid="$(cr_make_session proj-x)"
  # shellcheck disable=SC2086
  $CR_TMUX select-pane -t proj-x -T "${PFX}eigene_session"
  make_titled_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/fremd.jsonl" "fremde_session"
  # Guard: the foreign transcript must really be resolvable, or this stops being a
  # reproduction of the bug and quietly degrades into "a pane title is displayed".
  [ "$(cr_session_title "$(cr_session_file fremd)")" = "fremde_session" ]
  fixture="$(mktemp)"
  cat >"$fixture" <<JSON
{ "sessions": [ { "agent_cli":"claude","pid":${pid},"project_name":"proj","status":"Idle","model":"opus","context_percent":35,"current_task":"waiting","session_id":"fremd" } ] }
JSON
  export ABTOP_FIXTURE="$fixture"

  run cr_menu_lines
  [ "$status" -eq 0 ]
  [[ "$output" == *"eigene_session"* ]]
  [[ "$output" != *"fremde_session"* ]]
}

@test "the picker still reads the transcript when the pane carries no title" {
  source "$LIB"
  pid="$(cr_make_session alpha-y)"
  # shellcheck disable=SC2086
  $CR_TMUX select-pane -t alpha-y -T "${PFX}${CR_TITLE_PLACEHOLDER}"
  make_titled_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-2.jsonl" "aus-transkript"
  fixture="$(mktemp)"
  cat >"$fixture" <<JSON
{ "sessions": [ { "agent_cli":"claude","pid":${pid},"project_name":"alpha","status":"Idle","model":"opus","context_percent":5,"current_task":"waiting","session_id":"sid-2" } ] }
JSON
  export ABTOP_FIXTURE="$fixture"

  run cr_menu_lines
  [ "$status" -eq 0 ]
  [[ "$output" == *"aus-transkript"* ]]
}

@test "a session actually renamed to the placeholder still shows its name" {
  # The one string the gates cannot tell apart from "no title". It costs nothing
  # here because tier 2 answers: the transcript says the name really is that.
  source "$LIB"
  pid="$(cr_make_session alpha-z)"
  # shellcheck disable=SC2086
  $CR_TMUX select-pane -t alpha-z -T "${PFX}${CR_TITLE_PLACEHOLDER}"
  make_titled_transcript "${CR_PROJECTS_DIR}/-Users-x-alpha/sid-3.jsonl" "Claude Code"
  fixture="$(mktemp)"
  cat >"$fixture" <<JSON
{ "sessions": [ { "agent_cli":"claude","pid":${pid},"project_name":"alpha","status":"Idle","model":"opus","context_percent":5,"current_task":"waiting","session_id":"sid-3" } ] }
JSON
  export ABTOP_FIXTURE="$fixture"

  run cr_menu_lines
  [[ "$output" == *"Claude Code"* ]]
}

@test "cr_resolve_titles passes non-S rows through untouched" {
  source "$LIB"
  printf '%s\t%s\n' 4242 "${PFX}aus-pane" >"$MAP"
  run resolve_rows "$MAP" $'N\t3'
  [ "$output" = $'N\t3' ]
}
