load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

# cr_resolve_new_dir maps the picker's "neue Session" directory prompt to a
# "<kind>\t<dir>" pair. kind is "bare" only for the ergonomic shortcut (a plain
# project name under $CR_NEW_DIR), so the caller may offer to create it; every
# other form is "path" and must already exist.

@test "cr_resolve_new_dir: empty input falls back to CR_NEW_DIR" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  CR_NEW_DIR=/tmp/proj run cr_resolve_new_dir ""
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'path\t/tmp/proj')" ]
}

@test "cr_resolve_new_dir: a bare name becomes CR_NEW_DIR/<name> tagged bare" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  CR_NEW_DIR=/tmp/proj run cr_resolve_new_dir "myapp"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'bare\t/tmp/proj/myapp')" ]
}

@test "cr_resolve_new_dir: a bare name expands a tilde in CR_NEW_DIR" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  CR_NEW_DIR='~/Projects' run cr_resolve_new_dir "myapp"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'bare\t%s/Projects/myapp' "$HOME")" ]
}

@test "cr_resolve_new_dir: a bare-looking ~ is home, not a project name" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_resolve_new_dir "~"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'path\t%s' "$HOME")" ]
}

@test "cr_resolve_new_dir: ~/foo expands to \$HOME/foo as a path" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_resolve_new_dir "~/foo"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'path\t%s/foo' "$HOME")" ]
}

@test "cr_resolve_new_dir: \$HOME/foo expands as a path" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_resolve_new_dir '$HOME/foo'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'path\t%s/foo' "$HOME")" ]
}

@test "cr_resolve_new_dir: an absolute path is left as a path" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  run cr_resolve_new_dir "/tmp/x"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'path\t/tmp/x')" ]
}

@test "cr_resolve_new_dir: a relative path with a slash is not a bare name" {
  source "${REPO_ROOT}/lib/claude-remote-lib.sh"
  CR_NEW_DIR=/tmp/proj run cr_resolve_new_dir "sub/x"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'path\tsub/x')" ]
}
