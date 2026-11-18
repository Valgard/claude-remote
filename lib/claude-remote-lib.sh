#!/usr/bin/env bash
# claude-remote shared helpers. Sourced by bin/claude-remote, bin/claude-remote-pick, and tests.
# All tmux/abtop access goes through the CR_TMUX / CR_ABTOP env seams.

: "${CR_TMUX:=tmux}"
: "${CR_ABTOP:=abtop}"
: "${CR_SSH_PORT:=22}"
: "${CR_ANCHOR:=_cr_anchor}"
: "${CR_NEW_DIR:=~/Projects}"
: "${CR_PROJECTS_DIR:=${HOME:-~}/.claude/projects}"
: "${CR_TAC:=tac}"
: "${CR_SESSIONS_DIR:=${HOME:-~}/.claude/sessions}"
: "${CR_PS:=ps}"
: "${CR_PGREP:=pgrep}"
: "${CR_LAUNCHCTL:=launchctl}"
: "${CR_ANCHOR_LABEL:=de.valgard.claude-remote-anchor}"
# Seconds cr_start_anchor waits for the replacement server; must exceed the
# LaunchAgent's StartInterval (CR_ANCHOR_INTERVAL, 60) so one retry tick fits.
: "${CR_ANCHOR_WAIT:=90}"
# Where the restart snapshot is kept, and how long (seconds) cr_restore_sessions waits
# after launching before it checks which sessions died at once.
: "${CR_RESTART_DIR:=${TMPDIR:-/tmp}}"
: "${CR_RESTORE_SETTLE:=3}"
# _cr_seconds_seam <var> <default>: default <var> like the seams above, then hold it
# to whole seconds, at most eight digits, read as decimal. `30s`, the form direnv's
# own DIRENV_WARN_TIMEOUT takes and the likely slip, would make the pane's zsh abort
# its arithmetic before claude starts, a leading zero (08) would make bash read an
# invalid octal number in the restore's wait, and nine digits overflow the pane's
# timer. Anything else falls back to <default>, with a warning.
_cr_seconds_seam() {
  local value=${!1:-$2}
  case $value in *[!0-9]* | ?????????*)
    echo "claude-remote: $1='$value' ist keine ganze Zahl von Sekunden, nehme $2" >&2
    value=$2
    ;;
  esac
  printf -v "$1" '%s' "$((10#$value))"
}
# How long a login-shell pane gives direnv to load the start dir's .envrc before it
# starts claude without it (0: no limit), and how long a launch that attaches holds
# direnv's complaint on screen before claude's TUI covers it.
_cr_seconds_seam CR_DIRENV_TIMEOUT 30
_cr_seconds_seam CR_DIRENV_HOLD 15
# Claude Code writes its session title into the terminal title, prefixed with a
# status glyph (U+2733 + space), and uses a fixed placeholder while no title is
# set. Both are Claude Code's format, not ours — hence the seams: if either ever
# changes, one env var restores the picker without a release. That matters more
# than it looks: a dead prefix gate does NOT degrade to the project name, it
# degrades to the transcript tier, i.e. straight back into the foreign-name bug
# this tier exists to prevent (see cr_resolve_titles). Spelled as bytes: the
# comparison is byte-wise, so it must not depend on this file's encoding
# surviving an edit.
: "${CR_TITLE_PREFIX:=$'\xe2\x9c\xb3 '}"
: "${CR_TITLE_PLACEHOLDER:=Claude Code}"

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

