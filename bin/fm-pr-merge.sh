#!/usr/bin/env bash
# Merge a task's PR or MR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical URL is parsed by bin/fm-pr-lib.sh. A GitHub pull request is
# addressed through gh-axi by the derived owner and repository; a GitLab merge
# request is addressed through glab by the project URL rebuilt from the parsed
# host and path, so any instance works and no host is hardcoded.
#
# EVERY GUARD BELOW RUNS ON BOTH FORGES. They read the base branch and head from
# the forge that hosts the request and compare them with git, so nothing in them
# is GitHub-specific except how those two refs are named and asked for.
#
# MERGE-TIME STATIC GUARD. Immediately before the merge, this computes the exact
# merge RESULT of the PR head onto the CURRENT base-branch tip with
# `git merge-tree --write-tree`, writes that tree out, and runs the project's
# OWN pinned static check against it (bin/fm-static-guard-lib.sh owns discovery
# and execution). A red result refuses the merge and tells the lane to rebase
# onto current main and re-gate; a conflicted merge is refused on the same
# ground. The guard runs unconditionally rather than behind a staleness probe:
# it was measured at a 1.0s median across 106 merges of a project whose checker
# is a fast linter, which does not pay for the extra branch. That median is not
# universal - a project whose own gate is a slow one pays that gate on every
# merge here; see docs/verification/merge-time-static-guard.md. It never writes
# to the project.
#
# WHAT THE GUARD DOES NOT CATCH. The static class only - undefined names,
# imports, formatting, and whatever else the project's own checker reports.
# Runtime test failures, type-checker errors, and snapshot drift all pass it.
#
# THE GUARD DOES NOT SURVIVE AN AIRGAPPED SITE. It needs the forge to learn the
# current tip of the branch it targets, and a pinned checker fetched by its
# pin needs the network on a cold cache. Where it cannot REACH the check at
# all it says "merge-guard: UNGUARDED - <reason>" out loud and merges as
# before, rather than implying a check that did not happen or wedging every
# merge behind an unrelated outage.
#
# A CHECK THAT RAN OUT OF BUDGET IS DIFFERENT, AND REFUSES. The unguarded cases
# above have no next step: the forge is gone, or the project declares no check.
# A check that was discovered, launched, and then killed by its budget has an
# obvious one - run it again with room - and it measured nothing, so treating it
# as permission to merge is exactly the "unmeasured is green" conflation this
# guard exists to remove. On 2026-08-24 that conflation merged a PR after
# printing its own absence. A timeout now refuses, naming the budget that was
# exceeded and the two ways forward.
#
# The verdict is recorded in the task's metadata as ONE field:
#   merge_guard=green | red | off
#              | unguarded: <reason>       no verdict reachable; merged
#              | timeout: <reason>         check killed; merge REFUSED
#              | timeout-allowed: <reason> check killed; merged by explicit flag
# so teardown and any later audit can see whether it ran and what it said, and
# can tell an operator's deliberate override from a default.
#
# FM_MERGE_GUARD selects the guard's posture and takes exactly three values:
#   unset          run the guard; refuse red, conflicts, and an unfinished check
#   off            skip the guard entirely and record merge_guard=off. For the
#                  one case refusing cannot fix: a default branch already red for
#                  reasons this PR did not cause, where every merge would
#                  otherwise be blocked. A deliberate decision, not a way past an
#                  inconvenient red.
#   allow-timeout  run the guard and still refuse red and conflicts, but merge
#                  past a check that could not finish. Narrower than off on
#                  purpose: it answers "the check could not finish", never "the
#                  check said no".
# Any other value is refused rather than silently ignored, so a misspelled
# override never quietly becomes a different posture than the operator asked for.
#
# Merge method on GitHub defaults to --squash when the caller passes none of
# --squash, --merge, --rebase, or --method after the optional -- separator.
# The gh-axi merge abstraction always performs the merge; the outcome read that
# follows it never becomes a prerequisite for reaching that abstraction. After
# gh-axi returns success, GitHub's live state is read back and accepted only
# when the pull request is merged or in the merge queue. gh's GraphQL API
# supplies that queue-aware read when gh is on PATH; when gh is absent or its
# read fails, gh-axi's own view still proves a landed merge, and every outcome
# it cannot prove refuses, reporting the single failed read when gh is absent
# and naming both failed reads when gh is present and its own read failed.
# If the pull request remains open and the base branch has an effective
# merge_queue rule, the refusal names the queue's configured merge method and
# the exact -- --auto --<method> retry flags, unless the caller already passed
# that method with --auto to a merge command that returned success, in which
# case it reports instead that the accepted request has not entered the queue
# and the queue state has to be re-checked.
# No method is selected for the caller in any case. A rules response that names
# no queue rule, one that could not be read, rules that disagree, and a method
# this script does not recognise are four distinct outcomes and are reported
# apart, because each one leaves the operator somewhere different.
# A caller-requested --auto that leaves the pull request neither merged nor
# queued is refused the same way and says auto-merge was armed with nothing
# landed or queued yet, or, when the merge command itself failed, that auto-merge
# was only requested; both are read from the caller's own arguments rather than
# from the forge's prose. The observed state is judged the same way whichever
# read produced it, and a refusal built on the gh-axi view says the merge queue
# could not be observed at all rather than implying an unqueued pull request.
# Every refusal that follows a merge command which returned success quotes that
# command's own output, marked as the forge's text and kept apart from this
# script's verdict, including the refusal for an outcome that cannot be read;
# a merge command that failed keeps its original error surfaced raw and first.
# GitLab adds no method flag at all: its merge method is the project's own
# setting, which the merge API applies, and imposing squash there would override
# that convention rather than mirror the GitHub default.
#
# A GitLab merge is refused unless every pre-merge condition holds, each read
# live at merge time rather than taken from recorded metadata: the merge request
# is open, detailed_merge_status is mergeable, has_conflicts is false,
# blocking_discussions_resolved is true, and the head pipeline succeeded at the
# exact current head commit. Every failing condition is reported, not just the
# first. The verified head is then passed to glab as --sha, so a push that lands
# between that read and the merge fails the merge instead of landing commits
# nothing verified. A recorded pr_head that disagrees with the live head is
# reported rather than trusted, because a rebase moves the head and leaves the
# recorded value stale. Reading that state needs glab and jq, and either one
# absent stops the merge before any state is recorded.
#
# Extra args must not include --repo or -R in any form, including a bundled
# short-option cluster such as -yR, because the repository comes only from the
# URL, nor --sha on GitLab because the head comes only from the live read.
#
# UPSTREAM-HISTORY GUARD. That squash default is right for a lane's own work and
# wrong for a fork-sync PR, where the history IS the deliverable. Squashing one
# flattens its merge and drops the upstream commits it brought in out of the
# base branch's ancestry, so the next sync computes its merge base against a
# waypoint that is no longer reachable and replays commits the base already
# carries. On 2026-08-25 that erased upstream 7f5255a from this repo's main.
# Before any method that rewrites history - squash, rebase, or the squash
# default - this checks whether the PR head carries commits that are reachable
# from an upstream remote and not already reachable from the PR's base branch.
# When it does, the merge is REFUSED and the commits that would be erased are
# named. On GitHub the remedy is --merge, the only method that keeps them
# reachable. On GitLab the merge method is the project's own setting, which this
# path can neither read nor override, so an unnamed method reads as rewriting
# and such a merge request is refused here; land it in GitLab with the project
# configured to create a merge commit. There is deliberately no override flag on
# either forge: a flag the caller must remember is exactly what failed.
#
# WHICH REMOTES COUNT AS UPSTREAM. Any remote of the local copy whose fetch URL
# names a hosted repository OTHER than the one this PR is on. That reads the
# fork-source relationship out of long-lived repository configuration instead of
# a per-task branch name a brief could misspell. A remote whose URL is a local
# path is excluded: those are another tool's private mirror of this same
# repository, and counting one would make every ordinary PR look like shared
# history.
#
# WHAT THIS GUARD DOES NOT CATCH. A project with no upstream remote has no
# shared history to preserve and is never checked. A configured upstream remote
# that was never fetched here leaves nothing local to compare against; that says
# so out loud and merges, because refusing would wedge every merge in a fresh
# clone. Where an upstream remote HAS been fetched, a base or head that could
# not be resolved REFUSES, on the same ground as the static guard's timeout: an
# unmeasured check is not a clear one.
#
# FM_MERGE_GUARD does not reach this guard. It selects the static check's
# posture only, and `off` turns that check off, never this one.
#
# REQUIRED WAYPOINT ANCESTRY GUARD. An upstream reconciliation batch names the
# exact upstream commit that must remain reachable from what is merged. The
# guard resolves the forge's current PR head and refuses unless
# `git merge-base --is-ancestor <waypoint> <head>` succeeds. Both the waypoint
# and head are printed on success and failure, so a pipeline-flattened batch is
# loud even though its file content still looks complete. The value must be a
# full lowercase 40-character commit SHA; this keeps the assertion immutable
# and prevents a moving ref from changing what was checked.
#
# The waypoint comes from either of two places, so the assertion does not
# depend on remembering a flag at merge time:
#   --require-ancestor <sha>   passed on this command, before the optional --
#   waypoint=<sha>             recorded in state/<task-id>.meta when the batch
#                              was prepared
# When both are present they must name the same commit; disagreement is a
# refusal, because two different answers to "what must survive" is not a
# question this script may settle on its own.
#
# On GitLab, this script confirms the MR is actually merged before reporting it;
# an auto-merge-queued or unconfirmed request leaves the poll armed and records
# no landed outcome. bin/fm-merge-outcome-lib.sh owns a confirmed merge's
# destination, normal-case deduplication, and at-least-once recovery.
# A landed merge whose outcome cannot be written is reported loudly rather than
# misreported as a failed merge.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--require-ancestor <sha>] [-- <extra forge merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-static-guard-lib.sh
. "$SCRIPT_DIR/fm-static-guard-lib.sh"
# shellcheck source=bin/fm-merge-outcome-lib.sh
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
# Role partition: merging is MAIN-owned; the Pi supervision branch reports the
# green PR and never merges (contract: bin/fm-lease-lib.sh; no-op in homes
# without a branch actor).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "PR merge (fm-pr-merge)"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
# The forge-neutral identity of the project this request is on: <owner>/<repo>
# on GitHub, and the full namespace path on GitLab. Every guard that has to ask
# "is this remote the same project?" compares against this one value.
PR_PATH=$FM_PR_PATH
# glab resolves the instance from the project URL passed to -R, so the host is
# rebuilt from the parsed identity rather than read from any ambient default.
PROJECT_URL="https://$FM_PR_HOST/$FM_PR_PATH"
shift 2

