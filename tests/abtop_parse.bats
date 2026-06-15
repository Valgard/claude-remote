load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "cr_abtop_sessions emits one TSV row per claude session" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  export ABTOP_FIXTURE="${REPO_ROOT}/tests/fixtures/abtop-sample.json"
  run cr_abtop_sessions
  [ "$status" -eq 0 ]
  # 2 claude sessions, codex excluded
  [ "${#lines[@]}" -eq 2 ]
  # columns: pid \t project \t status \t ctx% \t model \t task
  [[ "${lines[0]}" == 84717$'\t'claude-remote$'\t'Executing$'\t'* ]]
  [[ "${lines[1]}" == 90001$'\t'demo$'\t'Idle$'\t'* ]]
}

@test "cr_abtop_sessions returns non-zero when abtop fails" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  unset ABTOP_FIXTURE   # stub exits 1
  run cr_abtop_sessions
  [ "$status" -ne 0 ]
}
