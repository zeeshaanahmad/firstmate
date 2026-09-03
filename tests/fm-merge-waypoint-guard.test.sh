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
#   (j) a named upstream waypoint that is an ancestor of the PR head passes and
#       names both commits in the successful assertion
#   (k) a flattened branch with identical upstream content but no waypoint in
#       its ancestry is refused, naming the missing waypoint and exact PR head
#   (l) a waypoint recorded in the task's durable record is asserted even when
#       the merge command omits the flag, passing on an intact batch and
#       refusing a flattened one, so the guarantee does not rest on a flag
#   (m) a flag and a recorded waypoint that name different commits refuse
#       before any merge, rather than one silently winning
#   (n) --require-ancestor '' is refused as a malformed value, not treated as
#       the flag being absent
#   (o) --require-ancestor= is refused the same way
#   (p) a GitLab merge request carrying upstream history is refused too, and
#       names the remedy that forge actually has
#   (q) non-vacuity and the positive GitLab path: an ordinary merge request with
#       a reachable waypoint passes both guards and merges through glab
#   (r) --merge does not excuse a GitLab merge request the way it does a pull
#       request, because that forge takes no merge-method flag at all
#   (s) a GitLab merge request whose live head (read moments before merging)
#       differs from the head the guards actually measured is refused, naming
#       both commits, rather than merging a commit none of them evaluated
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
wp_make_project() {  # <case_dir> <sync|flattened|ordinary|no-upstream|unfetched>
  local case_dir=$1 variant=$2 work="$1/work" origin="$1/origin.git" upstream_tip commit
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
    flattened)
      # This is the silent failure shape: the upstream content is present, but
      # cherry-picking gave it new identities and removed the waypoint from
      # ancestry. A content-only check would accept it.
      wp_git "$work" checkout -q -b flattened main
      printf 'fork-side change\n' > "$work/FORK.md"
      wp_git "$work" add -A
      wp_git "$work" commit -qm 'fork: move the replay base'
      for commit in $(wp_git "$work" rev-list --reverse "main..$upstream_tip"); do
        wp_git "$work" cherry-pick "$commit" >/dev/null
      done
      wp_git "$work" push -q origin flattened
      git -C "$origin" update-ref refs/pull/7/head "$(wp_git "$work" rev-parse flattened)"
      printf '%s\n' "$(wp_git "$work" rev-parse flattened)" > "$case_dir/head.sha"
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
  git -C "$origin" update-ref refs/merge_requests/7/head "$(cat "$case_dir/head.sha")"
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
  # glab answers the one merge request view the GitLab path reads, with every
  # pre-merge condition satisfied, so a refusal in these cases can only come
  # from a guard rather than from the merge request's own state.
  cat > "$fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf 'GITLAB_HOST=%s %s\n' "${GITLAB_HOST-<unset>}" "$*" >> "$FM_TEST_GLAB_LOG"
case "${1:-} ${2:-}" in
  "mr view") cat "$FM_TEST_GLAB_JSON" ; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/glab"
  printf '{"iid":7,"state":"opened","detailed_merge_status":"mergeable",' \
    > "$case_dir/mr.json"
  printf '"has_conflicts":false,"blocking_discussions_resolved":true,' \
    >> "$case_dir/mr.json"
  printf '"target_branch":"main","sha":"%s","head_pipeline":{"sha":"%s","status":"success"}}\n' \
    "$head" "$head" >> "$case_dir/mr.json"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/glab.log"
  printf '%s\n' "$case_dir"
}

run_pr_merge() {  # <case_dir> <args...>
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GLAB_LOG="$case_dir/glab.log" \
  FM_TEST_GLAB_JSON="$case_dir/mr.json" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
}

# The GitLab fixture's identity: a namespace deeper than one group, because a
# GitLab project has no owner/repository pair for a guard to compare against.
MR_PROJECT_URL=https://gitlab.example/group/subgroup/project
MR_URL="$MR_PROJECT_URL/-/merge_requests/7"

