#!/usr/bin/env bats
# The login-shell launch against the real direnv, in a sandbox (cr_direnv_sandbox):
# the developer's allow list is never read or written, and no test runs `direnv allow`.
load helpers

setup() {
  cr_setup
  cr_login_shell_env
  proj="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$proj"
}
teardown() { cr_teardown; }

_cr_pane_shows() { cr_pane_text "$1" | grep -qF -- "$2"; }

# _cr_held_launch <hold s>: the pane script started from $proj in session `held` as
# an attached launch would start it, holding a complaint for <hold> seconds.
_cr_held_launch() {
  (
    source "${REPO_ROOT}/lib/claude-remote-lib.sh"
    cd "$proj" && ${CR_TMUX} new-session -d -s held -- zsh -lic "$CR_PANE_LOADER" cr "$CR_PANE_SCRIPT" 30 "$1"
  )
}

@test "an allowed .envrc reaches claude, without direnv's status lines" {
  echo 'export CR_PROBE=loaded' >"$proj/.envrc"
  cr_direnv_sandbox "$proj"
  cr_launch_in "$proj"
  cr_await_claude_env
  grep -qx 'CR_PROBE=loaded' "$FAKE_CLAUDE_ENV_FILE"
  run cr_pane_text "$sess"
  [[ "$output" != *direnv:* ]]
  [[ "$output" != *claude-remote:* ]]
  [ "$(cr_direnv_option)" = ok ]
  # The pane's error file is gone again.
  [ -z "$(find "$TMPDIR" -name 'claude-remote-direnv.*')" ]
}

@test "each session gets its own start directory's .envrc and nothing reaches the server" {
  echo 'export CR_SECRET=project' >"$proj/.envrc"
  mkdir -p "${BATS_TEST_TMPDIR}/elsewhere"
  cr_direnv_sandbox "$proj"
  cr_launch_in "$proj"
  cr_await_claude_env
  grep -qx 'CR_SECRET=project' "$FAKE_CLAUDE_ENV_FILE"
  mv "$FAKE_CLAUDE_ENV_FILE" "${BATS_TEST_TMPDIR}/first-env"
  cr_launch_in "${BATS_TEST_TMPDIR}/elsewhere"
  cr_await_claude_env
  run grep -q '^CR_SECRET=' "$FAKE_CLAUDE_ENV_FILE"
  [ "$status" -ne 0 ]
  run ${CR_TMUX} show-environment -g
  [[ "$output" != *CR_SECRET* ]]
}

@test "the sandboxed direnv never reads the developer's ~/.direnvrc" {
  echo 'export CR_PROBE=loaded' >"$proj/.envrc"
  cr_direnv_sandbox "$proj"
  # A HOME of the test's own with a ~/.direnvrc that would leak in if direnv fell back
  # to it, as it does when the config dir has no direnvrc.
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"
  echo 'export CR_FROM_HOME=1' >"$HOME/.direnvrc"
  cr_launch_in "$proj"
  cr_await_claude_env
  grep -qx 'CR_PROBE=loaded' "$FAKE_CLAUDE_ENV_FILE"
  run grep -q '^CR_FROM_HOME=' "$FAKE_CLAUDE_ENV_FILE"
  [ "$status" -ne 0 ]
}

@test "the first line direnv prints is the one reported, flattened, and the .envrc still loads" {
  printf 'printf "first\\tcomplaint\\n" >&2\necho second >&2\nexport CR_PROBE=loaded\n' >"$proj/.envrc"
  cr_direnv_sandbox "$proj"
  cr_launch_in "$proj"
  cr_await_claude_env
  grep -qx 'CR_PROBE=loaded' "$FAKE_CLAUDE_ENV_FILE"
  [ "$(cr_direnv_option)" = "first complaint" ]
}

@test "blank and control-only lines are skipped, and a line that cleans up to ok is reworded" {
  # A blank line, a bare bell, then `ok;`: tmux would read a trailing `;` as a
  # command separator, and `ok` alone would claim there was no problem.
  printf 'echo >&2\nprintf "\\a\\n" >&2\necho "ok;" >&2\nexport CR_PROBE=loaded\n' >"$proj/.envrc"
  cr_direnv_sandbox "$proj"
  cr_launch_in "$proj"
  cr_await_claude_env
  [ "$(cr_direnv_option)" = "ok (Ausgabe der .envrc)" ]
}

