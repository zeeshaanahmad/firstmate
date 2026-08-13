#!/usr/bin/env bash
# tests/fm-ci-probe.test.sh - fm-ci-probe.sh derives its none/present/unknown
# verdict from the forge's actions/runs answer, never from a hardcoded repo
# name, and never guesses "none" when that answer could not be read. With no
# argument it must resolve owner/repo from the current directory's "origin"
# remote directly rather than ambient `gh repo view` resolution, which on a
# fork defaults to the parent repo instead of origin. The verdict must also
# come from pull_request/push-triggered runs only, not from unrelated
# Actions activity (dependabot, schedule, workflow_dispatch) that never
# attaches a check to a PR.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROBE="$ROOT/bin/fm-ci-probe.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-probe)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")

# The fake `gh` records the exact owner/repo it was asked about and, when
# FM_TEST_GH_REPOVIEW is set, answers `repo view` with a DIFFERENT repo than
# origin - simulating ambient gh resolution picking a fork's parent. A probe
# that still called `gh repo view` for no-arg resolution would query that
# wrong repo instead of origin, and the call-recording assertions below would
# catch it.
#
# `api` answers per triggering event: a query naming event=pull_request or
# event=push answers from FM_TEST_GH_TOTAL_PR / FM_TEST_GH_TOTAL_PUSH
# (falling back to FM_TEST_GH_TOTAL when unset, so single-count fixtures keep
# working unchanged), and any other query (i.e. an unfiltered count, the
# pre-fix probe's own request shape) answers from FM_TEST_GH_TOTAL alone -
# this is what lets a fixture simulate real but PR-irrelevant Actions history
# (dependabot/schedule runs inflating the unfiltered total) while both
# event-filtered counts stay zero.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "$1" in
  repo)
    [ "${FM_TEST_GH_REPOVIEW_FAIL:-0}" = 0 ] || exit 1
    printf '%s\n' "${FM_TEST_GH_REPOVIEW:-owner/repo}"
    ;;
  api)
    [ "${FM_TEST_GH_API_FAIL:-0}" = 0 ] || exit 1
    case "$*" in
      *event=pull_request*) printf '%s\n' "${FM_TEST_GH_TOTAL_PR:-${FM_TEST_GH_TOTAL:-0}}" ;;
      *event=push*) printf '%s\n' "${FM_TEST_GH_TOTAL_PUSH:-${FM_TEST_GH_TOTAL:-0}}" ;;
      *) printf '%s\n' "${FM_TEST_GH_TOTAL:-0}" ;;
    esac
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$FAKEBIN/gh"

run_probe() {  # [<owner/repo>]
  : > "$TMP_ROOT/gh.log"
  FM_TEST_GH_LOG="$TMP_ROOT/gh.log" PATH="$FAKEBIN:$PATH" "$PROBE" "$@"
}

# run_probe_in <dir> [<owner/repo>]: run_probe with the current directory set
# to <dir>, so the probe's origin-remote resolution reads that repo's config.
run_probe_in() {
  local dir=$1
  shift
  ( cd "$dir" && run_probe "$@" )
}

# git_repo_with_origin <url>: init a scratch git repo (no commit needed, only
# remote config is read) with "origin" pointing at <url>, and echo its path.
git_repo_with_origin() {
  local url=$1 dir
  dir=$(mktemp -d "$TMP_ROOT/repo.XXXXXX")
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$url"
  printf '%s\n' "$dir"
}

# A repo whose forge reports zero Actions runs ever - the ci step's trap
# condition - is excluded: the probe answers "none".
out=$(FM_TEST_GH_TOTAL=0 run_probe agentic/no-checks-repo)
[ "$out" = "none" ] || fail "zero runs did not verdict none (got: $out)"
grep -q 'api repos/agentic/no-checks-repo/actions/runs' "$TMP_ROOT/gh.log" \
  || fail "probe did not query the exact owner/repo it was given"
pass "a repo with zero Actions runs ever verdicts none"

# A repo with real check history is not excluded: the probe answers "present".
out=$(FM_TEST_GH_TOTAL=42 run_probe real/checks-repo)
[ "$out" = "present" ] || fail "nonzero runs did not verdict present (got: $out)"
pass "a repo with Actions run history verdicts present"

# The verdict is read from the forge's answer, not the repo's name: swapping
# which fixture reports zero runs swaps which one verdicts none, proving the
# logic is not hardcoded to any specific project.
out=$(FM_TEST_GH_TOTAL=0 run_probe real/checks-repo)
[ "$out" = "none" ] || fail "verdict did not follow the forge's answer for a renamed fixture (got: $out)"
pass "verdict is derived from the forge's answer, not a hardcoded repo name"

# No argument, https origin: the probe resolves owner/repo by parsing the
# current directory's origin remote URL directly, then asks the same question.
REPO_DIR=$(git_repo_with_origin "https://github.com/resolved/via-origin.git")
out=$(FM_TEST_GH_TOTAL=0 run_probe_in "$REPO_DIR")
[ "$out" = "none" ] || fail "no-arg https resolution did not verdict none (got: $out)"
grep -q 'api repos/resolved/via-origin/actions/runs' "$TMP_ROOT/gh.log" \
  || fail "no-arg probe did not query the repo parsed from the https origin remote"
pass "with no argument and an https origin, the probe resolves the repo from origin"