# How a login-shell launch starts claude in the pane, after ~/.zshrc (ADR-001,
# ADR-004):
#   zsh -lic "$CR_PANE_LOADER" cr "$CR_PANE_SCRIPT" <direnv limit s> <hold s> <args…>
# The -c string is parsed after ~/.zshrc, so its aliases would rewrite the script's
# commands and an option like IGNORE_BRACES would make it unparsable. The loader
# therefore resets the options to zsh's defaults (`emulate -R` leaves only those
# describing the terminal, such as MONITOR and ZLE, as they were) and turns aliases
# off before it parses the script; only the loader's own three words are left
# exposed. The script's `emulate -L zsh` would turn aliases back on for the $(…) it
# parses only as it runs, hence `no_aliases` again inside; and since a ~/.zshrc can
# shadow a builtin with a function (`no_aliases` does not touch functions), the
# builtins it relies on are called through `builtin`, the external commands through
# `command`.
# The script loads the nearest .envrc at or above the start dir, says so when that
# went wrong, and then execs claude. The exec is load-bearing — inside a function
# zsh never execs implicitly — and keeps the pid, so the pane process stays claude
# (the pid join, the exit capture, the Ctrl+Z binding). `command` bypasses a
# `claude` zsh function, which a user's ~/.zshrc may well point at claude-remote.
# - direnv: ~/.zshrc only registers _direnv_hook for the next prompt and the next
#   cd, and the script reaches neither before its exec, so it fires the hook itself.
#   The hook's existence is the opt-in. Without it nothing loads, but a direnv on
#   PATH that sees an .envrc here turns that into a reported problem, not the
#   silence that hid the missing call from 2026-06 to 2026-11. The hook returns
#   early unless the shell is interactive and not a subshell, hence `-i` and a call
#   outside any $(…).
# - Ctrl-C and the limit: the hook runs in a try block whose always arm cancels the
#   interrupt, so Ctrl-C gives up on direnv rather than on the launch, as at a
#   terminal prompt; the hold below does the same. The limit is a timer that sends
#   what Ctrl-C sends: SIGINT to the terminal's foreground process group. That is the
#   shell's own while direnv runs inside the hook's $(…), but under `-i` a plain
#   command gets a group of its own, which a SIGINT to the shell's group would miss.
#   ps pads the group number with blanks, hence the strip. The timer waits in the
#   zselect builtin, so killing it leaves no sleep behind. A timer firing between
#   the hook's end and its own kill (the first thing the always arm does) hits the
#   shell instead, and the arm drops the interrupt: at worst an abort is reported
#   for an .envrc that loaded. It takes an .envrc that lasts the limit to the
#   instant.
# - Output: DIRENV_LOG_FORMAT= silences direnv's status lines, not its errors, and
#   DIRENV_WARN_TIMEOUT is raised past the limit to keep direnv's own "taking a
#   while" note out too. Whatever still reaches the error file is a problem, or an
#   .envrc writing to stderr of its own accord. Without an error file (mktemp
#   failed) direnv writes straight to the screen, and where there is an .envrc to
#   load, that failure is the problem.
# - A problem is printed and, when <hold> > 0 (a launch that attaches), held until a
#   key or <hold> seconds, as claude's TUI covers it otherwise. Keys typed while the
#   .envrc loaded are discarded first, or the first of them would skip the hold.
#   The first line that is not blank once ANSI codes and control characters are
#   removed goes into the pane option @cr_direnv right before the exec, without
#   trailing semicolons (tmux reads one as a command separator). `ok` there means no
#   problem, so a line that cleans up to `ok`, or nothing left at all, is reported in
#   other words. cr_restore_sessions waits for the option and reports it; setting it
#   needs `tmux` on the pane's PATH.
# - The script must hold no single quote, which would end this string.
# shellcheck disable=SC2016 # expanded by the pane's zsh, not here
CR_PANE_LOADER='emulate -R zsh; setopt no_aliases; eval "$1"'
# shellcheck disable=SC2016 # expanded by the pane's zsh, not here
CR_PANE_SCRIPT='() {
  emulate -L zsh
  setopt extendedglob no_aliases
  local limit=$1 hold=$2 problem= errf= timer= out= clean= reason= line= esc=
  builtin shift 2
  if (( ${+functions[_direnv_hook]} )); then
    if ! errf=$(command mktemp "${TMPDIR:-/tmp}/claude-remote-direnv.XXXXXX" 2>/dev/null); then
      [[ "$(command direnv status 2>/dev/null)" == *"Found RC path "* ]] &&
        problem="direnv-Ausgabe nicht prüfbar (mktemp schlug fehl)"
    fi
    if (( limit > 0 )); then
      {
        if builtin zmodload -F zsh/zselect b:zselect 2>/dev/null; then
          builtin zselect -t $(( limit * 100 ))
        else
          command sleep $limit
        fi
        local pg=$(command ps -o tpgid= -p $$ 2>/dev/null)
        pg=${pg//[^0-9]/}
        (( pg > 1 )) || pg=$$
        builtin kill -INT -- -$pg
      } </dev/null >/dev/null 2>&1 &!
      timer=$!
    fi
    {
      DIRENV_LOG_FORMAT= DIRENV_WARN_TIMEOUT=$(( limit + 60 ))s _direnv_hook 2>>${errf:-/dev/stderr}
    } always {
      [[ -n $timer ]] && builtin kill $timer 2>/dev/null
      if (( TRY_BLOCK_INTERRUPT )); then
        TRY_BLOCK_INTERRUPT=0
        problem="direnv abgebrochen (Zeitlimit von $limit s oder Ctrl-C)"
      fi
    }
    if [[ -n $errf ]]; then
      [[ -s $errf ]] && out=$(<$errf)
      command rm -f -- $errf
    fi
  elif (( ${+commands[direnv]} )) && [[ "$(command direnv status 2>/dev/null)" == *"Found RC path "* ]]; then
    problem="direnv ist installiert und hier liegt eine .envrc, aber ~/.zshrc definiert keinen direnv-Hook (_direnv_hook)"
  fi
  if [[ -n $problem || -n $out ]]; then
    builtin print -u2 -r -- "claude-remote: direnv meldet ein Problem mit der .envrc. Claude startet womöglich ohne ihre Variablen."
    [[ -n $problem ]] && builtin print -u2 -r -- "$problem"
    [[ -n $out ]] && builtin print -u2 -r -- "$out"
    if (( hold > 0 )); then
      while builtin read -t 0 -k1 -s; do :; done
      builtin print -u2 -rn -- "Weiter mit beliebiger Taste (Claude startet sonst in $hold s) … "
      { builtin read -k1 -s -t $hold } always { TRY_BLOCK_INTERRUPT=0 }
      builtin print -u2
    fi
    reason=$problem
    if [[ -z $reason ]]; then
      builtin printf -v esc "\e"
      clean=${out//${esc}\[[0-9;]#[[:alpha:]]/}
      for line in "${(@f)clean}"; do
        line=${line//[[:cntrl:]]/ }
        line=${${line##[[:space:]]#}%%[[:space:];]#}
        [[ -n $line ]] && { reason=$line; break }
      done
    fi
    case $reason in
      "") reason="direnv gab nur Leerzeilen oder Steuerzeichen aus" ;;
      ok) reason="ok (Ausgabe der .envrc)" ;;
    esac
  fi
  [[ -n $TMUX ]] && command tmux set-option -p @cr_direnv "${reason:-ok}" 2>/dev/null
  exec command claude "$@"
} "${@[2,-1]}"'

# cr_launch <name> <attach:0|1> <wait:0|1> -- <claude args...>
# Creates a detached tmux session running claude, so pane_pid == claude pid.
# CR_LOGIN_SHELL=1 (default): runs CR_PANE_SCRIPT under `zsh -lic` (through
# CR_PANE_LOADER), so the pane gets the full ~/.zshrc environment (PATH, secrets,
# MCP tokens, etc.) plus the start dir's .envrc before the script execs claude.
# Only a launch that attaches holds a direnv complaint on screen: a detached one
# (--no-attach, the restore) has nobody to read it, and claude would only start
# late. CR_LOGIN_SHELL=0
# keeps the legacy direct exec form (used by the test harness for hermeticity).
# Renames the session to <name>-<pane_pid>, arms post-exit capture, then either
# attaches (cr_attach_and_drain, honouring <wait>) or, in no-attach mode, prints
# the session name. Shared by the wrapper and the picker's new-session path.
# The attach is NOT exec'd (see cr_attach), so the caller regains control to
# drain Claude's post-exit output instead of just "[exited]".
cr_launch() {
  local name="$1" attach="$2" wait="$3"
  shift 3
  [ "${1-}" = "--" ] && shift
  local tmp pid final hold=0
  tmp="${name}-tmp-$$"
  if [ "${CR_LOGIN_SHELL:-1}" = 1 ]; then
    if [ "$attach" = 1 ]; then hold=$CR_DIRENV_HOLD; fi
    # shellcheck disable=SC2086 # intentional word-split on $CR_TMUX
    $CR_TMUX new-session -d -s "$tmp" -- zsh -lic "$CR_PANE_LOADER" cr "$CR_PANE_SCRIPT" "$CR_DIRENV_TIMEOUT" "$hold" "$@" || return 1
  else
    # shellcheck disable=SC2086
    $CR_TMUX new-session -d -s "$tmp" -- claude "$@" || return 1
  fi
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
# (written by its pane-died hook). Drops tmux's own "Pane is dead (…)" banner
# (status N on a clean exit, signal int on Ctrl-C/kill) and the blank padding
# capture-pane leaves, then prints what Claude
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
  # 2>/dev/null: another attached client (or an old pre-fix client) can unlink the
  # file between the [ -f ] check above and this read — swallow grep's "No such
  # file"/"Permission denied" so a lost race yields "nothing to show", not noise.
  # Match "Pane is dead (" without pinning the reason: tmux writes "(status N, …)"
  # on a normal exit but "(signal int, …)" when the pane is killed by a signal
  # (Ctrl-C, kill) — both are noise, as is any future variant.
  content="$(grep -vE '^[[:space:]]*Pane is dead \(' "$file" 2>/dev/null | awk '
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

# cr_kill_session <session>: terminate a claude-remote session from the picker.
# kill-session sends SIGHUP to the claude pane and tears the session down — the
# remain-on-exit/pane-died capture machinery is irrelevant here (the user is
# deliberately discarding, not exiting cleanly). Refuses an empty target and the
# keychain anchor ($CR_ANCHOR): the anchor is already hidden from the menu (so it
# can't be selected), but the guard is cheap defense-in-depth against ever tearing
# down the server's Aqua holding session. Drops any stale post-exit capture file
# for the session (cr_reap_exit_files would eventually clean it, but a kill makes
# the immediate removal trivial); a capture written by a pane-died race is harmless
# — the session is gone, so it is never drained, and reap sweeps it. Returns
# non-zero on a refused/failed kill so the caller can report it.
cr_kill_session() {
  local session="$1"
  [ -n "$session" ] || return 1
  [ "$session" = "$CR_ANCHOR" ] && return 1
  # shellcheck disable=SC2086
  $CR_TMUX kill-session -t "$session" || return 1
  rm -f "$(cr_exit_file "$session")" 2>/dev/null
  return 0
}

# cr_anchor_plist <label> <prog_a> <prog_b> <interval>
# Emit the LaunchAgent plist to stdout. prog_a/prog_b are the two ProgramArguments
# entries: either [/usr/bin/open, <app-path>] (app anchor) or
# [<claude-remote-pick>, --ensure-anchor] (script anchor / degrade).
cr_anchor_plist() {
  local label="$1" prog_a="$2" prog_b="$3" interval="$4"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${prog_a}</string>
    <string>${prog_b}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>${interval}</integer>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
</dict>
</plist>
EOF
}

# cr_anchor_app_needs_build <src> <bin>
# Return 0 (needs build) if <bin> is missing, not executable, or older than <src>.
# Return 1 (up to date) when <bin> exists, is executable, and is not older than <src>.
# Used by install.sh to implement build-once semantics: the ad-hoc cdhash (and thus
# the one-time macOS Local Network grant) stays stable across re-runs of install.sh.
cr_anchor_app_needs_build() {
  local src="$1" bin="$2"
  [ ! -x "$bin" ] && return 0
  [ "$src" -nt "$bin" ] && return 0
  return 1
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

# --- server restart ---------------------------------------------------------------

# Launch flags that stay as they are when a session is relaunched after a server
# restart (the allowlist; everything else is dropped). Not --strict-mcp-config: it means
# "only the servers from --mcp-config", and --mcp-config is always dropped, so keeping
# it alone would bring the session back without any MCP server. Dropping it would widen
# the session instead, so a session started with it is not restorable at all (see
# CR_RESTRICT_FLAGS).
CR_KEEP_FLAGS="--allow-dangerously-skip-permissions --dangerously-skip-permissions --brief --chrome --no-chrome --ide --verbose --ax-screen-reader --disable-slash-commands --bare --safe-mode --restricted"
# Allowlisted flags that take a value; kept together with the next token.
CR_KEEP_VALUE_FLAGS="--model --fallback-model --effort --permission-mode --agent --autocompact --setting-sources --system-prompt-snapshot"
# Launch flags that restrict what a session may do (tools, settings with deny rules, MCP
# servers, the permission prompt). None is on the allowlist, so a relaunch would drop
# it and bring the session back with FEWER restrictions than it ran with; a session
# started with one is therefore not restorable at all (also in its --flag=value form).
# --allowedTools is deliberately absent: it only pre-approves tools, so dropping it
# costs permission prompts, never a restriction; it is dropped and listed like any other.
CR_RESTRICT_FLAGS="--disallowedTools --disallowed-tools --tools --settings --strict-mcp-config --permission-prompt-tool"
# The awk function who(): how the summary, its re-ask and the restore report name a
# snapshot row (the current record): `<title> (<tmux name>)`, or the bare tmux name
# when column 10 is empty or absent (a 9-column snapshot from before the title
# column). The tmux name alone, `<start-dir basename>-<pid>`, does not tell apart the
# sessions started in one directory. One definition, spliced in front of each program.
# SC2016: $1/$10 are awk fields, not shell expansions.
# shellcheck disable=SC2016
CR_RESTART_WHO_AWK='
function who() { return ($10 == "") ? $1 : ($10 " (" $1 ")") }
'

# cr_server_pid: print the running tmux server's pid; return 1 when none runs.
cr_server_pid() {
  local pid
  # shellcheck disable=SC2086
  pid="$($CR_TMUX display-message -p '#{pid}' 2>/dev/null)" || return 1
  [ -n "$pid" ] || return 1
  printf '%s\n' "$pid"
}

# _cr_supervisor_pids: the anchor supervisors, one pid per line. `pgrep -f` matches a
# substring, so it also finds any process that merely MENTIONS the supervisor (a grep
# over a log, or a `watch pgrep -f …` in a terminal); only a pid whose command line
# ends in `<dir>/claude-remote-pick --supervise-anchor` is ours. The app stub execs the
# script by absolute path and its `#!/usr/bin/env bash` turns that into
# `bash <dir>/claude-remote-pick --supervise-anchor`; the `/` is what tells it apart from
# a typed `pgrep -f claude-remote-pick --supervise-anchor`, which ends the same way.
_cr_supervisor_pids() {
  local pid args
  for pid in $($CR_PGREP -f 'claude-remote-pick --supervise-anchor' 2>/dev/null); do
    args="$("$CR_PS" -o args= -p "$pid" 2>/dev/null)" || continue
    args="${args%"${args##*[! ]}"}"
    case $args in
      */claude-remote-pick" --supervise-anchor") printf '%s\n' "$pid" ;;
    esac
  done
}

# cr_stop_anchor_and_server: end the anchor supervisor(s) first, so the old instance
# cannot re-birth the server under itself (a fresh instance the agent starts meanwhile
# may, which is harmless); only once they are provably gone kill the server. TERM, wait
# up to 5 s, KILL the survivors, wait up to 2 s; if any is still alive return 1 WITHOUT
# touching the server (fail safe: no session is ended). Returns 1 also when a server
# still answers after kill-server. Order is load-bearing.
cr_stop_anchor_and_server() {
  local pids pid
  pids="$(_cr_supervisor_pids)"
  for pid in $pids; do
    kill -TERM "$pid" 2>/dev/null
  done
  # shellcheck disable=SC2086
  _cr_wait_gone 5 $pids && pids=""
  if [ -n "$pids" ]; then
    # Skip pids that are already gone. This does not detect a pid reused during the
    # wait (it would pass kill -0 too); only the command-line check before TERM did.
    for pid in $pids; do
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null
      fi
    done
    # shellcheck disable=SC2086
    _cr_wait_gone 2 $pids || return 1
  fi
  # shellcheck disable=SC2086
  $CR_TMUX kill-server 2>/dev/null
  cr_server_pid >/dev/null && return 1
  return 0
}

# _cr_wait_gone <seconds> [<pid>...]: poll once per second until none of the pids is
# alive; return 1 when some still is after <seconds>.
_cr_wait_gone() {
  local max=$1 i=0 pid alive
  shift
  while :; do
    alive=0
    for pid in "$@"; do
      kill -0 "$pid" 2>/dev/null && alive=1
    done
    [ "$alive" -eq 0 ] && return 0
    [ "$i" -ge "$max" ] && return 1
    sleep 1
    i=$((i + 1))
  done
}

# cr_start_anchor <old_server_pid> [<report-file>]: kickstart the anchor LaunchAgent and
# poll once per second, up to $CR_ANCHOR_WAIT, until the anchor session exists on a
# server whose pid differs from <old_server_pid>. Returns 0 on success, 1 on timeout.
# `=` makes the match exact: without it tmux falls back to a prefix match
# (`_cr_anchor_old`). A failed kickstart is printed (and noted in <report-file>) with its
# exit code and error, and the wait still runs: the restart checked that the agent is
# loaded, so its own interval can birth the anchor all the same.
cr_start_anchor() {
  local old=$1 report=${2:-} i=0 new err rc=0
  # -k: the agent job may be mid-run (the per-interval `open` in flight); without it a
  # kickstart can leave that run alone and no fresh anchor starts until the next tick.
  err="$("$CR_LAUNCHCTL" kickstart -k "gui/$(id -u)/$CR_ANCHOR_LABEL" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    err="$(printf '%s\n' "$err" | awk 'NF { last = $0 } END { print last }')"
    _cr_restart_note "$report" "launchctl kickstart fehlgeschlagen (Exit $rc)${err:+: $err}"
  fi
  while :; do
    # shellcheck disable=SC2086
    if $CR_TMUX has-session -t "=$CR_ANCHOR" 2>/dev/null; then
      new="$(cr_server_pid)" && [ "$new" != "$old" ] && return 0
    fi
    [ "$i" -ge "$CR_ANCHOR_WAIT" ] && return 1
    sleep 1
    i=$((i + 1))
  done
}

# cr_session_label <session_name>: the name without its trailing -<digits> (pid) suffix.
cr_session_label() {
  local name=$1
  case $name in
    *-[0-9]*) ;;
    *) printf '%s\n' "$name" && return 0 ;;
  esac
  local tail=${name##*-}
  case $tail in
    '' | *[!0-9]*) printf '%s\n' "$name" ;;
    *) printf '%s\n' "${name%-*}" ;;
  esac
}

# cr_rewrite_claude_args <session_id> [<arg>...]: classify each launch token as kept
# (+<TAB>token) or dropped (-<TAB>token), in input order, then append the exact
# `--resume <session_id>`. Only allowlisted flags survive; positional prompts, --name,
# --worktree and variadic flags are dropped. The tokens that pick which conversation
# opens (--resume/-r and --session-id with their optional value, --continue/-c,
# --fork-session) print no line at all: the appended --resume REPLACES that choice,
# so reporting them as dropped would only bury the real drops. Their value is the next
# token iff it does not start with `-` (claude's `-r, --resume [value]`), so a flag
# after them, restricting or not, is still classified on its own. --fork-session needs
# no successor: the session file already holds the forked id.
cr_rewrite_claude_args() {
  local sid=$1 tok flag
  shift
  while [ $# -gt 0 ]; do
    tok=$1
    shift
    case $tok in
      --resume | -r | --session-id)
        case ${1:--} in
          -*) ;;
          *) shift ;;
        esac
        continue
        ;;
      --resume=* | --session-id=* | --continue | -c | --fork-session) continue ;;
    esac
    flag=${tok%%=*}
    case " $CR_KEEP_FLAGS " in
      *" $tok "*)
        printf '+\t%s\n' "$tok"
        continue
        ;;
    esac
    case " $CR_KEEP_VALUE_FLAGS " in
      *" $flag "*)
        if [ "$flag" != "$tok" ]; then
          printf '+\t%s\n' "$tok"
        elif [ $# -gt 0 ]; then
          printf '+\t%s\n+\t%s\n' "$tok" "$1"
          shift
        else
          printf -- '-\t%s\n' "$tok"
        fi
        continue
        ;;
    esac
    printf -- '-\t%s\n' "$tok"
  done
  printf '+\t--resume\n+\t%s\n' "$sid"
}

