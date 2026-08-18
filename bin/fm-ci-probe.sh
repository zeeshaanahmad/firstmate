#!/usr/bin/env bash
# Prints whether a GitHub repo has any reachable CI check surface, derived
# from the forge's own answer rather than any per-project hardcoding:
#   none      every real workflow on the repo (i.e. every workflow whose path
#             is not GitHub's own dynamically-provided "dynamic/..." kind) is
#             in a non-active state (disabled_manually, disabled_inactivity,
#             disabled_fork, or deleted) - no real workflow can ever run, so
#             no check can ever register on a PR. no-mistakes' ci step has no
#             reachable end condition (kunchenguid/no-mistakes#475, #666: it
#             polls its full timeout, historically 168h, for a check that can
#             never arrive). Start no-mistakes with --skip=ci.
#   present   at least one real (non-dynamic) workflow is active - a check may
#             land on a PR.
#   unknown   the repo to probe could not even be determined (no origin
#             remote, or its URL could not be parsed). Never guess: treat
#             like "present" and let the ci step run, or fail loudly and ask
#             before skipping it.
#
# Judges on the CURRENT STATE of the repo's workflows
# (repos/{o}/{r}/actions/workflows), never on historical run counts
# (repos/{o}/{r}/actions/runs): a repo can carry Actions run history from
# before its workflows were disabled (e.g. hundreds of old pull_request runs
# on a workflow now state=disabled_manually), which would misreport "present"
# for a repo that can no longer ever complete a check.
#
# Excludes every workflow whose path starts with "dynamic/" - GitHub's own
# dynamically-provided workflows (Dependabot Updates, Copilot code review,
# Copilot cloud agent) that have no YAML file in the repository. These read
# state=active but never register a check on an ordinary code pull request,
# so counting them as "present" would arm a ci step that still wedges
# forever. The "dynamic/" path prefix is a structural fact of the API
# response, not a name a release note could rename out from under this
# check.
#
# Deliberately does not call the repos/{o}/{r}/actions/permissions endpoint:
# it 403s for anyone without admin rights on the repo, which is the common
# case for a contributor fork, and would degrade every such probe to unknown.
# The actions/workflows list needs only ordinary read access.
#
# When the forge's workflow-state answer cannot be read or understood (API
# error, auth failure, an unparseable response), this reports "present" -
# not "none" - so an unreadable answer never silently disarms CI. Only a
# failure to even determine which repo to ask about reports "unknown".
#
# Usage: fm-ci-probe.sh [<owner/repo>]
#   With no argument, resolves owner/repo by parsing the current directory's
#   "origin" remote URL directly (https or ssh form). This is deliberate:
#   bare `gh repo view` resolves ambient parent-repo defaults (e.g. a fork's
#   upstream parent) instead of origin, which would probe the wrong repo's
#   Actions history on a fork and defeat the whole check.
# Requires the `gh` CLI, authenticated for the target repo. Never used to
# monitor an in-progress run: no-mistakes' own ci step owns that; this is a
# one-time answer read before a run starts.
set -eu

case "${1:-}" in
  -h|--help)
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
    exit 0
    ;;
esac

REPO="${1:-}"
if [ -z "$REPO" ]; then
  ORIGIN_URL=$(git remote get-url origin 2>/dev/null) || {
    echo "unknown"
    echo "error: could not read the current directory's origin remote" >&2
    exit 0
  }
  case "$ORIGIN_URL" in
    git@github.com:*)
      REPO=${ORIGIN_URL#git@github.com:}
      ;;
    ssh://git@github.com/*)
      REPO=${ORIGIN_URL#ssh://git@github.com/}
      ;;
    https://github.com/*)
      REPO=${ORIGIN_URL#https://github.com/}
      ;;
    *)
      REPO=
      ;;
  esac
  REPO=${REPO%.git}
  if [ -z "$REPO" ]; then
    echo "unknown"
    echo "error: could not parse owner/repo from origin remote url: $ORIGIN_URL" >&2
    exit 0
  fi
fi

STATES=$(gh api "repos/$REPO/actions/workflows" --paginate -q \
  '.workflows[] | select((.path | startswith("dynamic/")) | not) | .state' 2>/dev/null) || {
  echo "present"
  echo "error: could not read repos/$REPO/actions/workflows" >&2
  exit 0
}

HAS_ACTIVE=0
UNPARSEABLE=0
while IFS= read -r STATE; do
  [ -z "$STATE" ] && continue
  case "$STATE" in
    active)
      HAS_ACTIVE=1
      ;;
    disabled_fork|disabled_inactivity|disabled_manually|deleted)
      ;;
    *)
      UNPARSEABLE=1
      ;;
  esac
done <<EOF
$STATES
EOF

if [ "$UNPARSEABLE" = "1" ]; then
  echo "present"
  echo "error: repos/$REPO/actions/workflows returned an unparseable workflow state" >&2
  exit 0
fi

if [ "$HAS_ACTIVE" = "1" ]; then
  echo "present"
else
  echo "none"
fi