REQUIRED_ANCESTOR=
REQUIRE_ANCESTOR_SEEN=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --require-ancestor)
      [ -z "$REQUIRE_ANCESTOR_SEEN" ] || {
        echo "error: --require-ancestor may be passed only once" >&2
        exit 2
      }
      REQUIRE_ANCESTOR_SEEN=1
      [ "$#" -ge 2 ] || {
        echo "error: --require-ancestor requires a full commit SHA" >&2
        exit 2
      }
      REQUIRED_ANCESTOR=$2
      shift 2
      ;;
    --require-ancestor=*)
      [ -z "$REQUIRE_ANCESTOR_SEEN" ] || {
        echo "error: --require-ancestor may be passed only once" >&2
        exit 2
      }
      REQUIRE_ANCESTOR_SEEN=1
      REQUIRED_ANCESTOR=${1#--require-ancestor=}
      shift
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done
if [ -n "$REQUIRE_ANCESTOR_SEEN" ] && ! fm_static_guard_sha_valid "$REQUIRED_ANCESTOR"; then
  echo "error: --require-ancestor requires a full lowercase 40-character commit SHA" >&2
  exit 2
fi

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

# The merge method the caller's own extra arguments named, in the --flag,
# --method <value> and --method=<value> forms caller_has_merge_method accepts.
caller_merge_method() {
  local arg method='' pending=false
  for arg in "$@"; do
    if [ "$pending" = true ]; then
      method=$arg
      pending=false
      continue
    fi
    case "$arg" in
      --squash) method=squash ;;
      --merge) method=merge ;;
      --rebase) method=rebase ;;
      --method) pending=true ;;
      --method=*) method=${arg#--method=} ;;
    esac
  done
  printf '%s' "$method"
}

# Whether the caller's own extra arguments asked for auto-merge, including the
# --flag=value spelling the forge's flag parser accepts. --disable-auto cancels
# the request, and gh exposes no short option that could bundle either flag.
caller_requested_auto_merge() {
  local arg requested=1
  for arg in "$@"; do
    case "$arg" in
      --auto) requested=0 ;;
      --auto=*)
        case "${arg#--auto=}" in
          [tT]|[tT][rR][uU][eE]|1) requested=0 ;;
          *) requested=1 ;;
        esac
        ;;
      --disable-auto) requested=1 ;;
    esac
  done
  return "$requested"
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
      --*) ;;
      # A single-dash argument is a short-option cluster, which both CLIs expand
      # one character at a time, so -yR carries --repo exactly as a bare -R does.
      -*R*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_head_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --sha|--sha=*)
        echo "error: extra merge arguments must not override the head commit" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1
[ "$PROVIDER" != gitlab ] || reject_head_overrides "$@" || exit 1

# Resolved once, before any work, so an unreadable posture stops the merge
# rather than half-running it.
MERGE_GUARD_MODE=${FM_MERGE_GUARD:-}
case "$MERGE_GUARD_MODE" in
  ''|off|allow-timeout) ;;
  *)
    echo "error: FM_MERGE_GUARD must be unset, off, or allow-timeout" >&2
    exit 2
    ;;
esac

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Reading the merge request state needs both tools. Report them together and
# before anything is recorded, so a missing tool is a named prerequisite rather
# than a merge that is armed and then refused for an unexplained reason.
GITLAB_MISSING=
if [ "$PROVIDER" = gitlab ]; then
  command -v glab >/dev/null 2>&1 || GITLAB_MISSING="glab"
  if ! command -v jq >/dev/null 2>&1; then
    GITLAB_MISSING="${GITLAB_MISSING:+$GITLAB_MISSING and }jq"
  fi
  if [ -n "$GITLAB_MISSING" ]; then
    echo "error: merging a GitLab merge request requires $GITLAB_MISSING on PATH" >&2
    exit 1
  fi
fi

# The recorded head is read before bin/fm-pr-check.sh rewrites the metadata,
# because that script re-records pr= and drops a pr_head= it cannot resolve.
RECORDED_HEAD=
if [ "$PROVIDER" = gitlab ]; then
  RECORDED_HEAD=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
fi

record_pr_metadata() {
  if ! "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"; then
    return 1
  fi
  grep -qxF "pr=$URL" "$META" || {
    echo "error: PR metadata recording failed" >&2
    return 1
  }
}

# Record before either forge call, and before the guards below, so the merge
# poll is armed with the PR identity teardown needs even when a guard refuses
# or a provider read fails after a real merge. The waypoint is read after this
# runs, because bin/fm-pr-check.sh rewrites the metadata.
record_pr_metadata || exit 1