# cr_drops_restriction [<arg>...]: 0 iff cr_rewrite_claude_args would drop a restricting
# flag (CR_RESTRICT_FLAGS, as a whole token or as --flag=value) from these launch args.
cr_drops_restriction() {
  local line flag
  while IFS= read -r line; do
    [ "${line%%$'\t'*}" = - ] || continue
    flag=${line#*$'\t'}
    flag=${flag%%=*}
    case " $CR_RESTRICT_FLAGS " in
      *" $flag "*) return 0 ;;
    esac
  done < <(cr_rewrite_claude_args - "$@")
  return 1
}

# cr_session_record <pid>: one line `session_id<TAB>kind<TAB>status<TAB>proc_start` from
# $CR_SESSIONS_DIR/<pid>.json. A missing or non-string field is empty and control
# characters are flattened to spaces (as in cr_session_title), so a tab cannot tear the
# record. Returns 1 if the file is missing, 2 if it is not a JSON object.
cr_session_record() {
  local f="${CR_SESSIONS_DIR}/$1.json" out
  [ -f "$f" ] || return 1
  out="$(jq -r 'select(type == "object")
                | [.sessionId, .kind, .status, .procStart]
                | map(if type == "string" then gsub("[[:cntrl:]]"; " ") else "" end)
                | join("\t")' "$f" 2>/dev/null)" || return 2
  [ -n "$out" ] || return 2
  printf '%s\n' "$out"
}

# cr_proc_start_matches <pid> <proc_start>: 0 iff the process' start time equals the
# recorded one. The session file's procStart is UTC in `ps -o lstart` format; ps pads a
# single-digit day with an extra space, so both sides are squeezed and right-trimmed.
# This is the pid-reuse guard: a stale session file whose pid now belongs to another
# process started at another time.
cr_proc_start_matches() {
  local have want
  have="$(LC_ALL=C TZ=UTC "$CR_PS" -o lstart= -p "$1" 2>/dev/null | tr -s ' ')" || return 1
  want="$(printf '%s' "$2" | tr -s ' ')"
  have="${have%"${have##*[! ]}"}"
  want="${want%"${want##*[! ]}"}"
  [ -n "$have" ] && [ "$have" = "$want" ]
}

# cr_proc_claude_args <pid>: the words after argv0 of the process' command line,
# space-joined (possibly empty). Returns 1 if ps fails or argv0 is not `claude`.
cr_proc_claude_args() {
  local line argv0 rest
  line="$("$CR_PS" -o args= -p "$1" 2>/dev/null)" || return 1
  line="${line#"${line%%[! ]*}"}"
  argv0="${line%% *}"
  [ "${argv0##*/}" = "claude" ] || return 1
  case $line in
    *' '*) rest="${line#* }" ;;
    *) rest="" ;;
  esac
  printf '%s\n' "$(printf '%s' "$rest" | tr -s ' ')"
}

# cr_last_cwd <transcript.jsonl>: the cwd of the transcript's most recent record ("" if
# none). Read the same way as cr_session_title: backwards, grep prefilter, jq -R with
# fromjson?. -m3 rather than -m1 because a transcript being appended to right now ends
# mid-line, and the reversers glue that fragment onto the last complete record: the
# first hit is then unparsable and that complete record is lost with it. The next-older
# record answers, which is usually the same cwd but not always: a directory change made
# in the last complete record is missed while a write is in flight (accepted, the value
# only feeds the informational drift marker).
cr_last_cwd() {
  local f="$1"
  [ -n "$f" ] && [ -f "$f" ] || return 0
  cr_reverse_lines "$f" 2>/dev/null |
    grep -m3 '"cwd":"' 2>/dev/null |
    jq -R -r 'fromjson? | .cwd? // empty' 2>/dev/null |
    head -n 1
  return 0
}

# _cr_args_drop_restriction <space-joined args>: cr_drops_restriction on the args split
# the way cr_restore_sessions splits them (on blanks, never globbing).
_cr_args_drop_restriction() {
  local words
  IFS=$' \t\n' read -r -a words <<<"$1"
  [ "${#words[@]}" -gt 0 ] && cr_drops_restriction "${words[@]}"
}

