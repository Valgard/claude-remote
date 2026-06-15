# claude-remote Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build two stateless shell scripts that make interactive Claude Code sessions remotely attachable from another device (iPad/Blink) over the local network, via tmux + sshd + abtop.

**Architecture:** `claude-remote` launches `claude` directly inside a named, detached tmux session (named `<label-or-cwd-basename>-<claude-pid>`, where the pid equals the tmux pane_pid) and attaches. `claude-remote-pick` lists running sessions by joining `abtop --json` metadata with tmux panes on the Claude PID, renders a picker, and attaches in a loop. No long-running own process — tmux/sshd/abtop do the heavy lifting.

**Tech Stack:** POSIX-ish Bash, tmux, abtop (`--json`), jq, fzf (optional), bats (tests), shellcheck + shfmt (lint/format).

---

## Toolchain reality (verified 2026-06-15)

Present: `tmux`, `jq`, `fzf`, `abtop` (`~/local/bin/abtop`), `shellcheck`, real `claude` binary at `~/.local/bin/claude` (the interactive `claude` is a zsh **function** wrapping it).
Missing — install in Task 0: `bats`, `shfmt`.

`claude` zsh function (from `~/.zsh_aliases`) cds to git root and adds `--allow-dangerously-skip-permissions --brief`. `claude-remote` stays generic; the user's function will call it.

## Testability seams (env overrides honored by all scripts)

- `CR_TMUX` — tmux command (default `tmux`). Tests set `CR_TMUX="tmux -L cr_test_<unique>"` for an **isolated** tmux server that never touches real sessions.
- `CR_ABTOP` — abtop command (default `abtop`). Tests point it at a fixture-printing stub.

`claude` itself is **not** path-resolved by the wrapper: it is passed straight to tmux's `--` exec form, which execvp's it from `PATH` without a shell — so the interactive `claude` zsh function is bypassed automatically (same effect `command claude` has in a shell). Tests prepend a stub named `claude` to `PATH`.

## File Structure

```
claude-remote/
  bin/
    claude-remote            # launch wrapper (executable)
    claude-remote-pick       # session picker (executable)
  lib/
    claude-remote-lib.sh     # shared pure-ish helpers, sourced by both bins + tests
  install.sh                 # symlink bins into ~/.local/bin, print setup snippets
  Makefile                   # test / lint / fmt targets
  README.md
  .shellcheckrc
  tests/
    helpers.bash             # bats setup/teardown (isolated tmux, stubs)
    fixtures/
      fake-claude            # stub "claude": stays alive so the pane persists
      abtop-sample.json      # real-shape abtop --json snapshot
      abtop-stub             # prints a chosen fixture file to stdout
    name.bats
    launch.bats
    abtop_parse.bats
    pane_map.bats
    join.bats
    render.bats
    fallback.bats
```

**Responsibility split:** `lib/claude-remote-lib.sh` holds every function with logic worth testing (naming, abtop parsing, tmux pane mapping, join, rendering). The two `bin/` scripts are thin entry points: parse args, source the lib, orchestrate. This keeps the testable surface in one focused file.

---

## Task 0: Scaffolding, dev tooling, test harness

**Files:**
- Create: `Makefile`, `.shellcheckrc`, `tests/helpers.bash`, `tests/fixtures/fake-claude`, `lib/claude-remote-lib.sh` (empty stub with shebang + guard)

- [ ] **Step 1: Install missing dev tools**

Run:
```bash
brew install bats-core shfmt
```
Expected: both install; `bats --version` and `shfmt --version` succeed.

- [ ] **Step 2: Create the `fake-claude` stub**

`tests/fixtures/fake-claude`:
```bash
#!/usr/bin/env bash
# Test stub standing in for the real claude binary.
# Stays alive so the tmux pane it runs in does not exit immediately.
# Echoes its args to a file so tests can assert passthrough.
if [ -n "${FAKE_CLAUDE_ARGV_FILE:-}" ]; then
  printf '%s\n' "$*" > "$FAKE_CLAUDE_ARGV_FILE"
fi
exec sleep 600
```
Then:
```bash
chmod +x tests/fixtures/fake-claude
```

