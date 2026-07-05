load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "cr_ensure_line adds a leading newline when the file lacks a trailing one" {
  f="$(mktemp)"
  printf 'set -g default-command "zsh -l"' >"$f" # NO trailing newline
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  cr_ensure_line "$f" 'setw -g aggressive-resize on'
  run cat "$f"
  [ "${lines[0]}" = 'set -g default-command "zsh -l"' ]
  [ "${lines[1]}" = 'setw -g aggressive-resize on' ]
}

@test "cr_ensure_line is idempotent (no duplicate on second call)" {
  f="$(mktemp)"
  printf 'setw -g aggressive-resize on\n' >"$f"
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  cr_ensure_line "$f" 'setw -g aggressive-resize on'
  run grep -c 'aggressive-resize' "$f"
  [ "$output" = "1" ]
}

@test "cr_ensure_line creates the file when it does not exist" {
  f="$(mktemp -u)" # non-existent path
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  cr_ensure_line "$f" 'setw -g aggressive-resize on'
  run cat "$f"
  [ "$output" = 'setw -g aggressive-resize on' ]
}

@test "sign-tmux machinery is gone" {
  [ ! -e "${CR_REPO}/bin/cr-sign-tmux" ]
  ! grep -q "sign-tmux" "${CR_REPO}/Makefile"
  ! grep -q "cr-sign-tmux" "${CR_REPO}/install.sh"
}
