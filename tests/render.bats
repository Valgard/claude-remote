load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

LIB="${REPO_ROOT}/lib/claude-remote-lib.sh"

@test "cr_format_rows (plain): glyph, name #pid, ctx%, short model; raw status/model gone" {
  joined="$(printf 'S\tclaude-remote-84717\t84717\tclaude-remote\tExecuting\t49\tclaude-opus-4-8\tdoing things\nN\t0\n')"
  run bash -c "source '$LIB'; printf '%s\n' \"\$1\" | cr_format_rows" _ "$joined"
  [ "$status" -eq 0 ]
  # the attach key (column 1) stays the full session name
  [ "${lines[0]%%$'\t'*}" = "claude-remote-84717" ]
  [[ "${lines[0]}" == *"►"* ]]
  [[ "${lines[0]}" == *"claude-remote #84717"* ]]
  [[ "${lines[0]}" == *"49%"* ]]
  [[ "${lines[0]}" == *"opus"* ]]
  # the verbose model and the status word are not shown
  [[ "${lines[0]}" != *"claude-opus-4-8"* ]]
  [[ "${lines[0]}" != *"Executing"* ]]
}

@test "cr_format_rows: status maps to a glyph and an empty model shows a dash" {
  joined="$(printf 'S\tdemo-9\t9\tdemo\tWaiting\t0\t-\twaiting\nN\t0\n')"
  run bash -c "source '$LIB'; printf '%s\n' \"\$1\" | cr_format_rows" _ "$joined"
  [[ "${lines[0]}" == *"◐"* ]]
  [[ "${lines[0]}" == *"—"* ]]
  [[ "${lines[0]}" == *"demo #9"* ]]
}

@test "cr_format_rows (plain) emits no ANSI escape codes" {
  joined="$(printf 'S\tcr-7\t7\tcr\tExecuting\t49\topus\ttask\nN\t0\n')"
  run bash -c "source '$LIB'; printf '%s\n' \"\$1\" | cr_format_rows" _ "$joined"
  [[ "$output" != *$'\033['* ]]
}

@test "cr_format_rows (CR_COLOR=1) emits ANSI for glyph/ctx and dims the pid" {
  joined="$(printf 'S\tcr-7\t7\tcr\tExecuting\t49\topus\ttask\nN\t0\n')"
  run bash -c "source '$LIB'; export CR_COLOR=1; printf '%s\n' \"\$1\" | cr_format_rows" _ "$joined"
  # green (active status + ctx<50) and dim (pid) codes present
  [[ "$output" == *$'\033[32m'* ]]
  [[ "$output" == *$'\033[2m'* ]]
  # visible text survives (a dim code sits between the name and "#pid", so the
  # contiguous "cr #7" is intentionally split — check the parts)
  [[ "$output" == *"49%"* ]]
  [[ "$output" == *"cr"* ]]
  [[ "$output" == *"#7"* ]]
}

@test "cr_footnote prints the non-attachable hint only when N>0" {
  run bash -c "source '$LIB'; printf 'N\t3\n' | cr_footnote"
  [[ "$output" == *"3"* ]]
  [[ "$output" == *"claude-remote"* ]]
  run bash -c "source '$LIB'; printf 'N\t0\n' | cr_footnote"
  [ -z "$output" ]
}
