#!/usr/bin/env bash
# claude-remote shared helpers. Sourced by bin/claude-remote, bin/claude-remote-pick, and tests.
# All tmux/abtop access goes through the CR_TMUX / CR_ABTOP env seams.

: "${CR_TMUX:=tmux}"
: "${CR_ABTOP:=abtop}"
: "${CR_SSH_PORT:=22}"
: "${CR_ANCHOR:=_cr_anchor}"
: "${CR_NEW_DIR:=~/Projects}"

# (functions added by later tasks)

# cr_resolve_new_dir <input> -> "<kind>\t<dir>" on stdout.
# Resolves the picker's "neue Session" directory prompt. Ergonomics: a bare name
# (no '/', no leading '~' or '$') is taken as a project under $CR_NEW_DIR, so on a
# remote keyboard you type just "myproject" instead of the tilde-troublesome
# "~/Projects/myproject" or a long absolute path.
#   ""           -> path  $CR_NEW_DIR
#   myproject    -> bare  $CR_NEW_DIR/myproject
#   ~ , ~/x      -> path  $HOME , $HOME/x
#   $HOME/x      -> path  (env expanded)
#   /abs , rel/x -> path  (left as typed)
# kind is "bare" only for the shortcut case, letting the caller offer to create a
# missing bare-name dir while still rejecting a missing explicit path. Bare-name
# prepending runs BEFORE the ~/$HOME expansion below, otherwise the cases overlap
# (and CR_NEW_DIR itself defaults to the literal "~/Projects", so it needs it too).
cr_resolve_new_dir() {
  local dir="$1" kind=path
  if [ -z "$dir" ]; then
    dir="$CR_NEW_DIR"
  else
    case "$dir" in
      */* | "~"* | '$'*) ;; # explicit path, home, or env-var -> leave as typed
      *)
        kind=bare
        dir="${CR_NEW_DIR%/}/$dir"
        ;;
    esac
  fi
  # ~ and ${HOME}/$HOME stay literal under `read -r`, so expand them by hand (no
  # eval -- the input is typed at an interactive prompt).
  # SC2088: the tilde here is a literal match/strip target, not meant to expand.
  # shellcheck disable=SC2088
  case "$dir" in
    "~") dir="$HOME" ;;
    "~/"*) dir="$HOME/${dir#"~/"}" ;;
  esac
  dir="${dir//\$\{HOME\}/$HOME}"
  dir="${dir//\$HOME/$HOME}"
  printf '%s\t%s\n' "$kind" "$dir"
}

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

# cr_launch <name> <attach:0|1> <wait:0|1> -- <claude args...>
# Creates a detached tmux session running claude directly, so pane_pid == claude pid.
# `claude` is resolved from PATH by tmux's exec form (no shell involved, so the
# interactive claude zsh function never enters the picture — equivalent to
# `command claude`). Renames the session to <name>-<pane_pid>, arms post-exit
# capture, then either attaches (cr_attach_and_drain, honouring <wait>) or, in
# no-attach mode, prints the session name. Shared by the wrapper and the picker's
# new-session path. The attach is NOT exec'd (see cr_attach), so the caller
# regains control to drain Claude's post-exit output instead of just "[exited]".
cr_launch() {
  local name="$1" attach="$2" wait="$3"
  shift 3
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
  cr_configure_exit_capture "$final"
  if [ "$attach" -eq 1 ]; then
    cr_attach_and_drain "$final" "$wait"
    return 0
  fi
  printf '%s\n' "$final"
}

# --- post-exit output capture --------------------------------------------------
# When Claude leaves its full-screen TUI it prints a couple of lines to the
# primary screen (e.g. the session id). Those vanish the instant claude exits:
# tmux tears the session down and the attached client only sees "[exited]". We
# hold the dead pane (remain-on-exit) just long enough for a pane-died hook to
# capture the primary-screen history to a file and kill the session itself; the
# attaching caller then drains and prints that file.

# cr_sanitize_name <s> -> <s> with anything outside [A-Za-z0-9._-] collapsed to
# '_', so a session name is safe both as a path segment and a tmux buffer name.
cr_sanitize_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# cr_exit_dir -> directory holding per-session post-exit capture files.
# Override with CR_EXIT_DIR (tests point this at an isolated dir).
cr_exit_dir() {
  local base="${TMPDIR:-/tmp}"
  base="${base%/}"
  printf '%s\n' "${CR_EXIT_DIR:-${base}/claude-remote-exit}"
}

# cr_exit_file <session> -> absolute path of the capture file for <session>.
cr_exit_file() {
  printf '%s/%s\n' "$(cr_exit_dir)" "$(cr_sanitize_name "$1")"
}

# cr_exit_buf <session> -> the (path-free) tmux paste-buffer name for <session>.
cr_exit_buf() {
  printf 'cr_exit_%s\n' "$(cr_sanitize_name "$1")"
}

# cr_drain_exit_output <session>: print the post-exit capture file for <session>
# (written by its pane-died hook). Drops tmux's own "Pane is dead (status …)"
# banner and the blank padding capture-pane leaves, then prints what Claude
# actually wrote — raw, no header. Session-specific on purpose: it must never
# surface a *different* (or stale) session's leftover file, and on a plain detach
# (session still alive, so no capture for it) it correctly shows nothing. It does
# **not** delete the file: a dying session may have several clients attached
# (e.g. the launching iTerm window AND a re-attached iPad), each of which returns
# from `tmux attach` and drains — deleting here lets the first client win the race
# and leaves the others (incl. the picker that wants to pause) with nothing.
# Cleanup is out of band via cr_reap_exit_files. The banner match tolerates
# leading whitespace in case a tmux build centres it. Returns 0 iff the file
# existed and yielded non-empty output, so a caller can decide whether to pause
# afterwards (the picker does; the wrapper doesn't).
cr_drain_exit_output() {
  local file content
  file="$(cr_exit_file "$1")"
  [ -f "$file" ] || return 1
  content="$(grep -vE '^[[:space:]]*Pane is dead \(status ' "$file" | awk '
    NF { if (!s) s = NR; e = NR }
    { line[NR] = $0 }
    END { for (i = s; i <= e; i++) print line[i] }
  ')"
  [ -n "$content" ] || return 1
  printf '%s\n' "$content"
}

# cr_reap_exit_files: delete capture files older than the reap grace (default 1
# minute, override with CR_EXIT_TTL_MIN). Because cr_drain_exit_output no longer
# deletes (so every client of a multi-client session can read the same capture),
# files must be cleaned up here. A file older than the grace belongs to a session
# that died long ago — the file is written at death and read by all attached
# clients within ~a second — so removing it is safe and never races a reader.
# Called at the picker loop top and once by the wrapper.
cr_reap_exit_files() {
  local dir
  dir="$(cr_exit_dir)"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f -mmin +"${CR_EXIT_TTL_MIN:-1}" -delete 2>/dev/null
  return 0
}

# cr_configure_exit_capture <session>: arm <session> so its post-exit output is
# preserved. Sets remain-on-exit so the pane is held (not destroyed) when claude
# exits — that both keeps the primary-screen grid AND fires pane-died — then
# installs a 4-command pane-died hook that copies the full grid history into a
# paste buffer (-S - -E -: the dead-pane banner repaint pushes the top line(s)
# out of the visible area, so visible-only capture would lose them), saves it to
# the per-session file, deletes the buffer, and kills the session. Pure tmux
# commands (no `run-shell 'tmux …'`) so they hit THIS server's socket. Idempotent:
# `set-hook` (no -a) replaces the hook, the appends rebuild it, so re-arming the
# same session yields the identical 4-command hook with no accumulation. Values
# are baked in by our shell (not tmux #{} formats) so names stay per-session.
cr_configure_exit_capture() {
  local session="$1" file buf
  file="$(cr_exit_file "$session")"
  buf="$(cr_exit_buf "$session")"
  mkdir -p "$(cr_exit_dir)" 2>/dev/null || true
  # shellcheck disable=SC2086
  $CR_TMUX set-option -w -t "$session" remain-on-exit on 2>/dev/null || true
  # shellcheck disable=SC2086
  $CR_TMUX set-hook -t "$session" pane-died "capture-pane -b '$buf' -S - -E -" 2>/dev/null || true
  # shellcheck disable=SC2086
  $CR_TMUX set-hook -a -t "$session" pane-died "save-buffer -b '$buf' '$file'" 2>/dev/null || true
  # shellcheck disable=SC2086
  $CR_TMUX set-hook -a -t "$session" pane-died "delete-buffer -b '$buf'" 2>/dev/null || true
  # shellcheck disable=SC2086
  $CR_TMUX set-hook -a -t "$session" pane-died "kill-session -t '$session'" 2>/dev/null || true
}

# cr_attach <session>: attach to <session>. Deliberately NOT exec'd — the caller
# (the wrapper, or the picker loop / its new-session subshell) must regain control
# afterwards to drain Claude's post-exit output and, in the picker, redraw.
cr_attach() {
  # shellcheck disable=SC2086
  $CR_TMUX attach -t "$1"
}

# cr_attach_and_drain <session> <wait:0|1>: attach, then surface whatever Claude
# printed after leaving its TUI (cr_drain_exit_output). With wait=1 (the picker)
# pause for a keypress so that output survives the picker's next full-screen
# redraw (fzf uses the alternate screen); the wrapper passes wait=0 — its output
# just stays in the scrollback above the shell prompt. The prompt goes to stderr
# and the read tolerates EOF, so piped/test stdin never hangs. `|| true` on the
# attach keeps a failed/ended attach from tripping the wrapper's `set -e`.
cr_attach_and_drain() {
  local session="$1" wait="$2"
  cr_attach "$session" || true
  if cr_drain_exit_output "$session" && [ "$wait" -eq 1 ]; then
    printf 'Weiter mit Enter … ' >&2
    # Read the keypress from the controlling terminal, NOT fd 0. In the picker
    # loop, after `tmux attach` returns over SSH, a read from fd 0 comes back
    # immediately (no genuine wait) — whereas /dev/tty blocks for a real key.
    # Fall back to fd 0 only when there is no controlling terminal (piped/tests).
    if [ -e /dev/tty ]; then
      read -r _ </dev/tty || true
    else
      read -r _ || true
    fi
  fi
}

# cr_reattach <session> <wait:0|1>: arm capture on an already-running session
# (it may predate this feature or have been started outside claude-remote), then
# attach + drain exactly like a fresh launch. Picker-only — the wrapper never
# re-attaches. Symmetric with cr_launch: both delegate to the same building blocks.
cr_reattach() {
  cr_configure_exit_capture "$1"
  cr_attach_and_drain "$1" "$2"
}

# cr_ensure_anchor: if no tmux server is running yet, birth one via a detached
# "holding" session named $CR_ANCHOR; otherwise do nothing.
#
# The point is the server's launchd bootstrap namespace, which is fixed at birth and
# inherited by every pane. Run from the GUI (Aqua) session via the install.sh
# LaunchAgent at login — when normally no server exists yet — the server it births is
# keychain-capable, so a later iPad picker session born inside it can write the login
# keychain (OAuth token refresh) instead of failing with errSecInteractionNotAllowed
# (-25308), which is what happens when the picker's `tmux new-session` instead births
# a fresh server inside the SSH forced command's Background launchd domain. The
# detached holding session then keeps that Aqua server alive across session churn.
#
# It is a no-op whenever a server is ALREADY running — we can't change a running
# server's namespace anyway, and must never disturb a server we didn't birth (e.g. the
# user's existing sessions). This also makes the LaunchAgent safe to load at any time:
# with sessions already up it does nothing, and takes effect at the next clean login.
# The holding session is hidden from the picker (see cr_menu_lines).
cr_ensure_anchor() {
  # shellcheck disable=SC2086
  $CR_TMUX list-sessions >/dev/null 2>&1 && return 0
  # shellcheck disable=SC2086
  $CR_TMUX new-session -d -s "$CR_ANCHOR"
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
    # keep the "session<TAB>display" contract the loop expects. The $CR_ANCHOR
    # holding session is internal plumbing (see cr_ensure_anchor) — filter it out.
    # shellcheck disable=SC2086
    $CR_TMUX list-sessions -F '#{session_name}'$'\t''#{session_name}' 2>/dev/null |
      awk -F'\t' -v anchor="$CR_ANCHOR" '$1 != anchor'
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

# cr_ensure_utf8_locale: guarantee a UTF-8 character locale so Claude panes born
# from the picker handle multibyte (UTF-8) input/paste correctly. Under a stripped
# environment (SSH forced command, launchd) LANG/LC_* are often empty, leaving
# child processes on the C/US-ASCII locale; tmux still renders glyphs via the
# client's utf8 flag, but pasted UTF-8 is mangled by the ASCII input layer. We act
# only when the effective character locale (LC_ALL > LC_CTYPE > LANG, POSIX order)
# is not already UTF-8, and only set a locale the system actually provides. The
# first available of CR_LOCALE (default de_DE.UTF-8), en_US.UTF-8, C.UTF-8 wins.
cr_ensure_utf8_locale() {
  local eff="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  case "$eff" in
    *[Uu][Tt][Ff]-8 | *[Uu][Tt][Ff]8) return 0 ;;
  esac
  local avail cand
  avail="$(locale -a 2>/dev/null)"
  for cand in "${CR_LOCALE:-}" de_DE.UTF-8 en_US.UTF-8 C.UTF-8; do
    [ -n "$cand" ] || continue
    if printf '%s\n' "$avail" | grep -qxF "$cand"; then
      export LANG="$cand" LC_CTYPE="$cand"
      return 0
    fi
  done
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