# The same fixture with the GitHub head ref removed, because a GitLab origin
# publishes a request head under refs/merge_requests/<n>/head and nothing else.
# Leaving refs/pull/<n>/head in place would let the GitHub refspec resolve the
# head and prove nothing about the GitLab one.
make_gitlab_case() {  # <name> <variant>
  local case_dir
  case_dir=$(make_case "$1" "$2")
  git -C "$case_dir/origin.git" update-ref -d refs/pull/7/head
  printf '%s\n' "$case_dir"
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

test_required_waypoint_ancestor_passes() {
  local case_dir waypoint head
  case_dir=$(make_case required-waypoint-passes sync)
  waypoint=$(cat "$case_dir/upstream-tip.sha")
  head=$(cat "$case_dir/head.sha")

  run_pr_merge "$case_dir" task-w1 https://github.com/example/repo/pull/7 \
    --require-ancestor "$waypoint" -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "required-waypoint-passes: a reachable waypoint should permit the merge"

  assert_grep "upstream-waypoint: green - $waypoint is an ancestor of PR head $head" "$case_dir/stdout" \
    "required-waypoint-passes: the assertion did not name the waypoint and PR head"
  grep -qxF 'pr merge 7 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "required-waypoint-passes: the merge method was not forwarded after the waypoint assertion"
  pass "a required upstream waypoint that reaches the PR head passes with both commits named"
}

test_flattened_branch_missing_waypoint_refuses() {
  local case_dir waypoint head rc
  case_dir=$(make_case flattened-waypoint-refuses flattened)
  waypoint=$(cat "$case_dir/upstream-tip.sha")
  head=$(cat "$case_dir/head.sha")
  git -C "$case_dir/work" diff --quiet "$waypoint" "$head" -- UPSTREAM.md \
    || fail "flattened-waypoint-refuses: fixture lost the upstream content"
  if git -C "$case_dir/work" merge-base --is-ancestor "$waypoint" "$head"; then
    fail "flattened-waypoint-refuses: fixture still carries the upstream waypoint"
  fi

  set +e
  run_pr_merge "$case_dir" task-w1 https://github.com/example/repo/pull/7 \
    --require-ancestor "$waypoint" -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "flattened-waypoint-refuses: a flattened batch must be refused"
  assert_grep "required upstream waypoint $waypoint is not an ancestor of PR head $head" "$case_dir/stderr" \
    "flattened-waypoint-refuses: the refusal did not name the waypoint and exact PR head"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "flattened-waypoint-refuses: gh-axi was called after the ancestry assertion failed"
  pass "a content-complete flattened batch is refused when its named waypoint is absent from ancestry"
}

record_waypoint() {  # <case_dir> <sha>
  printf 'waypoint=%s\n' "$2" >> "$1/state/task-w1.meta"
}

test_recorded_waypoint_passes_without_flag() {
  local case_dir waypoint head
  case_dir=$(make_case recorded-waypoint-passes sync)
  waypoint=$(cat "$case_dir/upstream-tip.sha")
  head=$(cat "$case_dir/head.sha")
  record_waypoint "$case_dir" "$waypoint"

  run_pr_merge "$case_dir" task-w1 https://github.com/example/repo/pull/7 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "recorded-waypoint-passes: an intact batch should merge on its recorded waypoint"

  assert_grep "upstream-waypoint: green - $waypoint is an ancestor of PR head $head" "$case_dir/stdout" \
    "recorded-waypoint-passes: the recorded waypoint was not asserted"
  grep -qxF 'pr merge 7 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "recorded-waypoint-passes: the merge did not proceed after the assertion"
  pass "a waypoint recorded on the task is asserted with no flag and lets an intact batch merge"
}

test_recorded_waypoint_refuses_flattened_without_flag() {
  local case_dir waypoint head rc
  case_dir=$(make_case recorded-waypoint-flattened flattened)
  waypoint=$(cat "$case_dir/upstream-tip.sha")
  head=$(cat "$case_dir/head.sha")
  record_waypoint "$case_dir" "$waypoint"

  set +e
  run_pr_merge "$case_dir" task-w1 https://github.com/example/repo/pull/7 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "recorded-waypoint-flattened: a flattened batch must be refused on its recorded waypoint alone"
  assert_grep "required upstream waypoint $waypoint is not an ancestor of PR head $head" "$case_dir/stderr" \
    "recorded-waypoint-flattened: the refusal did not name the waypoint and exact PR head"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "recorded-waypoint-flattened: gh-axi was called after the recorded waypoint failed"
  pass "a flattened batch is refused from its recorded waypoint even when the merge command omits the flag"
}

test_flag_and_recorded_waypoint_disagreement_refuses() {
  local case_dir waypoint other rc
  case_dir=$(make_case waypoint-disagreement sync)
  waypoint=$(cat "$case_dir/upstream-tip.sha")
  other=$(git -C "$case_dir/work" rev-parse main)
  [ "$waypoint" != "$other" ] || fail "waypoint-disagreement: fixture produced two identical commits"
  record_waypoint "$case_dir" "$waypoint"

  set +e
  run_pr_merge "$case_dir" task-w1 https://github.com/example/repo/pull/7 \
    --require-ancestor "$other" -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "waypoint-disagreement: two different waypoints must refuse"
  assert_grep "--require-ancestor $other disagrees with the waypoint $waypoint recorded for this task" "$case_dir/stderr" \
    "waypoint-disagreement: the refusal did not name both commits"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "waypoint-disagreement: gh-axi was called despite disagreeing waypoints"
  pass "a flag and a recorded waypoint naming different commits refuse instead of one silently winning"
}

test_empty_require_ancestor_space_form_refuses() {
  local case_dir rc
  case_dir=$(make_case empty-require-ancestor-space sync)

  set +e
  run_pr_merge "$case_dir" task-w1 https://github.com/example/repo/pull/7 \
    --require-ancestor '' -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "empty-require-ancestor-space: an explicitly empty --require-ancestor value must be refused"
  assert_grep 'error: --require-ancestor requires a full lowercase 40-character commit SHA' "$case_dir/stderr" \
    "empty-require-ancestor-space: the refusal did not name the SHA-format requirement"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "empty-require-ancestor-space: gh-axi was called despite an empty waypoint value"
  pass "--require-ancestor '' is refused as a malformed value rather than treated as the flag being absent"
}

test_empty_require_ancestor_equals_form_refuses() {
  local case_dir rc
  case_dir=$(make_case empty-require-ancestor-equals sync)

  set +e
  run_pr_merge "$case_dir" task-w1 https://github.com/example/repo/pull/7 \
    --require-ancestor= -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "empty-require-ancestor-equals: an explicitly empty --require-ancestor= value must be refused"
  assert_grep 'error: --require-ancestor requires a full lowercase 40-character commit SHA' "$case_dir/stderr" \
    "empty-require-ancestor-equals: the refusal did not name the SHA-format requirement"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "empty-require-ancestor-equals: gh-axi was called despite an empty waypoint value"
  pass "--require-ancestor= is refused as a malformed value rather than treated as the flag being absent"
}

# A merge request can carry shared upstream history exactly as a pull request
# can, and GitLab applies the project's own merge method rather than one this
# command can name, so nothing here can prove the history survives.
test_gitlab_upstream_history_refused() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-upstream-history sync)

  set +e
  run_pr_merge "$case_dir" task-w1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-upstream-history: a merge request carrying upstream history should be refused"
  assert_grep 'merge refused' "$case_dir/stderr" \
    "gitlab-upstream-history: refusal did not say the merge was refused"
  assert_grep 'upstream: second waypoint' "$case_dir/stderr" \
    "gitlab-upstream-history: refusal did not name the upstream commits it would erase"
  assert_grep 'land this merge request in GitLab' "$case_dir/stderr" \
    "gitlab-upstream-history: refusal did not name a remedy this forge actually has"
  assert_no_grep ' mr merge ' "$case_dir/glab.log" \
    "gitlab-upstream-history: the merge request was merged despite erasing upstream history"
  pass "a GitLab merge request carrying upstream history is refused with a GitLab remedy"
}

