#!/usr/bin/env bash
# Tests for the merge-time static guard in bin/fm-pr-merge.sh and the shared
# owner it runs on, bin/fm-static-guard-lib.sh.
#
# The defect being guarded: a PR's gate validates it against the base it was
# rebased onto, and where the forge runs no CI nothing ever validates the
# COMBINATION of that PR with whatever landed on the default branch in the
# meantime. Every fixture here is that shape - a rename on the default branch
# and a use of the old name in the PR, each side green on its own.
#
# Matrix:
#   (a) a merge result that fails the project's own check refuses the merge,
#       prints the checker's output, and records merge_guard=red
#   (b) a merge result that passes merges as before and records merge_guard=green
#   (c) non-vacuity: the same checker is GREEN on the default branch alone and
#       GREEN on the PR head alone, so (a) is red only for the combination
#   (d) a PR that conflicts with the current default branch is refused
#   (e) a project with no discoverable static check merges, loudly unguarded
#   (f) the check command is read from the default branch, so a PR that rewrites
#       its own .no-mistakes.yaml cannot disable the guard
#   (g) FM_MERGE_GUARD=off skips the guard and records merge_guard=off
#   (h) a forge that does not serve refs/pull/<n>/head still gets a verdict from
#       the recorded PR head
#   (i) recording the verdict leaves the task metadata re-readable, so a second
#       merge attempt on the same task still works
#   (j) recording the verdict leaves the armed merge poll valid to the watcher
#   (k) a Makefile lint: target is the second discovery source
#   (l) an unreachable forge degrades loudly instead of wedging every merge
set -u

# shellcheck source=tests/static-guard-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/static-guard-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-static-guard-tests)

# state dir, task meta pointing at the project, and forge mocks.
make_case() {
  local name=$1 variant=${2:-plain} case_dir fakebin head
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_sg_make_project "$case_dir" "$variant"
  head=$(fm_sg_git "$case_dir/work" rev-parse feat)
  fm_write_meta "$case_dir/state/task-g1.meta" \
    "window=fm-task-g1" \
    "worktree=$case_dir/work" \
    "project=$case_dir/work" \
    "kind=ship" \
    "mode=no-mistakes"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
  *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
  *baseRefName*) printf '%s\n' 'main' ; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh"
  : > "$case_dir/gh-axi.log"
  printf '%s\n' "$case_dir"
}

run_pr_merge() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
}

test_refuses_red_merge_result() {
  local case_dir rc
  case_dir=$(make_case red-merge-result)
  fm_sg_advance_main_rename "$case_dir"

  set +e
  run_pr_merge "$case_dir" task-g1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "red-merge-result: the merge should be refused"
  assert_grep 'merge refused' "$case_dir/stderr" \
    "red-merge-result: refusal did not say the merge was refused"
  assert_grep 'undefined name: USE_OLD' "$case_dir/stderr" \
    "red-merge-result: the checker's own output was not printed"
  assert_grep 'rebase onto current main and re-gate' "$case_dir/stderr" \
    "red-merge-result: refusal did not tell the lane what to do"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "red-merge-result: the PR was merged despite a red merge result"
  assert_grep 'merge_guard=red' "$case_dir/state/task-g1.meta" \
    "red-merge-result: the guard outcome was not recorded in task metadata"
  pass "the merge-time guard refuses a PR whose squash result fails the project's own check"
}

test_allows_green_merge_result() {
  local case_dir
  case_dir=$(make_case green-merge-result)
  fm_sg_advance_main_harmless "$case_dir"

  run_pr_merge "$case_dir" task-g1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "green-merge-result: fm-pr-merge failed: $(cat "$case_dir/stderr")"

  assert_grep 'pr merge 7 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    "green-merge-result: the PR was not merged"
  assert_grep 'merge-guard: green' "$case_dir/stdout" \
    "green-merge-result: the green verdict was not reported"
  assert_grep 'merge_guard=green' "$case_dir/state/task-g1.meta" \
    "green-merge-result: the guard outcome was not recorded in task metadata"
  pass "the merge-time guard merges a PR whose squash result passes the project's own check"
}

