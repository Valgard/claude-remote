load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "cr_sshd_running returns non-zero when the port is closed" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  # A high port nothing should be listening on.
  CR_SSH_PORT=59999 run cr_sshd_running
  [ "$status" -ne 0 ]
}

@test "cr_sshd_running returns zero when something is listening" {
  command -v python3 >/dev/null || skip "python3 not available"
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  portfile="$(mktemp)"
  python3 -c 'import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen()
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
time.sleep(10)' "$portfile" &
  local pid=$!
  # Wait until the listener has written its port.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$portfile" ] && break
    sleep 0.2
  done
  local port
  port="$(cat "$portfile")"
  CR_SSH_PORT="$port" run cr_sshd_running
  kill "$pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
}
