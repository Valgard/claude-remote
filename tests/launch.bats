load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "claude-remote creates a tmux session named <base>-<pane_pid>" {
  cd /tmp
  # Run launch in no-attach mode so the test is non-interactive.
  run claude-remote --no-attach -l proj
  [ "$status" -eq 0 ]
  # exactly one session, name proj-<digits>
  run bash -c "${CR_TMUX} list-sessions -F '#{session_name}'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^proj-[0-9]+$ ]]
}

@test "the pid in the session name equals the pane_pid" {
  cd /tmp
  run claude-remote --no-attach -l proj
  [ "$status" -eq 0 ]
  local sess pane_pid name_pid
  sess="$(${CR_TMUX} list-sessions -F '#{session_name}')"
  pane_pid="$(${CR_TMUX} display-message -p -t "$sess" '#{pane_pid}')"
  name_pid="${sess##*-}"
  [ "$pane_pid" = "$name_pid" ]
}

@test "claude-remote passes through claude args after --" {
  cd /tmp
  argv_file="$(mktemp)"
  FAKE_CLAUDE_ARGV_FILE="$argv_file" run claude-remote --no-attach -l proj -- --brief --model opus
  [ "$status" -eq 0 ]
  run cat "$argv_file"
  [ "$output" = "--brief --model opus" ]
}

@test "claude-remote errors clearly when -l has no argument" {
  cd /tmp
  run claude-remote -l
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires an argument"* ]]
}

@test "cr_launch does not crash without a -- separator under set -u" {
  cd /tmp
  run bash -c "set -u; source '${REPO_ROOT}/lib/claude-remote-lib.sh'; cr_launch foo 0 0"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^foo-[0-9]+$ ]]
}

@test "claude-remote resolves its lib when invoked via a symlink (install scenario)" {
  cd /tmp
  linkdir="$(mktemp -d)"
  ln -s "${REPO_ROOT}/bin/claude-remote" "${linkdir}/claude-remote"
  run "${linkdir}/claude-remote" --no-attach -l linktest
  [ "$status" -eq 0 ]
  run bash -c "${CR_TMUX} list-sessions -F '#{session_name}'"
  [[ "$output" =~ ^linktest-[0-9]+$ ]]
}

@test "claude-remote hides the tmux status line for its sessions" {
  cd /tmp
  run claude-remote --no-attach -l statustest
  [ "$status" -eq 0 ]
  sess="$(${CR_TMUX} list-sessions -F '#{session_name}')"
  run bash -c "${CR_TMUX} show-options -t '$sess' status"
  [[ "$output" == *"off"* ]]
}

# A recording tmux stub: logs the new-session argv NUL-separated (the login-shell
# script is one multi-line element) and answers display-message with a fixed pid, so
# we can assert the exact command cr_launch constructs without a real tmux server or
# a real ~/.zshrc. Every other subcommand (attach, hooks) succeeds silently.
_cr_make_tmux_stub() {
  local stub="$1" rec="$2"
  cat >"$stub" <<EOF
#!/usr/bin/env bash
case "\$1" in
  new-session) shift; printf '%s\0' "\$@" >>"$rec" ;;
  display-message) echo 4242 ;;
esac
exit 0
EOF
  chmod +x "$stub"
}

# _cr_recorded_launch <attach> <claude args…>: run cr_launch against the recording
# stub and leave the recorded argv in the array `argv`. The direnv limits default to
# 7 and 9 s, unless the caller sets them.
_cr_recorded_launch() {
  local stub="${BATS_TEST_TMPDIR}/tmux-stub" rec="${BATS_TEST_TMPDIR}/argv" el attach="$1"
  shift
  _cr_make_tmux_stub "$stub" "$rec"
  CR_TMUX="$stub" CR_EXIT_DIR="${BATS_TEST_TMPDIR}/exit" \
    CR_DIRENV_TIMEOUT="${CR_DIRENV_TIMEOUT-7}" CR_DIRENV_HOLD="${CR_DIRENV_HOLD-9}" \
    bash -c "set -uo pipefail; source '${REPO_ROOT}/lib/claude-remote-lib.sh'; cr_launch proj $attach 0 -- \"\$@\"" _ "$@"
  argv=()
  while IFS= read -r -d '' el; do argv+=("$el"); done <"$rec"
}