# The red case above must be red because of the COMBINATION, not because the
# fixture's checker fails on anything it is pointed at.
test_each_side_is_green_alone() {
  local case_dir work rc
  case_dir=$(make_case non-vacuity)
  fm_sg_advance_main_rename "$case_dir"
  work="$case_dir/work"

  set +e
  ( cd "$work" && git -c advice.detachedHead=false checkout -q main && ./check.sh ) > "$case_dir/main.out" 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "non-vacuity: the default branch alone should pass its own checker"

  set +e
  ( cd "$work" && git -c advice.detachedHead=false checkout -q feat && ./check.sh ) > "$case_dir/feat.out" 2>&1
  rc=$?
  set -e
  ( cd "$work" && git checkout -q main )
  expect_code 0 "$rc" "non-vacuity: the PR head alone should pass its own checker"
  pass "each side of the guarded merge is green on its own, so a red verdict is the combination"
}

test_refuses_conflicting_merge() {
  local case_dir rc
  case_dir=$(make_case conflicting-merge)
  fm_sg_advance_main_rename "$case_dir"
  fm_sg_make_conflicting_pr "$case_dir"

  set +e
  run_pr_merge "$case_dir" task-g1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "conflicting-merge: the merge should be refused"
  assert_grep 'conflicts with the current tip of main' "$case_dir/stderr" \
    "conflicting-merge: refusal did not name the conflict"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "conflicting-merge: a conflicted PR was merged"
  pass "a PR that conflicts with the current default branch is refused, not merged"
}

test_no_static_check_is_loudly_unguarded() {
  local case_dir
  case_dir=$(make_case no-static-check nocheck)
  fm_sg_advance_main_rename "$case_dir"

  run_pr_merge "$case_dir" task-g1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "no-static-check: fm-pr-merge failed: $(cat "$case_dir/stderr")"

  assert_grep 'UNGUARDED' "$case_dir/stderr" \
    "no-static-check: the degradation was not announced"
  assert_grep 'no static check discovered' "$case_dir/stderr" \
    "no-static-check: the reason was not named"
  assert_grep 'pr merge 7 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    "no-static-check: the merge did not proceed unguarded"
  assert_grep 'merge_guard=unguarded' "$case_dir/state/task-g1.meta" \
    "no-static-check: the unguarded outcome was not recorded in task metadata"
  pass "a project with no discoverable static check merges loudly unguarded, not silently"
}

test_pr_cannot_redirect_its_own_check() {
  local case_dir rc
  case_dir=$(make_case pr-owned-config prconfig)
  fm_sg_advance_main_rename "$case_dir"

  set +e
  run_pr_merge "$case_dir" task-g1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-owned-config: a PR rewriting its own check config still must not merge"
  assert_grep 'undefined name: USE_OLD' "$case_dir/stderr" \
    "pr-owned-config: the default branch's check command was not the one that ran"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "pr-owned-config: a PR disabled the guard by editing its own config"
  pass "the check command comes from the default branch, so a PR cannot disable the guard"
}

test_guard_off_is_recorded() {
  local case_dir
  case_dir=$(make_case guard-off)
  fm_sg_advance_main_rename "$case_dir"

  FM_MERGE_GUARD=off run_pr_merge "$case_dir" task-g1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "guard-off: fm-pr-merge failed: $(cat "$case_dir/stderr")"

  assert_grep 'OFF by FM_MERGE_GUARD=off' "$case_dir/stderr" \
    "guard-off: switching the guard off was not announced"
  assert_grep 'pr merge 7 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    "guard-off: the merge did not proceed"
  assert_grep 'merge_guard=off' "$case_dir/state/task-g1.meta" \
    "guard-off: the disabled guard was not recorded in task metadata"
  pass "FM_MERGE_GUARD=off skips the guard and records that it was skipped"
}