- [ ] **Step 3: Create `tests/fixtures/abtop-stub`**

`tests/fixtures/abtop-stub`:
```bash
#!/usr/bin/env bash
# Stub standing in for `abtop`. Prints the fixture named by ABTOP_FIXTURE.
# With no/invalid fixture and abtop-style args, exits non-zero to exercise fallback.
case "$1" in
  --json)
    if [ -n "${ABTOP_FIXTURE:-}" ] && [ -f "${ABTOP_FIXTURE}" ]; then
      cat "${ABTOP_FIXTURE}"
    else
      exit 1
    fi
    ;;
  *) exit 1 ;;
esac
```
Then:
```bash
chmod +x tests/fixtures/abtop-stub
```

- [ ] **Step 4: Create `tests/helpers.bash`**

```bash
# Shared bats helpers. Source from each .bats file: `load helpers`.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

cr_setup() {
  # Isolated tmux server — never touches the user's real sessions.
  CR_SOCKET="cr_test_${BATS_SUITE_TEST_NUMBER}_$$"
  export CR_TMUX="tmux -L ${CR_SOCKET}"
  export CR_ABTOP="${REPO_ROOT}/tests/fixtures/abtop-stub"
  # Inject a stub named `claude` ahead of the real one on PATH. The isolated
  # tmux server started below inherits this PATH and resolves `claude` to the stub.
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_BIN"
  ln -sf "${REPO_ROOT}/tests/fixtures/fake-claude" "${STUB_BIN}/claude"
  export PATH="${STUB_BIN}:${REPO_ROOT}/bin:${PATH}"
}

cr_teardown() {
  ${CR_TMUX} kill-server 2>/dev/null || true
}

# Start an isolated tmux session running the fake-claude stub.
# Usage: cr_make_session <session-name>  -> echoes the pane_pid
cr_make_session() {
  local name="$1"
  ${CR_TMUX} new-session -d -s "$name" -- claude >/dev/null
  ${CR_TMUX} display-message -p -t "$name" '#{pane_pid}'
}
```

- [ ] **Step 5: Create `lib/claude-remote-lib.sh` stub**

```bash
#!/usr/bin/env bash
# claude-remote shared helpers. Sourced by bin/claude-remote, bin/claude-remote-pick, and tests.
# All tmux/abtop access goes through the CR_TMUX / CR_ABTOP env seams.

: "${CR_TMUX:=tmux}"
: "${CR_ABTOP:=abtop}"

# (functions added by later tasks)
```

- [ ] **Step 6: Create `.shellcheckrc`**

```
# Allow sourcing files shellcheck can't follow at lint time.
external-sources=true
```

- [ ] **Step 7: Create `Makefile`**

```makefile
.PHONY: test lint fmt fmt-check
test:
	bats tests/

lint:
	shellcheck bin/claude-remote bin/claude-remote-pick lib/claude-remote-lib.sh install.sh

fmt:
	shfmt -w -i 2 -ci bin/ lib/ install.sh

fmt-check:
	shfmt -d -i 2 -ci bin/ lib/ install.sh
```

- [ ] **Step 8: Commit**

```bash
git add Makefile .shellcheckrc lib/claude-remote-lib.sh tests/
git commit -m "chore: scaffold project, dev tooling, and test harness"
```

---

## Task 1: Session-name helper

**Files:**
- Modify: `lib/claude-remote-lib.sh`
- Test: `tests/name.bats`

- [ ] **Step 1: Write the failing test**

`tests/name.bats`:
```bash
load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "cr_session_name uses label when given" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_session_name "refactor"
  [ "$status" -eq 0 ]
  [ "$output" = "refactor" ]
}

@test "cr_session_name falls back to basename of cwd" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  cd /tmp
  run cr_session_name ""
  [ "$status" -eq 0 ]
  [ "$output" = "tmp" ]
}

@test "cr_session_name sanitizes characters tmux dislikes" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_session_name "feature/login.v2"
  [ "$status" -eq 0 ]
  [ "$output" = "feature_login_v2" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/name.bats`
Expected: FAIL — `cr_session_name: command not found`.

- [ ] **Step 3: Implement**

