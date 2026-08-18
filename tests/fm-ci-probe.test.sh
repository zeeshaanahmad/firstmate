#!/usr/bin/env bash
# tests/fm-ci-probe.test.sh - fm-ci-probe.sh derives its none/present/unknown
# verdict from the forge's CURRENT WORKFLOW STATE
# (repos/{o}/{r}/actions/workflows), never from historical run counts
# (repos/{o}/{r}/actions/runs): a repo can carry old run history from before
# its workflows were disabled, and the verdict must follow the live state,
# not that history. With no argument it must resolve owner/repo from the
# current directory's "origin" remote directly rather than ambient
# `gh repo view` resolution, which on a fork defaults to the parent repo
# instead of origin. GitHub's own dynamically-provided workflows (Dependabot
# Updates, Copilot review), identified by a "dynamic/" path prefix, must
# never count toward "present": they read state=active but never register a
# check on an ordinary code pull request. Any indeterminate answer - the API
# call failing, an authentication failure, or a response this probe cannot
# make sense of - must verdict "present", never "none": an unreadable
# forge answer must never silently disarm CI. Only a failure to even
# determine which repo to ask about (no origin remote, an unparseable origin
# URL) verdicts "unknown".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROBE="$ROOT/bin/fm-ci-probe.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-probe)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")

HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# workflows_json <path>:<state> [<path>:<state> ...]: build the
# repos/{o}/{r}/actions/workflows response body fm-ci-probe.sh's real -q
# filter is run against.
workflows_json() {
  local out="[" first=1 entry path state
  for entry in "$@"; do
    path=${entry%%:*}
    state=${entry#*:}
    [ "$first" = 1 ] || out="$out,"
    first=0
    out="$out{\"path\":\"$path\",\"state\":\"$state\"}"
  done
  printf '%s' "$out]"
}

# The fake `gh` records the exact owner/repo it was asked about and, when
# FM_TEST_GH_REPOVIEW is set, answers `repo view` with a DIFFERENT repo than
# origin - simulating ambient gh resolution picking a fork's parent. A probe
# that still called `gh repo view` for no-arg resolution would query that
# wrong repo instead of origin, and the call-recording assertions below would
# catch it.
#
# `api` runs the probe's OWN "-q" jq filter (extracted from its real argv,
# never reimplemented) against FM_TEST_GH_WORKFLOWS_JSON's ".workflows"
# array through the real jq binary, so these tests exercise the script's
# actual filter expression rather than asserting its source bytes.
cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
case "\$1" in
  repo)
    [ "\${FM_TEST_GH_REPOVIEW_FAIL:-0}" = 0 ] || exit 1
    printf '%s\n' "\${FM_TEST_GH_REPOVIEW:-owner/repo}"
    ;;
  api)
    [ "\${FM_TEST_GH_API_FAIL:-0}" = 0 ] || exit 1
    jqexpr=""
    prev=""
    for a in "\$@"; do
      [ "\$prev" = "-q" ] && jqexpr=\$a
      prev=\$a
    done
    body="{\"workflows\":\${FM_TEST_GH_WORKFLOWS_JSON:-[]}}"
    printf '%s' "\$body" | $(command -v jq) -r "\$jqexpr"
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

if [ "$HAVE_JQ" = 1 ]; then

# A repo whose only real (non-dynamic) workflow is disabled verdicts "none":
# no check can ever register.
out=$(FM_TEST_GH_WORKFLOWS_JSON=$(workflows_json ".github/workflows/ci.yml:disabled_manually") \
  run_probe agentic/disabled-repo)
[ "$out" = "none" ] || fail "an all-disabled real workflow did not verdict none (got: $out)"
grep -q 'api repos/agentic/disabled-repo/actions/workflows' "$TMP_ROOT/gh.log" \
  || fail "probe did not query the exact owner/repo it was given"
pass "a repo whose only real workflow is disabled verdicts none"

# A repo with an active real workflow verdicts "present".
out=$(FM_TEST_GH_WORKFLOWS_JSON=$(workflows_json ".github/workflows/ci.yml:active") \
  run_probe real/active-repo)