meta_field() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# A batch that recorded its waypoint when it was prepared is asserted even if
# the merge command omits --require-ancestor, so the guarantee does not rest on
# remembering a flag. A recorded value that is not a full SHA is an error rather
# than something to skip past: it was written to be checked.
RECORDED_ANCESTOR=$(meta_field waypoint)
if [ -n "$RECORDED_ANCESTOR" ]; then
  if ! fm_static_guard_sha_valid "$RECORDED_ANCESTOR"; then
    echo "error: recorded waypoint for this task is not a full lowercase 40-character commit SHA: $RECORDED_ANCESTOR" >&2
    exit 2
  fi
  if [ -z "$REQUIRED_ANCESTOR" ]; then
    REQUIRED_ANCESTOR=$RECORDED_ANCESTOR
  elif [ "$REQUIRED_ANCESTOR" != "$RECORDED_ANCESTOR" ]; then
    echo "error: merge refused - --require-ancestor $REQUIRED_ANCESTOR disagrees with the waypoint $RECORDED_ANCESTOR recorded for this task" >&2
    echo "resolve which upstream commit this batch must keep reachable before merging" >&2
    exit 1
  fi
fi

# Remove a temporary file this script created, refusing an empty path so no
# removal can compose a root-relative target.
tmp_remove() {  # <path>
  local tmp=${1-}
  [ -n "$tmp" ] || return 0
  [ -f "$tmp" ] && [ ! -L "$tmp" ] || return 0
  rm -f -- "$tmp"
}

# Rewrite the single merge_guard= line, preserving every other metadata line.
merge_guard_record() {  # <value>
  local value=$1 lock tmp
  # bin/fm-pr-lib.sh owns which verdict strings the metadata may carry, so a
  # value it would later refuse never reaches the file.
  fm_pr_merge_guard_value_valid "$value" || return 1
  lock=$(fm_meta_lock_path "$META") || return 1
  fm_lock_acquire_wait "$lock"
  [ -f "$META" ] && [ ! -L "$META" ] || { fm_lock_release "$lock"; return 1; }
  tmp=$(mktemp "$STATE/.fm-pr-merge-meta.XXXXXX") || { fm_lock_release "$lock"; return 1; }
  if ! { grep -v '^merge_guard=' "$META" || true; } > "$tmp"; then
    tmp_remove "$tmp"; fm_lock_release "$lock"; return 1
  fi
  printf 'merge_guard=%s\n' "$value" >> "$tmp" || { tmp_remove "$tmp"; fm_lock_release "$lock"; return 1; }
  chmod 0600 "$tmp" || { tmp_remove "$tmp"; fm_lock_release "$lock"; return 1; }
  mv -f -- "$tmp" "$META" || { tmp_remove "$tmp"; fm_lock_release "$lock"; return 1; }
  fm_lock_release "$lock"
}

# Which local checkout of this project can lend its object store. The task's own
# worktree is the first choice because it already contains the PR's history;
# the registered clone is the fallback for a task whose worktree is gone.
merge_guard_source_repo() {
  local candidate
  for candidate in "$(meta_field worktree)" "$(meta_field project)"; do
    [ -n "$candidate" ] && [ -d "$candidate" ] || continue
    git -C "$candidate" rev-parse --git-dir >/dev/null 2>&1 || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

# The branch this PR actually targets, which is not always the repository's
# default branch. The forge is authoritative; the remote's advertised HEAD is
# the fallback when the forge cannot be asked.
merge_guard_base_branch() {  # <source-repo> <remote-url>
  local src=$1 url=$2 branch=
  case "$PROVIDER" in
    github)
      if command -v gh >/dev/null 2>&1 \
        && branch=$(cd "$src" && gh pr view "$URL" --json baseRefName -q .baseRefName 2>/dev/null) \
        && fm_static_guard_ref_name_safe "$branch"; then
        printf '%s\n' "$branch"
        return 0
      fi
      ;;
    gitlab)
      # A separate read from the pre-merge one below, because it answers a
      # different question and is needed before the guards run rather than at
      # the moment of merging. GITLAB_HOST comes from the parsed URL for the
      # same reason it does there.
      if branch=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" -R "$PROJECT_URL" -F json 2>/dev/null \
        | jq -r 'if type == "object" then (.target_branch // "") else "" end' 2>/dev/null) \
        && fm_static_guard_ref_name_safe "$branch"; then
        printf '%s\n' "$branch"
        return 0
      fi
      ;;
  esac
  fm_static_guard_default_branch "$url" || return 1
  printf '%s\n' "$FM_STATIC_GUARD_BRANCH"
}

# The PR's base branch tip as the forge has it right now, and the PR head, both
# resolved into a private object store that borrows the local copy's objects.
# Both merge guards read the same pair, so neither can judge a different merge
# than the other. Resolved at most once per run; a failure records the reason
# and each guard decides for itself what an unresolved pair means.
MERGE_REFS_BRANCH=
MERGE_REFS_BASE=
MERGE_REFS_HEAD=
MERGE_REFS_REASON=
MERGE_REFS_ATTEMPTED=
MERGE_REFS_OK=
merge_refs_resolve() {
  local src url branch base head recorded_head head_ref
  MERGE_REFS_BRANCH=
  MERGE_REFS_BASE=
  MERGE_REFS_HEAD=
  MERGE_REFS_REASON=
  command -v git >/dev/null 2>&1 || { MERGE_REFS_REASON='git is unavailable'; return 1; }
  src=$(merge_guard_source_repo) || { MERGE_REFS_REASON='no local copy of this project to read objects from'; return 1; }
  fm_static_guard_remote_pick "$src" "$PR_PATH" \
    || { MERGE_REFS_REASON='no usable remote for this project'; return 1; }
  url=$FM_STATIC_GUARD_REMOTE
  branch=$(merge_guard_base_branch "$src" "$url") \
    || { MERGE_REFS_REASON='the base branch of this PR could not be resolved'; return 1; }
  MERGE_REFS_BRANCH=$branch
  fm_static_guard_scratch_new || { MERGE_REFS_REASON='no scratch directory'; return 1; }
  fm_static_guard_repo_prepare "$src" \
    || { MERGE_REFS_REASON='a private object store could not be prepared'; return 1; }
  recorded_head=$(meta_field pr_head)
  # Each forge publishes a request's head under its own namespace: GitHub serves
  # refs/pull/<n>/head, GitLab serves refs/merge_requests/<n>/head.
  case "$PROVIDER" in
    gitlab) head_ref="refs/merge_requests/$PR_NUMBER/head" ;;
    *) head_ref="refs/pull/$PR_NUMBER/head" ;;
  esac
  if fm_static_guard_fetch "$FM_STATIC_GUARD_GITDIR" "$url" \
    "+refs/heads/$branch:$FM_STATIC_GUARD_BASE_REF" \
    "+$head_ref:$FM_STATIC_GUARD_HEAD_REF"; then
    head=$(git --git-dir="$FM_STATIC_GUARD_GITDIR" rev-parse --verify --quiet "$FM_STATIC_GUARD_HEAD_REF" 2>/dev/null) || head=
  elif fm_static_guard_fetch "$FM_STATIC_GUARD_GITDIR" "$url" \
    "+refs/heads/$branch:$FM_STATIC_GUARD_BASE_REF"; then
    # A forge that does not serve that ref still leaves the head that
    # bin/fm-pr-check.sh recorded, which the borrowed object store already has.
    head=$(fm_static_guard_sha_valid "$recorded_head" \
      && git --git-dir="$FM_STATIC_GUARD_GITDIR" rev-parse --verify --quiet "$recorded_head^{commit}" 2>/dev/null) || head=
  else
    MERGE_REFS_REASON="the current tip of $branch could not be fetched"
    return 1
  fi
  base=$(git --git-dir="$FM_STATIC_GUARD_GITDIR" rev-parse --verify --quiet "$FM_STATIC_GUARD_BASE_REF" 2>/dev/null) || base=
  [ -n "$base" ] || { MERGE_REFS_REASON="the current tip of $branch could not be read"; return 1; }
  # Recorded ahead of the head check below so a caller can tell "this project's
  # base branch was genuinely reachable, but its head specifically was not" (a
  # real, actionable gap) apart from "nothing here could be checked at all" (an
  # unrelated, already-accepted environmental unguarded state).
  MERGE_REFS_BASE=$base
  [ -n "$head" ] || { MERGE_REFS_REASON='the PR head commit could not be read'; return 1; }
  MERGE_REFS_HEAD=$head
}

