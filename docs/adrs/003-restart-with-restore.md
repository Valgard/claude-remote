# ADR-003: Restart anchor and server from the picker, restoring every session by exact id

- Status: accepted
- Date: 2026-11-18

## Context and Problem Statement

macOS attributes file and network access of every pane to the *responsible process*: the `ClaudeRemoteAnchor.app` instance that births the tmux server (ADR-002). Processes inherit it at `fork`. In November 2026 a 41-day-old instance lost access to all network volumes (`readdir` → `Operation not permitted`) while `tccd` still reported the grant as allowed; a freshly opened instance of the same app had full access. The trigger is unknown, so the only cure is a new instance plus a new server — which ends every Claude session in it. Rebuilding a dozen sessions by hand, each with the right conversation and directory, is the cost this decision removes.

## Decision Drivers

- One command in the picker, usable on the Mac and from the iPad (SSH forced command).
- Each restored session continues **its own** conversation — never "the most recent one in this directory".
- No session disappears unnamed: each ends up restored, failed with a reason, or not restorable with a reason.
- The user never ends up without sessions *and* without a way back.
- The new server must be born in the GUI session (keychain), i.e. through the anchor LaunchAgent, never from the SSH picker.

## Considered Options

1. Status quo: `tmux kill-server`, then restart sessions by hand.
2. A tmux session-restore plugin (resurrect/continuum).
3. Bypass the server (`command claude` in a plain terminal).
4. A picker command that snapshots, replaces anchor and server, and relaunches each session with `--resume <exact id>`.

## Decision Outcome

Chosen: **Option 4** (picker `Ctrl-T`, numbered menu `s`; `claude-remote-pick --restore <snapshot>` re-runs the restore).

What makes it safe, in the order the run meets it:

- **Identity is exact.** A pane's session id comes from Claude Code's `~/.claude/sessions/<pid>.json`, accepted only when its `procStart` matches the process start time. abtop's id is a guess and is never used; neither are `--continue` or titles.
- **Arguments pass an allowlist.** Everything else is dropped and reported. Tokens that pick the conversation (`--resume`, `--session-id`, `--continue`, `--fork-session`) are replaced by the exact `--resume`, not reported. A session started with a *restricting* flag (`--disallowedTools`, `--tools`, `--settings`, `--strict-mcp-config`, `--permission-prompt-tool`) is not restorable: relaunched without it, it would run with fewer restrictions than before. `--allowedTools` only pre-approves and is simply dropped.
- **The user decides on full information.** Before `[j/N]` (default No) the summary names sessions as `<title> (<tmux name>)` and lists mid-turn sessions (their turn is lost), sessions that drifted from their start directory (they restart in it), and unrestorable ones with the reason. After `j` a fresh snapshot is compared by (name, verdict); any change re-asks.
- **Refuse before stopping.** Nothing is stopped unless the snapshot is readable (an empty one only for a server that holds nothing but the anchor — replacing the instance is the cure even then, since a bare `kill-server` lets the old supervisor re-birth the server) and `launchctl print` finds the anchor agent. A restart from inside the server it would end is refused; guard and actions address the same server (`TMUX` unset).
- **The way back is named first.** Snapshot path, the `--restore` command and a private `<snapshot>.report` are printed before anything stops; INT and HUP are ignored during the destructive phase, so a dropped iPad connection does not strand the run.
- **Stop order is fail-safe.** Supervisors first (TERM, then KILL; only processes whose command line ends in `<dir>/claude-remote-pick --supervise-anchor`), the server only once they are gone; otherwise nothing is killed. The new server comes from `launchctl kickstart -k` of the anchor agent.

### Consequences

- **Good:** one command cures a stale anchor instance; conversations come back exactly, attachable from picker and iPad, through the normal `cr_launch` path.
- **Cost:** in-flight turns, background shells and running tools are lost by construction. Drifted sessions (e.g. in a git worktree) restart in their start directory. The launch arguments are read back from `ps`, which flattens argv, so a multi-word value cannot be reconstructed exactly (it is dropped and listed).
- **Risk:** the identity source is an internal, undocumented Claude Code file. If its format changes, rows become "not restorable" (fail-safe), not wrongly restored.

### Confirmation

The bats suite covers each refusal, the stop order (including a supervisor that survives KILL), the argument rewriting, the confirm loop and the restore report on isolated tmux sockets, with production-shape tests fenced to their own `TMUX_TMPDIR`. Run for real on 2026-11-18 from a plain terminal: 13 of 13 sessions restored, each with exactly its previous session id; network volumes readable and keychain writes working from the new server; `launchctl print` and `kickstart` verified from an SSH session, and the SSH picker lists the restored sessions with their titles. The identity source follows in-process switches: after `/clear` and after `/resume` the pid's session file named the conversation then running, so a restart restores what the pane shows, not what it was launched with.

Rejected:

- **1** — correct but manual; finding the right conversation per session by hand is the error-prone part.
- **2** — restores layout and shells, not Claude conversations, and does not replace the anchor instance.
- **3** — sessions are no longer attachable from the iPad and lose the anchor's keychain and network grants.

## More Information

Raw design spec (deleted in this commit per the spec→ADR distillation; retrieve from git history, hash-free):

```
git show "$(git rev-list -1 HEAD -- docs/specs/2026-11-16-restart-server-design.md)^:docs/specs/2026-11-16-restart-server-design.md"
```
