# Restart the server with all sessions — Design

**Date:** 2026-11-16
**Status:** APPROVED (2026-11-16), not yet implemented

## Why

On 2026-11-16 every process in the long-lived tmux server suddenly got
`Operation not permitted` when reading **any** network volume (`readdir` on all
nine SMB mounts; `stat` still worked). Claude Code could no longer be started in a
directory on the NAS through `claude` → `claude-remote`, while `command claude` in
a plain iTerm tab worked.

The diagnosis pinned the defect to the **running anchor app instance**, not to the
app, its privacy grant, the mounts or our code:

- macOS attributes the access to the *responsible process*. For everything in the
  server that is the `ClaudeRemoteAnchor.app` instance which births and supervises
  it (ADR-002). That instance had been alive for 41 days.
- `tccd` still answered "Allowed (User Consent)" for the app's bundle. The failing
  reads never reached `tccd`; nothing was logged by `tccd`, `sandboxd` or the kernel
  sandbox. The trigger is unknown.
- A **second, freshly opened instance** of the same app (same bundle, same grant)
  births a server whose panes read the shares fine. This holds when the instance is
  opened from a plain terminal and when it is opened from an SSH session (the
  iPad's launch context).

Processes inherit their responsible process at `fork`, so sessions in the old
server can never regain access. The cure is a new anchor instance plus a new
server, and rebuilding ~15 sessions by hand afterwards is what this feature
removes. In the user's words: *"One command in the picker, and afterwards all
sessions are running again."*

## Goals

1. **One picker command** replaces the anchor instance and the tmux server, then
   restores every Claude session that ran in the old server. Each restored session
   continues **its own conversation** (same session ID) in the directory it was
   launched from.
2. Restored sessions go through claude-remote's normal launch path (`cr_launch`).
   They are therefore attachable from the picker and the iPad, keep
   `pane_pid == claude pid`, and are armed for post-exit capture.
3. Works from the Mac picker **and** from the iPad picker (SSH forced command).
4. Before anything is stopped, the user sees (a) the sessions that are mid-turn
   right now, with a warning, and (b) the sessions that cannot be restored, with the
   reason. Then comes a `[j/N]` confirmation, default No. *Decided by the user:
   "warn and ask whether to restart anyway".*
5. Afterwards the user learns which sessions came back and which did not, and why.

## Non-goals

- Detecting a locked-out server automatically, or restarting without being asked.
- Keeping processes alive. In-flight turns, background shells and running tools
  are lost by construction; the conversation itself survives in the transcript.
- Restoring panes that are not Claude Code (e.g. a bare shell): they are listed as
  "cannot be restored", nothing more.
- Sessions outside the server (the picker's `N` rows) are untouched.
- Redrawing the picker with the restored sessions afterwards. *The user called this
  optional.*

## Anti-goals (would make it a failure even if it "works")

- **A session disappears without being named.** Every session in the old server
  ends up in exactly one of: restored, failed (with reason), not restorable (with
  reason).
- **A restored session continues the wrong conversation.** Restoring must use the
  exact session ID. It must never rely on "most recent session in this directory"
  (`--continue`), on abtop's `session_id` (a guess, see `CLAUDE.md`), or on
  resuming by title.
- **The user is left without sessions and without a way back.** If the new server
  does not come up, or restoring fails half-way, the information needed to finish by
  hand must still exist.
- **The server is born outside the GUI session.** A server born directly from the
  SSH picker lands in the `Background` domain and loses keychain writes (the
  original reason for the anchor). The restart must go through the anchor.

## Constraints

Everything in `CLAUDE.md` → *Conventions that matter* applies: bash 3.2, shellcheck
and shfmt clean, logic as `cr_*` functions in the lib, every external tool behind an
env seam, user-facing strings German, bats tests hermetic (no real tmux server, no
real Claude, no real `launchctl`).

## Facts established on 2026-11-16 (re-verify before relying on them)

| # | Fact | How it was established |
|---|------|------------------------|
| F1 | Claude Code writes `~/.claude/sessions/<pid>.json` per running process. Fields include `sessionId`, `cwd`, `status` (`busy`, `waiting`, `idle`), `procStart`, `tmux` (`<session>:@<window>.%<pane>`), `kind`, `entrypoint`. Keyed by pid, so it is exact. It is an **internal, undocumented** format. | Read for all 15 panes of the live server; 15/15 resolved to a distinct session ID. |
| F2 | abtop also reports a status (`Executing`, `Thinking`, `Waiting`), but its pid→session link is a guess (see `CLAUDE.md`). | `abtop --json` |
| F3 | The pane's claude argv is visible via `ps -o args= -p <pane_pid>`. Observed shapes: `claude --allow-dangerously-skip-permissions --brief --resume <title>` (most), `… --name <name>`, and a bare `claude`. So the original flags vary, and many already contain a session-selecting flag. | `ps` on all panes |
| F4 | `#{pane_start_path}` is the directory the session was launched from. | `tmux list-panes` |
| F5 | `launchctl kickstart gui/<uid>/de.valgard.claude-remote-anchor` succeeds from an SSH session. `open -n <app>` from an SSH session starts a fresh instance whose server has share access. | Two non-destructive probes on separate tmux sockets |
| F6 | The LaunchAgent's program is `/usr/bin/open <app>` (app mode) or `claude-remote-pick --ensure-anchor` (degrade mode without a compiler). While an instance runs, the agent's `open` exits 1 on every interval (the Apple event to the running instance is refused). This is harmless but explains the minutely `tccd` "Platform binary … Deny" log noise, which is **not** related to network volumes. | `launchctl print`, `tccd` log |
| F7 | The app instance *is* the `claude-remote-pick --supervise-anchor` process (the stub `exec`s into it, same pid). Killing that process ends the instance. | `ps` |

## How it behaves

### Flow

1. **Trigger.** A new picker command. Both pickers return a new parameterless
   token (e.g. `__RESTART__`) under the existing token contract. *My call:* key
   choice and menu wording follow the existing pattern (fzf `--expect` key next to
   `ctrl-r`/`ctrl-x`; a letter in the numbered menu; mentioned in the footer).
2. **Snapshot.** For every pane in the server except `$CR_ANCHOR`, collect: session
   name, pane pid, start path (F4), argv (F3) and the session file (F1). Classify
   each into:
   - *restorable*: the pane process is Claude Code, a session file exists for its
     pid, it parses, and it names a session ID;
   - *not restorable*, with a reason: not a Claude pane, no session file, file
     unreadable, no session ID.
   Separately flag the restorable sessions whose `status` is `busy` or `waiting` as
   **mid-turn**. *My call:* `waiting` counts as mid-turn. In the session file it
   comes with `waitingFor: "input needed"`, i.e. a session blocked on a prompt in
   the middle of a turn.
   Also flag sessions that **last worked somewhere else** than their start path, e.g.
   in a git worktree below it. Their transcript's most recent `cwd` (or Claude
   Code's `worktree-state` entry) tells. At the time of writing that was 4 of 15.
3. **Confirm.** Show the counts, the mid-turn list (with a warning that their
   current turn is lost), the drifted list and the not-restorable list. Ask `[j/N]`,
   default No, read like the existing kill confirmation.
4. **Persist the snapshot** to a file *before* anything is stopped. Anti-goal 3
   needs this. *My call:* a TSV under `$TMPDIR` whose path is printed whenever
   something fails.
5. **Stop.** First end the anchor instance(s), then `kill-server`. The order
   matters: if the server dies first, the old supervisor can re-birth a server under
   the defective instance on its next interval. *My call:* end every
   `--supervise-anchor` process of this user, since they are all ours.
6. **Start.** Kickstart the anchor LaunchAgent (F5). This one call covers both
   install modes (F6). Then wait until the new server's `$CR_ANCHOR` session exists
   and its server pid differs from the old one. Give up after a timeout and report
   it (see *Open for the builder*).
7. **Restore.** For each restorable session, from its start path:
   `cr_launch <label> 0 0 -- <allowlisted original flags> --resume <sessionId>`
   (see *Argument rewriting*).
   Here `<label>` is the old session name without its `-<pid>` suffix. *My call:*
   sessions restart one after another, detached.
   **Where a restored session runs** (*decided by the user*): always in its
   **start path**, the same place a manual `claude --resume` would use. It does
   **not** run in the directory it last worked in. A drifted session is marked
   instead, e.g. "arbeitete zuletzt in …/.worktrees/restart-server". Moving back is
   left to the session. The reason: Claude Code files a transcript under the start
   directory, so a launch from elsewhere risks not finding the session or splitting
   the conversation.
8. **Report.** For example "13 von 15 wiederhergestellt", plus each failure with its
   reason, the drifted sessions with their last directory, the dropped arguments
   per session, and the snapshot path. *My call:* if no server comes up at all, the report
   says so and names the snapshot.

### Argument rewriting

*My call, after the builder check:* an **allowlist**, not a denylist. A denylist
would silently pass any session-selecting or side-effect flag that a future Claude
Code adds.

- **Kept:** flags that only configure the session, such as `--model`, `--brief`,
  `--effort` and the permission flags (`--allow-dangerously-skip-permissions`,
  `--permission-mode`, …), each with its value. The builder fixes the list against
  `claude --help` of the installed version.
- **Dropped:** everything else. That includes:
  - session selection (`-r/--resume [value]`, `-c/--continue`, `--session-id`,
    `--fork-session`, `--from-pr`, `--teleport`);
  - flags that act at startup (`-w/--worktree`, `--tmux`, `--bg`, `--file`,
    `--remote-control`, `-p/--print`);
  - `-n/--name`. A later `/rename` lives in the session and comes back with
    `--resume`, so replaying the launch-time name would undo it. Seen live: a session
    launched with `--name link_tokens` was renamed afterwards.
  - **every positional argument.** A launch prompt replayed on restore would run an
    old instruction again as a new turn, usually with permissions skipped.

  Dropping is not silent: the report names the dropped tokens per session.
- **Not restorable:** a pane whose process is a Claude Code subcommand
  (`claude attach …`, `claude agents`), not an interactive session.
- **Then append** `--resume <sessionId>`. A session launched as a bare `claude`
  comes back with only that.

Dropping every unknown token also defuses the `ps` ambiguity below for tokens that
are not on the allowlist. `-r/--resume` takes an *optional* value, so in `ps` output
a multi-word title and a positional prompt look the same, and both are dropped
either way.

### Guard: never restart from inside the server

If the picker itself runs inside the server it is about to kill (`$TMUX` points at
the same socket), it refuses with a message to run it from a plain terminal or from
the iPad. Without this guard the restart would kill itself half-way, which is
anti-goal 3.

## Open for the builder

- **Exact argv.** `ps -o args=` joins the arguments with spaces, so an argument that
  contains a space cannot be split back reliably. Options: record the argv at launch
  time on the tmux session (a user option set by `cr_launch`), which is exact for
  sessions started after this change, with `ps` as the fallback for older sessions;
  or read the argv exactly from the kernel. Decide, and make an ambiguous case land
  in "not restorable" or "failed" rather than restoring with mangled flags.
- **Resume from the start path works.** Verify that `claude --resume <id>` from the
  pane's start path finds and continues the transcript, including a drifted session
  whose transcript stays under the original project directory (see
  `cr_session_file`). Also decide how to read a session's last working directory
  cheaply: transcripts reach hundreds of MB, so read from the end, as
  `cr_session_title` does.
- **Stale session files and pid reuse.** Ensure the session file belongs to the live
  pane process, e.g. its `pid`/`procStart` match the process. Stale files for dead
  or reused pids do exist in `~/.claude/sessions`. `procStart` is formatted like
  `ps -o lstart` but in **UTC**, so compare against `LC_ALL=C TZ=UTC ps -o lstart=`.
- **Session switches inside a process.** The session file's `formerNames` entries
  carry their own `sessionId`. That suggests the file follows `/clear` and `/resume`
  inside a running process, so `sessionId` is the session the process holds *now*.
  Anti-goal 2 rests on this, so confirm it once.
- **Wait timeout.** It must cover the case where the LaunchAgent's interval fires
  between "instance ended" and "kickstart": a new instance may then already exist
  but only birth the server on its next loop, up to `CR_ANCHOR_INTERVAL` later.
- **Retry path.** Decide how a user finishes a half-failed restore from the
  snapshot, e.g. an entry point that restores from a snapshot file.
- **New seams**, at least for the session-files directory, the LaunchAgent label or
  `launchctl` itself, the wait timeout, and **ending the anchor instance**. Without
  the last one the bats suite would end the user's real anchor.

## Verification

- **bats, hermetic:** snapshot classification, argument rewriting (all argv shapes
  from F3 plus quoting edge cases), label derivation, the inside-the-server guard,
  and the confirm/abort path. Use an isolated tmux socket with `fake-claude` panes,
  fixture session files and a stubbed `launchctl`.
- **Manual, on the real machine (cannot be automated):**
  1. After a restart, a restored session can read a network volume.
  2. The new server is keychain-capable. A non-interactive login-keychain write from
     a restored pane succeeds; a server born in the `Background` domain would fail
     with `-25308`.
  3. The same restart run from the iPad.
  4. Every restored session shows its previous conversation.
