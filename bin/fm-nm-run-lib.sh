#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the no-mistakes run-attribution primitives used by
# fm-crew-state.sh (read-only current-state reporting) and fm-teardown.sh
# (pre-teardown run abort, see its "Fix 1" header comment). Teardown uses only
# strict branch-and-head identity; crew-state additionally permits the active
# pipeline-owned exemption defined below. Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# Bounded call to `$3 "${@:4}"` in dir $1, timeout $2 seconds. Preserves
# stdout, stderr, and exit status. The single owner of the timeout-detection
# dance (timeout/gtimeout/perl fallback) for every bounded external command
# this repo shells out to under a read deadline - originally hardcoded to
# `no-mistakes` (fm_nm_run_bounded below still is, for compatibility), then
# generalized so fm-crew-state.sh's forge verification could reuse the exact
# same bounded-call guarantee for `gh` instead of re-deriving it.
fm_bounded_cmd() {  # <dir> <timeout_secs> <cmd> <args...>
  local dir=$1 timeout_secs=$2 cmd=$3 have_timeout=none
  shift 3
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" "$cmd" "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" "$cmd" "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" "$cmd" "$@" ) ;;
    *)        return 1 ;;
  esac
}

# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2
  shift 2
  fm_bounded_cmd "$dir" "$timeout_secs" no-mistakes "$@"
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1, at any depth,
# first match wins. Correct for keys that appear once, including the top-level
# `outcome:`, which is not part of the run object.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# Scalar value of a field of the RUN OBJECT specifically: a key indented exactly
# one level inside the `run:` block. `axi status` also prints a cached
# `branch_sync` block that repeats `branch`, `status`, and `head` at a deeper
# indent, so a depth-blind read can return a neighbouring value instead of the
# run's own - reporting a finished run as still running, which is the one
# direction an attribution read must never fail in. Use this wherever the answer
# must be the run's own identity or state; fm_nm_field stays correct for keys
# that appear once.
fm_nm_run_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | awk -v want="$2" '
    !inrun && $0 ~ /^run:[ \t]*$/ { inrun = 1; next }
    inrun && $0 ~ /^[^ \t]/ { exit }
    inrun && index($0, "  " want ":") == 1 {
      v = substr($0, length(want) + 4)
      sub(/^[ \t]+/, "", v)
      sub(/[ \t]+$/, "", v)
      print v
      exit
    }
  '
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
# fm_nm_run_is_pipeline_owned_active below carries the one exemption: a live
# run whose pipeline currently owns the branch binds without head equality.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# 0 if run head $2 is consistent with worktree $1 owning an IN-FLIGHT run.
#
# fm_nm_head_matches_worktree above answers a question about code that is
# already in hand, and rejects a head it cannot resolve. That is right for its
# callers - teardown must never act on a run it cannot prove it owns - but it is
# wrong for a liveness read, because a running pipeline's head is routinely
# unresolvable here: no-mistakes commits its fixes in its own gate repo and does
# not push them until the push step, so from the first auto-fix round until then
# `axi status` reports a commit this object store has never seen. Requiring it to
# resolve makes a healthy run indistinguishable from a dead one for the whole
# review step, which is exactly the period the read exists to cover.
#
# So resolvability selects the question rather than deciding the answer:
#   - not a commit-ish token: reject, so prose or a truncated read can never be
#     mistaken for the unresolvable case below
#   - unreadable worktree: reject, so a broken checkout is never read as in-flight
#   - head resolves here: apply the strict rule above unchanged, which still
#     rejects a run validating superseded or rewritten code
#   - head does not resolve here: accept as a pipeline commit not yet pushed
#
# Accepting the unresolvable case does NOT weaken attribution, because it is not
# what binds the run to the task. `axi status` resolves its repo from the
# invoking directory and refuses outright outside a registered one, and within a
# repo git allows a branch to be checked out by only one worktree, so the
# caller's branch match is what proves ownership. This function's remaining job
# is to reject a run on that branch that is not the current work, and it keeps
# doing that whenever the head is resolvable. Callers must still bound liveness
# on the run's own non-terminal state and dated activity.
fm_nm_head_allows_inflight() {  # <worktree> <run_head>
  local wt=$1 run_head=$2
  case "$run_head" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
  [ "${#run_head}" -ge 7 ] && [ "${#run_head}" -le 40 ] || return 1
  git -C "$wt" rev-parse --verify --quiet HEAD >/dev/null 2>&1 || return 1
  if git -C "$wt" rev-parse --verify --quiet "${run_head}^{commit}" >/dev/null 2>&1; then
    fm_nm_head_matches_worktree "$wt" "$run_head"
    return
  fi
  return 0
}

