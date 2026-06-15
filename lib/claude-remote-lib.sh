#!/usr/bin/env bash
# claude-remote shared helpers. Sourced by bin/claude-remote, bin/claude-remote-pick, and tests.
# All tmux/abtop access goes through the CR_TMUX / CR_ABTOP env seams.

: "${CR_TMUX:=tmux}"
: "${CR_ABTOP:=abtop}"

# (functions added by later tasks)

# cr_session_name <label> -> base session name (no pid suffix yet).
# Uses the label if non-empty, else basename of $PWD. tmux session names
# may not contain '.' or ':' and spaces are awkward, so collapse them to '_'.
cr_session_name() {
  local label="$1" name
  if [ -n "$label" ]; then
    name="$label"
  else
    name="$(basename "$PWD")"
  fi
  printf '%s\n' "$name" | tr ' ./:' '____'
}

# cr_launch <name> <attach:0|1> -- <claude args...>
# Creates a detached tmux session running claude directly, so pane_pid == claude pid.
# `claude` is resolved from PATH by tmux's exec form (no shell involved, so the
# interactive claude zsh function never enters the picture — equivalent to
# `command claude`). Renames the session to <name>-<pane_pid>, then optionally attaches.
cr_launch() {
  local name="$1" attach="$2"
  shift 2
  [ "${1-}" = "--" ] && shift
  local tmp pid final
  tmp="${name}-tmp-$$"
  # shellcheck disable=SC2086
  $CR_TMUX new-session -d -s "$tmp" -- claude "$@" || return 1
  # shellcheck disable=SC2086
  pid="$($CR_TMUX display-message -p -t "$tmp" '#{pane_pid}')" || return 1
  if [ -z "$pid" ]; then
    # shellcheck disable=SC2086
    $CR_TMUX kill-session -t "$tmp" 2>/dev/null
    echo "claude-remote: could not determine claude pid (session exited early?)" >&2
    return 1
  fi
  final="${name}-${pid}"
  # shellcheck disable=SC2086
  $CR_TMUX rename-session -t "$tmp" "$final" || return 1
  if [ "$attach" -eq 1 ]; then
    # shellcheck disable=SC2086
    exec $CR_TMUX attach -t "$final"
  fi
  printf '%s\n' "$final"
}

# cr_abtop_sessions -> TSV rows for claude sessions:
#   pid \t project_name \t status \t context_percent \t model \t current_task
# Returns non-zero if abtop is missing or its output is not valid JSON.
cr_abtop_sessions() {
  local json
  # shellcheck disable=SC2086
  json="$($CR_ABTOP --json 2>/dev/null)" || return 1
  printf '%s' "$json" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s' "$json" | jq -r '
    .sessions[]
    | select(.agent_cli == "claude")
    | [ (.pid|tostring), (.project_name // ""), (.status // ""),
        ((.context_percent // 0)|floor|tostring), (.model // ""),
        (.current_task // "") ]
    | @tsv'
}
