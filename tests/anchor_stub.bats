#!/usr/bin/env bats
load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "cr-anchor-stub execs claude-remote-pick with --supervise-anchor" {
  command -v clang >/dev/null || skip "clang not available"
  # Fake claude-remote-pick records its argv, then exits 0.
  fake="${BATS_TEST_TMPDIR}/crp"
  cat >"$fake" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"${CRP_ARGV_OUT}"
EOF
  chmod +x "$fake"
  bin="${BATS_TEST_TMPDIR}/cr-anchor-stub"
  clang -O2 -DCRP_PATH="\"${fake}\"" -o "$bin" "${CR_REPO}/anchor-app/cr-anchor-stub.c"
  CRP_ARGV_OUT="${BATS_TEST_TMPDIR}/argv" "$bin"
  run cat "${BATS_TEST_TMPDIR}/argv"
  [ "$status" -eq 0 ]
  [ "$output" = "--supervise-anchor" ]
}