# Resolve the pair on first use and reuse that outcome afterwards, so two guards
# never fetch twice or disagree about what the fetch found.
merge_refs_ensure() {
  if [ -z "$MERGE_REFS_ATTEMPTED" ]; then
    MERGE_REFS_ATTEMPTED=1
    if merge_refs_resolve; then MERGE_REFS_OK=1; else MERGE_REFS_OK=; fi
  fi
  [ -n "$MERGE_REFS_OK" ]
}

# Sets MERGE_GUARD_VERDICT to green, red, or "unguarded: <reason>", and
# MERGE_GUARD_NOTE to the human-readable line printed for it. Never exits.
MERGE_GUARD_VERDICT=
MERGE_GUARD_NOTE=
# Record that no verdict was reached, and why. The reason is never empty,
# because "unguarded" with nothing after it tells the reader nothing.
merge_guard_unguarded() {  # <reason>
  local reason=${1:-no reason given}
  [ -n "$reason" ] || reason='no reason given'
  MERGE_GUARD_VERDICT="unguarded: $reason"
  MERGE_GUARD_NOTE="$reason"
}
merge_guard_evaluate() {
  local branch base rc=0
  MERGE_GUARD_VERDICT=
  MERGE_GUARD_NOTE=
  merge_refs_ensure || { merge_guard_unguarded "$MERGE_REFS_REASON"; return 0; }
  branch=$MERGE_REFS_BRANCH
  base=$MERGE_REFS_BASE
  rc=0
  fm_static_guard_merge_tree "$FM_STATIC_GUARD_GITDIR" "$base" "$MERGE_REFS_HEAD" || rc=$?
  if [ "$rc" -eq 2 ]; then
    MERGE_GUARD_VERDICT=red
    MERGE_GUARD_NOTE="the PR conflicts with the current tip of $branch"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    merge_guard_unguarded 'the merge result could not be computed'
    return 0
  fi
  fm_static_guard_evaluate_tree "$FM_STATIC_GUARD_GITDIR" "$base" "$FM_STATIC_GUARD_TREE"
  case "$FM_STATIC_GUARD_VERDICT" in
    green)
      MERGE_GUARD_VERDICT=green
      MERGE_GUARD_NOTE="$branch@${base:0:12} + this PR passes ${FM_STATIC_GUARD_DETAIL}"
      ;;
    red)
      MERGE_GUARD_VERDICT=red
      MERGE_GUARD_NOTE="the merge result of this PR onto $branch@${base:0:12} fails ${FM_STATIC_GUARD_DETAIL}"
      ;;
    timeout)
      MERGE_GUARD_VERDICT=timeout
      MERGE_GUARD_NOTE="$FM_STATIC_GUARD_DETAIL"
      ;;
    *)
      merge_guard_unguarded "$FM_STATIC_GUARD_DETAIL"
      ;;
  esac
}

# The merge method this invocation will actually use: the caller's explicit
# choice, or the forge default when it passes none. A --method with no value, or
# one naming something this script does not recognise, reads as empty, which the
# upstream-history guard treats as rewriting - so a malformed method can never
# slip past it as though it were --merge. GitLab's unnamed default is the
# project's own setting, which nothing here can read, so it reads as rewriting
# for the same reason rather than being assumed safe.
resolved_merge_method() {
  local arg method want_value=
  # GitLab applies the project's own merge method and takes no flag for it, so
  # no argument on this command can prove the result will keep shared history.
  # That reads as rewriting rather than being assumed safe.
  if [ "$PROVIDER" = gitlab ]; then
    printf '\n'
    return 0
  fi
  method=squash
  for arg in "$@"; do
    if [ -n "$want_value" ]; then
      method=$arg
      want_value=
      continue
    fi
    case "$arg" in
      --squash) method=squash ;;
      --merge) method=merge ;;
      --rebase) method=rebase ;;
      --method=*) method=${arg#--method=} ;;
      --method) method=; want_value=1 ;;
    esac
  done
  printf '%s\n' "$method"
}

# The hosted project path a remote URL names - <owner>/<repo> on GitHub and the
# full namespace path on GitLab - and nothing for a URL that names no host. The
# whole path is kept rather than its last two segments so this compares equal to
# the parsed PR_PATH on a forge whose namespaces nest. A local path is
# deliberately not a slug: another tool's private mirror of this same repository
# must never read as a separate upstream.
upstream_remote_slug() {  # <url>
  local url=${1-} path
  url=${url%/}
  url=${url%.git}
  case "$url" in
    /*|file://*) return 1 ;;
    *://*)
      # scheme://[user@]host[:port]/<path>
      path=${url#*://}
      path=${path#*@}
      case "$path" in
        */*) path=${path#*/} ;;
        *) return 1 ;;
      esac
      ;;
    *:*) path=${url#*:} ;;
    *) return 1 ;;
  esac
  case "$path" in
    */*) ;;
    *) return 1 ;;
  esac
  [ "${path%/*}" != "" ] && [ "${path##*/}" != "" ] || return 1
  # Lowercased because a forge that treats project paths case-insensitively
  # would otherwise let a differently-cased origin URL read as a second,
  # foreign repository and make every ordinary PR look like shared history.
  printf '%s\n' "$path" | tr '[:upper:]' '[:lower:]'
}

