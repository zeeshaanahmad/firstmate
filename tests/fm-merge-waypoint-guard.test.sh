#!/usr/bin/env bash
# Tests for the upstream-history guard in bin/fm-pr-merge.sh: the check that
# refuses a merge method which would rewrite shared upstream commits out of the
# base branch's ancestry.
#
# The defect being guarded, measured on this repo on 2026-08-25: batch 3 of an
# upstream reconciliation was merged with fm-pr-merge.sh's squash DEFAULT. The
# branch was correct, and the squash flattened its merge commit and dropped
# upstream waypoint 7f5255a out of main's ancestry, so the next batch would
# compute its merge base against a commit main no longer reaches and replay
# nine commits main already carries.
#
# Every fixture here is that shape: a fork whose local copy tracks an upstream
# repository, and a PR whose head merges upstream commits the fork's default
# branch does not have.
#
# Matrix:
#   (a) the squash DEFAULT is refused for such a PR, names the commits it would
#       erase, and never reaches gh-axi
#   (b) scope: an ordinary PR in the SAME repo, with the same upstream remote
#       fetched, still merges on the squash default - the guard discriminates
#       rather than being globally on
#   (c) the remedy works: --merge is not refused and is forwarded unchanged
#   (d) --rebase is refused too, because it rewrites the same commits out
#   (e) an explicit --method=squash is refused, so naming the default is not a
#       way around it
#   (f) FM_MERGE_GUARD=off does not reach this guard: it selects the static
#       check's posture, not this one
#   (g) a project with no upstream remote is not checked at all and stays silent
#   (h) a configured upstream that was never fetched here is loudly unguarded
#       rather than wedging the merge
#   (i) upstream history IS present locally, but the base branch or PR head
#       cannot be resolved - this REFUSES, unlike (h), because history that
#       cannot be measured is not history that was found clear
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-waypoint-tests)

wp_git() {  # <repo> <git args...>
  git -C "$1" -c user.name=fmtest -c user.email=fmtest@example.invalid "${@:2}"
}

# Build <case_dir>/origin.git and <case_dir>/work for one variant, and leave the
# PR head at refs/pull/7/head in origin.git.
#
# The upstream commits are real objects reachable from a real refs/remotes/
# tracking ref; only the upstream remote's URL is a stand-in, because the guard
# reads that URL to classify the remote and never fetches from it.
wp_make_project() {  # <case_dir> <sync|ordinary|no-upstream|unfetched>
  local case_dir=$1 variant=$2 work="$1/work" origin="$1/origin.git" upstream_tip
  mkdir -p "$case_dir"
  git init -q --bare "$origin"
  git clone -q "$origin" "$work" 2>/dev/null
  printf 'base\n' > "$work/README.md"
  wp_git "$work" add -A
  wp_git "$work" commit -qm base
  wp_git "$work" branch -M main
  wp_git "$work" push -q origin main
  git -C "$origin" symbolic-ref HEAD refs/heads/main

  if [ "$variant" != no-upstream ]; then
    wp_git "$work" remote add upstream https://github.com/upstream-owner/repo.git
  fi

  # Two commits that exist only upstream, on a file the fork never touches.
  wp_git "$work" checkout -q -b upstream-line main
  printf 'one\n' > "$work/UPSTREAM.md"
  wp_git "$work" add -A
  wp_git "$work" commit -qm 'upstream: first waypoint'
  printf 'one\ntwo\n' > "$work/UPSTREAM.md"
  wp_git "$work" add -A
  wp_git "$work" commit -qm 'upstream: second waypoint'
  upstream_tip=$(wp_git "$work" rev-parse HEAD)
  printf '%s\n' "$upstream_tip" > "$case_dir/upstream-tip.sha"
  wp_git "$work" checkout -q main
  if [ "$variant" != unfetched ] && [ "$variant" != no-upstream ]; then
    wp_git "$work" update-ref refs/remotes/upstream/main "$upstream_tip"
  fi
  wp_git "$work" branch -q -D upstream-line

  case "$variant" in
    sync)
      # The sync-batch shape: a branch whose merge brings upstream history in.
      wp_git "$work" checkout -q -b sync main
      wp_git "$work" merge -q --no-ff -m 'merge: bring in upstream waypoints' "$upstream_tip"
      wp_git "$work" push -q origin sync
      git -C "$origin" update-ref refs/pull/7/head "$(wp_git "$work" rev-parse sync)"
      printf '%s\n' "$(wp_git "$work" rev-parse sync)" > "$case_dir/head.sha"
      ;;
    *)
      # A lane's own work: nothing shared with upstream.
      wp_git "$work" checkout -q -b feat main
      printf 'feature\n' > "$work/feature.txt"
      wp_git "$work" add -A
      wp_git "$work" commit -qm feat
      wp_git "$work" push -q origin feat
      git -C "$origin" update-ref refs/pull/7/head "$(wp_git "$work" rev-parse feat)"
      printf '%s\n' "$(wp_git "$work" rev-parse feat)" > "$case_dir/head.sha"
      ;;
  esac
  wp_git "$work" checkout -q main
}