# 0 if run head $2 binds a run in state $3 with outcome $4 to worktree $1.
#
# The two rules above answer different questions, and picking between them is
# itself part of attribution, so the choice lives here rather than at each call
# site. A TERMINAL run must prove its head: its fixes were pushed at the push
# step, so an unresolvable head means the run is not this worktree's work, and a
# terminal verdict is exactly the evidence that would justify tearing down or
# restarting. An IN-FLIGHT run must not be required to, for the reason
# fm_nm_head_allows_inflight documents: from the first auto-fix round until the
# push step the reported head exists only in no-mistakes' own gate repository,
# so demanding resolution rejects every run between those two points.
#
# That window is not an edge case. It spans the review, test, document, and lint
# steps, which is where a run parks at awaiting_approval or fix_review, so a
# strict-only reader loses attribution for precisely the state supervision must
# surface and falls back to the pane - reporting a crew waiting at a gate as
# working, or as unknown when its pane is quiet.
#
# In-flight is an ALLOW-LIST of the run states no-mistakes actually reports for a
# live run, so the loosening can never widen on its own: a state this list does
# not name (including an empty one, and any terminal or gate value invented
# later) keeps the strict proof. tests/fm-nm-status-shape-live-e2e.test.sh is the
# drift guard that fails when the installed binary reports a state absent here.
fm_nm_head_binds_run() {  # <worktree> <run_head> <run_status> <run_outcome>
  local wt=$1 run_head=$2 run_status=$3 run_outcome=${4:-}
  if [ -z "$run_outcome" ]; then
    case "$run_status" in
      running|fixing|pending|awaiting_approval|fix_review)
        fm_nm_head_allows_inflight "$wt" "$run_head"
        return ;;
    esac
  fi
  fm_nm_head_matches_worktree "$wt" "$run_head"
}

# 0 if head $2 resolves to a commit object in worktree $1 at all. This
# distinguishes a PROVEN mismatch (resolvable but not current: a historical or
# diverged head fm_nm_head_matches_worktree correctly rejects) from UNKNOWN
# attribution (unresolvable: e.g. a pipeline-owned lane head that never
# reached this worktree). A caller scanning run rows newest-first must stop on
# unknown attribution rather than surface an older, superseded run.
fm_nm_head_resolvable() {  # <worktree> <head>
  [ -n "$2" ] || return 1
  git -C "$1" rev-parse --verify --quiet "$2^{commit}" >/dev/null 2>&1
}

# branch_sync.state from captured `axi status` TOON $1: the scalar directly
# under the top-level `branch_sync:` block. The first `state:` inside the
# block is the direct child (the nested local/pipeline/target/remote
# sub-blocks carry no `state:` key). Empty when the block is absent: no run
# on the current branch, another branch's run, or a CLI without branch sync.
fm_nm_branch_sync_state() {  # <toon-output>
  local s
  s=$(printf '%s\n' "$1" \
    | sed -n '/^[[:space:]]*branch_sync:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]\{1,\}state:[[:space:]]*\(.*\)/\1/p' \
    | head -1)
  fm_nm_strip_quotes "$s"
}

# 0 if the run in captured `axi status` TOON $1 is still in flight: no
# terminal outcome and no terminal status.
fm_nm_run_is_active() {  # <toon-output>
  local status outcome
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$1" status)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$1" outcome)")
  [ -z "$outcome" ] || return 1
  case "$status" in completed|failed|cancelled) return 1 ;; esac
}

# The one exemption to the head rule above: while the pipeline OWNS the branch
# (branch_sync.state=pipeline_owned), the daemon's own branch attribution IS
# the attribution for an ACTIVE run, and
# head equality must not be required - the pipeline's lane head is routinely
# not a git object in the task worktree (rebase and fix commits that were
# never pushed back), so the head rule rejects exactly the run that is most
# current. The exemption never applies to a terminal run: a terminal run has
# released the branch, and binding one by branch name alone is the historical
# reused-branch misattribution the head rule exists to prevent.
fm_nm_run_is_pipeline_owned_active() {  # <toon-output>
  [ "$(fm_nm_branch_sync_state "$1")" = pipeline_owned ] || return 1
  fm_nm_run_is_active "$1"
}
