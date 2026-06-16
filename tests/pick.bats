load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

LIB="${REPO_ROOT}/lib/claude-remote-lib.sh"

# --- numbered menu ---

@test "cr_pick_numbered maps a numeric choice to the session key" {
  run bash -c "source '$LIB'; printf '1\n' | cr_pick_numbered '' \$'sess-one\tproj one' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "sess-one" ]
}

@test "cr_pick_numbered: q returns __QUIT__" {
  run bash -c "source '$LIB'; printf 'q\n' | cr_pick_numbered '' \$'sess-one\tproj one' 2>/dev/null"
  [ "$output" = "__QUIT__" ]
}

@test "cr_pick_numbered: the new-session index returns __NEW__" {
  # one session -> new-session entry is index 2
  run bash -c "source '$LIB'; printf '2\n' | cr_pick_numbered '' \$'sess-one\tproj one' 2>/dev/null"
  [ "$output" = "__NEW__" ]
}

@test "cr_pick_numbered: an out-of-range choice returns __NONE__ (redraw)" {
  run bash -c "source '$LIB'; printf '99\n' | cr_pick_numbered '' \$'sess-one\tproj one' 2>/dev/null"
  [ "$output" = "__NONE__" ]
}

@test "cr_pick_numbered: with no sessions, choice 1 is the new-session entry" {
  run bash -c "source '$LIB'; printf '1\n' | cr_pick_numbered '' 2>/dev/null"
  [ "$output" = "__NEW__" ]
}

# --- fzf path (real fzf interaction is manual; here we stub fzf to test mapping) ---

@test "cr_pick_fzf maps the fzf-selected line to its session key" {
  stub="$(mktemp -d)"
  cat >"$stub/fzf" <<'STUB'
#!/bin/bash
# Ignore options, read candidates from stdin, emit the one for sess-two.
grep -m1 'sess-two' || true
STUB
  chmod +x "$stub/fzf"
  export PATH="$stub:$PATH"
  run bash -c "source '$LIB'; cr_pick_fzf '' \$'sess-one\tproj one' \$'sess-two\tproj two' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "sess-two" ]
}

@test "cr_pick_fzf returns __QUIT__ when fzf is cancelled" {
  stub="$(mktemp -d)"
  printf '#!/bin/bash\nexit 130\n' >"$stub/fzf"
  chmod +x "$stub/fzf"
  export PATH="$stub:$PATH"
  run bash -c "source '$LIB'; cr_pick_fzf '' \$'sess-one\tproj one' 2>/dev/null"
  [ "$output" = "__QUIT__" ]
}
