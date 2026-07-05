#!/usr/bin/env bats
load helpers

setup() { cr_setup; }
teardown() {
  [ -n "${SUP_PID:-}" ] && kill "$SUP_PID" 2>/dev/null
  cr_teardown
}

# Poll up to ~5s for the anchor session to (dis)appear.
_wait_anchor() { # $1 = present|absent
  local want="$1" i
  for i in $(seq 1 50); do
    if $CR_TMUX has-session -t "$CR_ANCHOR" 2>/dev/null; then
      [ "$want" = present ] && return 0
    else
      [ "$want" = absent ] && return 0
    fi
    sleep 0.1
  done
  return 1
}

@test "--supervise-anchor births the anchor and self-heals after a kill" {
  CR_ANCHOR_INTERVAL=1 "${CR_REPO}/bin/claude-remote-pick" --supervise-anchor &
  SUP_PID=$!
  _wait_anchor present || { echo "anchor never born"; false; }
  $CR_TMUX kill-session -t "$CR_ANCHOR"
  _wait_anchor absent || { echo "anchor not killed"; false; }
  # next tick (interval=1s) must re-birth it
  _wait_anchor present || { echo "anchor not self-healed"; false; }
}
