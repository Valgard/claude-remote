load helpers

setup() { source "${REPO_ROOT}/lib/claude-remote-lib.sh"; }

kept() { cr_rewrite_claude_args "$@" | awk -F'\t' '$1=="+"{print $2}' | paste -sd' ' -; }
dropped() { cr_rewrite_claude_args "$@" | awk -F'\t' '$1=="-"{print $2}' | paste -sd' ' -; }

@test "label strips the pid suffix only" {
  [ "$(cr_session_label Projects-41963)" = Projects ]
  [ "$(cr_session_label Feist,_Raymond_E-56846)" = Feist,_Raymond_E ]
  [ "$(cr_session_label my-proj)" = my-proj ]
}

@test "launch-time --resume title is replaced by the exact id" {
  [ "$(kept SID --allow-dangerously-skip-permissions --brief --resume claude_guards)" = "--allow-dangerously-skip-permissions --brief --resume SID" ]
  [ "$(dropped SID --allow-dangerously-skip-permissions --brief --resume claude_guards)" = "--resume claude_guards" ]
}

@test "--name is dropped so a later /rename survives" {
  [ "$(dropped SID --brief --name link_tokens)" = "--name link_tokens" ]
}

@test "bare claude comes back with only --resume" {
  [ "$(kept SID)" = "--resume SID" ]
}

@test "value flags keep their value, a positional prompt is dropped" {
  [ "$(kept SID --model opus fix the build)" = "--model opus --resume SID" ]
  [ "$(dropped SID --model opus fix the build)" = "fix the build" ]
}

@test "--flag=value form is kept, a dangling value flag is dropped" {
  [ "$(kept SID --model=opus)" = "--model=opus --resume SID" ]
  [ "$(dropped SID --brief --model)" = "--model" ]
}

@test "a multi-word -r title from ps is dropped entirely" {
  [ "$(kept SID -r my long title --brief)" = "--brief --resume SID" ]
}

@test "startup actions and variadic flags are dropped" {
  [ "$(kept SID --worktree feat --tmux --bg --continue --session-id X --fork-session --add-dir /a /b --verbose)" = "--verbose --resume SID" ]
}
