#!/usr/bin/env bash
# Tests for bin/fm-main-guard.sh: the registered watcher check that notices a
# managed repository's default branch has moved and, when the new tip fails that
# project's OWN pinned static check, wakes firstmate with one line.
#
# This is the backstop to the merge-time guard: it covers a merge done by hand
# on the forge, and the seconds-wide race the merge-time check cannot close.
# The two share bin/fm-static-guard-lib.sh, so both suites drive the same
# fixture from tests/static-guard-helpers.sh.
#
# Matrix:
#   (a) arming binds the check's bytes, so the watcher will execute it
#   (b) arming refuses a project with no discoverable static check
#   (c) a green tip produces no wake line at all
#   (d) a tip that fails the project's check produces exactly one wake line and
#       keeps the checker's output where the line says it is
#   (e) the same red tip is not re-reported on the next poll
#   (f) a later green tip is silent again and retires the stale output
#   (g) the watcher's own snapshot step accepts the check and it reports from there
#   (h) disarming removes the check, its binding, and its private state
#   (i) disarming refuses, rather than follows, a state artifact it did not write
set -u

# shellcheck source=tests/static-guard-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/static-guard-helpers.sh" || exit 1
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-check-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

GUARD="$ROOT/bin/fm-main-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-main-guard-tests)

make_case() {  # <name> [plain|nocheck]
  local name=$1 variant=${2:-plain} case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"
  fm_sg_make_project "$case_dir" "$variant"
  printf '%s\n' "$case_dir"
}

arm() {  # <case_dir> <id>
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$1/state" \
    "$GUARD" arm "$2" "$1/work"
}

# Run the armed check exactly as the watcher does: `bash <file>`, with nothing
# from firstmate's environment carried in.
run_check() {  # <check-path>
  env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE bash "$1"
}

test_arming_binds_the_check() {
  local case_dir out
  case_dir=$(make_case arming)
  out=$(arm "$case_dir" main-guard-alpha) || fail "arming: fm-main-guard.sh arm failed"

  assert_contains "$out" "armed: main-guard-alpha" "arming: the armed line did not name the check"
  assert_contains "$out" "./check.sh" "arming: the discovered check command was not reported"
  assert_present "$case_dir/state/main-guard-alpha.check.sh" "arming: no check was written"
  [ "$(fm_pr_file_mode "$case_dir/state/main-guard-alpha.check.sh")" = 700 ] \
    || fail "arming: the check is not a mode-0700 file"
  [ "$(fm_pr_file_link_count "$case_dir/state/main-guard-alpha.check.sh")" = 1 ] \
    || fail "arming: the check is not a single-link file"
  fm_task_script_registered "$case_dir/state" main-guard-alpha check \
    || fail "arming: the check's bytes were not bound, so the watcher would refuse it"
  pass "arming writes a mode-0700 single-link check and binds its bytes for the watcher"
}

test_arming_refuses_without_a_static_check() {
  local case_dir rc
  case_dir=$(make_case no-check nocheck)
  set +e
  arm "$case_dir" main-guard-nocheck > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "no-check: arming should refuse a project with no discoverable check"
  assert_grep 'no static check discovered' "$case_dir/err" \
    "no-check: the refusal did not say what was missing"
  assert_absent "$case_dir/state/main-guard-nocheck.check.sh" \
    "no-check: a check was armed that can never reach a verdict"
  pass "arming refuses a project whose static check cannot be discovered"
}