# --merge is the GitHub remedy and cannot be the GitLab one: glab takes no
# merge-method flag, so passing it proves nothing about what GitLab will do and
# must not buy a pass the way it does on a pull request.
test_gitlab_merge_flag_does_not_excuse_upstream_history() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-merge-flag sync)

  set +e
  run_pr_merge "$case_dir" task-w1 "$MR_URL" -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-merge-flag: --merge must not excuse a GitLab merge request carrying upstream history"
  assert_grep 'upstream: second waypoint' "$case_dir/stderr" \
    "gitlab-merge-flag: refusal did not name the upstream commits it would erase"
  assert_no_grep ' mr merge ' "$case_dir/glab.log" \
    "gitlab-merge-flag: the merge request merged because --merge was passed"
  pass "--merge does not excuse a GitLab merge request the way it does a pull request"
}

# Non-vacuity for the case above and the positive GitLab path in one: the same
# fixture and the same fetched upstream remote, an ordinary merge request, and a
# waypoint the guard must resolve from GitLab's own head ref to call reachable.
test_gitlab_ordinary_mr_merges_after_waypoint_assertion() {
  local case_dir waypoint head
  case_dir=$(make_gitlab_case gitlab-ordinary-merges ordinary)
  head=$(cat "$case_dir/head.sha")
  waypoint=$(wp_git "$case_dir/work" rev-parse main)

  run_pr_merge "$case_dir" task-w1 "$MR_URL" --require-ancestor "$waypoint" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "gitlab-ordinary-merges: an ordinary merge request with a reachable waypoint should merge"

  assert_grep "upstream-waypoint: green - $waypoint is an ancestor of PR head $head" "$case_dir/stdout" \
    "gitlab-ordinary-merges: the waypoint assertion did not resolve the GitLab merge request head"
  assert_no_grep 'upstream-history' "$case_dir/stderr" \
    "gitlab-ordinary-merges: the guard spoke about a merge request that carries no upstream history"
  grep -qF "mr merge 7 -R $MR_PROJECT_URL --sha $head --yes" "$case_dir/glab.log" \
    || fail "gitlab-ordinary-merges: the merge request did not merge through glab at its verified head"
  pass "an ordinary GitLab merge request passes both guards and merges through glab"
}