@test "cr_launch hands the pane script, the direnv limits and the claude args to a login shell" {
  cd /tmp
  CR_LOGIN_SHELL=1 _cr_recorded_launch 0 --brief "two words"
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  # new-session -d -s <tmp> -- zsh -lic <loader> cr <script> <timeout> <hold> <args…>
  [ "${argv[3]}" = "--" ]
  [ "${argv[4]}" = "zsh" ]
  [ "${argv[5]}" = "-lic" ]
  # shellcheck disable=SC2016 # the pane's zsh expands it
  [ "${argv[6]}" = 'emulate -R zsh; setopt no_aliases; eval "$1"' ]
  [ "${argv[7]}" = "cr" ]
  [ "${argv[8]}" = "$CR_PANE_SCRIPT" ]
  [ "${argv[9]}" = "7" ]
  [ "${argv[10]}" = "0" ] # detached: nobody could read a warning, so no hold
  [ "${argv[11]}" = "--brief" ]
  [ "${argv[12]}" = "two words" ]
  [ "${#argv[@]}" -eq 13 ]
}

@test "cr_launch holds a direnv warning only for a launch that attaches" {
  cd /tmp
  CR_LOGIN_SHELL=1 _cr_recorded_launch 1 --brief
  [ "${argv[9]}" = "7" ]
  [ "${argv[10]}" = "9" ]
}

@test "a non-numeric CR_DIRENV_TIMEOUT or CR_DIRENV_HOLD falls back to its default, with a warning" {
  cd /tmp
  CR_LOGIN_SHELL=1 CR_DIRENV_TIMEOUT=30s CR_DIRENV_HOLD=x _cr_recorded_launch 1 --brief 2>"${BATS_TEST_TMPDIR}/err"
  [ "${argv[9]}" = "30" ]
  [ "${argv[10]}" = "15" ]
  grep -q 'CR_DIRENV_TIMEOUT' "${BATS_TEST_TMPDIR}/err"
  grep -q 'CR_DIRENV_HOLD' "${BATS_TEST_TMPDIR}/err"
}

@test "a zero-padded limit is read as decimal, and an absurdly long one falls back" {
  cd /tmp
  # bash reads 08 as an invalid octal number; nine digits overflow zselect's timer.
  CR_LOGIN_SHELL=1 CR_DIRENV_TIMEOUT=08 CR_DIRENV_HOLD=123456789 _cr_recorded_launch 1 --brief 2>"${BATS_TEST_TMPDIR}/err"
  [ "${argv[9]}" = "8" ]
  [ "${argv[10]}" = "15" ]
  grep -q 'CR_DIRENV_HOLD' "${BATS_TEST_TMPDIR}/err"
}

@test "cr_launch execs claude directly when CR_LOGIN_SHELL=0" {
  cd /tmp
  CR_LOGIN_SHELL=0 _cr_recorded_launch 0 --brief
  [ "${argv[3]}" = "--" ]
  [ "${argv[4]}" = "claude" ]
  [ "${argv[5]}" = "--brief" ]
  [ "${#argv[@]}" -eq 6 ]
}

# The login-shell launch for real (cr_login_shell_env), with a stand-in for the
# function `eval "$(direnv hook zsh)"` defines in ~/.zshrc. zsh only calls that
# function before a prompt or after a cd, and `zsh -c` reaches neither, so it runs
# only if the launch fires it. tests/direnv.bats drives the real direnv.

@test "a login-shell launch fires the direnv hook in the start directory before claude starts" {
  cr_login_shell_env
  echo '_direnv_hook() { export CR_DIRENV_PROBE="${PWD:A}"; }' >>"${ZDOTDIR}/.zshrc"
  # Born elsewhere, so the start directory cannot be mistaken for the server's.
  mkdir -p "${BATS_TEST_TMPDIR}/born"
  (cd "${BATS_TEST_TMPDIR}/born" && ${CR_TMUX} new-session -d -s born 'exec sleep 600')
  cr_launch_in /tmp
  cr_await_claude_env
  grep -qx "CR_DIRENV_PROBE=$(cd /tmp && pwd -P)" "$FAKE_CLAUDE_ENV_FILE"
}

