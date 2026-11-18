# ADR-004: Load the start directory's .envrc at launch, and say so when it fails

- Status: accepted
- Date: 2026-11-18

## Context and Problem Statement

ADR-001 runs each Claude pane as `zsh -lic '… exec command claude "$@"'` and listed, as a benefit, that the direnv hook in `~/.zshrc` loads the start directory's `.envrc`. It never did. `~/.zshrc` only registers `_direnv_hook` for the next prompt and the next `cd`, and `zsh -c` reaches neither. So from June to November 2026 no session started by claude-remote saw a project variable (`JIRA_CONFIG_FILE` in one case) while the same `claude` started in a terminal did. Nothing showed the gap.

Firing the hook explicitly closes it, but a launch that loads an `.envrc` can now fail in ways a terminal makes visible and a pane does not. Claude's TUI covers whatever direnv prints. A blocked `.envrc` (any edit re-blocks it) leaves a session that looks healthy and lacks its env. An `.envrc` that waits on a prompt keeps the pane a `zsh`, so the session is missing from the picker. Ctrl-C, direnv's own advice, ends the whole launch. And the restart restore counts a session as restored three seconds after launch, which can still be inside the `.envrc`.

## Decision Drivers

- Parity with a terminal: a session started in a project dir has what `claude` started there would have, including the reason when it does not.
- Each session gets only its own project's variables. Secrets must not spread across sessions or into the tmux server's environment.
- No unbounded hang behind an unattended launch (the restore, `--no-attach`), and no restore report that counts a session that is about to die.
- Leave the picker's display pipeline alone.

## Considered Options

Where a failed `.envrc` becomes visible:

1. A warning in the pane before Claude starts, held for a key on an attached launch, plus a line in the restore report.
2. A marker in the picker row.
3. Both.

How to bound a slow or hanging `.envrc`:

1. A time limit after which direnv is abandoned like on Ctrl-C, and a restore that waits until Claude actually runs.
2. No limit; a picker row for sessions still loading.
3. Only fix the restore.

What to do with direnv's status lines (`loading …`, `export +NAMES`):

1. Silence them for this one call.
2. Keep them, as a terminal shows them.

## Decision Outcome

Chosen: the warning before start, the time limit with a waiting restore, and silenced status lines. The pane runs `CR_PANE_SCRIPT` (`lib/claude-remote-lib.sh`), parsed only after a small loader has reset the options and switched off the aliases the user's `~/.zshrc` set, either of which could otherwise bend or break it; it calls its builtins through `builtin`, since a `~/.zshrc` function could shadow one. It fires `_direnv_hook` when `~/.zshrc` defines it, which keeps the decision whether direnv is in use with `~/.zshrc`. It bounds the hook with `CR_DIRENV_TIMEOUT` (default 30 s). Any output direnv still produces is printed and held for `CR_DIRENV_HOLD` (default 15 s) or a key on attached launches only. Its first non-blank line goes into the pane option `@cr_direnv`, and the script then execs Claude. `cr_restore_sessions` settles once every pane has set that option, or at a deadline, and lists the problems in a section of its own.

The picker marker was rejected: it adds a column through `cr_pane_titles`/`cr_format_rows` and a second channel for a state the attached screen and the report already carry. No limit was rejected because an unattended launch, or a secret-store dialog on a Mac nobody is watching, would hang without end. Keeping the status lines was rejected because they surface only in the post-exit output, after the session they describe has ended, while hiding them leaves errors intact. Measured: `DIRENV_LOG_FORMAT=` silences status lines but not errors. With direnv's own "taking a while" note also kept out (its `DIRENV_WARN_TIMEOUT` raised past the limit), whatever direnv still prints is a problem.

### Consequences

- **Good:** project variables reach claude-remote sessions on every launch path (wrapper, picker, restore), each session only its own start directory's (direnv's nearest-`.envrc` rule, parents only through `source_up`), frozen at launch like the rest of its env.
- **Good:** a blocked, denied or failing `.envrc` and an `.envrc` without a hook to load it are named before Claude starts, or in the restore report.
- **Good:** Ctrl-C during a slow `.envrc` gives up on direnv, not on Claude, as at a terminal prompt.
- **Cost:** a failing `.envrc` delays an attached start by up to `CR_DIRENV_HOLD`. A restore waits for slow `.envrc` files, up to `CR_DIRENV_TIMEOUT` plus 10 s; that deadline also bounds a `~/.zshrc` that blocks before the pane script runs, and such a session is listed as giving no feedback.
- **Accepted:** an `.envrc` that writes to stderr on its own is reported as a problem although it loaded, so the warning says "womöglich". An `.envrc` legitimately slower than the limit is cut off.
- **Accepted:** the pane script depends on direnv's internals: the name `_direnv_hook`, its early return outside an interactive top-level shell, and the `Found RC path` line of `direnv status`. If direnv changes them, loading stops or the missing-hook warning goes quiet. `tests/direnv.bats` runs against the real direnv to notice.
- **Accepted:** a launch with `--no-attach` shows its warning to nobody. It stays in the pane's history and reaches the post-exit output.

### Confirmation

`tests/direnv.bats` drives the real direnv in a sandbox: a whitelist in a private `DIRENV_CONFIG` with an empty `direnvrc`, a private `XDG_DATA_HOME`, never `direnv allow`. It covers each failure mode, the limit (also with the blank-padded group number macOS `ps` reports), Ctrl-C during loading and at the hold, the reported line, and the isolation between sessions. `tests/launch.bats` pins the argv, the argument order through the real login shell, the start directory, the pane-process invariant, the bypass of a `claude` shell function, the timer's cancellation, and a `~/.zshrc` whose options and aliases would break the script. `tests/restart_restore.bats` pins the waiting restore for every session, its deadline, and the report section.

## More Information

ADR-001 records the login-shell launch this builds on; its Consequences point here.