test_green_tip_is_silent_and_red_tip_wakes_once() {
  local case_dir check out lines
  case_dir=$(make_case lifecycle)
  arm "$case_dir" main-guard-beta > /dev/null || fail "lifecycle: arming failed"
  check="$case_dir/state/main-guard-beta.check.sh"

  out=$(run_check "$check") || fail "lifecycle: the check failed on a green tip"
  [ -z "$out" ] || fail "lifecycle: a green default branch produced output: $out"
  assert_present "$case_dir/state/main-guard-beta.main-guard-seen" \
    "lifecycle: the evaluated tip was not recorded"

  out=$(run_check "$check") || fail "lifecycle: the check failed on an unchanged tip"
  [ -z "$out" ] || fail "lifecycle: an unchanged tip produced output: $out"

  fm_sg_break_main "$case_dir"
  out=$(run_check "$check") || fail "lifecycle: the check failed on a red tip"
  lines=$(printf '%s\n' "$out" | grep -c .)
  [ "$lines" = 1 ] || fail "lifecycle: a red tip must wake with exactly one line, got $lines: $out"
  assert_contains "$out" "work main@" "lifecycle: the wake line did not name the project and branch"
  assert_contains "$out" "fails the project static check" \
    "lifecycle: the wake line did not say what happened"
  assert_contains "$out" "main-guard-output" "lifecycle: the wake line did not point at the output"
  assert_grep 'undefined name: USE_OLD' "$case_dir/state/main-guard-beta.main-guard-output" \
    "lifecycle: the checker's output was not kept"

  out=$(run_check "$check") || fail "lifecycle: the check failed re-polling the same red tip"
  [ -z "$out" ] || fail "lifecycle: the same red tip woke firstmate twice: $out"

  fm_sg_repair_main "$case_dir"
  out=$(run_check "$check") || fail "lifecycle: the check failed on the repaired tip"
  [ -z "$out" ] || fail "lifecycle: a repaired default branch still produced output: $out"
  assert_absent "$case_dir/state/main-guard-beta.main-guard-output" \
    "lifecycle: the stale red output survived a repaired default branch"
  pass "the detector is silent while the default branch is green and wakes once per red tip"
}

test_check_runs_from_a_watcher_style_snapshot() {
  local case_dir snapshot out
  case_dir=$(make_case snapshot)
  arm "$case_dir" main-guard-gamma > /dev/null || fail "snapshot: arming failed"
  run_check "$case_dir/state/main-guard-gamma.check.sh" > /dev/null \
    || fail "snapshot: the first poll failed"

  fm_sg_break_main "$case_dir"
  # Exactly what the watcher does before running a custom check: verify the
  # binding and copy the bytes to a private, differently named snapshot.
  fm_task_script_snapshot_prepare "$case_dir/state" main-guard-gamma check \
    || fail "snapshot: the watcher's own snapshot step refused the armed check"
  snapshot=$FM_TASK_SCRIPT_SNAPSHOT
  out=$(run_check "$snapshot") || fail "snapshot: the check failed when run from the snapshot"
  fm_task_script_snapshot_cleanup
  assert_contains "$out" "fails the project static check" \
    "snapshot: the check did not report from the snapshot the watcher runs"
  pass "the armed check reports the same way from the private snapshot the watcher executes"
}

test_disarm_removes_every_artifact() {
  local case_dir
  case_dir=$(make_case disarm)
  arm "$case_dir" main-guard-delta > /dev/null || fail "disarm: arming failed"
  run_check "$case_dir/state/main-guard-delta.check.sh" > /dev/null || fail "disarm: the poll failed"

  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    "$GUARD" disarm main-guard-delta > /dev/null || fail "disarm: disarming failed"

  assert_absent "$case_dir/state/main-guard-delta.check.sh" "disarm: the check survived"
  assert_absent "$case_dir/state/main-guard-delta.check-trust" "disarm: the binding survived"
  assert_absent "$case_dir/state/main-guard-delta.main-guard" "disarm: the configuration survived"
  assert_absent "$case_dir/state/main-guard-delta.main-guard-seen" "disarm: the recorded tip survived"
  pass "disarming removes the check, its binding, and its private state"
}

test_disarm_refuses_an_artifact_it_did_not_write() {
  local case_dir outside rc
  case_dir=$(make_case disarm-symlink)
  arm "$case_dir" main-guard-eps > /dev/null || fail "disarm-symlink: arming failed"

  # Something replaced one artifact with a link out of the state directory.
  outside="$case_dir/outside.txt"
  printf 'keep me\n' > "$outside"
  rm -f "$case_dir/state/main-guard-eps.main-guard-seen"
  ln -s "$outside" "$case_dir/state/main-guard-eps.main-guard-seen"

  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    "$GUARD" disarm main-guard-eps > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  expect_code 1 "$rc" "disarm-symlink: disarming should refuse an artifact it did not write"
  assert_grep 'not a plain guard artifact' "$case_dir/err" \
    "disarm-symlink: the refusal did not say what it would not touch"
  [ -f "$outside" ] && [ "$(cat "$outside")" = 'keep me' ] \
    || fail "disarm-symlink: removal followed a link out of the state directory"
  pass "disarming refuses a state artifact that is not a plain file it wrote"
}

test_arming_binds_the_check
test_arming_refuses_without_a_static_check
test_green_tip_is_silent_and_red_tip_wakes_once
test_check_runs_from_a_watcher_style_snapshot
test_disarm_removes_every_artifact
test_disarm_refuses_an_artifact_it_did_not_write