Append to `lib/claude-remote-lib.sh`:
```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/name.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Lint + commit**

```bash
make lint
git add lib/claude-remote-lib.sh tests/name.bats
git commit -m "feat: add cr_session_name helper"
```

---

## Task 2: `claude-remote` launch wrapper

**Files:**
- Create: `bin/claude-remote`
- Modify: `lib/claude-remote-lib.sh`
- Test: `tests/launch.bats`

- [ ] **Step 1: Write the failing test**

`tests/launch.bats`:
```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/launch.bats`
Expected: FAIL — `claude-remote: command not found` (or no such file).

- [ ] **Step 3: Add the launch helper to the lib**

Append to `lib/claude-remote-lib.sh`:
```bash
# cr_launch <name> <attach:0|1> -- <claude args...>
# Creates a detached tmux session running claude directly, so pane_pid == claude pid.
# `claude` is resolved from PATH by tmux's exec form (no shell involved, so the
# interactive claude zsh function never enters the picture — equivalent to
# `command claude`). Renames the session to <name>-<pane_pid>, then optionally attaches.
cr_launch() {
  local name="$1" attach="$2"
  shift 2
  [ "$1" = "--" ] && shift
  local tmp pid final
  tmp="${name}-tmp-$$"
  # shellcheck disable=SC2086
  $CR_TMUX new-session -d -s "$tmp" -- claude "$@" || return 1
  # shellcheck disable=SC2086
  pid="$($CR_TMUX display-message -p -t "$tmp" '#{pane_pid}')"
  final="${name}-${pid}"
  # shellcheck disable=SC2086
  $CR_TMUX rename-session -t "$tmp" "$final" || return 1
  if [ "$attach" -eq 1 ]; then
    # shellcheck disable=SC2086
    exec $CR_TMUX attach -t "$final"
  fi
  printf '%s\n' "$final"
}
```

- [ ] **Step 4: Create `bin/claude-remote`**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/claude-remote-lib.sh
. "${HERE}/../lib/claude-remote-lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: claude-remote [-l|--label LABEL] [--no-attach] [-- CLAUDE_ARGS...]
Launches claude inside a named, persistent tmux session and attaches.
EOF
}

label=""
attach=1
while [ $# -gt 0 ]; do
  case "$1" in
    -l|--label) label="$2"; shift 2 ;;
    --no-attach) attach=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

name="$(cr_session_name "$label")"
cr_launch "$name" "$attach" -- "$@"
```
Then:
```bash
chmod +x bin/claude-remote
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/launch.bats`
Expected: PASS (3 tests).

- [ ] **Step 6: Lint + commit**

```bash
make lint
git add bin/claude-remote lib/claude-remote-lib.sh tests/launch.bats
git commit -m "feat: add claude-remote launch wrapper"
```

---

## Task 3: Parse abtop sessions

**Files:**
- Create: `tests/fixtures/abtop-sample.json`
- Modify: `lib/claude-remote-lib.sh`
- Test: `tests/abtop_parse.bats`

- [ ] **Step 1: Create the fixture** (`tests/fixtures/abtop-sample.json`)

Real-shape snapshot with two claude sessions and one non-claude session:
```json
{
  "generated_at_ms": 1781523105592,
  "sessions": [
    {
      "agent_cli": "claude",
      "pid": 84717,
      "project_name": "claude-remote",
      "cwd": "/Users/valgard/projects/claude-remote",
      "status": "Executing",
      "model": "claude-opus-4-8",
      "context_percent": 49.6955,
      "total_tokens": 5155499,
      "git_branch": "main",
      "current_task": "Bash for t in tmux bats ..."
    },
    {
      "agent_cli": "claude",
      "pid": 90001,
      "project_name": "demo",
      "cwd": "/Users/valgard/projects/demo",
      "status": "Idle",
      "model": "claude-sonnet-4-6",
      "context_percent": 12.0,
      "total_tokens": 100,
      "git_branch": "dev",
      "current_task": null
    },
    {
      "agent_cli": "codex",
      "pid": 70000,
      "project_name": "other",
      "cwd": "/tmp/other",
      "status": "Idle",
      "model": "gpt-x",
      "context_percent": 1.0,
      "total_tokens": 1,
      "git_branch": null,
      "current_task": null
    }
  ]
}
```

