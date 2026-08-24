#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# MERGE-TIME STATIC GUARD. Immediately before the merge, this computes the exact
# squash RESULT of the PR head onto the CURRENT default-branch tip with
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
# current default-branch tip, and a pinned checker fetched by its pin needs the
# network on a cold cache. Where it cannot REACH the check at all it says
# "merge-guard: UNGUARDED - <reason>" out loud and merges as before, rather than
# implying a check that did not happen or wedging every merge behind an
# unrelated outage.
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
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
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

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

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

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

meta_field() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

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
  local src=$1 url=$2 branch
  if command -v gh >/dev/null 2>&1 \
    && branch=$(cd "$src" && gh pr view "$URL" --json baseRefName -q .baseRefName 2>/dev/null) \
    && fm_static_guard_ref_name_safe "$branch"; then
    printf '%s\n' "$branch"
    return 0
  fi
  fm_static_guard_default_branch "$url" || return 1
  printf '%s\n' "$FM_STATIC_GUARD_BRANCH"
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
  local src url branch base head recorded_head rc=0
  MERGE_GUARD_VERDICT=
  MERGE_GUARD_NOTE=
  command -v git >/dev/null 2>&1 || { merge_guard_unguarded 'git is unavailable'; return 0; }
  src=$(merge_guard_source_repo) || { merge_guard_unguarded 'no local copy of this project to read objects from'; return 0; }
  fm_static_guard_remote_pick "$src" "$PR_OWNER/$PR_REPO" \
    || { merge_guard_unguarded 'no usable remote for this project'; return 0; }
  url=$FM_STATIC_GUARD_REMOTE
  branch=$(merge_guard_base_branch "$src" "$url") \
    || { merge_guard_unguarded 'the base branch of this PR could not be resolved'; return 0; }
  fm_static_guard_scratch_new || { merge_guard_unguarded 'no scratch directory'; return 0; }
  fm_static_guard_repo_prepare "$src" \
    || { merge_guard_unguarded 'a private object store could not be prepared'; return 0; }
  recorded_head=$(meta_field pr_head)
  if fm_static_guard_fetch "$FM_STATIC_GUARD_GITDIR" "$url" \
    "+refs/heads/$branch:$FM_STATIC_GUARD_BASE_REF" \
    "+refs/pull/$PR_NUMBER/head:$FM_STATIC_GUARD_HEAD_REF"; then
    head=$(git --git-dir="$FM_STATIC_GUARD_GITDIR" rev-parse --verify --quiet "$FM_STATIC_GUARD_HEAD_REF" 2>/dev/null) || head=
  elif fm_static_guard_fetch "$FM_STATIC_GUARD_GITDIR" "$url" \
    "+refs/heads/$branch:$FM_STATIC_GUARD_BASE_REF"; then
    # A forge that does not serve refs/pull/<n>/head still leaves the head that
    # bin/fm-pr-check.sh recorded, which the borrowed object store already has.
    head=$(fm_static_guard_sha_valid "$recorded_head" \
      && git --git-dir="$FM_STATIC_GUARD_GITDIR" rev-parse --verify --quiet "$recorded_head^{commit}" 2>/dev/null) || head=
  else
    merge_guard_unguarded "the current tip of $branch could not be fetched"
    return 0
  fi
  base=$(git --git-dir="$FM_STATIC_GUARD_GITDIR" rev-parse --verify --quiet "$FM_STATIC_GUARD_BASE_REF" 2>/dev/null) || base=
  [ -n "$base" ] || { merge_guard_unguarded "the current tip of $branch could not be read"; return 0; }
  [ -n "$head" ] || { merge_guard_unguarded 'the PR head commit could not be read'; return 0; }
  rc=0
  fm_static_guard_merge_tree "$FM_STATIC_GUARD_GITDIR" "$base" "$head" || rc=$?
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
      MERGE_GUARD_NOTE="the squash result of this PR onto $branch@${base:0:12} fails ${FM_STATIC_GUARD_DETAIL}"
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

if [ "$MERGE_GUARD_MODE" = off ]; then
  echo "merge-guard: OFF by FM_MERGE_GUARD=off - merging without a static check of the merge result" >&2
  merge_guard_record off || { echo "error: guard outcome could not be recorded" >&2; exit 1; }
else
  trap 'fm_static_guard_cleanup' EXIT
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

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
