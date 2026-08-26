#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's shared fixture-tempdir helper
# (fm_test_tmproot / fm_test_cleanup / fm_test_reap_orphans).
#
# The near-universal call pattern across this suite is
# `TMP_ROOT=$(fm_test_tmproot prefix)`, which forks a subshell to capture the
# function's stdout. These tests spawn real, separate bash processes that use
# that exact pattern and assert the fixture root is actually gone once the
# owning process's guarded teardown has run - on a normal exit and on a
# terminating signal - plus that a stale marked fixture from a killed prior
# run gets reaped on the next source. Nothing here inspects tests/lib.sh's
# source text; it only observes filesystem state around the real helper.
#
# It also pins the two guards that keep that teardown from removing the working
# directory. A test file copied out of tests/ cannot resolve `. lib.sh`, and bash
# treats that failed source as an ordinary non-zero return: the file used to keep
# running with fm_test_tmproot undefined, so `TMP_ROOT=$(fm_test_tmproot pfx)`
# became the empty string and the widespread `TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)`
# idiom then turned it into $PWD, which the file's own EXIT trap `rm -rf`d. That
# really happened, to a live task worktree. Both halves are covered because they
# fail independently: fm_test_rmtree refuses any path outside the fixture temp
# root (empty or not), and every lib-dependent file aborts at its source line.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

LIB="$ROOT/tests/lib.sh"

test_fixture_root_gone_after_normal_exit() {
  local child_out child_dir
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-exit)
    printf "%s\n" "$d"
    if [ -d "$d" ]; then printf "mid:present\n"; else printf "mid:missing\n"; fi
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  assert_contains "$child_out" "mid:present" \
    "the fixture root was not present while its owning process was still alive"
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived its owning process's normal exit"
  pass "fm_test_tmproot cleans up its fixture root on normal exit"
}

test_fixture_root_gone_after_sigterm() {
  local harness dirfile child_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-sigterm-harness)
  dirfile="$harness/child-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-term)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the child never published its fixture root before the wait timed out"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the child's fixture root did not exist before it was signaled"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived SIGTERM to its owning process"
  pass "fm_test_tmproot cleans up its fixture root on SIGTERM"
}

test_cleanup_registry_resists_precreation() {
  local harness shared_tmp victim
  harness=$(fm_test_tmproot fm-test-cleanup-registry-harness)
  shared_tmp="$harness/shared-tmp"
  victim="$harness/victim"
  mkdir -p "$shared_tmp" "$victim"

  TMPDIR="$shared_tmp" bash -c '
    printf "%s\n" "$1" > "$TMPDIR/.fm-test-cleanup.$$"
    . "$2"
  ' _ "$victim" "$LIB"

  assert_present "$victim" \
    "a precreated predictable cleanup registry injected an arbitrary deletion target"
  pass "the cleanup registry cannot be injected through path precreation"
}

test_fixture_registration_failure_rolls_back_root() {
  local harness failure_tmp registry_dir output leaked_root
  harness=$(fm_test_tmproot fm-test-cleanup-registration-harness)
  failure_tmp="$harness/tmp"
  registry_dir="$harness/registry-dir"
  mkdir -p "$failure_tmp" "$registry_dir"

  if output=$(TMPDIR="$failure_tmp" FM_TEST_CLEANUP_REGISTRY="$registry_dir" \
    fm_test_tmproot fm-test-cleanup-registration-failure 2>/dev/null); then
    fail "fm_test_tmproot succeeded after its cleanup registry rejected registration"
  fi
  [ -z "$output" ] || fail "fm_test_tmproot published an unregistered fixture root"
  for leaked_root in "$failure_tmp"/fm-test-cleanup-registration-failure.*; do
    [ ! -e "$leaked_root" ] || fail "fm_test_tmproot leaked a root after registration failed"
  done
  pass "failed fixture registration rolls back the new root"
}

test_orphan_sweep_respects_fixture_ownership() {
  local harness dirfile active_dir stale_dir fresh_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-orphan-harness)
  dirfile="$harness/active-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-active)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the active child never published its fixture root before the wait timed out"
  active_dir=$(cat "$dirfile")
  touch -t 202001010000 "$active_dir/.fm-test-fixture"

  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-stale.XXXXXX")
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"
  fresh_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-fresh.XXXXXX")
  : > "$fresh_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
  '

  assert_absent "$stale_dir" \
    "a stale fixture root whose PID was reused by another process was not reaped"
  assert_present "$active_dir" \
    "the orphan reaper removed an old fixture root whose owning process was still alive"
  assert_present "$fresh_dir" \
    "the orphan reaper removed a fresh marked fixture root it does not own yet"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$active_dir" \
    "the active fixture root survived its owning process's teardown"
  rm -rf "$fresh_dir"
  pass "the orphan sweep reaps only old fixtures without a live owner"
}