- [ ] **Step 2: Write the failing test** (`tests/abtop_parse.bats`)

```bash
load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "cr_abtop_sessions emits one TSV row per claude session" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  export ABTOP_FIXTURE="${REPO_ROOT}/tests/fixtures/abtop-sample.json"
  run cr_abtop_sessions
  [ "$status" -eq 0 ]
  # 2 claude sessions, codex excluded
  [ "${#lines[@]}" -eq 2 ]
  # columns: pid \t project \t status \t ctx% \t model \t task
  [[ "${lines[0]}" == 84717$'\t'claude-remote$'\t'Executing$'\t'* ]]
  [[ "${lines[1]}" == 90001$'\t'demo$'\t'Idle$'\t'* ]]
}

@test "cr_abtop_sessions returns non-zero when abtop fails" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  unset ABTOP_FIXTURE   # stub exits 1
  run cr_abtop_sessions
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bats tests/abtop_parse.bats`
Expected: FAIL — `cr_abtop_sessions: command not found`.

- [ ] **Step 4: Implement**

Append to `lib/claude-remote-lib.sh`:
```bash
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bats tests/abtop_parse.bats`
Expected: PASS (2 tests).

- [ ] **Step 6: Lint + commit**

```bash
make lint
git add lib/claude-remote-lib.sh tests/abtop_parse.bats tests/fixtures/abtop-sample.json
git commit -m "feat: parse claude sessions from abtop --json"
```

---

## Task 4: Map tmux panes to Claude PIDs

**Files:**
- Modify: `lib/claude-remote-lib.sh`
- Test: `tests/pane_map.bats`

- [ ] **Step 1: Write the failing test** (`tests/pane_map.bats`)

```bash
load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "cr_pane_map emits pane_pid<TAB>session for each session" {
  pid="$(cr_make_session demo)"
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_pane_map
  [ "$status" -eq 0 ]
  [[ "$output" == "${pid}"$'\t'demo ]]
}

@test "cr_pane_map is empty when no sessions exist" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_pane_map
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/pane_map.bats`
Expected: FAIL — `cr_pane_map: command not found`.

- [ ] **Step 3: Implement**

Append to `lib/claude-remote-lib.sh`:
```bash
# cr_pane_map -> "pane_pid<TAB>session_name" for every pane across all sessions.
# pane_pid is the process tmux exec'd in the pane == the claude pid (we launch
# claude directly). Empty output (status 0) when no server/sessions exist.
cr_pane_map() {
  # shellcheck disable=SC2086
  $CR_TMUX list-panes -a -F '#{pane_pid}'$'\t''#{session_name}' 2>/dev/null || true
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/pane_map.bats`
Expected: PASS (2 tests).

- [ ] **Step 5: Lint + commit**

```bash
make lint
git add lib/claude-remote-lib.sh tests/pane_map.bats
git commit -m "feat: map tmux panes to claude pids"
```

---

## Task 5: Join abtop sessions with attachable tmux panes

**Files:**
- Modify: `lib/claude-remote-lib.sh`
- Test: `tests/join.bats`

Output protocol (single stream, fully testable):
- attachable row: `S<TAB>session<TAB>pid<TAB>project<TAB>status<TAB>ctx%<TAB>model<TAB>task`
- summary line:    `N<TAB><count of claude sessions NOT attachable>`

- [ ] **Step 1: Write the failing test** (`tests/join.bats`)

```bash
load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "cr_join marks attachable sessions S and counts the rest N" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  # pane map: pid 84717 is in tmux as session 'cr', 90001 is NOT.
  panemap="$(mktemp)"
  printf '84717\tcr\n' > "$panemap"
  # abtop rows: pid \t project \t status \t ctx \t model \t task
  abtop_rows="$(printf '84717\tclaude-remote\tExecuting\t49\topus\tdoing things\n90001\tdemo\tIdle\t12\tsonnet\t\n')"

  run bash -c "printf '%s\n' \"\$1\" | cr_join \"\$2\"" _ "$abtop_rows" "$panemap"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == S$'\t'cr$'\t'84717$'\t'claude-remote$'\t'Executing$'\t'* ]]
  [[ "${lines[1]}" == N$'\t'1 ]]
}

@test "cr_join reports N=0 when all sessions are attachable" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  panemap="$(mktemp)"
  printf '84717\tcr\n' > "$panemap"
  abtop_rows="$(printf '84717\tclaude-remote\tExecuting\t49\topus\tx\n')"
  run bash -c "printf '%s\n' \"\$1\" | cr_join \"\$2\"" _ "$abtop_rows" "$panemap"
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == N$'\t'0 ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/join.bats`
Expected: FAIL — `cr_join: command not found`.