@test "a login-shell launch passes every claude argument through, in order and unsplit" {
  cr_login_shell_env
  cr_launch_in /tmp --model opus "two words" --brief
  cr_await_claude_env
  [ "$(grep '^FAKE_CLAUDE_ARG=' "$FAKE_CLAUDE_ENV_FILE")" = "$(printf 'FAKE_CLAUDE_ARG=%s\n' --model opus "two words" --brief)" ]
}

@test "a login-shell launch that loads direnv still leaves claude as the pane process" {
  cr_login_shell_env
  # The pane script runs claude from inside a function, where zsh never execs on its
  # own, so a lost `exec` splits the pid by itself. The TRAPEXIT keeps the test biting
  # should the exec ever move to the top level of the -c string, where zsh would exec
  # the last command implicitly unless an exit trap obliges it to outlive it.
  printf '%s\n' '_direnv_hook() { export CR_DIRENV_PROBE=1; }' 'TRAPEXIT() { :; }' >>"${ZDOTDIR}/.zshrc"
  cr_launch_in /tmp
  cr_await_claude_env
  local pane_pid
  pane_pid="$(${CR_TMUX} display-message -p -t "$sess" '#{pane_pid}')"
  grep -qx "FAKE_CLAUDE_PID=${pane_pid}" "$FAKE_CLAUDE_ENV_FILE"
  [ "${sess##*-}" = "$pane_pid" ]
}

@test "a login-shell launch runs the claude binary, never a claude shell function" {
  cr_login_shell_env
  # A user's ~/.zshrc may well define claude() as `claude-remote …`; without the
  # `command` every pane would launch another session, without end.
  echo "claude() { : >${BATS_TEST_TMPDIR}/recursed; }" >>"${ZDOTDIR}/.zshrc"
  cr_launch_in /tmp
  cr_await_claude_env
  [ ! -e "${BATS_TEST_TMPDIR}/recursed" ]
}

@test "the direnv time limit is called off once the hook is done" {
  cr_login_shell_env
  echo '_direnv_hook() { :; }' >>"${ZDOTDIR}/.zshrc"
  export CR_DIRENV_TIMEOUT=1
  cr_launch_in /tmp
  cr_await_claude_env
  # A timer left running would interrupt claude itself once the limit is up.
  sleep 2.5
  ${CR_TMUX} has-session -t "=$sess"
  kill -0 "$(sed -n 's/^FAKE_CLAUDE_PID=//p' "$FAKE_CLAUDE_ENV_FILE")"
}

@test "options and aliases a ~/.zshrc sets cannot bend the pane script" {
  cr_login_shell_env
  # Each would break the script as parsed or run in the user's settings: braces
  # stop being syntax, arrays start at 0, any failing command exits the shell,
  # aliases rewrite the commands the script calls — also inside the $(…) it parses
  # only when it runs — and functions shadow builtins: a dead kill would leave the
  # limit unenforced, a dead shift would hand the limit and the hold to claude as
  # arguments. The functions come before the aliases, which would rewrite them too:
  # `kill() …` after `alias kill=false` defines a function named false. The hook
  # outlasts the limit, so the timer and the interrupt handling run under all of it.
  cat >>"${ZDOTDIR}/.zshrc" <<'EOF'
_direnv_hook() { command sleep 5; }
kill() { :; }
shift() { :; }
setopt ignore_braces ksh_arrays err_exit
alias kill=false print=false printf=false read=false local=false command=false
EOF
  export CR_DIRENV_TIMEOUT=1
  cr_launch_in /tmp --brief
  cr_await_claude_env 4
  [ "$(cr_direnv_option)" = "direnv abgebrochen (Zeitlimit von 1 s oder Ctrl-C)" ]
  [ "$(grep '^FAKE_CLAUDE_ARG=' "$FAKE_CLAUDE_ENV_FILE")" = "FAKE_CLAUDE_ARG=--brief" ]
}

@test "a login-shell launch without direnv in play starts claude silently and reports ok" {
  cr_login_shell_env
  cr_launch_in /tmp
  cr_await_claude_env
  # an unguarded call would leave `command not found: _direnv_hook` in the pane
  run cr_pane_text "$sess"
  [[ "$output" != *_direnv_hook* ]]
  [[ "$output" != *claude-remote:* ]]
  [ "$(cr_direnv_option)" = ok ]
}