[ "$out" = "present" ] || fail "an active real workflow did not verdict present (got: $out)"
pass "a repo with an active real workflow verdicts present"

# The verdict is read from the forge's answer, not the repo's name: swapping
# which fixture reports active swaps which one verdicts present, proving the
# logic is not hardcoded to any specific project.
out=$(FM_TEST_GH_WORKFLOWS_JSON=$(workflows_json ".github/workflows/ci.yml:disabled_manually") \
  run_probe real/active-repo)
[ "$out" = "none" ] || fail "verdict did not follow the forge's answer for a renamed fixture (got: $out)"
pass "verdict is derived from the forge's answer, not a hardcoded repo name"

# The exact regression this fix closes: a repo carries real workflows (ci,
# docker) that are ALL disabled, while GitHub's own dynamically-provided
# Dependabot workflow reads state=active. Counting that dynamic entry as
# "present" would arm a ci step that can never see a check land - the probe
# must exclude it and verdict "none".
out=$(FM_TEST_GH_WORKFLOWS_JSON=$(workflows_json \
    ".github/workflows/ci.yml:disabled_manually" \
    ".github/workflows/docker.yml:disabled_manually" \
    "dynamic/dependabot/dependabot-updates:active") \
  run_probe agentic/dependabot-only-active)
[ "$out" = "none" ] || fail "an active-only-via-Dependabot repo verdicted present instead of none (got: $out)"
pass "an active Dependabot dynamic workflow alone (all real workflows disabled) verdicts none"

# The same shape, but with one real workflow still active alongside the
# dynamic Dependabot entry: the real workflow's own active state is what
# makes this "present", not the dynamic one.
out=$(FM_TEST_GH_WORKFLOWS_JSON=$(workflows_json \
    ".github/workflows/ci.yml:active" \
    "dynamic/dependabot/dependabot-updates:active") \
  run_probe agentic/dependabot-plus-real)
[ "$out" = "present" ] || fail "an active real workflow alongside Dependabot did not verdict present (got: $out)"
pass "an active real workflow alongside an active Dependabot entry verdicts present"

# Judgment comes from current workflow STATE, never from historical Actions
# run counts: the probe must query actions/workflows and must never query
# actions/runs at all.
out=$(FM_TEST_GH_WORKFLOWS_JSON=$(workflows_json ".github/workflows/ci.yml:disabled_manually") \
  run_probe agentic/heavy-run-history)
[ "$out" = "none" ] || fail "a workflow-state-disabled repo did not verdict none regardless of run history (got: $out)"
grep -q 'actions/workflows' "$TMP_ROOT/gh.log" \
  || fail "probe did not query repos/{owner}/{repo}/actions/workflows"
assert_not_contains "$(cat "$TMP_ROOT/gh.log")" "actions/runs" \
  "probe queried actions/runs (historical run counts) instead of judging on live workflow state"
pass "the probe judges on current workflow state and never queries historical run counts"

# The forge's answer could not be read (API error / auth failure - the same
# failure surface on the gh api call): never guess "none" here either. This
# is the fail-safe direction, and it differs from the old "unknown" verdict:
# an indeterminate CI-state read must arm the ci step, not stop it.
out=$(FM_TEST_GH_API_FAIL=1 run_probe owner/unreadable)
[ "$out" = "present" ] || fail "an unreadable actions/workflows answer did not verdict present (got: $out)"
pass "an unreadable actions/workflows answer (API/auth failure) verdicts present, not none or unknown"

# The response could be read but contains a workflow state this probe does
# not recognize (e.g. schema drift introducing a new enum value): treated as
# unparseable, and also verdicts present rather than silently treating the
# unrecognized state as inactive.
out=$(FM_TEST_GH_WORKFLOWS_JSON=$(workflows_json ".github/workflows/ci.yml:some_future_state") \
  run_probe owner/unparseable-state)
[ "$out" = "present" ] || fail "an unrecognized workflow state did not verdict present (got: $out)"
pass "an unparseable/unrecognized workflow state verdicts present rather than none"

