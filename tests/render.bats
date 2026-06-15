load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "cr_format_rows renders one human line per attachable session" {
  joined="$(printf 'S\tcr\t84717\tclaude-remote\tExecuting\t49\topus\tdoing things\nN\t2\n')"
  run bash -c "source '${REPO_ROOT}/lib/claude-remote-lib.sh'; printf '%s\n' \"\$1\" | cr_format_rows" _ "$joined"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"cr"* ]]
  [[ "${lines[0]}" == *"claude-remote"* ]]
  [[ "${lines[0]}" == *"Executing"* ]]
  [[ "${lines[0]}" == *"49%"* ]]
}

@test "cr_footnote prints the non-attachable hint only when N>0" {
  run bash -c "source '${REPO_ROOT}/lib/claude-remote-lib.sh'; printf 'N\t3\n' | cr_footnote"
  [[ "$output" == *"3"* ]]
  [[ "$output" == *"claude-remote"* ]]
  run bash -c "source '${REPO_ROOT}/lib/claude-remote-lib.sh'; printf 'N\t0\n' | cr_footnote"
  [ -z "$output" ]
}