# Remotes of the local copy that serve a hosted repository other than the one
# this PR is on. That is the fork-source relationship, read from configuration
# the repository already keeps for its own reasons.
upstream_remote_names() {  # <source-repo>
  local src=$1 name url slug self
  self=$(printf '%s' "$PR_PATH" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    url=$(git -C "$src" remote get-url "$name" 2>/dev/null) || continue
    fm_project_origin_safe "$url" || continue
    slug=$(upstream_remote_slug "$url") || continue
    [ "$slug" != "$self" ] || continue
    printf '%s\n' "$name"
  done < <(git -C "$src" remote 2>/dev/null)
}

# Every commit the local copy has as a tip of those remotes. Reachability from
# any one of them is what makes a commit shared history rather than this lane's
# own work.
upstream_tip_commits() {  # <source-repo> <remote-name>...
  local src=$1 name
  shift
  for name in "$@"; do
    git -C "$src" for-each-ref --format='%(objectname)' "refs/remotes/$name/" 2>/dev/null
  done | LC_ALL=C sort -u
}

# Sets UPSTREAM_GUARD_VERDICT to one of:
#   none        this project tracks no upstream, so there is nothing to preserve
#   clear       the PR adds no commit that upstream also has
#   blocked     it does, and rewriting would erase them; UPSTREAM_GUARD_ERASED
#               holds those commits, newest first
#   unguarded   nothing local to compare against; the reason is in the note
#   unmeasured  upstream history exists here but the comparison could not be run
# Never exits, so the caller owns the refusal path.
UPSTREAM_GUARD_VERDICT=
UPSTREAM_GUARD_NOTE=
UPSTREAM_GUARD_ERASED=
upstream_guard_evaluate() {
  local src names tips added kept erased kept_file count name_line
  local -a tip_args=()
  UPSTREAM_GUARD_VERDICT=
  UPSTREAM_GUARD_NOTE=
  UPSTREAM_GUARD_ERASED=
  command -v git >/dev/null 2>&1 || {
    UPSTREAM_GUARD_VERDICT=unguarded
    UPSTREAM_GUARD_NOTE='git is unavailable'
    return 0
  }
  src=$(merge_guard_source_repo) || {
    UPSTREAM_GUARD_VERDICT=unguarded
    UPSTREAM_GUARD_NOTE='no local copy of this project to read its remotes from'
    return 0
  }
  names=$(upstream_remote_names "$src") || names=
  if [ -z "$names" ]; then
    UPSTREAM_GUARD_VERDICT=none
    return 0
  fi
  while IFS= read -r name_line; do
    [ -n "$name_line" ] || continue
    tip_args+=("$name_line")
  done <<UPSTREAM_NAMES
$names
UPSTREAM_NAMES
  tips=$(upstream_tip_commits "$src" "${tip_args[@]+"${tip_args[@]}"}") || tips=
  if [ -z "$tips" ]; then
    UPSTREAM_GUARD_VERDICT=unguarded
    UPSTREAM_GUARD_NOTE='this project tracks an upstream repository that has never been fetched into this copy, so there is no upstream history here to compare against'
    return 0
  fi
  tip_args=()
  while IFS= read -r name_line; do
    [ -n "$name_line" ] || continue
    tip_args+=("$name_line")
  done <<UPSTREAM_TIPS
$tips
UPSTREAM_TIPS
  merge_refs_ensure || {
    UPSTREAM_GUARD_VERDICT=unmeasured
    UPSTREAM_GUARD_NOTE=$MERGE_REFS_REASON
    return 0
  }
  added=$(git --git-dir="$FM_STATIC_GUARD_GITDIR" rev-list \
    "$MERGE_REFS_BASE..$MERGE_REFS_HEAD" 2>/dev/null) || {
    UPSTREAM_GUARD_VERDICT=unmeasured
    UPSTREAM_GUARD_NOTE="the commits this PR adds to $MERGE_REFS_BRANCH could not be listed"
    return 0
  }
  if [ -z "$added" ]; then
    UPSTREAM_GUARD_VERDICT=clear
    return 0
  fi
  # The same range with everything upstream can reach excluded. Whatever the
  # exclusion removes is the shared history a rewrite would take with it.
  kept=$(git --git-dir="$FM_STATIC_GUARD_GITDIR" rev-list --ignore-missing \
    "$MERGE_REFS_BASE..$MERGE_REFS_HEAD" --not "${tip_args[@]+"${tip_args[@]}"}" 2>/dev/null) || {
    UPSTREAM_GUARD_VERDICT=unmeasured
    UPSTREAM_GUARD_NOTE='this PR could not be compared against the upstream history this copy holds'
    return 0
  }
  kept_file="$FM_STATIC_GUARD_SCRATCH/upstream-kept"
  printf '%s\n' "$kept" > "$kept_file" || {
    UPSTREAM_GUARD_VERDICT=unmeasured
    UPSTREAM_GUARD_NOTE='the upstream comparison could not be written to scratch'
    return 0
  }
  erased=$(printf '%s\n' "$added" | grep -vxF -f "$kept_file") || erased=
  fm_static_guard_scratch_file_remove "$kept_file" || true
  if [ -z "$erased" ]; then
    UPSTREAM_GUARD_VERDICT=clear
    return 0
  fi
  count=$(printf '%s\n' "$erased" | grep -c . || true)
  UPSTREAM_GUARD_VERDICT=blocked
  UPSTREAM_GUARD_ERASED=$erased
  UPSTREAM_GUARD_NOTE="this PR carries $count commit(s) that the upstream repository also has and $MERGE_REFS_BRANCH does not"
}

# The commits a rewrite would erase, newest first, bounded so a large sync batch
# still prints a refusal a reader can take in.
upstream_guard_print_erased() {
  local sha shown=0 total
  total=$(printf '%s\n' "$UPSTREAM_GUARD_ERASED" | grep -c . || true)
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    shown=$((shown + 1))
    [ "$shown" -le 3 ] || continue
    git --git-dir="$FM_STATIC_GUARD_GITDIR" log -1 --format='  %h %s' "$sha" 2>/dev/null \
      || printf '  %s\n' "$sha"
  done <<UPSTREAM_ERASED
$UPSTREAM_GUARD_ERASED
UPSTREAM_ERASED
  [ "$total" -le 3 ] || printf '  ... and %s more\n' "$((total - 3))"
}

# Assert the named upstream waypoint against the exact PR head fetched for the
# other merge guards. This guard fails closed: a missing object or unreadable
# head is not evidence that ancestry is intact.
required_ancestor_assert() {
  local rc=0 head
  merge_refs_ensure || {
    head=${MERGE_REFS_HEAD:-unresolved}
    echo "error: merge refused - required upstream waypoint $REQUIRED_ANCESTOR could not be checked against PR head $head: $MERGE_REFS_REASON" >&2
    return 1
  }
  head=$MERGE_REFS_HEAD
  if ! git --git-dir="$FM_STATIC_GUARD_GITDIR" rev-parse --verify --quiet \
    "$REQUIRED_ANCESTOR^{commit}" >/dev/null 2>&1; then
    echo "error: merge refused - required upstream waypoint $REQUIRED_ANCESTOR could not be read while checking PR head $head" >&2
    return 1
  fi
  git --git-dir="$FM_STATIC_GUARD_GITDIR" merge-base --is-ancestor \
    "$REQUIRED_ANCESTOR" "$head" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0)
      echo "upstream-waypoint: green - $REQUIRED_ANCESTOR is an ancestor of PR head $head"
      ;;
    1)
      echo "error: merge refused - required upstream waypoint $REQUIRED_ANCESTOR is not an ancestor of PR head $head" >&2
      return 1
      ;;
    *)
      echo "error: merge refused - required upstream waypoint $REQUIRED_ANCESTOR could not be compared with PR head $head" >&2
      return 1
      ;;
  esac
}

