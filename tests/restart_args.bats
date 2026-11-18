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

@test "--strict-mcp-config is dropped with --mcp-config, never kept on its own" {
  # Kept alone it would mean "only the servers from --mcp-config", which is always
  # dropped — the session would come back without any MCP server.
  [ "$(kept SID --strict-mcp-config --mcp-config a.json --brief)" = "--brief --resume SID" ]
  [ "$(dropped SID --strict-mcp-config --mcp-config a.json --brief)" = "--strict-mcp-config --mcp-config a.json" ]
}

@test "every restricting flag is detected, in both spellings and the =value form" {
  local flag
  for flag in --disallowedTools --disallowed-tools --allowedTools --allowed-tools \
    --tools --settings --permission-prompt-tool; do
    cr_drops_restriction --brief "$flag" "Bash(rm *)"
    cr_drops_restriction "$flag=x" --brief
  done
  cr_drops_restriction --strict-mcp-config --brief
  cr_drops_restriction --brief --strict-mcp-config=true
}

@test "args without a restricting flag are not flagged" {
  run cr_drops_restriction --allow-dangerously-skip-permissions --brief --resume t --name n fix it
  [ "$status" -eq 1 ]
  run cr_drops_restriction
  [ "$status" -eq 1 ]
  # Only a whole flag counts, not a word that merely starts like one.
  run cr_drops_restriction --toolsmith --settingsfile
  [ "$status" -eq 1 ]
}
