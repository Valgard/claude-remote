load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

@test "cr_augment_path appends an existing tool dir to a minimal PATH" {
  fakehome="$(mktemp -d)"
  mkdir -p "$fakehome/.local/bin"
  run env HOME="$fakehome" PATH="/usr/bin:/bin" bash -c \
    "source '${REPO_ROOT}/lib/claude-remote-lib.sh'; cr_augment_path; printf '%s' \"\$PATH\""
  [ "$status" -eq 0 ]
  # original entries keep priority (appended, not prepended)
  [[ "$output" == "/usr/bin:/bin"* ]]
  # the existing tool dir was added
  [[ "$output" == *":$fakehome/.local/bin"* ]]
}

@test "cr_augment_path orders ~/.local/bin before /opt/homebrew/bin (user-pinned binary wins)" {
  # A version pinned into ~/.local/bin (e.g. a specific native claude) must win
  # over a Homebrew cask of the same tool, regardless of launch path. Among the
  # dirs cr_augment_path adds, the user-local bin must therefore precede Homebrew.
  [ -d /opt/homebrew/bin ] || skip "no /opt/homebrew/bin on this host"
  fakehome="$(mktemp -d)"
  mkdir -p "$fakehome/.local/bin"
  run env HOME="$fakehome" PATH="/usr/bin:/bin" bash -c \
    "source '${REPO_ROOT}/lib/claude-remote-lib.sh'; cr_augment_path; printf '%s' \"\$PATH\""
  [ "$status" -eq 0 ]
  # the part of PATH before /opt/homebrew/bin must already contain ~/.local/bin
  [[ "${output%%/opt/homebrew/bin*}" == *"$fakehome/.local/bin"* ]]
}

@test "cr_augment_path does not add a non-existent dir and does not duplicate" {
  fakehome="$(mktemp -d)" # no .local/bin or local/bin created
  run env HOME="$fakehome" PATH="/usr/bin:/bin" bash -c \
    "source '${REPO_ROOT}/lib/claude-remote-lib.sh'; cr_augment_path; cr_augment_path; printf '%s' \"\$PATH\""
  [ "$status" -eq 0 ]
  # non-existent fake home dirs are not appended
  [[ "$output" != *"$fakehome"* ]]
  # idempotent: /opt/homebrew/bin (if present) appears at most once
  count="$(awk -F'/opt/homebrew/bin' '{print NF-1}' <<<"$output")"
  [ "$count" -le 1 ]
}