make_case() {  # <name> <variant>
  local name=$1 variant=$2 case_dir fakebin head
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  wp_make_project "$case_dir" "$variant"
  head=$(cat "$case_dir/head.sha")
  fm_write_meta "$case_dir/state/task-w1.meta" \
    "window=fm-task-w1" \
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

run_pr_merge() {  # <case_dir> <args...>
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
}

test_squash_default_refused_for_upstream_history() {
  local case_dir rc
  case_dir=$(make_case squash-default-refused sync)

  set +e
  run_pr_merge "$case_dir" task-w1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-default-refused: the squash default should be refused"
  assert_grep 'merge refused' "$case_dir/stderr" \
    "squash-default-refused: refusal did not say the merge was refused"
  assert_grep 'upstream: second waypoint' "$case_dir/stderr" \
    "squash-default-refused: refusal did not name the upstream commits it would erase"
  assert_grep 'merge this PR with --merge' "$case_dir/stderr" \
    "squash-default-refused: refusal did not name the remedy"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "squash-default-refused: the PR was merged despite erasing upstream history"
  pass "the squash default is refused for a PR carrying upstream history the base branch lacks"
}

# Non-vacuity for the case above: the same repo, the same fetched upstream
# remote, an ordinary PR. If this went red the guard would just be "refuse
# everything", which is not a guard.
test_ordinary_pr_still_squashes() {
  local case_dir
  case_dir=$(make_case ordinary-still-squashes ordinary)

  run_pr_merge "$case_dir" task-w1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "ordinary-still-squashes: an ordinary PR should still merge"

  grep -qxF 'pr merge 7 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "ordinary-still-squashes: the ordinary PR did not merge on the squash default"
  assert_no_grep 'upstream-history' "$case_dir/stderr" \
    "ordinary-still-squashes: the guard spoke about a PR that carries no upstream history"
  pass "an ordinary PR in the same fork still merges on the squash default"
}

test_merge_method_is_allowed_and_forwarded() {
  local case_dir
  case_dir=$(make_case merge-method-allowed sync)

  run_pr_merge "$case_dir" task-w1 https://github.com/example/repo/pull/7 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "merge-method-allowed: --merge should not be refused"

  grep -qxF 'pr merge 7 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "merge-method-allowed: --merge was not forwarded unchanged"
  pass "--merge is the remedy the guard names and is not itself refused"
}

test_rebase_refused_for_upstream_history() {
  local case_dir rc
  case_dir=$(make_case rebase-refused sync)

  set +e
  run_pr_merge "$case_dir" task-w1 https://github.com/example/repo/pull/7 -- --rebase \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "rebase-refused: --rebase should be refused"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "rebase-refused: the PR was rebased despite erasing upstream history"
  pass "--rebase is refused too, because it rewrites the same commits out of ancestry"
}

test_explicit_squash_method_refused() {
  local case_dir rc
  case_dir=$(make_case explicit-squash-refused sync)

  set +e
  run_pr_merge "$case_dir" task-w1 https://github.com/example/repo/pull/7 -- --method=squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "explicit-squash-refused: --method=squash should be refused"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "explicit-squash-refused: naming the default squash method got past the guard"
  pass "asking for squash explicitly is refused exactly as the default is"
}

test_static_guard_off_does_not_disable_this_guard() {
  local case_dir rc
  case_dir=$(make_case guard-off-still-refuses sync)

  set +e
  FM_MERGE_GUARD=off run_pr_merge "$case_dir" task-w1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "guard-off-still-refuses: FM_MERGE_GUARD=off must not disable this guard"
  assert_grep 'merge refused' "$case_dir/stderr" \
    "guard-off-still-refuses: the merge was not refused under FM_MERGE_GUARD=off"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "guard-off-still-refuses: FM_MERGE_GUARD=off merged a PR that erases upstream history"
  pass "FM_MERGE_GUARD=off selects the static check's posture and never this guard's"
}

test_project_without_upstream_is_not_checked() {
  local case_dir
  case_dir=$(make_case no-upstream-remote no-upstream)

  run_pr_merge "$case_dir" task-w1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "no-upstream-remote: a project with no upstream should merge unchanged"

  grep -qxF 'pr merge 7 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "no-upstream-remote: the merge did not proceed on the squash default"
  assert_no_grep 'upstream-history' "$case_dir/stderr" \
    "no-upstream-remote: the guard spoke about a project that tracks no upstream"
  pass "a project that tracks no upstream repository is not checked and stays silent"
}

test_unfetched_upstream_is_loudly_unguarded() {
  local case_dir
  case_dir=$(make_case unfetched-upstream unfetched)

  run_pr_merge "$case_dir" task-w1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "unfetched-upstream: an unfetched upstream must not wedge the merge"

  assert_grep 'upstream-history: UNGUARDED' "$case_dir/stderr" \
    "unfetched-upstream: the guard merged without saying it had nothing to compare against"
  grep -qxF 'pr merge 7 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "unfetched-upstream: the merge did not proceed"
  pass "an upstream remote that was never fetched here is loudly unguarded, not a wedge"
}

test_unresolvable_history_refuses_when_upstream_present() {
  local case_dir rc
  case_dir=$(make_case unresolvable-history-refuses sync)
  # The forge is gone: the guard's shared ref resolution cannot fetch the
  # current base tip or the PR head, even though upstream history IS present
  # locally via refs/remotes/upstream/main. Contrast with (h): there, no local
  # upstream refs exist at all, so the guard has nothing to measure against and
  # merges loudly; here, upstream history exists but the specific comparison it
  # needs cannot be run, so it refuses instead.
  mv "$case_dir/origin.git" "$case_dir/origin-moved.git"

  set +e
  run_pr_merge "$case_dir" task-w1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unresolvable-history-refuses: an unmeasured base/head must refuse, not merge"
  assert_grep 'merge refused' "$case_dir/stderr" \
    "unresolvable-history-refuses: refusal did not say the merge was refused"
  assert_grep 'an unmeasured history check is not a clear one' "$case_dir/stderr" \
    "unresolvable-history-refuses: refusal did not name the unmeasured-check doctrine"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unresolvable-history-refuses: the PR was merged despite an unmeasured comparison"
  pass "upstream history present but unresolvable base/head refuses, unlike an unfetched upstream which merges loudly"
}

test_squash_default_refused_for_upstream_history
test_ordinary_pr_still_squashes
test_merge_method_is_allowed_and_forwarded
test_rebase_refused_for_upstream_history
test_explicit_squash_method_refused
test_static_guard_off_does_not_disable_this_guard
test_project_without_upstream_is_not_checked
test_unfetched_upstream_is_loudly_unguarded
test_unresolvable_history_refuses_when_upstream_present
