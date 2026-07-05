load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "cr_anchor_plist (app) emits open + app path, no --ensure-anchor" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_anchor_plist "de.valgard.claude-remote-anchor" "/usr/bin/open" "/x/ClaudeRemoteAnchor.app" 60
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "/usr/bin/open"
  echo "$output" | grep -q "ClaudeRemoteAnchor.app"
  echo "$output" | grep -q "<integer>60</integer>"
  echo "$output" | grep -q "de.valgard.claude-remote-anchor"
  ! echo "$output" | grep -q -- "--ensure-anchor"
}

@test "cr_anchor_plist (degrade) emits --ensure-anchor, no open" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_anchor_plist "de.valgard.claude-remote-anchor" "/x/claude-remote-pick" "--ensure-anchor" 60
  echo "$output" | grep -q -- "--ensure-anchor"
  ! echo "$output" | grep -q "/usr/bin/open"
}

@test "cr_anchor_app_needs_build: missing binary needs build" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  src="$(mktemp)"
  bin="$(mktemp -u)"
  run cr_anchor_app_needs_build "$src" "$bin"
  [ "$status" -eq 0 ]
}

@test "cr_anchor_app_needs_build: up-to-date binary skips build" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  src="$(mktemp)"
  bin="$(mktemp)"
  chmod +x "$bin"
  touch -t 202001010000 "$src" # src older than bin
  run cr_anchor_app_needs_build "$src" "$bin"
  [ "$status" -eq 1 ]
}

@test "cr_anchor_app_needs_build: source newer than binary needs build" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  src="$(mktemp)"
  bin="$(mktemp)"
  chmod +x "$bin"
  touch -t 202001010000 "$bin" # bin older than src
  run cr_anchor_app_needs_build "$src" "$bin"
  [ "$status" -eq 0 ]
}
