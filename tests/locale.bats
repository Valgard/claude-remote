load helpers

setup() { cr_setup; }
teardown() { cr_teardown; }

# Helper: run cr_ensure_utf8_locale in a clean child shell with a controlled
# locale environment and print the resulting LANG. PATH keeps /usr/bin so the
# `locale`/`grep` the function relies on resolve.
run_ensure() {
  run env "$@" PATH="/usr/bin:/bin" bash -c \
    "source '${REPO_ROOT}/lib/claude-remote-lib.sh'; cr_ensure_utf8_locale; printf '%s' \"\${LANG:-}\""
}

@test "cr_ensure_utf8_locale sets a UTF-8 locale when none is present" {
  run_ensure LANG= LC_ALL= LC_CTYPE=
  [ "$status" -eq 0 ]
  # some UTF-8 locale was selected
  [[ "$output" == *.UTF-8 ]]
}

@test "cr_ensure_utf8_locale leaves an already-UTF-8 LANG untouched" {
  run_ensure LANG=fr_FR.UTF-8 LC_ALL= LC_CTYPE=
  [ "$status" -eq 0 ]
  # no-op: the existing UTF-8 locale is preserved, not replaced by the default
  [ "$output" = "fr_FR.UTF-8" ]
}

@test "cr_ensure_utf8_locale honours CR_LOCALE override" {
  run_ensure LANG= LC_ALL= LC_CTYPE= CR_LOCALE=en_US.UTF-8
  [ "$status" -eq 0 ]
  [ "$output" = "en_US.UTF-8" ]
}

@test "cr_ensure_utf8_locale skips an unavailable target and falls back" {
  run_ensure LANG= LC_ALL= LC_CTYPE= CR_LOCALE=zz_ZZ.UTF-8
  [ "$status" -eq 0 ]
  # the bogus locale is not installed, so a real UTF-8 fallback is used instead
  [ "$output" != "zz_ZZ.UTF-8" ]
  [[ "$output" == *.UTF-8 ]]
}