- [ ] **Step 3: Implement**

Append to `lib/claude-remote-lib.sh`:
```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/join.bats`
Expected: PASS (2 tests).

- [ ] **Step 5: Lint + commit**

```bash
make lint
git add lib/claude-remote-lib.sh tests/join.bats
git commit -m "feat: join abtop sessions with attachable tmux panes"
```

---

## Task 6: Render the picker menu (numbered fallback + fzf)

**Files:**
- Modify: `lib/claude-remote-lib.sh`
- Test: `tests/render.bats`

- [ ] **Step 1: Write the failing test** (`tests/render.bats`)

```bash
load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "cr_format_rows renders one human line per attachable session" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  joined="$(printf 'S\tcr\t84717\tclaude-remote\tExecuting\t49\topus\tdoing things\nN\t2\n')"
  run bash -c "printf '%s\n' \"\$1\" | cr_format_rows" _ "$joined"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"cr"* ]]
  [[ "${lines[0]}" == *"claude-remote"* ]]
  [[ "${lines[0]}" == *"Executing"* ]]
  [[ "${lines[0]}" == *"49%"* ]]
}

@test "cr_footnote prints the non-attachable hint only when N>0" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run bash -c "printf 'N\t3\n' | cr_footnote"
  [[ "$output" == *"3"* ]]
  [[ "$output" == *"claude-remote"* ]]
  run bash -c "printf 'N\t0\n' | cr_footnote"
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/render.bats`
Expected: FAIL — `cr_format_rows: command not found`.

- [ ] **Step 3: Implement**

Append to `lib/claude-remote-lib.sh`:
```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/render.bats`
Expected: PASS (2 tests).

- [ ] **Step 5: Lint + commit**

```bash
make lint
git add lib/claude-remote-lib.sh tests/render.bats
git commit -m "feat: render picker rows and non-attachable footnote"
```

---

## Task 7: `claude-remote-pick` entry point (with `tmux ls` fallback)

**Files:**
- Create: `bin/claude-remote-pick`
- Modify: `lib/claude-remote-lib.sh`
- Test: `tests/fallback.bats`

The interactive loop (read selection → attach → redraw on detach → quit) is verified
manually (Task 9 checklist). The **data assembly** and **fallback** are unit-tested
via a `--list` mode that prints the menu lines and exits.

- [ ] **Step 1: Write the failing test** (`tests/fallback.bats`)

```bash
load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "--list shows abtop-enriched rows for attachable sessions" {
  pid="$(cr_make_session proj)"
  # Build an abtop fixture whose pid matches the live pane pid.
  fixture="$(mktemp)"
  cat > "$fixture" <<JSON
{ "sessions": [ { "agent_cli":"claude","pid":${pid},"project_name":"proj","status":"Idle","model":"opus","context_percent":7,"current_task":"hello" } ] }
JSON
  ABTOP_FIXTURE="$fixture" run claude-remote-pick --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"proj"* ]]
  [[ "$output" == *"Idle"* ]]
  [[ "$output" == *"hello"* ]]
}

@test "--list falls back to tmux session names when abtop fails" {
  cr_make_session standalone >/dev/null
  unset ABTOP_FIXTURE   # abtop stub now exits 1
  run claude-remote-pick --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"standalone"* ]]
  [[ "$output" == *"(abtop nicht verfügbar"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/fallback.bats`
Expected: FAIL — `claude-remote-pick: command not found`.

- [ ] **Step 3: Add the menu-assembly + fallback helpers to the lib**