# Fork scenario: origin names a repo that differs from what ambient `gh repo
# view` resolution would pick (its parent repo, per FM_TEST_GH_REPOVIEW). The
# probe must query ORIGIN's runs, never gh's ambient answer, and must never
# call `gh repo view` at all for no-arg resolution.
FORK_DIR=$(git_repo_with_origin "https://github.com/fork-owner/fork-repo.git")
out=$(FM_TEST_GH_REPOVIEW=upstream-owner/parent-repo FM_TEST_GH_TOTAL=0 \
  run_probe_in "$FORK_DIR")
[ "$out" = "none" ] || fail "fork-shaped no-arg resolution did not verdict none (got: $out)"
grep -q 'api repos/fork-owner/fork-repo/actions/runs' "$TMP_ROOT/gh.log" \
  || fail "probe on a fork did not query origin's repo (fork-owner/fork-repo)"
assert_not_contains "$(cat "$TMP_ROOT/gh.log")" "repo view" \
  "probe called gh repo view instead of parsing origin directly"
assert_not_contains "$(cat "$TMP_ROOT/gh.log")" \
  "repos/upstream-owner/parent-repo/actions/runs" \
  "probe queried the fork's parent repo instead of origin"
pass "on a fork, the probe queries origin's Actions runs, not gh's ambient parent-repo answer"

# No argument, ssh origin: the same direct parse handles the ssh remote form.
SSH_DIR=$(git_repo_with_origin "git@github.com:ssh-owner/ssh-repo.git")
out=$(FM_TEST_GH_TOTAL=7 run_probe_in "$SSH_DIR")
[ "$out" = "present" ] || fail "no-arg ssh resolution did not verdict present (got: $out)"
grep -q 'api repos/ssh-owner/ssh-repo/actions/runs' "$TMP_ROOT/gh.log" \
  || fail "no-arg probe did not query the repo parsed from the ssh origin remote"
pass "with no argument and an ssh origin, the probe resolves the repo from origin"

# The forge's answer could not be read (auth, network, missing repo, API
# error): the probe never guesses "none" - it says so plainly.
out=$(FM_TEST_GH_API_FAIL=1 run_probe owner/unreadable)
[ "$out" = "unknown" ] || fail "an unreadable forge answer did not verdict unknown (got: $out)"
pass "an unreadable actions/runs answer verdicts unknown rather than guessing"

# The origin remote itself could not be resolved (no remote configured at
# all): same refusal to guess.
NOREMOTE_DIR=$(mktemp -d "$TMP_ROOT/norepo.XXXXXX")
git -C "$NOREMOTE_DIR" init -q
out=$(run_probe_in "$NOREMOTE_DIR")
[ "$out" = "unknown" ] || fail "a missing origin remote did not verdict unknown (got: $out)"
pass "a missing origin remote verdicts unknown rather than guessing"

# An origin remote in an unparseable form (neither github.com https nor ssh):
# same refusal to guess.
UNPARSEABLE_DIR=$(git_repo_with_origin "https://gitlab.com/owner/repo.git")
out=$(run_probe_in "$UNPARSEABLE_DIR")
[ "$out" = "unknown" ] || fail "an unparseable origin remote did not verdict unknown (got: $out)"
pass "an unparseable origin remote verdicts unknown rather than guessing"

# Second false-positive mode: a repo can carry real Actions run history from
# events that never attach a check to a PR (dependabot, schedule,
# workflow_dispatch) while zero of its runs were triggered by pull_request or
# push. Counting every run regardless of triggering event would misreport
# this repo as "present" and the ci step would wedge forever. The probe must
# query event-filtered totals and verdict "none" here.
out=$(FM_TEST_GH_TOTAL=15 FM_TEST_GH_TOTAL_PR=0 FM_TEST_GH_TOTAL_PUSH=0 \
  run_probe agentic/dependabot-only-repo)
[ "$out" = "none" ] || fail "PR/push-irrelevant Actions history verdicted present instead of none (got: $out)"
grep -q 'api repos/agentic/dependabot-only-repo/actions/runs?event=pull_request' "$TMP_ROOT/gh.log" \
  || fail "probe did not query event=pull_request runs"
grep -q 'api repos/agentic/dependabot-only-repo/actions/runs?event=push' "$TMP_ROOT/gh.log" \
  || fail "probe did not query event=push runs"
pass "Actions history from non-PR-triggering events (dependabot/schedule) verdicts none"

# The same repo shape but with at least one pull_request-triggered run: a
# real check can register on a PR, so the verdict is "present".
out=$(FM_TEST_GH_TOTAL_PR=1 FM_TEST_GH_TOTAL_PUSH=0 \
  run_probe agentic/pr-triggered-repo)
[ "$out" = "present" ] || fail "a pull_request-triggered run did not verdict present (got: $out)"
pass "at least one pull_request-triggered run verdicts present"

# Same shape but via a push-triggered run instead (a workflow scoped to
# `on: push` for the branch still attaches a check to the PR's head commit).
out=$(FM_TEST_GH_TOTAL_PR=0 FM_TEST_GH_TOTAL_PUSH=2 \
  run_probe agentic/push-triggered-repo)
[ "$out" = "present" ] || fail "a push-triggered run did not verdict present (got: $out)"
pass "at least one push-triggered run verdicts present"

echo "ALL TESTS PASSED"
