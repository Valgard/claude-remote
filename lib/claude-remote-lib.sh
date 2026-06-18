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
  # Hide tmux's status line for our sessions — Claude's full-screen TUI uses the
  # whole height; the row is pure overhead (toggle back with Prefix+S). Cosmetic,
  # so don't fail the launch if it doesn't take.
  # shellcheck disable=SC2086
  $CR_TMUX set-option -t "$final" status off 2>/dev/null || true
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
# Display: <glyph> <name #pid> <ctx%> <model> <task>, where name is the session
# name with its -<pid> suffix stripped (so a -l label shows through). When CR_COLOR=1
# the glyph and ctx% are ANSI-coloured and the pid is dimmed; otherwise plain.
# Padding is computed on visible length so colours don't break column alignment.
cr_format_rows() {
  awk -F'\t' -v color="${CR_COLOR:-0}" '
    function shortmodel(m) {
      if (m ~ /opus/) return "opus"
      if (m ~ /sonnet/) return "sonnet"
      if (m ~ /haiku/) return "haiku"
      if (m == "" || m == "-") return "—"
      return m
    }
    function glyph(s) {
      if (s == "Executing" || s == "Thinking") return "►"
      if (s == "Waiting") return "◐"
      if (s == "Idle") return "○"
      return "·"
    }
    $1 == "S" {
      # $2 session, $3 pid, $4 project, $5 status, $6 ctx, $7 model, $8 task
      session = $2; pid = $3; status = $5; ctx = $6 + 0
      model = shortmodel($7); task = $8
      name = session; sub("-" pid "$", "", name)
      if (length(task) > 40) task = substr(task, 1, 39) "…"
      g = glyph(status)
      if (color == "1") {
        sc = ""
        if (status == "Executing" || status == "Thinking") sc = "\033[32m"
        else if (status == "Waiting") sc = "\033[33m"
        cc = (ctx < 50) ? "\033[32m" : (ctx < 80 ? "\033[33m" : "\033[31m")
        plain = name " #" pid
        padn = 22 - length(plain); if (padn < 0) padn = 0
        glyph_str = sc g "\033[0m"
        label_str = name " \033[2m#" pid "\033[0m" sprintf("%*s", padn, "")
        ctx_str = cc sprintf("%3d%%", ctx) "\033[0m"
        printf "%s\t%s %s %s %-6s %s\n", session, glyph_str, label_str, ctx_str, model, task
      } else {
        printf "%s\t%s %-22s %3d%% %-6s %s\n", session, g, name " #" pid, ctx, model, task
      }
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

# cr_augment_path: append common tool locations to PATH so abtop/tmux/jq/fzf/claude
# resolve even under a stripped environment (e.g. an SSH forced command, whose PATH
# is typically just /usr/bin:/bin:/usr/sbin:/sbin). Appends (does not prepend) so an
# already-present entry keeps priority; only adds dirs that exist and aren't on PATH.
cr_augment_path() {
  local d
  for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/local/bin"; do
    [ -d "$d" ] || continue
    case ":$PATH:" in
      *":$d:"*) ;;
      *) PATH="$PATH:$d" ;;
    esac
  done
  export PATH
}

# cr_pick_numbered <footnote> <menu-line>...
# Renders a numbered menu on STDERR, reads one choice from stdin, and echoes a
# selection TOKEN on stdout: a tmux session name, __NEW__, __QUIT__, __RELOAD__
# (re-fetch the session list), or __NONE__ (invalid input -> caller redraws).
# Menu lines are "session<TAB>display".
cr_pick_numbered() {
  local footnote="$1"
  shift
  local menu=("$@") i=1 line choice newidx
  {
    echo "Claude-Sessions:"
    for line in "${menu[@]:-}"; do
      [ -z "$line" ] && continue
      printf "  %2d) %s\n" "$i" "${line#*$'\t'}"
      i=$((i + 1))
    done
    [ -n "$footnote" ] && printf '%s\n' "$footnote"
    printf "  %2d) ＋ neue Session\n" "$i"
    printf "   r) Aktualisieren\n"
    printf "   q) Beenden\n"
    printf "Auswahl: "
  } >&2
  newidx="$i"
  read -r choice || {
    echo "__QUIT__"
    return 0
  }
  case "$choice" in
    q | Q) echo "__QUIT__" ;;
    r | R) echo "__RELOAD__" ;;
    "$newidx") echo "__NEW__" ;;
    *)
      if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#menu[@]}" ]; then
        printf '%s\n' "${menu[$((choice - 1))]%%$'\t'*}"
      else
        echo "__NONE__"
      fi
      ;;
  esac
}

# cr_pick_fzf <footnote> <menu-line>...
# Presents the menu via fzf (interactive, uses /dev/tty), and echoes a selection
# TOKEN on stdout: a tmux session name, __NEW__, __RELOAD__ (Ctrl-R, re-fetch the
# list), or __QUIT__ (ESC/cancel). fzf shows only the display column (field 2..);
# the session key is field 1. With --expect=ctrl-r, fzf prints the pressed key on
# line 1 (empty for a plain Enter) and the selected line on line 2.
cr_pick_fzf() {
  local footnote="$1"
  shift
  local header="claude-remote — Enter: attach · Ctrl-R: aktualisieren · ESC: beenden"
  [ -n "$footnote" ] && header="${header}"$'\n'"${footnote}"
  local lines=()
  [ "$#" -gt 0 ] && lines=("$@")
  lines+=("__NEW__"$'\t'"＋ neue Session")
  local out key chosen
  out="$(printf '%s\n' "${lines[@]}" | fzf --ansi --delimiter=$'\t' --with-nth='2..' \
    --prompt='Session> ' --header="$header" --reverse --no-multi --expect=ctrl-r)" || true
  {
    IFS= read -r key
    IFS= read -r chosen
  } <<<"$out"
  if [ "$key" = "ctrl-r" ]; then
    echo "__RELOAD__"
  elif [ -z "$chosen" ]; then
    echo "__QUIT__"
  else
    printf '%s\n' "${chosen%%$'\t'*}"
  fi
}