test_verdict_without_a_pull_ref() {
  local case_dir rc
  case_dir=$(make_case no-pull-ref)
  fm_sg_advance_main_rename "$case_dir"
  git -C "$case_dir/origin.git" update-ref -d refs/pull/7/head

  set +e
  run_pr_merge "$case_dir" task-g1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "no-pull-ref: the guard should still refuse the red merge result"
  assert_grep 'undefined name: USE_OLD' "$case_dir/stderr" \
    "no-pull-ref: the recorded PR head was not used to reach a verdict"
  assert_grep 'pr_head=' "$case_dir/state/task-g1.meta" \
    "no-pull-ref: the fixture never recorded a PR head to fall back to"
  pass "a forge that does not serve refs/pull/<n>/head still yields a verdict from the recorded head"
}

test_second_merge_attempt_still_records() {
  local case_dir rc
  case_dir=$(make_case rerun)
  fm_sg_advance_main_harmless "$case_dir"

  run_pr_merge "$case_dir" task-g1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout1" 2> "$case_dir/stderr1" \
    || fail "rerun: the first merge failed: $(cat "$case_dir/stderr1")"

  set +e
  run_pr_merge "$case_dir" task-g1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e

  expect_code 0 "$rc" "rerun: a second merge attempt on the same task must still work: $(cat "$case_dir/stderr2")"
  assert_grep 'merge_guard=green' "$case_dir/state/task-g1.meta" \
    "rerun: the guard outcome was lost on the second attempt"
  assert_grep 'pr=https://github.com/example/repo/pull/7' "$case_dir/state/task-g1.meta" \
    "rerun: the PR record was lost on the second attempt"
  pass "recording the guard outcome does not break a later merge attempt on the same task"
}

test_recorded_verdict_keeps_the_merge_poll_valid() {
  local case_dir
  case_dir=$(make_case poll-still-valid)
  fm_sg_advance_main_harmless "$case_dir"

  run_pr_merge "$case_dir" task-g1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "poll-still-valid: fm-pr-merge failed: $(cat "$case_dir/stderr")"

  # The watcher validates a task's armed merge poll against its metadata before
  # running it; a recorded verdict must not make that poll unreadable.
  fm_pr_poll_artifacts_valid "$case_dir/state" task-g1 "$ROOT/bin/fm-pr-poll.sh" \
    || fail "poll-still-valid: the armed merge poll no longer validates against the task's metadata"
  pass "recording the guard verdict leaves the armed merge poll valid to the watcher"
}

test_makefile_lint_target_is_the_second_source() {
  local case_dir rc
  case_dir=$(make_case makefile-source makefile)
  fm_sg_advance_main_rename "$case_dir"

  set +e
  run_pr_merge "$case_dir" task-g1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "makefile-source: the merge should be refused"
  assert_grep 'undefined name: USE_OLD' "$case_dir/stderr" \
    "makefile-source: the Makefile lint target was not discovered and run"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "makefile-source: the PR merged despite a red merge result"
  pass "a project declaring its check as a Makefile lint target is guarded too"
}

test_unreachable_forge_is_loudly_unguarded() {
  local case_dir
  case_dir=$(make_case unreachable-forge)
  fm_sg_advance_main_rename "$case_dir"
  # The forge is gone: the current default-branch tip cannot be read at all.
  mv "$case_dir/origin.git" "$case_dir/origin-moved.git"

  run_pr_merge "$case_dir" task-g1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "unreachable-forge: fm-pr-merge should not wedge on an unreachable forge: $(cat "$case_dir/stderr")"

  assert_grep 'UNGUARDED' "$case_dir/stderr" \
    "unreachable-forge: the degradation was not announced"
  assert_grep 'pr merge 7 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    "unreachable-forge: the merge did not proceed"
  assert_grep 'merge_guard=unguarded' "$case_dir/state/task-g1.meta" \
    "unreachable-forge: the unguarded outcome was not recorded in task metadata"
  pass "an unreachable forge degrades to a loud unguarded merge, not a wedge or a silent pass"
}

test_refuses_red_merge_result
test_allows_green_merge_result
test_each_side_is_green_alone
test_refuses_conflicting_merge
test_no_static_check_is_loudly_unguarded
test_pr_cannot_redirect_its_own_check
test_guard_off_is_recorded
test_verdict_without_a_pull_ref
test_second_merge_attempt_still_records
test_recorded_verdict_keeps_the_merge_poll_valid
test_makefile_lint_target_is_the_second_source
test_unreachable_forge_is_loudly_unguarded
