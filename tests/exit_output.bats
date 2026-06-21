load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

# --- pure helpers: exit dir / file / buffer naming ------------------------------

@test "cr_exit_dir honours a CR_EXIT_DIR override" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run env CR_EXIT_DIR=/tmp/cr-xyz bash -c \
    "source '${REPO_ROOT}/lib/claude-remote-lib.sh'; cr_exit_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/cr-xyz" ]
}

@test "cr_exit_dir defaults to a claude-remote-exit dir under the temp dir" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run bash -c "unset CR_EXIT_DIR; source '${REPO_ROOT}/lib/claude-remote-lib.sh'; cr_exit_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-remote-exit" ]]
}

@test "cr_exit_file places a sanitised session name under the exit dir" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run env CR_EXIT_DIR=/tmp/cr-xyz bash -c \
    "source '${REPO_ROOT}/lib/claude-remote-lib.sh'; cr_exit_file 'proj/with space-123'"
  [ "$status" -eq 0 ]
  # stays inside the dir, odd characters collapsed to underscores
  [ "$output" = "/tmp/cr-xyz/proj_with_space-123" ]
}

@test "cr_exit_buf derives a path-free, sanitised buffer name from the session" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_exit_buf 'proj/with space-123'
  [ "$status" -eq 0 ]
  [[ "$output" != *"/"* ]]          # buffer names carry no path
  [[ "$output" == *"proj_with_space-123" ]]
}

# --- cr_drain_exit_output ------------------------------------------------------

@test "cr_drain_exit_output prints the named session's captured lines, dropping banner and blank padding" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  d="$(mktemp -d)"
  export CR_EXIT_DIR="$d"
  printf 'SESSION-ID: abc\nResume: claude --resume abc\nPane is dead (status 0, Sun Jun 21)\n\n\n' \
    >"$(cr_exit_file sess-1)"
  run cr_drain_exit_output sess-1
  [ "$status" -eq 0 ]                                  # 0 == something was shown
  [[ "$output" == *"SESSION-ID: abc"* ]]
  [[ "$output" == *"Resume: claude --resume abc"* ]]
  ! grep -q 'Pane is dead' <<<"$output"               # tmux banner filtered out
  [ "$(printf '%s\n' "$output" | tail -1)" = "Resume: claude --resume abc" ]  # trailing blanks trimmed
  [ ! -e "$(cr_exit_file sess-1)" ]                    # capture file consumed
}

@test "cr_drain_exit_output returns non-zero and prints nothing when the session has no capture" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  export CR_EXIT_DIR="$(mktemp -d)" # empty dir
  run cr_drain_exit_output some-session
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "cr_drain_exit_output drops a capture that is only banner and blanks" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  d="$(mktemp -d)"
  export CR_EXIT_DIR="$d"
  printf '   Pane is dead (status 0, x)\n\n\n' >"$(cr_exit_file sess-1)" # leading spaces: tolerant filter
  run cr_drain_exit_output sess-1
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$(cr_exit_file sess-1)" ] # still consumed
}

@test "cr_drain_exit_output drains ONLY the named session, leaving other sessions' captures intact" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  d="$(mktemp -d)"
  export CR_EXIT_DIR="$d"
  printf 'mine: claude --resume mine\n' >"$(cr_exit_file sessA)"
  printf 'stale: claude --resume iter-16.1\n' >"$(cr_exit_file sessB)" # a different session's leftover
  run cr_drain_exit_output sessA
  [ "$status" -eq 0 ]
  [[ "$output" == *"mine: claude --resume mine"* ]]
  ! grep -q 'iter-16.1' <<<"$output"           # never shows another session's leftover
  [ ! -e "$(cr_exit_file sessA)" ]             # own file consumed
  [ -e "$(cr_exit_file sessB)" ]               # other session's file untouched
}

# --- cr_configure_exit_capture -------------------------------------------------

@test "cr_configure_exit_capture turns on remain-on-exit for the session" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  cr_make_session work >/dev/null
  cr_configure_exit_capture work
  run bash -c "$CR_TMUX show-options -w -t work remain-on-exit"
  [[ "$output" == *"on"* ]]
}

@test "cr_configure_exit_capture installs a pane-died hook that captures, saves and kills" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  cr_make_session work >/dev/null
  cr_configure_exit_capture work
  run bash -c "$CR_TMUX show-hooks -w -t work" # pane-died is a window-scoped hook
  [[ "$output" == *"pane-died"* ]]
  [[ "$output" == *"capture-pane"* ]]
  [[ "$output" == *"save-buffer"* ]]
  [[ "$output" == *"kill-session"* ]]
}

@test "cr_configure_exit_capture is idempotent (hook not duplicated on re-config)" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  cr_make_session work >/dev/null
  cr_configure_exit_capture work
  cr_configure_exit_capture work
  run bash -c "$CR_TMUX show-hooks -w -t work | grep -c kill-session"
  [ "$output" = "1" ]
}

# --- end to end: cr_launch arms capture; the hook writes the file on exit -------

@test "a launched session captures Claude's post-exit output to its file" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  d="$(mktemp -d)"
  export CR_EXIT_DIR="$d"
  export FAKE_CLAUDE_EXIT_LINES='SESSION-ID: e2e-xyz\nResume: claude --resume e2e-xyz\n'
  export FAKE_CLAUDE_EXIT_DELAY=1
  run cr_launch proj 0 0 -- # attach=0, wait=0 -> creates+arms, prints the name
  [ "$status" -eq 0 ]
  sess="$output"
  file="$(cr_exit_file "$sess")"
  # the pane-died hook writes the file ~1s later, after fake-claude exits
  for _ in $(seq 1 40); do
    [ -s "$file" ] && break
    sleep 0.1
  done
  [ -s "$file" ]
  grep -q 'SESSION-ID: e2e-xyz' "$file"
  grep -q 'Resume: claude --resume e2e-xyz' "$file"
}

# --- cr_attach_and_drain / cr_reattach -----------------------------------------

@test "cr_attach_and_drain drains a pending capture and does not block with wait=0" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  d="$(mktemp -d)"
  export CR_EXIT_DIR="$d"
  printf 'SESSION-ID: drainme\n' >"$d/ghost"
  # The bare attach to a non-existent session fails fast (no tty / no session);
  # the drain must still run afterwards, and wait=0 must not pause.
  run cr_attach_and_drain ghost 0
  [[ "$output" == *"SESSION-ID: drainme"* ]]
  [ ! -e "$d/ghost" ]
}

@test "cr_reattach arms capture on a pre-existing (foreign) session" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  export CR_EXIT_DIR="$(mktemp -d)"
  cr_make_session work >/dev/null # a session NOT born via cr_launch
  run cr_reattach work 0          # attach fails (no tty) but configure runs first
  run bash -c "$CR_TMUX show-options -w -t work remain-on-exit"
  [[ "$output" == *"on"* ]]
}