# Pre-merge conditions for a GitLab merge request, read from one live view of
# the merge request. Sets FM_PR_MERGE_HEAD to the verified head on success and
# returns non-zero after reporting every condition that failed.
FM_PR_MERGE_HEAD=
gitlab_verify_mergeable() {
  local json fields line
  local total=0 named=0 refusals=''
  local state='' detail='' conflicts='' discussions=''
  local live_head='' pipeline_sha='' pipeline_status=''

  # GITLAB_HOST is set to the same host the project URL already carries, so the
  # instance is taken from the parsed URL by both signals and never from the
  # operator's configured default.
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" -R "$PROJECT_URL" -F json 2>/dev/null) \
    || [ -z "$json" ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  # One named field per line. The names keep a trailing empty value readable
  # after command substitution strips blank lines, and an absent or null field
  # becomes an empty string or the literal "null", neither of which satisfies any
  # check below, so an unreadable field refuses the merge instead of passing it.
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "detail=" + ((.detailed_merge_status // "") | tostring),
        "conflicts=" + (.has_conflicts | tostring),
        "discussions=" + (.blocking_discussions_resolved | tostring),
        "head=" + ((.sha // "") | tostring),
        "pipeline_sha=" + ((.head_pipeline.sha // "") | tostring),
        "pipeline_status=" + ((.head_pipeline.status // "") | tostring)
      else
        error("merge request payload is not an object")
      end' 2>/dev/null); then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      detail=*) detail=${line#detail=} ;;
      conflicts=*) conflicts=${line#conflicts=} ;;
      discussions=*) discussions=${line#discussions=} ;;
      head=*) live_head=${line#head=} ;;
      pipeline_sha=*) pipeline_sha=${line#pipeline_sha=} ;;
      pipeline_status=*) pipeline_status=${line#pipeline_status=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  # Every field named exactly once and no unnamed line: a value carrying a
  # newline would split into a line no name matches, so it is refused here
  # rather than silently truncated into a value a check could accept.
  if [ "$named" -ne 7 ] || [ "$total" -ne 7 ]; then
    echo "error: could not read the GitLab merge request state before merging" >&2
    return 1
  fi

  if ! fm_pr_head_valid "$live_head"; then
    echo "error: could not read the GitLab merge request head commit before merging" >&2
    return 1
  fi
  # A rebase moves the head and leaves the recorded value behind, so the
  # disagreement is reported and the live head is what gets verified and merged.
  if [ -n "$RECORDED_HEAD" ] && [ "$RECORDED_HEAD" != "$live_head" ]; then
    printf 'notice: recorded head %s disagrees with the live head %s; verifying the live head\n' \
      "$RECORDED_HEAD" "$live_head" >&2
  fi

  [ "$state" = opened ] \
    || refusals="$refusals  - state is \"${state:-unreadable}\", not open
"
  [ "$detail" = mergeable ] \
    || refusals="$refusals  - detailed_merge_status is \"${detail:-unreadable}\", not mergeable
"
  [ "$conflicts" = false ] \
    || refusals="$refusals  - has_conflicts is \"${conflicts:-unreadable}\", not false
"
  [ "$discussions" = true ] \
    || refusals="$refusals  - blocking_discussions_resolved is \"${discussions:-unreadable}\", not true
"
  [ "$pipeline_status" = success ] \
    || refusals="$refusals  - the head pipeline status is \"${pipeline_status:-none}\", not success
"
  [ "$pipeline_sha" = "$live_head" ] \
    || refusals="$refusals  - the head pipeline ran at \"${pipeline_sha:-none}\", not at the current head $live_head
"

  if [ -n "$refusals" ]; then
    printf 'error: refusing to merge %s\n' "$URL" >&2
    printf '%s' "$refusals" >&2
    return 1
  fi
  printf 'verified: %s is open and mergeable, with a successful pipeline at head %s\n' \
    "$URL" "$live_head" >&2
  FM_PR_MERGE_HEAD=$live_head
}

# Read one live GitHub pull request view after gh-axi returns. The selected
# fields distinguish a landed pull request from a merge-queue entry and retain
# the concrete state needed for a refusal. gh supplies the complete queue-aware
# view when available; gh-axi remains the degradation path that can prove a
# landed merge without making gh a prerequisite for the merge abstraction.
FM_PR_GITHUB_STATE=
FM_PR_GITHUB_MERGED=
FM_PR_GITHUB_QUEUED=
FM_PR_GITHUB_BASE=
FM_PR_GITHUB_QUEUE_OBSERVED=false
github_read_outcome_with_gh() {
  local fields line
  local total=0 named=0
  local state='' merged='' queued='' base=''

  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if ! fields=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state merged isInMergeQueue baseRefName}}}' \
    -F "owner=$PR_OWNER" -F "repo=$PR_REPO" -F "number=$PR_NUMBER" \
    --jq '.data.repository.pullRequest | "state=" + (.state // ""), "merged=" + (.merged | tostring), "queued=" + (.isInMergeQueue | tostring), "base=" + (.baseRefName // "")' \
    2>/dev/null) || [ -z "$fields" ]; then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      queued=*) queued=${line#queued=} ;;
      base=*) base=${line#base=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 4 ] || [ "$total" -ne 4 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; } \
    || { [ "$queued" != true ] && [ "$queued" != false ]; } \
    || [ -z "$base" ]; then
    return 1
  fi

  FM_PR_GITHUB_STATE=$state
  FM_PR_GITHUB_MERGED=$merged
  FM_PR_GITHUB_QUEUED=$queued
  FM_PR_GITHUB_BASE=$base
  FM_PR_GITHUB_QUEUE_OBSERVED=true
}

github_read_outcome_with_gh_axi() {
  local output state
  if ! output=$(gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" 2>/dev/null); then
    return 1
  fi
  if ! state=$(printf '%s\n' "$output" | awk '
    $1 == "state:" { count++; value=$2 }
    END { if (count == 1 && value != "") print value; else exit 1 }
  '); then
    return 1
  fi
  case "$state" in
    merged)
      FM_PR_GITHUB_STATE=MERGED
      FM_PR_GITHUB_MERGED=true
      FM_PR_GITHUB_QUEUED=false
      ;;
    *)
      FM_PR_GITHUB_STATE=$state
      FM_PR_GITHUB_MERGED=false
      FM_PR_GITHUB_QUEUED=unknown
      ;;
  esac
  FM_PR_GITHUB_BASE=
  FM_PR_GITHUB_QUEUE_OBSERVED=false
}

github_read_outcome() {
  if ! command -v gh >/dev/null 2>&1; then
    github_read_outcome_with_gh_axi && return 0
    echo "error: could not read the GitHub pull request outcome after the merge attempt; PR metadata and merge poll remain recorded" >&2
    return 1
  fi
  # Only a failed gh read falls back. A gh read that completes and reports the
  # pull request as neither merged nor queued is a concrete outcome, not a
  # missing one, so it keeps its own refusal. The gh-axi view cannot observe the
  # merge queue, so it can only turn this into a proved merge or into a refusal.
  github_read_outcome_with_gh && return 0
  if github_read_outcome_with_gh_axi && [ "$FM_PR_GITHUB_MERGED" = true ]; then
    return 0
  fi
  echo "error: could not read the GitHub pull request outcome after the merge attempt: the gh read failed and the gh-axi view could not prove the outcome either; PR metadata and merge poll remain recorded" >&2
  return 1
}

github_urlencode_path_segment() {
  local LC_ALL=C input=$1 encoded='' char octet hex
  while [ -n "$input" ]; do
    char=${input%"${input#?}"}
    input=${input#?}
    case "$char" in
      [-._~a-zA-Z0-9]) encoded=$encoded$char ;;
      *)
        printf -v octet '%d' "'$char"
        [ "$octet" -ge 0 ] || octet=$((octet + 256))
        printf -v hex '%02X' "$octet"
        encoded=$encoded%$hex
        ;;
    esac
  done
  printf '%s' "$encoded"
}

# Read the effective merge-queue method for the observed base branch. The four
# situations the refusal has to keep apart - no queue rule, a rules response
# that could not be read, several rules that disagree, and a rule whose method
# this script does not recognise - are reported as a status rather than folded
# into one failure, because each one means something different to the operator.
FM_PR_GITHUB_QUEUE_METHOD=
FM_PR_GITHUB_QUEUE_METHODS=
FM_PR_GITHUB_QUEUE_STATUS=unreadable
github_read_queue_method() {
  local methods line candidate method='' count=0 branch_path
  local unrecognised=false conflicting=false
  FM_PR_GITHUB_QUEUE_METHOD=
  FM_PR_GITHUB_QUEUE_METHODS=
  FM_PR_GITHUB_QUEUE_STATUS=unreadable
  command -v gh >/dev/null 2>&1 || return 0
  [ -n "$FM_PR_GITHUB_BASE" ] || return 0
  branch_path=$(github_urlencode_path_segment "$FM_PR_GITHUB_BASE")
  if ! methods=$(gh api \
    --paginate "repos/$PR_OWNER/$PR_REPO/rules/branches/$branch_path" \
    --jq '.[] | select(.type == "merge_queue") | "merge_method=" + (.parameters.merge_method // "")' \
    2>/dev/null); then
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      merge_method=*) candidate=${line#merge_method=} ;;
      *) return 0 ;;
    esac
    count=$((count + 1))
    case "$candidate" in
      MERGE|SQUASH|REBASE) ;;
      *) unrecognised=true ;;
    esac
    if [ -z "$FM_PR_GITHUB_QUEUE_METHODS" ] && [ "$count" -eq 1 ]; then
      FM_PR_GITHUB_QUEUE_METHODS=$candidate
    else
      case ",$FM_PR_GITHUB_QUEUE_METHODS," in
        *",$candidate,"*) ;;
        *)
          FM_PR_GITHUB_QUEUE_METHODS="$FM_PR_GITHUB_QUEUE_METHODS,$candidate"
          conflicting=true
          ;;
      esac
    fi
    method=$candidate
  done <<METHODS