test_rmtree_refuses_an_empty_fixture_path() {
  local harness victim out
  harness=$(fm_test_tmproot fm-test-rmtree-empty)
  victim="$harness/victim"
  mkdir -p "$victim"
  printf 'precious\n' > "$victim/canary"

  # Run from inside the victim, so an empty path that degrades to the working
  # directory would take the canary with it.
  if out=$(cd "$victim" && bash -c '
    . "$1" || exit 1
    UNSET_ROOT=
    fm_test_rmtree "$UNSET_ROOT"
  ' _ "$LIB" 2>&1); then
    fail "fm_test_rmtree accepted an empty fixture path"$'\n'"--- output ---"$'\n'"$out"
  fi
  assert_contains "$out" "refused an empty fixture path" \
    "fm_test_rmtree refused an empty path without saying so"
  assert_present "$victim/canary" \
    "an empty fixture path reached rm -rf and removed the working directory"
  pass "fm_test_rmtree refuses an empty fixture path"
}

test_rmtree_refuses_a_path_outside_the_fixture_temp_root() {
  local harness fixture_tmp victim out
  harness=$(fm_test_tmproot fm-test-rmtree-outside)
  fixture_tmp="$harness/tmp"
  victim="$harness/victim"
  mkdir -p "$fixture_tmp" "$victim"
  printf 'precious\n' > "$victim/canary"

  # The child allocates fixtures under $fixture_tmp, so $victim is a perfectly
  # ordinary non-empty absolute path that is nonetheless outside the temp root
  # this suite owns. Non-empty is not the same as safe.
  if out=$(TMPDIR="$fixture_tmp" bash -c '
    . "$1" || exit 1
    fm_test_rmtree "$2"
  ' _ "$LIB" "$victim" 2>&1); then
    fail "fm_test_rmtree accepted a path outside the fixture temp root"$'\n'"--- output ---"$'\n'"$out"
  fi
  assert_contains "$out" "outside the fixture temp root" \
    "fm_test_rmtree refused an out-of-root path without saying so"
  assert_present "$victim/canary" \
    "a non-empty path outside the fixture temp root still reached rm -rf"
  pass "fm_test_rmtree refuses a non-empty path outside the fixture temp root"
}

test_rmtree_refuses_the_working_directory_an_unset_root_resolves_to() {
  local harness fixture_tmp workdir workdir_phys out
  harness=$(fm_test_tmproot fm-test-rmtree-pwd)
  fixture_tmp="$harness/tmp"
  workdir="$harness/work"
  mkdir -p "$fixture_tmp" "$workdir"
  printf 'precious\n' > "$workdir/canary"
  workdir_phys=$(cd "$workdir" && pwd -P)

  # The incident's exact value chain, driven through the real helper: `cd ""`
  # succeeds as a no-op, so an unset TMP_ROOT resolves to the working directory.
  if out=$(cd "$workdir" && TMPDIR="$fixture_tmp" bash -c '
    . "$1" || exit 1
    TMP_ROOT=
    TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
    printf "resolved:%s\n" "$TMP_ROOT"
    fm_test_rmtree "$TMP_ROOT"
  ' _ "$LIB" 2>&1); then
    fail "fm_test_rmtree accepted the working directory an unset root resolved to"$'\n'"--- output ---"$'\n'"$out"
  fi
  # Assert the divergence itself, so this case cannot go quietly vacuous if the
  # idiom ever stops producing the working directory.
  assert_contains "$out" "resolved:$workdir_phys" \
    "an unset TMP_ROOT no longer resolves to the working directory, so this case proves nothing"
  assert_present "$workdir/canary" \
    "the working directory an unset TMP_ROOT resolved to was removed"
  pass "fm_test_rmtree refuses the working directory an unset TMP_ROOT resolves to"
}

test_lib_dependent_files_refuse_to_run_outside_tests() {
  local harness file base sandbox before after out checked=0
  harness=$(fm_test_tmproot fm-test-outside-tests)

  # Discovery, not assertion: select every file in tests/ that DECLARES a
  # dependency on a tests/-local helper, guarded or not, so the sweep cannot
  # grade its own fix by only selecting files that already carry the guard.
  # Every assertion below is filesystem state and process output.
  while IFS= read -r file; do
    base=$(basename "$file")
    sandbox="$harness/out/$base"
    mkdir -p "$sandbox"
    printf 'precious uncommitted work\n' > "$sandbox/canary.txt"
    cp "$file" "$sandbox/copy.test.sh"
    before=$(find "$sandbox" -mindepth 1 -maxdepth 1 | sort)
    out=$(cd "$sandbox" && bash ./copy.test.sh 2>&1)
    assert_present "$sandbox/canary.txt" \
      "$base removed its working directory when run from outside tests/"
    # Refusing means stopping at the unresolvable source line, not carrying on
    # with undefined helpers - so the working directory must be untouched in
    # both directions. A file that kept going scatters its fixture tree here.
    after=$(find "$sandbox" -mindepth 1 -maxdepth 1 2>/dev/null | sort)
    [ "$after" = "$before" ] || fail \
      "$base kept running outside tests/ and changed its working directory"$'\n'"--- before ---"$'\n'"$before"$'\n'"--- after ---"$'\n'"$after"
    # A file that actually ran would report at least one passing check. Refusing
    # covers both shapes this takes: aborting at the unresolvable source line,
    # and an opt-in guard declining to run at all.
    assert_not_contains "$out" 'ok - ' \
      "$base ran real checks from outside tests/ instead of refusing"
    checked=$((checked + 1))
  done < <(grep -lE '^\. "\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/[a-z-]+\.sh"' "$ROOT"/tests/*.sh)

  [ "$checked" -ge 100 ] || fail \
    "the outside-tests sweep only found $checked dependent files; its discovery step went vacuous"
  pass "every tests/lib.sh-dependent file refuses to run outside tests/ ($checked files)"
}

test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_rmtree_refuses_an_empty_fixture_path
test_rmtree_refuses_a_path_outside_the_fixture_temp_root
test_rmtree_refuses_the_working_directory_an_unset_root_resolves_to
test_lib_dependent_files_refuse_to_run_outside_tests
