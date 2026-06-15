# Shared bats helpers. Source from each .bats file: `load helpers`.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

cr_setup() {
  # Isolated tmux server — never touches the user's real sessions.
  CR_SOCKET="cr_test_${BATS_SUITE_TEST_NUMBER}_$$"
  export CR_TMUX="tmux -L ${CR_SOCKET}"
  export CR_ABTOP="${REPO_ROOT}/tests/fixtures/abtop-stub"
  # Inject a stub named `claude` ahead of the real one on PATH. The isolated
  # tmux server started below inherits this PATH and resolves `claude` to the stub.
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_BIN"
  ln -sf "${REPO_ROOT}/tests/fixtures/fake-claude" "${STUB_BIN}/claude"
  export PATH="${STUB_BIN}:${REPO_ROOT}/bin:${PATH}"
}

cr_teardown() {
  ${CR_TMUX} kill-server 2>/dev/null || true
}

# Start an isolated tmux session running the fake-claude stub.
# Usage: cr_make_session <session-name>  -> echoes the pane_pid
cr_make_session() {
  local name="$1"
  ${CR_TMUX} new-session -d -s "$name" -- claude >/dev/null
  ${CR_TMUX} display-message -p -t "$name" '#{pane_pid}'
}