# cr_restart_snapshot: one TSV row per pane of every session except $CR_ANCHOR:
#   name  pid  start  verdict  reason  session_id  status  last_cwd  args  title
# verdict is `ok` or `skip`; the first failing check sets the (German) reason:
# not a claude process, no/garbled session file, session file of another process
# (pid reuse), not interactive, no session id, a restricting launch flag the relaunch
# would drop (CR_RESTRICT_FLAGS). last_cwd is where the transcript last worked, left
# empty when unknown or equal to start. title is for display only and comes from
# exact sources alone: the pane's own title (cr_pane_title_clean), else the transcript
# title of the row's session id, and only when that id is the pane process' own (not
# when the session file belongs to another process); never abtop's guessed id. Tab and
# newline in args become spaces (the restore splits on them anyway) and every control
# character in title does, so neither can shift a column. Returns 1 when no server runs.
cr_restart_snapshot() {
  local panes line name pid start ptitle verdict reason sid own kind sstat pstart args cwd rec rc title
  # pane_title goes last: split by hand below, a tab inside it stays in the title.
  # shellcheck disable=SC2086
  panes="$($CR_TMUX list-panes -a -F "#{session_name}"$'\t'"#{pane_pid}"$'\t'"#{pane_start_path}"$'\t'"#{pane_title}" 2>/dev/null)" || return 1
  while IFS= read -r line; do
    # Not `read` with a tab IFS: it collapses an empty start path and shifts the title.
    name=${line%%$'\t'*}
    line=${line#*$'\t'}
    pid=${line%%$'\t'*}
    line=${line#*$'\t'}
    start=${line%%$'\t'*}
    ptitle=${line#*$'\t'}
    [ -n "$name" ] || continue
    [ "$name" = "$CR_ANCHOR" ] && continue
    verdict=skip reason="" sid="" own="" sstat="" cwd="" args=""
    if ! args="$(cr_proc_claude_args "$pid")"; then
      args=""
      reason="kein Claude-Prozess"
    else
      rc=0
      rec="$(cr_session_record "$pid")" || rc=$?
      if [ "$rc" -eq 1 ]; then
        reason="keine Session-Datei"
      elif [ "$rc" -ne 0 ]; then
        reason="Session-Datei unlesbar"
      else
        # Split by hand: read with a tab IFS collapses empty fields and would shift
        # the columns when the session id is empty.
        sid=${rec%%$'\t'*}
        rec=${rec#*$'\t'}
        kind=${rec%%$'\t'*}
        rec=${rec#*$'\t'}
        sstat=${rec%%$'\t'*}
        pstart=${rec#*$'\t'}
        own=$sid
        if ! cr_proc_start_matches "$pid" "$pstart"; then
          # The id is the session of the process that wrote the file, not this pane's.
          own=""
          reason="Session-Datei gehört zu einem anderen Prozess"
        elif [ "$kind" != "interactive" ]; then
          reason="keine interaktive Session"
        elif [ -z "$sid" ]; then
          reason="keine Session-ID"
        elif _cr_args_drop_restriction "$args"; then
          reason="einschränkende Startoptionen (nicht sicher übertragbar)"
        else
          verdict=ok
          cwd="$(cr_last_cwd "$(cr_session_file "$sid")")"
          [ "$cwd" != "$start" ] || cwd=""
        fi
      fi
    fi
    cr_pane_title_clean "$ptitle"
    title=$CR_PANE_TITLE
    if [ -z "$title" ] && [ -n "$own" ]; then
      title="$(cr_session_title "$(cr_session_file "$own")")"
    fi
    args=${args//[$'\t\n']/ }
    title=${title//[[:cntrl:]]/ }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "$pid" "$start" "$verdict" "$reason" "$sid" "$sstat" "$cwd" "$args" "$title"
  done <<<"$panes"
  return 0
}

# cr_restart_summary <snapshot-file>: the German confirmation text for a restart.
# Mid-turn = ok rows that are busy/waiting (status of skip rows is ignored). awk with
# an explicit tab FS keeps empty columns in place; `read` with a tab IFS would not.
# A snapshot without rows says plainly that only anchor and server restart, so a user
# who knows of sessions sees before answering that the snapshot missed them. Each
# listed session is named by who() (CR_RESTART_WHO_AWK).
cr_restart_summary() {
  awk -F'\t' "$CR_RESTART_WHO_AWK"'
    { total++ }
    $4 == "ok" {
      ok++
      if ($7 == "busy" || $7 == "waiting") mid = mid "  - " who() "\n"
      if ($8 != "") drift = drift "  - " who() " → " $8 "\n"
    }
    $4 != "ok" { lost = lost "  - " who() ": " $5 "\n" }
    END {
      if (!total) {
        print "Keine Sessions – nur Anchor und tmux-Server werden neu gestartet."
        exit
      }
      print "Anchor und tmux-Server werden neu gestartet."
      printf "Wiederherstellen: %d von %d Sessions\n", ok, total
      if (mid != "") printf "⚠️  Mitten in einer Antwort – der laufende Turn geht verloren:\n%s", mid
      if (drift != "") printf "Arbeiteten zuletzt woanders – starten im Startordner:\n%s", drift
      if (lost != "") printf "Nicht wiederherstellbar:\n%s", lost
    }
  ' "$1"
}

# cr_restart_snapshot_file: take a restart snapshot into a new file under
# $CR_RESTART_DIR and print its path. mktemp makes it 0600 with an unpredictable name
# (over SSH TMPDIR is often unset, so this is the shared /tmp). On failure it prints
# the German cause on stderr, leaves no file behind and returns 1 when no server runs
# or 2 when the file cannot be created or written — two causes with two fixes, so
# they must not share one message.
cr_restart_snapshot_file() {
  local rows="" snap=""
  if ! rows="$(cr_restart_snapshot)"; then
    echo "Kein tmux-Server läuft." >&2
    return 1
  fi
  if ! snap="$(mktemp "${CR_RESTART_DIR%/}/claude-remote-restart-XXXXXX" 2>/dev/null)" ||
    { [ -n "$rows" ] && ! { printf '%s\n' "$rows" >"$snap"; } 2>/dev/null; }; then
    [ -z "$snap" ] || rm -f "$snap"
    echo "Snapshot-Datei in ${CR_RESTART_DIR%/} konnte nicht geschrieben werden – es wurde nichts beendet." >&2
    return 2
  fi
  printf '%s\n' "$snap"
}

# cr_restart_same_sessions <snapshot-a> <snapshot-b>: 0 iff both list the same
# (session name, verdict) pairs (columns 1 and 4, order ignored). The verdict counts
# too: a session that turned unrestorable since the summary would otherwise be killed
# without the user having seen that it will not come back. The title (column 10) does
# not: it may change at any time (a regenerated ai-title, a /rename) and is display only.
cr_restart_same_sessions() {
  [ "$(awk -F'\t' '{ print $1 "\t" $4 }' "$1" | LC_ALL=C sort)" = \
    "$(awk -F'\t' '{ print $1 "\t" $4 }' "$2" | LC_ALL=C sort)" ]
}

# cr_restart_confirm <snapshot-file>: the confirmation dialogue. Shows the summary and
# asks [j/N], default No, reading fd 0 like the kill confirm. A "j" is checked against
# a FRESH snapshot, because the user's reading time is a window in which sessions start,
# end or stop being restorable: one started meanwhile would be killed without having
# been named. When a session was added or removed, or its verdict changed, a notice and
# the new summary are shown and the question repeats. On a final "j" CR_RESTART_SNAP
# names the snapshot to execute with (the freshest one; an out-variable, because the
# dialogue itself owns stdout) and 0 is returned. Otherwise no snapshot file is left
# behind: 1 when declined, 2 when the fresh snapshot failed (its cause is printed).
cr_restart_confirm() {
  local snap=$1 fresh="" yn="" rc same
  CR_RESTART_SNAP=""
  cr_restart_summary "$snap"
  while :; do
    read -r -p 'Anchor und Server jetzt neu starten? [j/N] ' yn || yn=""
    case "$yn" in
      j | J | y | Y) ;;
      *)
        rm -f "$snap"
        return 1
        ;;
    esac
    rc=0
    fresh="$(cr_restart_snapshot_file)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      rm -f "$snap"
      return 2
    fi
    same=0
    cr_restart_same_sessions "$snap" "$fresh" && same=1
    rm -f "$snap"
    snap=$fresh
    if [ "$same" -eq 1 ]; then
      # SC2034: read by the caller (bin/claude-remote-pick), not in this file.
      # shellcheck disable=SC2034
      CR_RESTART_SNAP=$snap
      return 0
    fi
    echo "Die Sessions haben sich seit der Übersicht geändert:"
    cr_restart_summary "$snap"
  done
}

# _cr_session_live <session_id>: print the pid of a LIVE process holding that session id
# and succeed, i.e. some $CR_SESSIONS_DIR/<pid>.json names it and <pid> still started at
# the recorded procStart (the pid-reuse guard); return 1 when none does. Keeps a
# restore from running a second `claude --resume` on a transcript that a running
# process already writes. The pid tells the caller WHICH process that is.
_cr_session_live() {
  local f pid rec rsid rest pstart
  for f in "$CR_SESSIONS_DIR"/*.json; do
    [ -f "$f" ] || continue
    pid=${f##*/}
    pid=${pid%.json}
    rec="$(cr_session_record "$pid")" || continue
    rsid=${rec%%$'\t'*}
    [ "$rsid" = "$1" ] || continue
    rest=${rec#*$'\t'}  # kind
    rest=${rest#*$'\t'} # status
    pstart=${rest#*$'\t'}
    if cr_proc_start_matches "$pid" "$pstart"; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

# _cr_pane_direnv <session>: what CR_PANE_SCRIPT left in <session>'s @cr_direnv
# (ok, or the problem); empty until it reports. The trailing colon matters:
# display-message given a bare `=name` reads an empty option and still succeeds,
# while `=name:` is that session's pane.
_cr_pane_direnv() {
  # shellcheck disable=SC2086
  $CR_TMUX display-message -p -t "=$1:" '#{@cr_direnv}' 2>/dev/null
}

# _cr_await_pane_scripts <launched>: wait until every session named in <launched>
# (new_name<TAB>… lines) is gone or has set @cr_direnv, which CR_PANE_SCRIPT does
# right before it execs claude. Bounded by CR_DIRENV_TIMEOUT plus 10 s, since the
# script gives up on direnv at that limit itself; with no limit (0), 10 s. The
# deadline is shared, so waiting for the sessions one after another costs no longer
# than waiting for all of them at once.
_cr_await_pane_scripts() {
  local entry name deadline=$((SECONDS + CR_DIRENV_TIMEOUT + 10))
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    name=${entry%%$'\t'*}
    # shellcheck disable=SC2086
    while [ "$SECONDS" -lt "$deadline" ] && $CR_TMUX has-session -t "=$name" 2>/dev/null &&
      [ -z "$(_cr_pane_direnv "$name")" ]; do
      sleep 0.2
    done
  done <<<"$1"
}

# cr_restore_sessions <snapshot-file>: relaunch every `ok` row, in file order, as
# `claude <kept flags> --resume <session_id>` in the row's start dir under its old label
# (cr_launch appends the new pid). The rows are split by parameter expansion, never
# `read` with a tab IFS: tab is IFS whitespace, so empty columns (reason, last_cwd,
# args, title) would collapse and shift the rest. args is column 9 alone, so the title
# after it never becomes a launch argument; a 9-column snapshot (from before the title
# column) restores the same way, untitled. Every report line names its session by
# who() (CR_RESTART_WHO_AWK). A row whose start dir is gone fails alone.
# A row whose session id a live process already holds is not launched again: counted
# as restored and listed as already active — unless that holder is the row's OWN old
# process (its snapshot pid). That one is still exiting after kill-server, or outlives
# its pty; either way it runs outside any server and is lost once it ends, so the row
# fails (`alter Prozess läuft noch`) and the function returns non-zero (within a
# restart, cr_restart_execute then repeats the snapshot and the retry command; this
# function prints no hint itself). Before EVERY launch
# the anchor session must exist: cr_launch's new-session would otherwise birth a server
# outside the anchor, so once it is gone that row and all remaining ones fail
# (`kein Anchor-Server`). A row whose args carry a restricting flag
# (CR_RESTRICT_FLAGS) fails instead of being launched without it.
# Under a login shell the settle starts once every launched pane has reported from
# its pane script, or at the wait's deadline (_cr_await_pane_scripts): until then the
# pane is a live zsh, so a claude that dies at once behind a slow .envrc would be
# counted as restored. A pane that never reported is listed as such.
# After one $CR_RESTORE_SETTLE sleep every launched session that no longer exists is
# reported as having exited at once, with the LAST non-empty line it left behind
# (Claude's own; a login shell can put .zshrc output before it). Restored sessions that
# last worked somewhere other than their start dir are listed with that dir: they now
# run in the start dir. Restored sessions whose pane script reported a direnv problem
# (@cr_direnv, see CR_PANE_SCRIPT) are listed with it, since no one saw it on screen.
# The `skip` rows are listed with their reason, so every pane of the old server is
# named after the restart too. Report on stdout (German; empty sections omitted); a
# snapshot without rows (a server that held only the anchor) just says there is
# nothing to restore. Returns 0 iff every `ok` row was restored.
cr_restore_sessions() {
  local file=$1 rows line rest who name pid start sid cwd args label new tok mark holder
  local total=0 restored=0 failed="" dropped="" launched="" entry new_name cap
  local kept drop active="" drift="" noanchor=0 lost envrc direnvmsg=""
  # Each ok row with its who() name in front, so the loop names it without a fork.
  rows="$(awk -F'\t' "$CR_RESTART_WHO_AWK"'$4 == "ok" { print who() "\t" $0 }' "$file")" || return 1
  lost="$(awk -F'\t' "$CR_RESTART_WHO_AWK"'$4 != "ok" { print "  - " who() ": " $5 }' "$file")" || return 1
  if [ -z "$rows" ] && [ -z "$lost" ]; then
    echo "Keine Sessions wiederherzustellen."
    return 0
  fi
  if [ -n "$rows" ]; then
    while IFS= read -r line; do
      total=$((total + 1))
      rest=$line
      who=${rest%%$'\t'*}
      rest=${rest#*$'\t'}
      name=${rest%%$'\t'*}
      rest=${rest#*$'\t'}
      pid=${rest%%$'\t'*}
      rest=${rest#*$'\t'}
      start=${rest%%$'\t'*}
      rest=${rest#*$'\t'} # verdict
      rest=${rest#*$'\t'} # reason
      rest=${rest#*$'\t'}
      sid=${rest%%$'\t'*}
      rest=${rest#*$'\t'} # status
      rest=${rest#*$'\t'}
      cwd=${rest%%$'\t'*}
      rest=${rest#*$'\t'}
      args=${rest%%$'\t'*}
      if [ "$noanchor" -eq 1 ]; then
        failed="${failed}  - ${who}: kein Anchor-Server"$'\n'
        continue
      fi
      if holder="$(_cr_session_live "$sid")"; then
        if [ "$holder" = "$pid" ]; then
          failed="${failed}  - ${who}: alter Prozess läuft noch (pid ${pid})"$'\n'
        else
          restored=$((restored + 1))
          active="${active}  - ${who}"$'\n'
        fi
        continue
      fi
      if [ ! -d "$start" ]; then
        failed="${failed}  - ${who}: Startordner fehlt"$'\n'
        continue
      fi
      # shellcheck disable=SC2086
      if ! $CR_TMUX has-session -t "=$CR_ANCHOR" 2>/dev/null; then
        noanchor=1
        failed="${failed}  - ${who}: kein Anchor-Server"$'\n'
        continue
      fi
      # The args column is the space-joined `ps` args: split on spaces, no globbing.
      set -f
      # shellcheck disable=SC2086
      set -- $args
      set +f
      # The snapshot already marks such a row skip; this holds for any file handed in.
      if cr_drops_restriction "$@"; then
        failed="${failed}  - ${who}: einschränkende Startoptionen (nicht sicher übertragbar)"$'\n'
        continue
      fi
      kept=()
      drop=""
      while IFS= read -r tok; do
        mark=${tok%%$'\t'*}
        tok=${tok#*$'\t'}
        if [ "$mark" = "+" ]; then
          kept[${#kept[@]}]=$tok
        else
          drop="${drop:+$drop }$tok"
        fi
      done < <(cr_rewrite_claude_args "$sid" "$@")
      [ -z "$drop" ] || dropped="${dropped}  - ${who}: ${drop}"$'\n'
      label="$(cr_session_label "$name")"
      if new="$(cd "$start" && cr_launch "$label" 0 0 -- "${kept[@]}" </dev/null)" && [ -n "$new" ]; then
        launched="${launched}${new}"$'\t'"${who}"$'\t'"${cwd}"$'\n'
      else
        failed="${failed}  - ${who}: Start fehlgeschlagen"$'\n'
      fi
    done <<<"$rows"
  fi
  if [ -n "$launched" ]; then
    [ "${CR_LOGIN_SHELL:-1}" != 1 ] || _cr_await_pane_scripts "$launched"
    sleep "$CR_RESTORE_SETTLE"
    # new_name<TAB>who<TAB>last_cwd; last_cwd may be empty, so split by hand.
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      new_name=${entry%%$'\t'*}
      entry=${entry#*$'\t'}
      who=${entry%%$'\t'*}
      cwd=${entry#*$'\t'}
      # shellcheck disable=SC2086
      if $CR_TMUX has-session -t "=$new_name" 2>/dev/null; then
        restored=$((restored + 1))
        [ -z "$cwd" ] || drift="${drift}  - ${who} → ${cwd}"$'\n'
        if [ "${CR_LOGIN_SHELL:-1}" = 1 ]; then
          envrc="$(_cr_pane_direnv "$new_name")"
          case "$envrc" in
            ok) ;;
            "") direnvmsg="${direnvmsg}  - ${who}: keine Rückmeldung aus der Session (hängt sie in ~/.zshrc oder der .envrc, oder fehlt dort tmux?)"$'\n' ;;
            *) direnvmsg="${direnvmsg}  - ${who}: ${envrc}"$'\n' ;;
          esac
        fi
      else
        cap="$(cr_drain_exit_output "$new_name" 2>/dev/null | awk 'NF { last = $0 } END { print last }')"
        failed="${failed}  - ${who}: beendete sich sofort${cap:+: $cap}"$'\n'
      fi
    done <<<"$launched"
  fi
  printf 'Wiederhergestellt: %d von %d\n' "$restored" "$total"
  [ -z "$failed" ] || printf 'Fehlgeschlagen:\n%s' "$failed"
  [ -z "$lost" ] || printf 'Nicht wiederherstellbar:\n%s\n' "$lost"
  [ -z "$active" ] || printf 'Bereits aktiv (nicht doppelt gestartet):\n%s' "$active"
  [ -z "$drift" ] || printf 'Arbeiteten zuletzt woanders (laufen jetzt im Startordner):\n%s' "$drift"
  [ -z "$direnvmsg" ] || printf 'direnv meldete beim Start ein Problem:\n%s' "$direnvmsg"
  [ -z "$dropped" ] || printf 'Weggelassene Argumente:\n%s' "$dropped"
  [ "$restored" -eq "$total" ]
}

# _cr_restart_hint <snapshot-file>: where the snapshot is and how to finish by hand.
_cr_restart_hint() {
  echo "Snapshot: $1"
  echo "Wiederherstellen: claude-remote-pick --restore $1"
}

# _cr_restart_report_file <snapshot-file>: create `<snapshot-file>.report` next to the
# snapshot, private (0600) like it, and print its path; return 1 when that fails. Over
# SSH the snapshot lives in the shared /tmp, and its name is visible there while the
# user reads the summary, so a file already at that path is never reused or followed:
# noclobber refuses an existing one, and the result must be our own plain file.
_cr_restart_report_file() {
  local r="$1.report"
  if [ -e "$r" ] || [ -L "$r" ]; then
    return 1
  fi
  (
    set -C
    umask 077
    : >"$r"
  ) 2>/dev/null || return 1
  if [ ! -f "$r" ] || [ -L "$r" ] || [ ! -O "$r" ]; then
    return 1
  fi
  printf '%s\n' "$r"
}

# _cr_restart_note <report-file|""> <text>: print <text> and append it to the report
# file when there is one. A failed write there is ignored: the screen copy stands.
_cr_restart_note() {
  printf '%s\n' "$2"
  [ -z "$1" ] || printf '%s\n' "$2" 2>/dev/null >>"$1" || true
}

# cr_restart_execute <snapshot-file>: stop the anchor supervisor(s) and the server, let
# the LaunchAgent birth a fresh anchor (it is the only thing that may birth the server),
# then restore the sessions from the snapshot. The snapshot path, the retry command and
# the report file are printed BEFORE anything is stopped, so even a run that dies
# half-way has named its way back; each failure repeats them (or the retry) at the end.
# It refuses, with nothing stopped, without a usable snapshot or a loaded agent. INT
# and HUP are ignored for the whole destructive phase — Ctrl-C, or the iPad's SSH
# channel dropping while Blink is in the background, would otherwise kill the picker
# between kill-server and the restore — and the caller's traps are restored afterwards.
# Restored panes are forked by the tmux server, which resets its children's signals, so
# the ignore does not leak into the sessions. Returns 0 only when everything came back.
cr_restart_execute() {
  local rc=0 int_trap hup_trap
  int_trap="$(trap -p INT)"
  hup_trap="$(trap -p HUP)"
  trap '' INT HUP
  _cr_restart_run "$1" || rc=$?
  trap - INT HUP
  eval "$int_trap"
  eval "$hup_trap"
  return "$rc"
}

# _cr_restart_agent_loaded: 0 iff launchctl knows the anchor LaunchAgent. Otherwise it
# prints the German refusal, with launchctl's own last line, and returns 1.
_cr_restart_agent_loaded() {
  local out
  out="$("$CR_LAUNCHCTL" print "gui/$(id -u)/$CR_ANCHOR_LABEL" 2>&1)" && return 0
  out="$(printf '%s\n' "$out" | awk 'NF { last = $0 } END { print last }')"
  echo "LaunchAgent $CR_ANCHOR_LABEL nicht gefunden – ohne ihn käme kein neuer Server hoch. Neustart abgebrochen, es wurde nichts beendet."
  [ -z "$out" ] || echo "launchctl: $out"
  return 1
}

# _cr_server_only_anchor: 0 iff the server answers and holds no session but $CR_ANCHOR.
_cr_server_only_anchor() {
  local names
  # shellcheck disable=SC2086
  names="$($CR_TMUX list-sessions -F '#{session_name}' 2>/dev/null)" || return 1
  printf '%s\n' "$names" | awk -v a="$CR_ANCHOR" 'length($0) && $0 != a { other = 1 } END { exit other }'
}

# _cr_restart_run <snapshot-file>: the phases of cr_restart_execute, one German progress
# line each. Before anything is stopped it checks two preconditions and refuses without
# them: a snapshot file that exists and is readable (it is the only way back), and a
# loaded anchor LaunchAgent (it is the only thing that may birth the new server);
# without either the restart would end every session and bring nothing back. An EMPTY
# snapshot is legitimate only for a server that holds nothing but the anchor, which a
# fresh query must confirm; otherwise it does not cover the sessions the stop would end
# (one started after the snapshot, or a file the picker did not write) and is refused. That
# restart still matters: only replacing the anchor instance cures a stale one, while a
# bare kill-server would let the old supervisor re-birth the server in its context.
# After the stop it waits (up to 10 s) for the `ok` rows' old pane processes to exit:
# one still exiting would look like a live holder of its session to the restore (which
# then fails that row rather than counting it).
# The outcome also goes to `<snapshot>.report`, named before the stop: the restore
# report, or why the run ended before it. A dropped SSH channel takes the screen with
# it, while the restore runs on (HUP is ignored); the file is what is left to read.
_cr_restart_run() {
  local file=$1 old pids n rc=0 report out
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "Snapshot-Datei $file fehlt oder ist nicht lesbar – es wurde nichts beendet."
    return 1
  fi
  if [ ! -s "$file" ] && ! _cr_server_only_anchor; then
    echo "Snapshot-Datei $file ist leer, der Server hat aber Sessions – es wurde nichts beendet."
    return 1
  fi
  _cr_restart_agent_loaded || return 1
  _cr_restart_hint "$file"
  if report="$(_cr_restart_report_file "$file")"; then
    echo "Bericht: $report"
  else
    report=""
    echo "Bericht-Datei $file.report ließ sich nicht anlegen – der Bericht erscheint nur hier."
  fi
  old="$(cr_server_pid)" || old=""
  pids="$(awk -F'\t' '$4 == "ok" { print $2 }' "$file")"
  n="$(awk -F'\t' '$4 == "ok" { n++ } END { print n + 0 }' "$file")"
  echo "Beende Anchor und Server …"
  if ! cr_stop_anchor_and_server; then
    _cr_restart_note "$report" "Server ließ sich nicht beenden."
    _cr_restart_hint "$file"
    return 1
  fi
  # shellcheck disable=SC2086
  if ! _cr_wait_gone 0 $pids; then
    echo "Warte auf das Ende der alten Claude-Prozesse (bis zu 10 s) …"
    # shellcheck disable=SC2086
    _cr_wait_gone 10 $pids || true
  fi
  echo "Warte auf neuen Server (bis zu ${CR_ANCHOR_WAIT} s) …"
  if ! cr_start_anchor "$old" "$report"; then
    _cr_restart_note "$report" "Anchor/Server kam nicht hoch. Wiederherstellen, sobald er läuft: claude-remote-pick --restore $file"
    return 1
  fi
  [ "$n" -eq 0 ] || echo "Stelle $n Sessions wieder her …"
  # The restore prints its report only at the end, so collecting it costs no progress.
  out="$(cr_restore_sessions "$file")" || rc=$?
  _cr_restart_note "$report" "$out"
  [ "$rc" -eq 0 ] || _cr_restart_hint "$file"
  return "$rc"
}

# cr_restart_inside_server: succeeds iff $TMUX names the socket of the server that
# $CR_TMUX reaches with TMUX removed. That is the server a restart acts on, because the
# picker runs the whole restart path with TMUX unset; restarting from inside it would
# kill the restarter itself. Asking with $TMUX in place would be wrong: a tmux without
# -L/-S takes its socket from $TMUX, so it would always answer with the caller's own
# server.
cr_restart_inside_server() {
  local sock
  [ -n "${TMUX:-}" ] || return 1
  # shellcheck disable=SC2086
  sock="$(env -u TMUX $CR_TMUX display-message -p '#{socket_path}' 2>/dev/null)" || return 1
  [ -n "$sock" ] && [ "${TMUX%%,*}" = "$sock" ]
}

# cr_reverse_lines <file>: emit the file's lines last-to-first.
# Prefers GNU tac, falls back to macOS' BSD `tail -r` addressed by ABSOLUTE path —
# a bare `tail` here may well be GNU coreutils from Homebrew, which has no -r.
# Branch on availability rather than writing `tac "$f" || /usr/bin/tail -r "$f"`: our
# reader stops early, which kills the producer with SIGPIPE (exit 141), and an
# exit-status fallback reads that as failure and spawns the second tool on every large
# read. (It does not duplicate output — the consumer has closed the pipe by then, so
# the late producer dies of SIGPIPE itself; the cost is the wasted spawn.)
cr_reverse_lines() {
  if command -v "$CR_TAC" >/dev/null 2>&1; then
    "$CR_TAC" "$1"
  else
    /usr/bin/tail -r "$1"
  fi
}

# cr_session_title <transcript.jsonl> -> the session's display title ("" if none).
# Claude Code records two kinds, each as its own JSONL line type: `custom-title` (set
# by /rename) and `ai-title` (one it generates itself). /rename wins where both are
# present — a name the user chose beats an inferred one. Reading them in a single pass
# matters: a lookup per kind would make every session without a /rename (99.8% of the
# corpus) scan the transcript twice, since a miss cannot exit early.
#
# The file is append-only and both kinds are re-appended per turn, so the LAST of each
# is the live one — hence reading backwards and stopping early, which keeps a hit O(1)
# rather than O(file size); transcripts reach hundreds of MB. A miss still scans the
# whole file, because grep can only stop on a match.
#
# Precedence is decided by .type, NOT by position — the least obvious part of this,
# and the one a simplifying edit would break while every test still passed. After a
# rename Claude Code keeps appending both kinds as per-turn pairs ending on the
# ai-title, so the generated title is the *later* line in 98 of the 112 local
# transcripts carrying both. Taking "the last title line" would therefore show the
# inferred name for a renamed session in the large majority of cases.
#
# That same pairing is why -m4 suffices for one pass: exactly one title line follows
# the last custom-title (measured 2026-08-23 over all 226 local transcripts holding
# one — deepest position 2 counting back), leaving two spare slots. One absorbs a torn
# last line: a transcript being appended to right now ends mid-line, and both reversers
# treat the final newline as a *separator*, so that fragment is glued onto the front of
# the previous line and can render a title candidate unparsable. Losing one candidate
# is harmless because each kind repeats (custom-title median 28 entries, ai-title 6),
# so an earlier one within the window carries the same value. The bound is empirical
# and the format is not ours: if Claude Code ever emits more title lines per turn, a
# renamed session silently shows its generated title. tests/title.bats pins it.
#
# jq must tolerate garbage per line and per value:
#   - -R with fromjson? skips unparsable lines; plain jq aborts the whole stream on the
#     first parse error, which would discard the good candidates behind a torn line.
#   - select(.type == …) rejects a line that merely *mentions* the marker inside a
#     nested object.
#   - select(type == "string" and . != "") skips a title whose value is not usable.
#     Without it a numeric or object value reaches gsub, which is a *runtime* error and
#     kills the entire program — taking the other kind's fallback down with it, and
#     indistinguishable from "no title set" because stderr is discarded.
# grep stays a cheap byte-level prefilter matching the compact serialisation (a spaced
# variant would silently miss). gsub flattens all control characters, so neither a tab
# can tear the TSV pipeline apart nor an ESC confuse cr_format_rows' column maths.
cr_session_title() {
  local f="$1"
  [ -n "$f" ] && [ -f "$f" ] || return 0
  cr_reverse_lines "$f" 2>/dev/null |
    grep -m4 -E '"type":"(custom|ai)-title"' 2>/dev/null |
    jq -Rrs 'def pick($t; f): [ .[] | select(.type == $t) | f | select(type == "string" and . != "") ] | first;
             [ split("\n")[] | fromjson? | select(type == "object") ]
             | ( pick("custom-title"; .customTitle) // pick("ai-title"; .aiTitle) // empty )
             | gsub("[[:cntrl:]]"; " ")' 2>/dev/null
  return 0
}

# cr_session_file <session_id> -> path of that session's transcript ("" if not found).
# Claude Code stores it as $CR_PROJECTS_DIR/<encoded-cwd>/<session-id>.jsonl. The
# encoding itself is trivial (/ and . become -), but the cwd it encodes is the one the
# session STARTED in, while abtop reports the live cwd — a session that moved into a
# worktree keeps its transcript under the parent repo's dir. So probe the project dirs
# rather than derive a path: one stat per dir, against seconds for a recursive find
# over the ~10^5 transcripts these directories accumulate.
#
# Renamed or copied project dirs leave the same session id in several places (~1200
# such duplicates locally), so take the most recently written one rather than whatever
# the glob happens to yield first — an alphabetically earlier `…-sage/` copy would
# otherwise shadow the live `…-sagekit/` transcript and display a stale title.
cr_session_file() {
  local sid="$1" d f t newest="" newest_t=0
  [ -n "$sid" ] || return 0
  for d in "${CR_PROJECTS_DIR}"/*/; do
    f="${d}${sid}.jsonl"
    [ -f "$f" ] || continue
    t="$(command stat -c %Y "$f" 2>/dev/null || command stat -f %m "$f" 2>/dev/null)" || continue
    if [ -z "$newest" ] || [ "$t" -gt "$newest_t" ]; then
      newest="$f"
      newest_t="$t"
    fi
  done
  [ -n "$newest" ] && printf '%s\n' "$newest"
  return 0
}

# cr_resolve_titles [<pane-title-map-file>]
# stdin = cr_join output; stdout = the same rows with each S row extended by a
# trailing session-title column ("" when no tier answers). N rows pass through
# untouched.
#   Tier 1: the pane's own title, looked up by pid in <pane-title-map-file> — the
#     "<pane_pid>\t<raw title>" stream cr_pane_titles emits — and judged by
#     cr_pane_title_clean. Keyed by the pane, so it cannot name a foreign session,
#     and free. Omit the argument to skip the tier (the pre-2026-09 behaviour).
#   Tier 2: the session's own transcript (cr_session_file + cr_session_title) — the
#     user's /rename, else Claude Code's generated title. This is the only part of
#     the display pipeline that touches the filesystem, which is why it sits behind
#     tier 1 and after cr_join: only attachable sessions that the pane cannot answer
#     for cost a lookup. It is keyed by abtop's session_id, which is a guess (see
#     "Why the pane title comes first" in CLAUDE.md) — so this tier, not tier 1, is
#     where a wrong name comes from.
cr_resolve_titles() {
  local titlefile="${1:-}" map="" raw line sid title
  # Tier 1's whole map is read once, not re-scanned per row, and is wrapped in
  # newlines so cr_pane_title_for_row can anchor its lookup on "\n<pid>\t".
  # Gate on arity, not emptiness: `cr_resolve_titles "$(build_map)"` whose
  # substitution failed passes "", and a `-n` test would read that as the
  # supported no-argument form and drop tier 1 without a word — the same hole
  # cr_ensure_line refuses an empty line for. With `$#` the empty string reaches
  # the -r branch below and warns.
  if [ "$#" -gt 0 ]; then
    # `-r` and `! -d`, never `-f`: the caller passes a process substitution, and
    # /dev/fd/N is a pipe — `-f` is false for it and would disable the whole tier
    # in production while every test using a real file still passed. `-r` alone is
    # not enough either: a directory is readable, and `$(<dir)` then fails without
    # a byte on stderr. Verified on bash 3.2 and 5.3.
    if [ -r "$titlefile" ] && [ ! -d "$titlefile" ]; then
      raw="$(<"$titlefile")"
      # Only wrap when there is content: $'\n\n' is non-empty, so wrapping first
      # would make the "do we have a map?" test below always true.
      [ -n "$raw" ] && map=$'\n'"$raw"$'\n'
    else
      # A path that was passed but cannot be used is a caller error, not the
      # supported no-argument form. Silence here would leave the fix inactive with
      # the original bug as its only symptom — in a version announced as fixing it.
      printf 'claude-remote: Pane-Titel nicht lesbar (%s) — Titel kommen aus den Transkripten\n' \
        "$titlefile" >&2
    fi
  fi
  while IFS= read -r line; do
    case "$line" in
      S$'\t'*)
        cr_pane_title_for_row "$map" "$line"
        title="$CR_PANE_TITLE"
        # Tier 2, reached whenever the pane carries no usable title: the session's
        # own transcript. Costs a filesystem probe per row, so it stays behind the
        # tier that answers for free.
        if [ -z "$title" ]; then
          # session_id is the row's last field (pinned by a test on cr_abtop_sessions),
          # so strip the leading fields instead of forking cut per row. NOT `IFS=$'\t' read`:
          # tab is POSIX IFS whitespace, so bash collapses runs and drops empty fields — a
          # session without a project_name would silently shift every later column.
          sid="${line##*$'\t'}"
          title="$(cr_session_title "$(cr_session_file "$sid")")"
        fi
        printf '%s\t%s\n' "$line" "$title"
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
}

# cr_abtop_sessions -> TSV rows for claude sessions:
#   pid \t project_name \t status \t context_percent \t model \t current_task \t session_id
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
        (.current_task // ""), (.session_id // "") ]
    | @tsv'
}

# cr_pane_map -> "pane_pid<TAB>session_name" for every pane across all sessions.
# pane_pid is the process tmux exec'd in the pane == the claude pid (we launch
# claude directly). Empty output (status 0) when no server/sessions exist.
cr_pane_map() {
  # shellcheck disable=SC2086
  $CR_TMUX list-panes -a -F '#{pane_pid}'$'\t''#{session_name}' 2>/dev/null || true
}

# cr_pane_titles -> "<pane_pid>\t<raw pane title>" per pane, on stdout.
# The title Claude Code itself pushed into the terminal — the only title source
# that cannot point at a *different* session: abtop's session_id is a guess that
# picks the most recently written transcript in the project directory, which is
# the wrong one whenever a second Claude session ran in the same directory (a
# cross-session message is enough). Raw here; cr_pane_title_clean judges it.
# `-a` is load-bearing: without it tmux reports only the *current* session's panes
# and every other session silently loses tier 1 (pinned by a test).
# The swallowed error is a known blind spot, but a narrow one — measured, not
# assumed: a server that is simply dead fails cr_pane_map too, every row becomes
# an N row, and the menu comes up empty with its footnote. That is loud. The one
# harmful shape is a failure here while cr_pane_map succeeds (a transient error
# between the two calls): the rows render, tier 2 answers all of them, and the
# picker looks healthy while showing foreign names. Left as is — a TSV stream has
# no honest third state and the picker must still render — but that is the case
# to suspect if names go wrong again.
cr_pane_titles() {
  # shellcheck disable=SC2086
  $CR_TMUX list-panes -a -F '#{pane_pid}'$'\t''#{pane_title}' 2>/dev/null || true
}

# cr_pane_title_clean <raw pane title> -> sets CR_PANE_TITLE ("" when unusable).
# Two independent gates, because they fail independently:
#   - the prefix answers "did Claude Code set this title?" — a pane still showing
#     the terminal default (the hostname, e.g. before the trust prompt is
#     answered) has none;
#   - the placeholder answers "is it a real title?" — Claude Code shows it until
#     a /rename or a generated title exists, which is the common case.
# Both answers are "" so the caller falls through to its next tier — which is the
# transcript, NOT the project name: an empty answer here is not a safe default,
# it is a return to the source this tier was added to bypass.
# Out-variable rather than stdout, against the file's usual convention: this runs
# once per row on every redraw, and `$(…)` would fork per row — measured ~0.65 ms,
# some fifteen times the whole fork-free tier (~41 µs/row) and forty times the pid
# extraction it would be guarding. It judges a string rather than producing a
# stream, so it is not a pipeline stage; bash's own `read`/`REPLY` is the precedent.
cr_pane_title_clean() {
  local raw="${1:-}" title
  CR_PANE_TITLE=""
  case "$raw" in
    "$CR_TITLE_PREFIX"*) title="${raw#"$CR_TITLE_PREFIX"}" ;;
    *) return 0 ;;
  esac
  [ -z "$title" ] && return 0
  [ "$title" = "$CR_TITLE_PLACEHOLDER" ] && return 0
  CR_PANE_TITLE="$title"
}

# cr_pane_title_for_row <map> <S row> -> sets CR_PANE_TITLE ("" when none applies).
# <map> is cr_pane_titles' output wrapped in newlines (see cr_resolve_titles).
# Tier 1 of the title chain, split out so the loop body below stays readable.
cr_pane_title_for_row() {
  local map="$1" line="$2" pid hit
  CR_PANE_TITLE=""
  [ -n "$map" ] || return 0
  # The row is  S \t <session> \t <pid> \t … — narrow down to field 3. NOT
  # `IFS=$'\t' read`: tab is POSIX IFS whitespace, so bash collapses runs and
  # drops empty fields, which would shift every column after an empty one.
  pid="${line#*$'\t'}"
  pid="${pid#*$'\t'}"
  pid="${pid%%$'\t'*}"
  # Anchored on "\n<pid>\t" so a pid that is merely a prefix of another (424 vs
  # 4242) cannot match, and neither can a pid-shaped substring of a title.
  hit="${map#*$'\n'"$pid"$'\t'}"
  [ "$hit" = "$map" ] && return 0 # unchanged ⇒ anchor absent ⇒ no pane for this pid
  cr_pane_title_clean "${hit%%$'\n'*}"
}

# cr_format_rows: stdin = cr_join output; stdout = one display line per S row,
# TAB-separated as: <session>\t<human-text>. The session (col 1) is the attach key.
# Display: <glyph> <name #pid> <ctx%> <model> <task>. The name follows a preference
# chain, most specific first: the resolved session title (col 10 — the pane's own
# title if it has a usable one, else the transcript's; see cr_resolve_titles, which
# owns the column and its tiers), else abtop's project (col 4) — a *live* value, so
# a session running in a git worktree shows the worktree rather than the directory it
# happened to be launched from — else the tmux session name with its -<pid> suffix
# stripped (which is also what the abtop-less path in cr_menu_lines feeds in). Note
# that this makes a -l label invisible here — the label lives on in the session name,
# which stays the attach key in column 1. When CR_COLOR=1
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
    function statuscolor(s) {
      if (s == "Executing" || s == "Thinking") return "\033[32m"
      if (s == "Waiting") return "\033[33m"
      return ""
    }
    function ctxcolor(c) {
      if (c < 50) return "\033[32m"
      if (c < 80) return "\033[33m"
      return "\033[31m"
    }
    # This awk is BWK awk on macOS, whose length()/substr() count BYTES while its
    # regex engine is UTF-8 aware. Padding and truncation must go by rendered
    # columns, so measure with gsub(/./) — which counts characters — and let
    # RLENGTH hand substr the byte offset it needs. Getting this wrong is not
    # cosmetic: it both misaligns rows (the 3-byte "…" alone shifts one by two)
    # and can cut mid-codepoint, emitting invalid UTF-8.
    function vislen(s,   t) { t = s; return gsub(/./, "&", t) }
    function vistrunc(s, k) {
      if (vislen(s) <= k) return s
      match(s, "^.{" k - 1 "}")
      return substr(s, 1, RLENGTH) "…"
    }
    $1 == "S" {
      # $2 session, $3 pid, $4 project, $5 status, $6 ctx, $7 model, $8 task,
      # $9 session_id, $10 resolved session title (pane title, else transcript —
      #    see cr_resolve_titles). tmux rejects control characters in a pane title,
      #    so col 10 is safe for the column maths below either way.
      n++
      s_session[n] = $2; s_pid[n] = $3; s_status[n] = $5; s_ctx[n] = $6 + 0
      s_model[n] = shortmodel($7)
      s_task[n] = vistrunc($8, 24)
      name = $10                                     # resolved session title, if any
      if (name == "") name = $4                      # else abtop project
      if (name == "") { name = $2; sub("-" $3 "$", "", name) }   # else tmux name
      s_name[n] = vistrunc(name, 38)
      w = vislen(s_name[n]) + 2 + length($3)   # "<name> #<pid>", pid is ASCII
      if (w > width) width = w
    }
    # Rows are buffered rather than streamed so the name column can be sized to the
    # widest one actually present. A fixed width cannot work now that the name is a
    # session title or a worktree branch ("drill-in-row-model"): it overflows and
    # shoves that row own ctx% out of the other rows flush, while short names waste
    # the rest. Both branches pad explicitly (rather than the plain one using %-*s),
    # because %*s would count ANSI escape bytes in the colour branch — that is what
    # lets a single printf serve both.
    END {
      for (i = 1; i <= n; i++) {
        ctx = s_ctx[i]
        pad = sprintf("%*s", width - (vislen(s_name[i]) + 2 + length(s_pid[i])), "")
        if (color == "1") {
          g = statuscolor(s_status[i]) glyph(s_status[i]) "\033[0m"
          label = s_name[i] " \033[2m#" s_pid[i] "\033[0m" pad
          ctx_str = ctxcolor(ctx) sprintf("%3d%%", ctx) "\033[0m"
        } else {
          g = glyph(s_status[i])
          label = s_name[i] " #" s_pid[i] pad
          ctx_str = sprintf("%3d%%", ctx)
        }
        printf "%s\t%s %s %s %-6s %s\n", s_session[i], g, label, ctx_str, s_model[i], s_task[i]
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
    joined="$(printf '%s\n' "$abtop_rows" | cr_join <(cr_pane_map) | cr_resolve_titles <(cr_pane_titles))"
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
# stdin: abtop TSV rows (pid \t project \t status \t ctx \t model \t task \t session_id)
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
# Refuses an empty <line>: a caller whose command substitution failed would
# otherwise append a blank line on every run, unnoticed and without bound (a
# failing `$(…)` in argument position does not trip the caller's `set -e`).
cr_ensure_line() {
  local file="$1" line="$2"
  if [ -z "$line" ]; then
    echo "cr_ensure_line: refusing to append an empty line to ${file}" >&2
    return 1
  fi
  [ -f "$file" ] && grep -qF -- "$line" "$file" && return 0
  if [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ]; then
    printf '\n' >>"$file"
  fi
  printf '%s\n' "$line" >>"$file"
}

# --- Ctrl+Z containment -------------------------------------------------------
# Claude runs as the pane process itself (pane_pid == claude pid — the join
# invariant), so there is NO shell between it and tmux, and the pane's process
# group is orphaned: its parent, the tmux server, lives in another session.
#
# Observed 2026-08-06: after a stray Ctrl+Z the session is unusable while the
# process is still alive and NOT stopped. Keystrokes are echoed by the tty driver
# but never reach the TUI, and `fg` has no shell to be typed into — recovery is
# `claude-remote -- --resume`, nothing else. The mechanism is most likely the
# suspend handshake failing in an orphaned process group (a stop signal to such a
# group is discarded, so no SIGCONT follows and nothing restores raw mode); treat
# the observation as the fact and that as the best available explanation.
#
# Rebinding inside Claude does not help: A/B-tested against Claude Code 2.1.223
# on an isolated tmux socket (2026-08-06), a keybindings.json entry for ctrl+z
# never fires — 0x1A is consumed before the configurable key map is consulted.
# So tmux, one layer below, has to eat the key before it reaches the pane PTY.

# cr_tmux_claude_pane_cond -> the tmux format that is true in a pane whose
# foreground process image is named like Claude. It rides on the same property
# the abtop join needs: cr_launch's inner `exec` leaves `claude` as the pane
# process, so pane_current_command is `claude` — had we wrapped it in a shell,
# this would read `zsh` and the condition would be blind.
#
# Two limits follow from tmux resolving that name from the process *image*
# (symlinks are followed, argv[0] ignored — see tests/ctrl_z.bats):
#   - a `#!` wrapper named claude reports its interpreter, so an npm/node or
#     shim-based install is NOT covered and Ctrl+Z stays lethal there;
#   - the glob is deliberately loose (a renamed or suffixed binary still counts),
#     so any command containing "claude" loses Ctrl+Z as well.
# It also keys on the command, not on how the pane was launched: where you did
# start claude from a shell, Ctrl+Z/fg would have worked and this takes it away.
cr_tmux_claude_pane_cond() {
  printf '%s\n' '#{m:*claude*,#{pane_current_command}}'
}

# cr_tmux_ctrl_z_line -> the ~/.tmux.conf line installing that key binding.
# Emitted as ONE line because that is the unit cr_ensure_line both appends and
# checks for: `grep -F` reads a newline in the pattern as a pattern separator, so
# a multi-line form could never be checked as a whole. The conditional keeps
# Ctrl+Z as ordinary job control in every non-Claude pane; `display-message -d`
# needs tmux >= 3.2.
cr_tmux_ctrl_z_line() {
  printf '%s\n' "bind -n C-z if -F '$(cr_tmux_claude_pane_cond)' 'display-message -d 1500 \"Ctrl+Z ist in Claude Code deaktiviert (Detach: Prefix d)\"' 'send-keys C-z'"
}

# cr_tmux_ctrl_z_state <conf> -> ours | foreign | absent
# Decides what install.sh may do with a tmux config, by looking only at *active*
# root-table C-z bindings — a commented-out line, an `unbind -n C-z` (which
# contains "bind -n C-z" literally) or the string inside some option value are
# none of them a binding, and a plain substring check read all three as "already
# installed", silently skipping the install. `bind-key` is matched as well as
# `bind`: it is the spelling tmux itself prints and the one install.sh uses for
# the status toggle, so a user's own binding is at least as likely to be written
# that way — and going unnoticed there means appending ours below it, which
# silently wins (tmux applies the file in order, last binding for a key stands).
# `ours` is decided by the presence of cr_tmux_claude_pane_cond, which also
# recognises the hand-written multi-line form of the very same binding.
cr_tmux_ctrl_z_state() {
  local file="$1" binds
  [ -f "$file" ] || {
    printf 'absent\n'
    return 0
  }
  binds="$(grep -E '^[[:space:]]*bind(-key)?[[:space:]].*(-n|-T[[:space:]]+root)[[:space:]]+C-z([[:space:]]|$)' "$file")" || {
    printf 'absent\n'
    return 0
  }
  if printf '%s\n' "$binds" | grep -qF -- "$(cr_tmux_claude_pane_cond)"; then
    printf 'ours\n'
  else
    printf 'foreign\n'
  fi
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
# Among the *added* dirs the user-local bins come first, so a binary pinned into
# ~/.local/bin (e.g. a specific native claude) wins over a Homebrew copy of the same
# tool — matching the user's interactive PATH and keeping the launch path agnostic
# (a tmux pane inherits the launching client's PATH, so an unstripped Mac shell and a
# stripped SSH picker must resolve `claude` to the same pinned binary).
cr_augment_path() {
  local d
  for d in "$HOME/.local/bin" "$HOME/local/bin" /opt/homebrew/bin /usr/local/bin; do
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
# (re-fetch the session list), __KILL__<TAB>session (typing k<n> kills entry n),
# __RESTART__ (typing s), or __NONE__ (invalid input -> caller redraws). Menu lines are "session<TAB>display".
cr_pick_numbered() {
  local footnote="$1"
  shift
  local menu=("$@") i=1 line choice newidx kidx
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
    printf " k<n>) Session beenden\n"
    printf "   s) Server neu starten (alle Sessions)\n"
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
    s | S) echo "__RESTART__" ;;
    "$newidx") echo "__NEW__" ;;
    [kK][0-9]*)
      # k<n>: kill entry n. Emit a compound __KILL__<TAB>session token so the loop
      # learns both the intent AND the target in one read (the bare tokens above
      # carry no target). Out-of-range -> __NONE__ (redraw), like a bad number.
      kidx="${choice#[kK]}"
      if [ "$kidx" -ge 1 ] 2>/dev/null && [ "$kidx" -le "${#menu[@]}" ]; then
        printf '__KILL__\t%s\n' "${menu[$((kidx - 1))]%%$'\t'*}"
      else
        echo "__NONE__"
      fi
      ;;
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
# list), __KILL__<TAB>session (Ctrl-X on the highlighted session), __RESTART__
# (Ctrl-T; ctrl-s is avoided because terminals use it as XOFF), or __QUIT__
# (ESC/cancel). fzf shows only the display column (field 2..); the session key is
# field 1. With --expect=ctrl-r,ctrl-x,ctrl-t, fzf prints the pressed key on line 1 (empty
# for a plain Enter) and the selected line on line 2 — so Ctrl-X carries the
# highlighted target along, exactly like Enter does for attach.
cr_pick_fzf() {
  local footnote="$1"
  shift
  local header="claude-remote — Enter: attach · Ctrl-X: beenden · Ctrl-R: aktualisieren · Ctrl-T: Server neu starten · ESC: beenden"
  [ -n "$footnote" ] && header="${header}"$'\n'"${footnote}"
  local lines=()
  [ "$#" -gt 0 ] && lines=("$@")
  lines+=("__NEW__"$'\t'"＋ neue Session")
  local out key chosen sess
  out="$(printf '%s\n' "${lines[@]}" | fzf --ansi --delimiter=$'\t' --with-nth='2..' \
    --prompt='Session> ' --header="$header" --reverse --no-multi --expect=ctrl-r,ctrl-x,ctrl-t)" || true
  {
    IFS= read -r key
    IFS= read -r chosen
  } <<<"$out"
  if [ "$key" = "ctrl-r" ]; then
    echo "__RELOAD__"
  elif [ "$key" = "ctrl-t" ]; then
    echo "__RESTART__"
  elif [ "$key" = "ctrl-x" ]; then
    # Kill the highlighted session. Guard: ignore when nothing real is highlighted
    # (empty selection, or the synthetic __NEW__ line when the list is empty) so
    # Ctrl-X never emits a kill for a non-session entry — redraw instead.
    sess="${chosen%%$'\t'*}"
    case "$sess" in
      "" | __*) echo "__NONE__" ;;
      *) printf '__KILL__\t%s\n' "$sess" ;;
    esac
  elif [ -z "$chosen" ]; then
    echo "__QUIT__"
  else
    printf '%s\n' "${chosen%%$'\t'*}"
  fi
}
