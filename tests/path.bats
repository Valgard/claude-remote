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