$methods
METHODS
  if [ "$count" -eq 0 ]; then
    FM_PR_GITHUB_QUEUE_STATUS=none
  elif [ "$conflicting" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=conflicting
  elif [ "$unrecognised" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=unrecognised
  else
    FM_PR_GITHUB_QUEUE_STATUS=single
    FM_PR_GITHUB_QUEUE_METHOD=$method
  fi
}


FM_PR_GITHUB_AUTO_REQUESTED=false
FM_PR_GITHUB_MERGE_ACCEPTED=false
FM_PR_GITHUB_CALLER_METHOD=

# The single gate every statement about what the forge accepted, armed, or
# reported has to pass. A merge command that failed accepted nothing, so no
# such statement may be made on its path, and routing them all through one
# predicate keeps a later one from being written without the gate.
github_merge_command_succeeded() {
  [ "$FM_PR_GITHUB_MERGE_ACCEPTED" = true ]
}

github_report_forge_output() {
  local output=$1 line
  github_merge_command_succeeded || return 0
  [ -n "$output" ] || return 0
  echo "error: the merge command's own output follows, quoted; it is the forge CLI's report, not this script's verdict:" >&2
  while IFS= read -r line; do
    printf 'error: > %s\n' "$line" >&2
  done <<OUTPUT
$output
OUTPUT
}

github_state_is_open() {
  case "$FM_PR_GITHUB_STATE" in
    [oO][pP][eE][nN]) return 0 ;;
    *) return 1 ;;
  esac
}

# Whether the caller's own named method is the one the queue is configured for,
# compared without regard to the spelling either side happens to use.
github_caller_method_is() {
  case "$FM_PR_GITHUB_CALLER_METHOD" in
    [mM][eE][rR][gG][eE]) [ "$1" = merge ] ;;
    [sS][qQ][uU][aA][sS][hH]) [ "$1" = squash ] ;;
    [rR][eE][bB][aA][sS][eE]) [ "$1" = rebase ] ;;
    *) return 1 ;;
  esac
}

github_report_queue_rules() {
  local queue_method methods_display
  github_read_queue_method
  case "$FM_PR_GITHUB_QUEUE_STATUS" in
    single)
      case "$FM_PR_GITHUB_QUEUE_METHOD" in
        MERGE) queue_method=merge ;;
        SQUASH) queue_method=squash ;;
        REBASE) queue_method=rebase ;;
      esac
      if github_merge_command_succeeded \
        && [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ] \
        && github_caller_method_is "$queue_method"; then
        printf 'error: this run refuses even though the request for %s was accepted with the exact flags base branch %s requires (--auto --%s): the pull request has still not entered the merge queue, so no landed or queued outcome is proven; re-check the pull request'"'"'s merge queue state before retrying\n' \
          "$URL" "$FM_PR_GITHUB_BASE" "$queue_method" >&2
      else
        printf 'error: base branch %s requires the merge queue; retry with: %s %s %s -- --auto --%s\n' \
          "$FM_PR_GITHUB_BASE" "$0" "$ID" "$URL" "$queue_method" >&2
      fi
      ;;
    conflicting)
      printf 'error: base branch %s has conflicting merge queue methods (%s); exact retry flags are ambiguous\n' \
        "$FM_PR_GITHUB_BASE" "${FM_PR_GITHUB_QUEUE_METHODS//,/, }" >&2
      ;;
    unrecognised)
      methods_display=${FM_PR_GITHUB_QUEUE_METHODS//,/, }
      [ -n "$methods_display" ] || methods_display='<none reported>'
      printf 'error: base branch %s requires the merge queue, but its configured merge method (%s) is not one this script recognises, so exact retry flags cannot be named\n' \
        "$FM_PR_GITHUB_BASE" "$methods_display" >&2
      ;;
    unreadable)
      printf 'error: the branch rules for base branch %s could not be read, so a merge queue requirement can be neither confirmed nor ruled out here\n' \
        "${FM_PR_GITHUB_BASE:-<unknown>}" >&2
      ;;
  esac
}

github_report_unmerged_outcome() {
  printf 'error: GitHub merge outcome was not successful: state=%s, merged=%s, isInMergeQueue=%s\n' \
    "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
  if ! github_state_is_open || [ "$FM_PR_GITHUB_MERGED" != false ] \
    || [ "$FM_PR_GITHUB_QUEUED" = true ]; then
    return 0
  fi
  if [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ]; then
    if github_merge_command_succeeded; then
      printf 'error: auto-merge was requested and armed for %s, but nothing is merged or in the merge queue yet, so this run refuses instead of reporting an unproved merge\n' \
        "$URL" >&2
    else
      printf 'error: auto-merge was requested for %s, but the merge command itself failed, so nothing was enabled, merged or queued\n' \
        "$URL" >&2
    fi
  fi
  if [ "$FM_PR_GITHUB_QUEUE_OBSERVED" != true ]; then
    printf 'error: the merge queue could not be observed for %s because the queue-aware read was unavailable, so a pull request already in the merge queue cannot be told apart from one that never entered it; re-check the pull request'"'"'s merge queue state before retrying\n' \
      "$URL" >&2
    return 0
  fi
  github_report_queue_rules
}

gitlab_confirm_merged() {
  local json state
  if ! json=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$PR_NUMBER" \
    -R "$PROJECT_URL" -F json 2>/dev/null) || [ -z "$json" ]; then
    printf 'actionable: GitLab accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  if ! state=$(printf '%s' "$json" | jq -r \
    'if type == "object" and (.state | type == "string") then .state else error("invalid state") end' \
    2>/dev/null); then
    printf 'actionable: GitLab accepted the merge request for %s but its landed state could not be confirmed; the merge poll remains armed\n' \
      "$URL" >&2
    return 2
  fi
  [ "$state" = merged ]
}

trap 'fm_static_guard_cleanup' EXIT

if [ -n "$REQUIRED_ANCESTOR" ]; then
  required_ancestor_assert || exit 1
fi