# No argument, https origin: the probe resolves owner/repo by parsing the
# current directory's origin remote URL directly, then asks the same question.
REPO_DIR=$(git_repo_with_origin "https://github.com/resolved/via-origin.git")
out=$(FM_TEST_GH_WORKFLOWS_JSON=$(workflows_json ".github/workflows/ci.yml:disabled_manually") \
  run_probe_in "$REPO_DIR")
[ "$out" = "none" ] || fail "no-arg https resolution did not verdict none (got: $out)"
grep -q 'api repos/resolved/via-origin/actions/workflows' "$TMP_ROOT/gh.log" \
  || fail "no-arg probe did not query the repo parsed from the https origin remote"
pass "with no argument and an https origin, the probe resolves the repo from origin"

# Fork scenario: origin names a repo that differs from what ambient `gh repo
# view` resolution would pick (its parent repo, per FM_TEST_GH_REPOVIEW). The
# probe must query ORIGIN's workflows, never gh's ambient answer, and must
# never call `gh repo view` at all for no-arg resolution.
FORK_DIR=$(git_repo_with_origin "https://github.com/fork-owner/fork-repo.git")
out=$(FM_TEST_GH_REPOVIEW=upstream-owner/parent-repo \
  FM_TEST_GH_WORKFLOWS_JSON=$(workflows_json ".github/workflows/ci.yml:disabled_manually") \
  run_probe_in "$FORK_DIR")
[ "$out" = "none" ] || fail "fork-shaped no-arg resolution did not verdict none (got: $out)"
grep -q 'api repos/fork-owner/fork-repo/actions/workflows' "$TMP_ROOT/gh.log" \
  || fail "probe on a fork did not query origin's repo (fork-owner/fork-repo)"
assert_not_contains "$(cat "$TMP_ROOT/gh.log")" "repo view" \
  "probe called gh repo view instead of parsing origin directly"
assert_not_contains "$(cat "$TMP_ROOT/gh.log")" \
  "repos/upstream-owner/parent-repo/actions/workflows" \
  "probe queried the fork's parent repo instead of origin"
pass "on a fork, the probe queries origin's workflow state, not gh's ambient parent-repo answer"

# No argument, ssh origin: the same direct parse handles the ssh remote form.
SSH_DIR=$(git_repo_with_origin "git@github.com:ssh-owner/ssh-repo.git")
out=$(FM_TEST_GH_WORKFLOWS_JSON=$(workflows_json ".github/workflows/ci.yml:active") \
  run_probe_in "$SSH_DIR")
[ "$out" = "present" ] || fail "no-arg ssh resolution did not verdict present (got: $out)"
grep -q 'api repos/ssh-owner/ssh-repo/actions/workflows' "$TMP_ROOT/gh.log" \
  || fail "no-arg probe did not query the repo parsed from the ssh origin remote"
pass "with no argument and an ssh origin, the probe resolves the repo from origin"

else
  pass "workflow-state fixtures skipped: jq not found on PATH"
fi

# The origin remote itself could not be resolved (no remote configured at
# all): the repo to even ask about is unknown, so the probe verdicts
# "unknown" rather than guessing either "none" or "present".
NOREMOTE_DIR=$(mktemp -d "$TMP_ROOT/norepo.XXXXXX")
git -C "$NOREMOTE_DIR" init -q
out=$(run_probe_in "$NOREMOTE_DIR")
[ "$out" = "unknown" ] || fail "a missing origin remote did not verdict unknown (got: $out)"
pass "a missing origin remote verdicts unknown rather than guessing"

# An origin remote in an unparseable form (neither github.com https nor ssh):
# same refusal to guess which repo to even ask about.
UNPARSEABLE_DIR=$(git_repo_with_origin "https://gitlab.com/owner/repo.git")
out=$(run_probe_in "$UNPARSEABLE_DIR")
[ "$out" = "unknown" ] || fail "an unparseable origin remote did not verdict unknown (got: $out)"
pass "an unparseable origin remote verdicts unknown rather than guessing"

echo "ALL TESTS PASSED"