# The fork's three guards all read MERGE_REFS_HEAD, fetched from GitLab's own
# refs/merge_requests/<n>/head before the guards run. gitlab_verify_mergeable
# separately re-reads the live head from glab's own view moments before
# merging. If a push lands in that window the two heads diverge, and merging
# the live one anyway would land a commit none of the guards ever measured -
# exactly the erased-history outcome they exist to prevent, just unmeasured.
test_gitlab_guard_head_mismatch_refuses() {
  local case_dir rc clean_head diverged_head upstream_tip
  case_dir=$(make_gitlab_case gitlab-guard-head-mismatch ordinary)
  clean_head=$(cat "$case_dir/head.sha")
  upstream_tip=$(cat "$case_dir/upstream-tip.sha")

  # A second, real commit that DOES carry upstream history, built in the same
  # repo but never published at refs/merge_requests/7/head - the ref the
  # guards actually fetch and measure.
  wp_git "$case_dir/work" checkout -q -b diverged main
  wp_git "$case_dir/work" merge -q --no-ff -m 'merge: bring in upstream waypoints' "$upstream_tip"
  wp_git "$case_dir/work" push -q origin diverged
  diverged_head=$(wp_git "$case_dir/work" rev-parse diverged)

  # Drive glab's live view to the diverged commit, as though the merge
  # request moved after the guards already fetched and measured clean_head.
  printf '{"iid":7,"state":"opened","detailed_merge_status":"mergeable",' \
    > "$case_dir/mr.json"
  printf '"has_conflicts":false,"blocking_discussions_resolved":true,' \
    >> "$case_dir/mr.json"
  printf '"target_branch":"main","sha":"%s","head_pipeline":{"sha":"%s","status":"success"}}\n' \
    "$diverged_head" "$diverged_head" >> "$case_dir/mr.json"

  set +e
  run_pr_merge "$case_dir" task-w1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-guard-head-mismatch: a live head diverging from the guarded head must be refused"
  assert_grep 'merge refused' "$case_dir/stderr" \
    "gitlab-guard-head-mismatch: refusal did not say the merge was refused"
  assert_grep "$clean_head" "$case_dir/stderr" \
    "gitlab-guard-head-mismatch: refusal did not name the head the guards measured"
  assert_grep "$diverged_head" "$case_dir/stderr" \
    "gitlab-guard-head-mismatch: refusal did not name the verified live head"
  assert_no_grep ' mr merge ' "$case_dir/glab.log" \
    "gitlab-guard-head-mismatch: the merge request was merged despite the head mismatch"
  pass "a GitLab merge request whose live head diverges from the guarded head is refused before merging"
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
test_required_waypoint_ancestor_passes
test_flattened_branch_missing_waypoint_refuses
test_recorded_waypoint_passes_without_flag
test_recorded_waypoint_refuses_flattened_without_flag
test_flag_and_recorded_waypoint_disagreement_refuses
test_empty_require_ancestor_space_form_refuses
test_empty_require_ancestor_equals_form_refuses
test_gitlab_upstream_history_refused
test_gitlab_ordinary_mr_merges_after_waypoint_assertion
test_gitlab_merge_flag_does_not_excuse_upstream_history
test_gitlab_guard_head_mismatch_refuses