# The upstream-history guard runs before the static one: it is the cheaper of
# the two on a project with no upstream, and a sync batch it refuses should not
# first pay for a check of a merge that is not going to happen.
MERGE_METHOD=$(resolved_merge_method "$@")
if [ "$MERGE_METHOD" != merge ]; then
  upstream_guard_evaluate
  case "$UPSTREAM_GUARD_VERDICT" in
    none|clear) ;;
    unguarded)
      echo "upstream-history: UNGUARDED - $UPSTREAM_GUARD_NOTE; merging without checking whether this method erases shared history" >&2
      ;;
    unmeasured)
      echo "error: merge refused - $UPSTREAM_GUARD_NOTE" >&2
      echo "this project tracks an upstream repository, so squash and rebase can erase shared history here, and that was not measured" >&2
      echo "an unmeasured history check is not a clear one; re-run once the base branch and PR head can be read, or merge with --merge" >&2
      exit 1
      ;;
    *)
      echo "error: merge refused - $UPSTREAM_GUARD_NOTE" >&2
      upstream_guard_print_erased >&2
      echo "squash and rebase both rewrite those commits out of ${MERGE_REFS_BRANCH}'s ancestry, so the next sync computes its merge base against a waypoint that is gone and replays history ${MERGE_REFS_BRANCH} already carries" >&2
      if [ "$PROVIDER" = gitlab ]; then
        echo "GitLab applies the project's own merge method, which this path can neither read nor override, so land this merge request in GitLab with the project set to create a merge commit" >&2
      else
        echo "merge this PR with --merge, the only method that keeps them reachable" >&2
      fi
      exit 1
      ;;
  esac
fi

if [ "$MERGE_GUARD_MODE" = off ]; then
  echo "merge-guard: OFF by FM_MERGE_GUARD=off - merging without a static check of the merge result" >&2
  merge_guard_record off || { echo "error: guard outcome could not be recorded" >&2; exit 1; }
else
  merge_guard_evaluate
  case "$MERGE_GUARD_VERDICT" in
    green)
      echo "merge-guard: green - $MERGE_GUARD_NOTE"
      ;;
    red)
      echo "error: merge refused - $MERGE_GUARD_NOTE" >&2
      if [ -n "$FM_STATIC_GUARD_OUTPUT" ] && [ -s "$FM_STATIC_GUARD_OUTPUT" ]; then
        cat "$FM_STATIC_GUARD_OUTPUT" >&2
      fi
      echo "the lane must rebase onto current main and re-gate before this PR can merge" >&2
      # A refusal stands even if the record cannot be written: a recording
      # failure must never turn a red merge result into a merge.
      merge_guard_record red || echo "error: guard outcome could not be recorded" >&2
      exit 1
      ;;
    timeout)
      if [ "$MERGE_GUARD_MODE" = allow-timeout ]; then
        echo "merge-guard: UNGUARDED - $MERGE_GUARD_NOTE; merging by explicit FM_MERGE_GUARD=allow-timeout" >&2
        MERGE_GUARD_VERDICT="timeout-allowed: $MERGE_GUARD_NOTE"
      else
        echo "error: merge refused - $MERGE_GUARD_NOTE" >&2
        echo "the check was killed, not passed; an unmeasured merge result is not a green one" >&2
        echo "re-run with room (FM_STATIC_CHECK_TIMEOUT=<seconds>), or merge past it deliberately with FM_MERGE_GUARD=allow-timeout" >&2
        # The refusal stands even if the record cannot be written, exactly as it
        # does for red: a recording failure must never turn a refusal into a merge.
        merge_guard_record "timeout: $MERGE_GUARD_NOTE" \
          || echo "error: guard outcome could not be recorded" >&2
        exit 1
      fi
      ;;
    *)
      echo "merge-guard: UNGUARDED - $MERGE_GUARD_NOTE; merging without a static check of the merge result" >&2
      ;;
  esac
  merge_guard_record "$MERGE_GUARD_VERDICT" || {
    echo "error: guard outcome could not be recorded" >&2
    exit 1
  }
fi

case "$PROVIDER" in
  github)
    merge_output=
    merge_args=()
    if ! caller_has_merge_method "$@"; then
      merge_args=(--squash)
    fi
    if caller_requested_auto_merge "$@"; then
      FM_PR_GITHUB_AUTO_REQUESTED=true
    fi
    FM_PR_GITHUB_CALLER_METHOD=$(caller_merge_method "$@")
    if merge_output=$(gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
      "${merge_args[@]+"${merge_args[@]}"}" "$@" 2>&1); then
      FM_PR_GITHUB_MERGE_ACCEPTED=true
    else
      merge_status=$?
      [ -z "$merge_output" ] || printf '%s\n' "$merge_output" >&2
      if github_read_outcome; then
        if [ "$FM_PR_GITHUB_MERGED" != true ] && [ "$FM_PR_GITHUB_QUEUED" != true ]; then
          github_report_unmerged_outcome
        else
          printf 'actionable: the merge command for %s failed, but the pull request reads back as state=%s, merged=%s, isInMergeQueue=%s\n' \
            "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
        fi
      fi
      exit "$merge_status"
    fi
    if ! github_read_outcome; then
      github_report_forge_output "$merge_output"
      exit 1
    fi
    if [ "$FM_PR_GITHUB_MERGED" = true ]; then
      printf 'verified: %s is merged (state=%s, merged=%s, isInMergeQueue=%s)\n' \
        "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
    elif [ "$FM_PR_GITHUB_QUEUED" = true ]; then
      printf 'verified: %s is queued (state=%s, merged=%s, isInMergeQueue=%s)\n' \
        "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
      exit 0
    else
      github_report_forge_output "$merge_output"
      github_report_unmerged_outcome
      exit 1
    fi
    ;;
  gitlab)
    gitlab_verify_mergeable || exit 1
    # The guards above judged MERGE_REFS_HEAD, fetched before this live
    # verification ran. If the merge request moved in between - or its head
    # specifically could not be resolved even though its base branch could -
    # FM_PR_MERGE_HEAD names a commit none of the guards evaluated, and merging
    # it would be exactly the erased-history outcome they exist to prevent,
    # just unmeasured. MERGE_REFS_BASE gates this: an empty one means nothing
    # here was reachable at all, the same already-accepted unguarded state
    # every other environmentally-unreachable case in this script degrades to.
    if [ -n "$MERGE_REFS_BASE" ] && [ "$MERGE_REFS_HEAD" != "$FM_PR_MERGE_HEAD" ]; then
      printf 'error: merge refused - the guards measured head %s, but the verified mergeable head is %s; merging would land a commit none of them evaluated\n' \
        "${MERGE_REFS_HEAD:-<none: the guards could not resolve the head>}" "$FM_PR_MERGE_HEAD" >&2
      exit 1
    fi
    # --sha binds the merge to the head this run verified, so a push that lands
    # in between is refused by GitLab instead of merged unverified. --yes only
    # skips the interactive confirmation, which no supervised run can answer;
    # the conditions above are what authorize the merge.
    GITLAB_HOST="$FM_PR_HOST" glab mr merge "$PR_NUMBER" -R "$PROJECT_URL" \
      --sha "$FM_PR_MERGE_HEAD" --yes "$@"
    gitlab_confirm_rc=0
    gitlab_confirm_merged || gitlab_confirm_rc=$?
    [ "$gitlab_confirm_rc" -eq 0 ] || exit 0
    ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac

# Reached only after the forge confirmed the merge landed: set -e exits on a
# refused or failed merge above, and a queued forge merge exits without an
# outcome while its existing poll remains armed.
outcome_rc=0
fm_merge_outcome_report "$FM_HOME" "$STATE" "$ID" "$URL" self || outcome_rc=$?
case "$outcome_rc" in
  0) ;;
  3)
    printf 'actionable: merged %s but could not report it upward: this home has no readable secondmate identity or parent binding (.fm-secondmate-home, .fm-secondmate-parent)\n' \
      "$URL" >&2
    ;;
  *)
    printf 'actionable: merged %s but could not record the outcome for supervision\n' "$URL" >&2
    ;;
esac