Append to `lib/claude-remote-lib.sh`:
```bash
# cr_menu_lines -> "session\tdisplay" lines for attachable sessions, plus a footnote
# on stderr. Falls back to raw tmux session list (status 0) if abtop is unavailable.
# Prints nothing and returns 0 when there are no sessions at all.
cr_menu_lines() {
  local abtop_rows joined
  if abtop_rows="$(cr_abtop_sessions)"; then
    joined="$(printf '%s\n' "$abtop_rows" | cr_join <($CR_TMUX list-panes -a -F '#{pane_pid}'$'\t''#{session_name}' 2>/dev/null))"
    printf '%s\n' "$joined" | cr_format_rows
    printf '%s\n' "$joined" | cr_footnote >&2
  else
    # Fallback: plain tmux session list, reduced metadata.
    # shellcheck disable=SC2086
    $CR_TMUX list-sessions -F '#{session_name}'$'\t''#{session_name}' 2>/dev/null \
      | awk -F'\t' '{ printf "%s\t%s\n", $1, $2 }'
    echo "(abtop nicht verfügbar — reduzierte Anzeige)" >&2
  fi
}
```
Note: `cr_join` reads the pane map from a file path; `<(...)` process substitution
supplies it. The fallback's two identical columns keep the `session\tdisplay`
contract so the loop in `bin/claude-remote-pick` is uniform.

- [ ] **Step 4: Create `bin/claude-remote-pick`**

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/claude-remote-lib.sh
. "${HERE}/../lib/claude-remote-lib.sh"

# --list: print menu lines (session<TAB>display) and exit. Used by tests and scripts.
if [ "${1:-}" = "--list" ]; then
  cr_menu_lines
  exit 0
fi

# Interactive loop: render menu, read a choice, attach (no exec → return here on detach).
while true; do
  mapfile -t menu < <(cr_menu_lines 2>/dev/null)
  echo "Claude-Sessions:"
  cr_menu_lines >/dev/null 2>/tmp/cr_footnote.$$ || true
  i=1
  for line in "${menu[@]}"; do
    printf "  %2d) %s\n" "$i" "${line#*$'\t'}"
    i=$((i + 1))
  done
  [ -s /tmp/cr_footnote.$$ ] && cat /tmp/cr_footnote.$$; rm -f /tmp/cr_footnote.$$
  printf "  %2d) ＋ neue Session\n" "$i"
  printf "   q) Beenden\n"
  printf "Auswahl: "
  read -r choice

  case "$choice" in
    q|Q) exit 0 ;;
    "$i")
      printf "Verzeichnis (leer = \$HOME): "; read -r dir
      dir="${dir:-$HOME}"
      ( cd "$dir" && cr_launch "$(cr_session_name "")" 1 -- ) ;;
    *)
      if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#menu[@]}" ]; then
        sess="${menu[$((choice - 1))]%%$'\t'*}"
        # No exec: on detach (Ctrl-b d) we fall back into the loop.
        # shellcheck disable=SC2086
        $CR_TMUX attach -t "$sess"
      fi ;;
  esac
done
```
Then:
```bash
chmod +x bin/claude-remote-pick
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/fallback.bats`
Expected: PASS (2 tests).

- [ ] **Step 6: Lint + commit**

```bash
make lint
git add bin/claude-remote-pick lib/claude-remote-lib.sh tests/fallback.bats
git commit -m "feat: add claude-remote-pick with abtop picker and tmux fallback"
```

---

## Task 8: Full test + lint + format gate

**Files:** none (verification task)

- [ ] **Step 1: Run the whole suite**

Run: `make test`
Expected: all bats files pass (name, launch, abtop_parse, pane_map, join, render, fallback).

- [ ] **Step 2: Lint everything**

Run: `make lint`
Expected: no shellcheck findings.

- [ ] **Step 3: Format check**

Run: `make fmt-check`
Expected: no diff. If diffs: run `make fmt`, re-run tests, then commit.

- [ ] **Step 4: Commit any formatting**

```bash
git add -A
git commit -m "style: shfmt formatting" || echo "nothing to format"
```

---

## Task 9: Install script, tmux options, README, manual acceptance

**Files:**
- Create: `install.sh`, `README.md`

- [ ] **Step 1: Create `install.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
mkdir -p "$BIN_DIR"
ln -sf "${HERE}/bin/claude-remote" "${BIN_DIR}/claude-remote"
ln -sf "${HERE}/bin/claude-remote-pick" "${BIN_DIR}/claude-remote-pick"

