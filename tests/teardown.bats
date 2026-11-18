#!/usr/bin/env bats
load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

# tmux leaves its socket file behind when the server exits (tmux 3.8), so cr_teardown
# deletes it: otherwise every test that starts a server leaves one dead cr_test_* file
# in /tmp/tmux-<uid>.

# server_gone <pid>: true once <pid> has exited (kill-server returns before it does).
server_gone() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.2
  done
  return 1
}

@test "cr_setup records the socket file the -L server actually uses" {
  cr_make_session s >/dev/null
  local real
  real="$($CR_TMUX display-message -p '#{socket_path}')"
  # tmux reports the path with symlinks resolved (/tmp -> /private/tmp on macOS).
  [ "$(cd "$(dirname "$CR_SOCKET_FILE")" && pwd -P)/$(basename "$CR_SOCKET_FILE")" = "$real" ]
}

@test "cr_teardown ends the -L server and removes its socket file" {
  cr_make_session s >/dev/null
  local pid
  pid="$($CR_TMUX display-message -p '#{pid}')"
  [ -S "$CR_SOCKET_FILE" ]
  cr_teardown
  [ ! -e "$CR_SOCKET_FILE" ]
  server_gone "$pid"
}

@test "cr_teardown ends the -L server even while CR_TMUX names a stand-in" {
  # As a test leaves it when it fails before restoring CR_TMUX.
  cr_make_session s >/dev/null
  local pid
  pid="$($CR_TMUX display-message -p '#{pid}')"
  export CR_TMUX="$(stub tmux-nokill 'exit 0')"
  cr_teardown
  server_gone "$pid"
  [ ! -e "$CR_SOCKET_FILE" ]
}

@test "cr_teardown ends the -L server even with a tmux stub first on PATH" {
  cr_make_session s >/dev/null
  local pid
  pid="$($CR_TMUX display-message -p '#{pid}')"
  stub tmux 'exit 0' >/dev/null
  # bash has hashed tmux by now and would bypass the stub; forget it, as for a test
  # that put its stub in place before its first tmux call.
  hash -r
  cr_teardown
  server_gone "$pid"
  [ ! -e "$CR_SOCKET_FILE" ]
}

@test "cr_teardown ends a -L server started before cr_prod_setup" {
  cr_make_session s >/dev/null
  local pid
  pid="$($CR_TMUX display-message -p '#{pid}')"
  cr_prod_setup
  cr_teardown
  server_gone "$pid"
  [ ! -e "$CR_SOCKET_FILE" ]
}

@test "cr_teardown fails and keeps the socket while the server survives" {
  cr_make_session s >/dev/null
  local real=$CR_REAL_TMUX
  CR_REAL_TMUX="$(stub tmux-ignore 'exit 0')"
  run cr_teardown
  CR_REAL_TMUX=$real
  [ "$status" -eq 1 ]
  grep -qF -- "still accepts on $CR_SOCKET_FILE" <<<"$output"
  [ -S "$CR_SOCKET_FILE" ]
  # The socket still reaches the server, so the file's teardown can end it.
  $CR_TMUX has-session -t s
}
