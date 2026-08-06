load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

# A pane whose foreground binary is literally named `claude`. tmux reads
# pane_current_command from the process image (it follows symlinks and ignores
# argv[0]), so a symlink named `claude` would still report the target's name —
# hence the copy. The suite's fake-claude stub is unusable here for the same
# reason: it ends in `exec sleep`, so its pane reports the sleep binary.
# The copy must be verified before use: on a stock macOS `sleep` resolves to
# /bin/sleep, an Apple *platform binary*, which is SIGKILLed when executed from
# anywhere but its signed location — the pane would die instantly and the test
# would fail with a confusing "no such pane" instead of a reason.
cr_claude_pane() {
  local name="$1" dir="${BATS_TEST_TMPDIR}/claudebin"
  mkdir -p "$dir"
  cp -f "$(command -v sleep)" "${dir}/claude" || skip "no copyable sleep binary"
  chmod u+w "${dir}/claude" # sleep is mode 555; keep the helper re-callable
  "${dir}/claude" 0 2>/dev/null || skip "copied sleep is killed here (Apple platform binary) — needs e.g. brew coreutils"
  ${CR_TMUX} new-session -d -s "$name" -- "${dir}/claude" 60
}

# Evaluate the production condition against a live pane; echoes MATCH / NOMATCH.
cr_eval_cond() {
  ${CR_TMUX} display-message -p -t "$1" "#{?$(cr_tmux_claude_pane_cond),MATCH,NOMATCH}"
}

@test "the ctrl-z condition matches a pane running claude" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  cr_claude_pane claudepane
  run cr_eval_cond claudepane
  [ "$output" = "MATCH" ]
}

@test "the ctrl-z condition does not match a plain shell pane" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  ${CR_TMUX} new-session -d -s shellpane -- sh
  run cr_eval_cond shellpane
  [ "$output" = "NOMATCH" ]
}

@test "the ctrl-z config line parses to its end and binds C-z to the conditional" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  ${CR_TMUX} new-session -d -s host -- sh
  conf="${BATS_TEST_TMPDIR}/tmux.conf"
  cr_tmux_ctrl_z_line >"$conf"
  # Catches an unknown command or a bad flag (those DO exit non-zero). A quoting
  # error does not: source-file exits 0, prints nothing, and installs a mangled
  # binding — measured on 3.7b, so the exit status alone proves very little.
  ${CR_TMUX} source-file "$conf"
  # Hence assert on tmux's own re-quoted rendering of what it actually *parsed*.
  # This survives a reformat of the emitted line, but fails on every way the
  # binding can go wrong: a different key, a lost condition, a missing else
  # branch, swapped branches (which would swallow Ctrl+Z in shells and forward
  # it into Claude — the exact unrecoverable state this exists to prevent), and
  # an unbalanced \" in the message, which is what a botched collapse of the
  # multi-line form produces.
  run ${CR_TMUX} list-keys -T root
  [ "$status" -eq 0 ]
  binding="$(printf '%s\n' "$output" | grep -E '^bind-key[[:space:]]+-T root[[:space:]]+C-z[[:space:]]')"
  [ -n "$binding" ]
  # It guards on the production condition itself, not merely on some format
  # mentioning pane_current_command (compared as a fixed string, straight from
  # the function, so the two can never drift apart).
  printf '%s\n' "$binding" | grep -qF -- "\"$(cr_tmux_claude_pane_cond)\""
  printf '%s\n' "$binding" |
    grep -Eq 'if-shell -F "[^"]*" "display-message -d [0-9]+ \\"[^"]*\\"" "send-keys C-z"$'
}

@test "cr_tmux_ctrl_z_state: absent for a missing or unrelated config" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_tmux_ctrl_z_state "${BATS_TEST_TMPDIR}/does-not-exist"
  [ "$output" = "absent" ]
  f="${BATS_TEST_TMPDIR}/plain.conf"
  printf 'set -g mouse on\nbind-key S set-option status\n' >"$f"
  run cr_tmux_ctrl_z_state "$f"
  [ "$output" = "absent" ]
}

@test "cr_tmux_ctrl_z_state: ours for our own emitted line" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  f="${BATS_TEST_TMPDIR}/ours.conf"
  cr_tmux_ctrl_z_line >"$f"
  run cr_tmux_ctrl_z_state "$f"
  [ "$output" = "ours" ]
}

@test "cr_tmux_ctrl_z_state: ours for the hand-written multi-line form" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  f="${BATS_TEST_TMPDIR}/handwritten.conf"
  printf "%s\n" \
    "bind -n C-z if -F '$(cr_tmux_claude_pane_cond)' \\" \
    "  'display-message -d 1500 \"Ctrl+Z ist in Claude Code deaktiviert\"' \\" \
    "  'send-keys C-z'" >"$f"
  run cr_tmux_ctrl_z_state "$f"
  [ "$output" = "ours" ]
}

@test "cr_tmux_ctrl_z_state: foreign for a user's own binding, in either spelling" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  # `bind-key` is the long form tmux itself prints in list-keys — and the one
  # install.sh uses two lines above — so it is at least as likely as `bind`.
  for line in 'bind-key -n C-z resize-pane -Z' 'bind -n C-z send-keys C-z' 'bind -T root C-z copy-mode'; do
    f="${BATS_TEST_TMPDIR}/foreign.conf"
    printf '%s\n' "$line" >"$f"
    run cr_tmux_ctrl_z_state "$f"
    [ "$output" = "foreign" ] || {
      echo "expected foreign for: $line (got: $output)"
      return 1
    }
  done
}

@test "cr_tmux_ctrl_z_state: a commented-out or unbound C-z is not a binding" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  # Both used to read as "already present" under the plain substring check,
  # silently suppressing the install. `unbind` even contains `bind` literally.
  for line in '# bind -n C-z if -F something' '#bind -n C-z' 'unbind -n C-z' 'set -g @note "bind -n C-z is nice"'; do
    f="${BATS_TEST_TMPDIR}/inert.conf"
    printf '%s\n' "$line" >"$f"
    run cr_tmux_ctrl_z_state "$f"
    [ "$output" = "absent" ] || {
      echo "expected absent for: $line (got: $output)"
      return 1
    }
  done
}

@test "the install call site writes our line once and never touches a foreign one" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  # Mirrors install.sh exactly: state decides, cr_ensure_line only ever appends
  # into a config that has no C-z binding at all.
  f="${BATS_TEST_TMPDIR}/fresh.conf"
  printf 'set -g mouse on\n' >"$f"
  [ "$(cr_tmux_ctrl_z_state "$f")" = "absent" ]
  cr_ensure_line "$f" "$(cr_tmux_ctrl_z_line)"
  [ "$(cr_tmux_ctrl_z_state "$f")" = "ours" ]
  # second run: idempotent, nothing appended
  cr_ensure_line "$f" "$(cr_tmux_ctrl_z_line)"
  [ "$(grep -c 'bind -n C-z' "$f")" -eq 1 ]
}

@test "the ctrl-z config line is a single line (cr_ensure_line appends one)" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_tmux_ctrl_z_line
  [ "$status" -eq 0 ] # without this, a missing function's error message counts as a line
  [ "${#lines[@]}" -eq 1 ]
}