# tmux: let the active client drive the size when multiple clients attach.
TMUX_CONF="${HOME}/.tmux.conf"
grep -q 'aggressive-resize' "$TMUX_CONF" 2>/dev/null \
  || echo 'setw -g aggressive-resize on' >> "$TMUX_CONF"

cat <<EOF
Installed claude-remote and claude-remote-pick to ${BIN_DIR}.

1) Wrap your existing claude() zsh function so it launches via claude-remote:

   claude() {
     local git_root=\$(git rev-parse --show-toplevel 2>/dev/null)
     if [[ -n "\$git_root" ]]; then
       (cd "\$git_root" && claude-remote -- --allow-dangerously-skip-permissions --brief "\$@")
     else
       claude-remote -- --allow-dangerously-skip-permissions --brief "\$@"
     fi
   }

2) Give the iPad its own SSH key and restrict it to the picker in
   ~/.ssh/authorized_keys (ONE line):

   command="${BIN_DIR}/claude-remote-pick",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA... ipad

   SECURITY: tmux attach grants full interactive access. Treat this key like a
   login key — it is NOT a sandbox.

3) In Blink, connect to:  macbook.local   (Bonjour/mDNS over your local network)
EOF
```
Then: `chmod +x install.sh`

- [ ] **Step 2: Create `README.md`**

Document: what it is, the delegation architecture (tmux/sshd/abtop + 2 scripts), `claude-remote` usage and the `-l` label, the picker, the `command=`/key setup, the `macbook.local` transport, and the env seams (`CR_TMUX`, `CR_ABTOP`). Link to `docs/superpowers/specs/2026-06-15-claude-remote-design.md`.

- [ ] **Step 3: Manual acceptance checklist** (record results in the PR/commit message)

1. `claude-remote -l demo` in a repo → lands in claude; `tmux ls` shows `demo-<pid>`.
2. Detach (`Ctrl-b d`) → claude keeps running; `claude-remote-pick` lists `demo` with abtop metadata (status/ctx%/model).
3. From the iPad over `macbook.local` with the restricted key → picker appears on connect; select `demo` → attached; `Ctrl-b d` → back in the picker; `q` → SSH closes.
4. Start a bare `claude` (not via the wrapper) → it appears as the non-attachable footnote, not in the selectable list.
5. Temporarily rename the abtop binary → picker still lists sessions via the `tmux ls` fallback.

- [ ] **Step 4: Commit**

```bash
git add install.sh README.md
git commit -m "feat: add install script, tmux config, README, and acceptance checklist"
```

---

## Self-Review (completed)

**Spec coverage:** Launch wrapper → Task 2; auto-naming + label + pid disambiguator → Tasks 1–2; picker + abtop join → Tasks 3–7; `tmux ls` fallback → Task 7; non-attachable footnote → Tasks 5–6; SSH `command=` entry point + security note → Task 9; multi-attach `aggressive-resize` → Task 9; transport `macbook.local` → Task 9 (README); test strategy (bats, stubs, isolated tmux) → Tasks 0–8; "neue Session" from picker → Task 7. Default dir for "neue Session" resolved to `$HOME` prompt (was open in spec).

**Placeholder scan:** README content (Task 9 Step 2) is described rather than shown — acceptable, it is prose documentation, not code. All code steps contain full implementations.

**Type/name consistency:** `cr_session_name`, `cr_launch`, `cr_abtop_sessions`, `cr_pane_map`, `cr_join`, `cr_format_rows`, `cr_footnote`, `cr_menu_lines` — names used consistently across tasks and call sites. cr_join output protocol (`S`/`N` rows) consistent across Tasks 5–7. Env seams `CR_TMUX`/`CR_ABTOP` consistent throughout; `claude` is resolved from `PATH` (production) or a PATH-injected stub (tests), never an explicit path.
