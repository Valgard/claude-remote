load helpers

setup() {
  cr_setup
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  f="${BATS_TEST_TMPDIR}/snap.tsv"
}
teardown() { cr_teardown; }

@test "summary counts ok rows and lists busy and waiting as mid-turn" {
  printf '%s\n' $'a-1\t1\t/x\tok\t\tS1\tbusy\t\t' $'b-2\t2\t/x\tok\t\tS2\twaiting\t\t' $'c-3\t3\t/x\tok\t\tS3\tidle\t\t' >"$f"
  run cr_restart_summary "$f"
  [[ "$output" == *"Anchor und tmux-Server werden neu gestartet."* ]]
  [[ "$output" == *"Wiederherstellen: 3 von 3 Sessions"* ]]
  [[ "$output" == *"  - a-1"*"  - b-2"* ]]
  [[ "$output" != *"  - c-3"* ]]
  [[ "$output" != *"woanders"* ]]
  [[ "$output" != *"Nicht wiederherstellbar"* ]]
}

@test "summary lists drifted and not-restorable rows" {
  printf '%s\n' $'a-1\t1\t/x\tok\t\tS1\tidle\t/x/.worktrees/w\t' $'z-9\t9\t/x\tskip\tkeine Session-Datei\t\t\t\t' >"$f"
  run cr_restart_summary "$f"
  [[ "$output" == *"  - a-1 → /x/.worktrees/w"* ]]
  [[ "$output" == *"  - z-9: keine Session-Datei"* ]]
  [[ "$output" == *"Wiederherstellen: 1 von 2 Sessions"* ]]
  [[ "$output" != *"Mitten in einer Antwort"* ]]
}

@test "summary of a snapshot without rows says only anchor and server restart" {
  : >"$f"
  run cr_restart_summary "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "Keine Sessions – nur Anchor und tmux-Server werden neu gestartet." ]
}

@test "summary ignores status of skip rows" {
  printf '%s\n' $'z-9\t9\t/x\tskip\tkeine Session-ID\tS9\tbusy\t\t' >"$f"
  run cr_restart_summary "$f"
  [[ "$output" != *"Mitten in einer Antwort"* ]]
  [[ "$output" == *"Wiederherstellen: 0 von 1 Sessions"* ]]
}

@test "guard: inside the same server is refused, elsewhere allowed" {
  $CR_TMUX new-session -d -s x
  sock="$($CR_TMUX display-message -p '#{socket_path}')"
  run env TMUX="$sock,1,0" bash -c "source '${REPO_ROOT}/lib/claude-remote-lib.sh'; CR_TMUX='$CR_TMUX'; cr_restart_inside_server"
  [ "$status" -eq 0 ]
  run env TMUX="/other/sock,1,0" bash -c "source '${REPO_ROOT}/lib/claude-remote-lib.sh'; CR_TMUX='$CR_TMUX'; cr_restart_inside_server"
  [ "$status" -ne 0 ]
  run env -u TMUX bash -c "source '${REPO_ROOT}/lib/claude-remote-lib.sh'; CR_TMUX='$CR_TMUX'; cr_restart_inside_server"
  [ "$status" -ne 0 ]
}

@test "guard: production shape (no -L) asks the target server, not the one named by TMUX" {
  # CR_TMUX without -L/-S resolves its socket from $TMUX when that is set, so the
  # guard must query with TMUX removed. The default socket is isolated via TMUX_TMPDIR
  # and fenced; teardown ends both servers by their socket paths.
  cr_prod_setup
  local prod="tmux -f /dev/null" other="tmux -f /dev/null -L other_$$" tsock osock
  $prod new-session -d -s target
  cr_prod_fence $prod
  $other new-session -d -s other
  cr_prod_fence $other
  tsock="$($prod display-message -p '#{socket_path}')"
  osock="$($other display-message -p '#{socket_path}')"
  local lib="${REPO_ROOT}/lib/claude-remote-lib.sh"
  run env TMUX="$osock,1,0" bash -c "source '$lib'; CR_TMUX='$prod'; cr_restart_inside_server"
  [ "$status" -ne 0 ]
  run env TMUX="$tsock,1,0" bash -c "source '$lib'; CR_TMUX='$prod'; cr_restart_inside_server"
  [ "$status" -eq 0 ]
}

@test "the production-shape fence refuses a socket outside TMUX_TMPDIR" {
  # The suite's own -L server lives outside the isolated dir: the fence must refuse it,
  # and must refuse anything while TMUX is set or TMUX_TMPDIR is not.
  $CR_TMUX new-session -d -s outside
  local outside
  outside="$($CR_TMUX display-message -p '#{socket_path}')"
  cr_prod_setup
  run cr_prod_fence tmux -S "$outside"
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside $TMUX_TMPDIR"* ]]
  tmux -f /dev/null new-session -d -s inside
  run cr_prod_fence tmux -f /dev/null
  [ "$status" -eq 0 ]
  TMUX="$outside,1,0" run cr_prod_fence tmux -f /dev/null
  [ "$status" -ne 0 ]
  local keep=$TMUX_TMPDIR
  TMUX_TMPDIR="" run cr_prod_fence tmux -S "$keep/tmux-$(id -u)/default"
  [ "$status" -ne 0 ]
}