@test "CR_DIRENV_TIMEOUT=0 sets no limit" {
  printf 'sleep 1\nexport CR_PROBE=loaded\n' >"$proj/.envrc"
  cr_direnv_sandbox "$proj"
  export CR_DIRENV_TIMEOUT=0
  cr_launch_in "$proj"
  cr_await_claude_env 6
  grep -qx 'CR_PROBE=loaded' "$FAKE_CLAUDE_ENV_FILE"
  [ "$(cr_direnv_option)" = ok ]
}

@test "a temp dir that refuses the error file still shows direnv's complaint" {
  echo 'export CR_PROBE=loaded' >"$proj/.envrc"
  cr_direnv_sandbox # blocked
  export TMPDIR="${BATS_TEST_TMPDIR}/no-such-dir"
  cr_launch_in "$proj"
  cr_await_claude_env
  run cr_pane_text "$sess"
  [[ "$output" == *"is blocked"* ]]
  [[ "$output" == *"claude-remote: direnv meldet ein Problem mit der .envrc"* ]]
  [[ "$(cr_direnv_option)" == *mktemp* ]]
}

@test "a temp dir that refuses the error file is no problem where there is no .envrc" {
  cr_direnv_sandbox
  export TMPDIR="${BATS_TEST_TMPDIR}/no-such-dir"
  cr_launch_in "$proj"
  cr_await_claude_env
  run cr_pane_text "$sess"
  [[ "$output" != *claude-remote:* ]]
  [ "$(cr_direnv_option)" = ok ]
}

@test "a blocked .envrc is reported before claude starts, and claude starts without it" {
  echo 'export CR_PROBE=loaded' >"$proj/.envrc"
  cr_direnv_sandbox # nothing allowed
  cr_launch_in "$proj"
  cr_await_claude_env
  run grep -q '^CR_PROBE=' "$FAKE_CLAUDE_ENV_FILE"
  [ "$status" -ne 0 ]
  run cr_pane_text "$sess"
  [[ "$output" == *"claude-remote: direnv meldet ein Problem mit der .envrc"* ]]
  [[ "$output" == *"is blocked"* ]]
  # The report line is direnv's first line, stripped of its colour codes.
  run cr_direnv_option
  [[ "$output" == "direnv: error "*"is blocked"* ]]
  [[ "$output" != *$'\e'* ]]
}

@test "an .envrc that fails is reported, and claude starts" {
  printf 'export CR_PROBE=loaded\nexit 1\n' >"$proj/.envrc"
  cr_direnv_sandbox "$proj"
  cr_launch_in "$proj"
  cr_await_claude_env
  run cr_pane_text "$sess"
  [[ "$output" == *"claude-remote: direnv meldet ein Problem mit der .envrc"* ]]
  [ "$(cr_direnv_option)" = "direnv: error exit status 1" ]
}

@test "an .envrc that outlasts CR_DIRENV_TIMEOUT is abandoned and claude starts without it" {
  printf 'sleep 20\nexport CR_PROBE=loaded\n' >"$proj/.envrc"
  cr_direnv_sandbox "$proj"
  export CR_DIRENV_TIMEOUT=2
  cr_launch_in "$proj"
  cr_await_claude_env 8
  run grep -q '^CR_PROBE=' "$FAKE_CLAUDE_ENV_FILE"
  [ "$status" -ne 0 ]
  [ "$(cr_direnv_option)" = "direnv abgebrochen (Zeitlimit von 2 s oder Ctrl-C)" ]
  run cr_pane_text "$sess"
  [[ "$output" == *"direnv abgebrochen (Zeitlimit von 2 s oder Ctrl-C)"* ]]
  # A detached launch has nobody to press a key for it.
  [[ "$output" != *"Weiter mit beliebiger Taste"* ]]
}

@test "the time limit holds when ps pads the process group it reports" {
  # macOS ps right-aligns tpgid in four columns, so a group below 1000 comes with
  # blanks in front. Simulated for every group, through the pane's PATH.
  stub ps '/bin/ps "$@" | sed "s/^ */   /"' >/dev/null
  printf 'sleep 20\nexport CR_PROBE=loaded\n' >"$proj/.envrc"
  cr_direnv_sandbox "$proj"
  export CR_DIRENV_TIMEOUT=2
  cr_launch_in "$proj"
  cr_await_claude_env 8
  [ "$(cr_direnv_option)" = "direnv abgebrochen (Zeitlimit von 2 s oder Ctrl-C)" ]
}

