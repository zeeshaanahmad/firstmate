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
#   With no argument, resolves the repo from the current directory's "origin"
#   remote via `gh repo view`.
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
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    echo "unknown"
    echo "error: could not resolve owner/repo from the current directory's origin remote" >&2
    exit 0
  }
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
