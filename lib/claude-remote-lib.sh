#!/usr/bin/env bash
# claude-remote shared helpers. Sourced by bin/claude-remote, bin/claude-remote-pick, and tests.
# All tmux/abtop access goes through the CR_TMUX / CR_ABTOP env seams.

: "${CR_TMUX:=tmux}"
: "${CR_ABTOP:=abtop}"
: "${CR_SSH_PORT:=22}"

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

# cr_pane_map -> "pane_pid<TAB>session_name" for every pane across all sessions.
# pane_pid is the process tmux exec'd in the pane == the claude pid (we launch
# claude directly). Empty output (status 0) when no server/sessions exist.
cr_pane_map() {
  # shellcheck disable=SC2086
  $CR_TMUX list-panes -a -F '#{pane_pid}'$'\t''#{session_name}' 2>/dev/null || true
}

# cr_format_rows: stdin = cr_join output; stdout = one display line per S row,
# TAB-separated as: <session>\t<human-text>. The session (col 1) is the attach key.
cr_format_rows() {
  awk -F'\t' '
    $1 == "S" {
      # $2 session, $3 pid, $4 project, $5 status, $6 ctx, $7 model, $8 task
      task = $8; if (length(task) > 40) task = substr(task, 1, 39) "…"
      printf "%s\t%-18s %-9s %3s%% %-18s %s\n", $2, $4, $5, $6, $7, task
    }'
}

# cr_footnote: stdin = cr_join output; prints the non-attachable hint if N>0.
cr_footnote() {
  awk -F'\t' '$1 == "N" && ($2+0) > 0 {
    print "(" $2 " weitere Claude-Session(s) laufen ohne claude-remote — nicht attachbar)"
  }'
}

# cr_menu_lines -> "session<TAB>display" lines (stdout) for attachable sessions,
# plus a footnote on stderr. Falls back to a raw tmux session list if abtop is
# unavailable. Prints nothing (status 0) when abtop works but no claude sessions run.
cr_menu_lines() {
  local abtop_rows joined
  if abtop_rows="$(cr_abtop_sessions)"; then
    [ -z "$abtop_rows" ] && return 0
    joined="$(printf '%s\n' "$abtop_rows" | cr_join <(cr_pane_map))"
    printf '%s\n' "$joined" | cr_format_rows
    printf '%s\n' "$joined" | cr_footnote >&2
  else
    # Fallback: plain tmux session list (reduced metadata). Two identical columns
    # keep the "session<TAB>display" contract the loop expects.
    # shellcheck disable=SC2086
    $CR_TMUX list-sessions -F '#{session_name}'$'\t''#{session_name}' 2>/dev/null
    echo "(abtop nicht verfügbar — reduzierte Anzeige)" >&2
  fi
}

# cr_join <panemap_file>
# stdin: abtop TSV rows (pid \t project \t status \t ctx \t model \t task)
# stdout: 'S\t<session>\t<row>' for attachable claude sessions,
#         then 'N\t<count>' for claude sessions with no matching tmux pane.
cr_join() {
  local panemap="$1"
  awk -F'\t' -v panefile="$panemap" '
    BEGIN {
      while ((getline line < panefile) > 0) {
        n = split(line, a, "\t"); if (n >= 2) sess[a[1]] = a[2]
      }
    }
    {
      pid = $1
      if (pid in sess) { print "S\t" sess[pid] "\t" $0 }
      else { miss++ }
    }
    END { print "N\t" miss + 0 }
  '
}

# cr_ensure_line <file> <line>
# Append <line> to <file> only if not already present, guaranteeing it lands on
# its own line: if the file exists, is non-empty, and lacks a trailing newline,
# a newline is added first (otherwise the new line would merge onto the last one).
cr_ensure_line() {
  local file="$1" line="$2"
  [ -f "$file" ] && grep -qF -- "$line" "$file" && return 0
  if [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ]; then
    printf '\n' >>"$file"
  fi
  printf '%s\n' "$line" >>"$file"
}

# cr_sshd_running -> 0 if something is listening on localhost:${CR_SSH_PORT} (sshd),
# else 1. Read-only, no sudo: opens a TCP connection via bash's /dev/tcp in a
# subshell (the fd is closed when the subshell exits).
cr_sshd_running() {
  (exec 3<>"/dev/tcp/127.0.0.1/${CR_SSH_PORT}") 2>/dev/null
}