@test "Ctrl-C during a slow .envrc gives up on direnv, not on claude" {
  local running="${BATS_TEST_TMPDIR}/envrc-running"
  printf 'touch %q\nsleep 20\nexport CR_PROBE=loaded\n' "$running" >"$proj/.envrc"
  cr_direnv_sandbox "$proj"
  cr_launch_in "$proj"
  # Ctrl-C before the .envrc runs would test the shell's startup, not direnv.
  cr_await 5 test -e "$running"
  ${CR_TMUX} send-keys -t "$sess" C-c
  cr_await_claude_env 5
  run grep -q '^CR_PROBE=' "$FAKE_CLAUDE_ENV_FILE"
  [ "$status" -ne 0 ]
  [ "$(cr_direnv_option)" = "direnv abgebrochen (Zeitlimit von 30 s oder Ctrl-C)" ]
}

@test "a slow .envrc that finishes in time is no problem, whatever DIRENV_WARN_TIMEOUT says" {
  printf 'sleep 2\nexport CR_PROBE=loaded\n' >"$proj/.envrc"
  cr_direnv_sandbox "$proj"
  # direnv would print its "taking a while" warning after 1 s; the launch must not
  # mistake that for a failure.
  export DIRENV_WARN_TIMEOUT=1s
  cr_launch_in "$proj"
  cr_await_claude_env 8
  grep -qx 'CR_PROBE=loaded' "$FAKE_CLAUDE_ENV_FILE"
  run cr_pane_text "$sess"
  [[ "$output" != *claude-remote:* ]]
  [ "$(cr_direnv_option)" = ok ]
}

@test "an .envrc next to a ~/.zshrc without the direnv hook is reported" {
  echo 'export CR_PROBE=loaded' >"$proj/.envrc"
  cr_direnv_sandbox "$proj"
  : >"${ZDOTDIR}/.zshrc" # direnv installed, .envrc allowed, but no hook
  cr_launch_in "$proj"
  cr_await_claude_env
  run cr_pane_text "$sess"
  [[ "$output" == *"claude-remote: direnv meldet ein Problem mit der .envrc"* ]]
  [[ "$(cr_direnv_option)" == *"keinen direnv-Hook (_direnv_hook)"* ]]
}

@test "a held warning waits for a key before claude starts" {
  echo 'export CR_PROBE=loaded' >"$proj/.envrc"
  cr_direnv_sandbox # blocked
  _cr_held_launch 60
  cr_await 5 _cr_pane_shows held "Weiter mit beliebiger Taste (Claude startet sonst in 60 s)"
  sleep 1
  [ ! -e "$FAKE_CLAUDE_ENV_FILE" ]
  ${CR_TMUX} send-keys -t held x
  cr_await_claude_env 3
}

@test "a key typed while the .envrc loads does not skip the held warning" {
  local running="${BATS_TEST_TMPDIR}/envrc-running"
  printf 'touch %q\nsleep 1\necho complaint >&2\n' "$running" >"$proj/.envrc"
  cr_direnv_sandbox "$proj"
  _cr_held_launch 60
  cr_await 5 test -e "$running"
  ${CR_TMUX} send-keys -t held x
  cr_await 5 _cr_pane_shows held "Weiter mit beliebiger Taste"
  sleep 1
  [ ! -e "$FAKE_CLAUDE_ENV_FILE" ]
  ${CR_TMUX} send-keys -t held y
  cr_await_claude_env 3
}

@test "Ctrl-C at a held warning starts claude rather than ending the launch" {
  echo 'export CR_PROBE=loaded' >"$proj/.envrc"
  cr_direnv_sandbox # blocked
  _cr_held_launch 60
  cr_await 5 _cr_pane_shows held "Weiter mit beliebiger Taste"
  ${CR_TMUX} send-keys -t held C-c
  cr_await_claude_env 3
}

@test "a held warning lets claude start on its own once the hold time is over" {
  echo 'export CR_PROBE=loaded' >"$proj/.envrc"
  cr_direnv_sandbox # blocked
  _cr_held_launch 2
  cr_await 5 _cr_pane_shows held "Weiter mit beliebiger Taste (Claude startet sonst in 2 s)"
  [ ! -e "$FAKE_CLAUDE_ENV_FILE" ]
  cr_await_claude_env 4
}
