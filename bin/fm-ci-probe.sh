#!/usr/bin/env bash
# Prints whether a GitHub repo has any reachable CI check surface, derived
# from the forge's own answer rather than any per-project hardcoding:
#   none      no Actions run has ever completed on this repo - no-mistakes'
#             ci step has no reachable end condition (kunchenguid/no-mistakes#475,
#             #666: it polls its full timeout, historically 168h, for a check
#             that can never register). Start no-mistakes with --skip=ci.
#   present   at least one Actions run exists - checks may land on a PR.
#   unknown   the forge's answer could not be read (auth, network, missing
#             repo, or API error). Never guess: treat like "present" and let
#             the ci step run, or fail loudly and ask before skipping it.
#
# Deliberately does not call the repos/{o}/{r}/actions/permissions endpoint:
# it 403s for anyone without admin rights on the repo, which is the common
# case for a contributor fork, and would degrade every such probe to unknown.
# The actions/runs total_count needs only ordinary read access and directly
# answers the question that matters: has a check ever actually registered.
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

TOTAL=$(gh api "repos/$REPO/actions/runs?per_page=1" -q .total_count 2>/dev/null) || {
  echo "unknown"
  echo "error: could not read repos/$REPO/actions/runs" >&2
  exit 0
}

if [ "$TOTAL" = "0" ]; then
  echo "none"
else
  echo "present"
fi
