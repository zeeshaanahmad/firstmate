#!/usr/bin/env bash
# tests/fm-nm-status-shape-live-e2e.test.sh - opt-in drift guard proving the
# INSTALLED `no-mistakes` still emits `axi status` in the shape firstmate's run
# attribution reads (bin/fm-nm-run-lib.sh, bin/fm-liveness-lib.sh).
#
# Why this file exists: every portable test of that attribution feeds a fake
# `no-mistakes` on PATH, so it can only confirm the shape already transcribed
# into the fake. That is exactly how the gap this guard closes went unnoticed -
# the fixture agreed with itself while the real CLI reported a head the crew
# worktree could not resolve, and the built-in liveness source stayed silent for
# the whole review step of every validating task.
#
# A stub cannot catch a vendor changing its own output. Only the real binary can,
# so this reads it directly and fails naming the version.
#
# Everything here is read-only: it starts no run, answers no gate, and touches no
# daemon state, so it consumes no model tokens and cannot disturb work in flight.
#
# Standard CI has no no-mistakes binary or daemon, so this is opt-in and
# on-demand. The portable counterpart in tests/fm-liveness-source.test.sh pins
# the parsing and attribution logic in CI. Run this guard after any no-mistakes
# upgrade and before trusting refreshed evidence.
set -u

if [ "${FM_NM_STATUS_SHAPE_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_NM_STATUS_SHAPE_DRIFT=1 to run the installed no-mistakes status-shape drift guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$ROOT/bin/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-liveness-lib.sh
. "$ROOT/bin/fm-liveness-lib.sh"

LAB=
cleanup_all() { [ -n "${LAB:-}" ] && rm -rf "$LAB"; }
trap cleanup_all EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v no-mistakes >/dev/null 2>&1 \
  || fail "no-mistakes not found; this guard needs the real binary"
NM_VERSION=$(no-mistakes --version 2>&1 | head -1)
note "no-mistakes: $NM_VERSION"

# Every failure below names the version, because the answer to "did this drift?"
# is only meaningful against the release that produced it.
drift() { fail "$1 (no-mistakes: $NM_VERSION)"; }

# --- the run object is readable at the depth attribution anchors on ----------
#
# fm_nm_run_field deliberately reads only keys one level inside `run:`, because
# the cached branch_sync block repeats branch, status, and head deeper and a
# depth-blind read can report a finished run as still running.

STATUS_OUT=$(no-mistakes axi status 2>&1) \
  || drift "axi status failed in this repository"

case "$STATUS_OUT" in
  *"repo not initialized"*)
    fail "run this guard from a repository where no-mistakes is initialized" ;;
  *"No active run"*|*"no runs yet"*)
    note "no run on record in this repository; the run-object assertions need one"
    note "start any no-mistakes run here, then re-run this guard"
    exit 0 ;;
esac

printf '%s\n' "$STATUS_OUT" | grep -q '^run:' \
  || drift "axi status printed no top-level run object"

run_branch=$(fm_nm_strip_quotes "$(fm_nm_run_field "$STATUS_OUT" branch)")
[ -n "$run_branch" ] || drift "the run object exposed no branch field one level in"

run_status=$(fm_nm_strip_quotes "$(fm_nm_run_field "$STATUS_OUT" status)")
[ -n "$run_status" ] || drift "the run object exposed no status field one level in"

run_head=$(fm_nm_strip_quotes "$(fm_nm_run_field "$STATUS_OUT" head)")
[ -n "$run_head" ] || drift "the run object exposed no head field one level in"

pass "axi status prints a run object whose branch, status, and head read at the anchored depth"

# --- the head is a commit-ish token -----------------------------------------
#
# fm_nm_head_allows_inflight rejects anything that is not one, so that prose or a
# truncated read can never be mistaken for an unresolvable in-flight head.

case "$run_head" in
  ''|*[!0-9a-fA-F]*) drift "the run head '$run_head' is not a hex commit token" ;;
esac
[ "${#run_head}" -ge 7 ] && [ "${#run_head}" -le 40 ] \
  || drift "the run head '$run_head' is ${#run_head} characters, outside the 7..40 attribution accepts"
pass "the reported run head is a commit token attribution can bind on"

# --- the run status vocabulary has not grown --------------------------------
#
# bin/fm-liveness-lib.sh allows a NON-terminal run to answer for liveness, as an
# allow-list rather than a denial list, so a newly invented terminal value cannot
# quietly read as alive. The cost of that choice is that a newly invented ACTIVE
# value goes silent instead, which is safe but reopens exactly the gap this guard
# exists for. Catch either one here rather than in production.
#
# awaiting_approval and fix_review are accepted here as recognized GATE states so
# this guard can continue past a run genuinely parked at a gate, not as evidence
# of liveness; bin/fm-liveness-lib.sh must still never read a parked run as alive.

case "$run_status" in
  running|fixing|pending|awaiting_approval|fix_review|completed|failed|cancelled|aborted) ;;
  *) drift "unknown run status '$run_status'; classify it in bin/fm-liveness-lib.sh before it is read as alive or silently ignored" ;;
esac
pass "the reported run status is a value firstmate classifies"

# --- the active-step status vocabulary has not grown ------------------------
#
# This one carries the whole liveness claim for a running pipeline.
# fm_liveness_step_is_executing allow-lists the step statuses that mean "moving
# right now", and deliberately excludes both a queued step and one parked at a
# gate, since a parked run is waiting on firstmate and must still surface. A
# value no-mistakes invents later goes silent - safe, but it reopens exactly the
# systematic false alarm this rule closed - and a gate value that ever appeared
# here under a new name would be far worse, because it would read as executing.
# Catch either here rather than in production.

ACTIVE_STATUSES=$(printf '%s\n' "$STATUS_OUT" | fm_liveness_active_step_field status)
if [ -z "$ACTIVE_STATUSES" ]; then
  note "no run is executing here, so active-step statuses were not observed; re-run this guard during a run to cover them"
else
  while IFS= read -r step_status; do
    [ -n "$step_status" ] || continue
    case "$step_status" in
      running|fixing|pending|awaiting_approval|fix_review) ;;
      completed|failed|cancelled|aborted|skipped) ;;
      *) drift "unknown active-step status '$step_status'; classify it in bin/fm-liveness-lib.sh before it is read as executing or silently ignored" ;;
    esac
  done <<EOF
$ACTIVE_STATUSES
EOF
  pass "every active-step status firstmate saw is a value it classifies"
fi

# --- the binding rule actually binds the run the real binary reports ---------
#
# fm_nm_head_binds_run picks between a strict head proof and the in-flight
# allowance from the run's own state, so a state it does not classify silently
# falls back to strict - which is how a parked gate came to be reported as a busy
# pane. A fake `no-mistakes` can only confirm the states already transcribed into
# it, so the real binary's own answer is driven through the real rule here.

run_outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$STATUS_OUT" outcome)")
case "$run_outcome" in
  ''|passed|checks-passed|failed|cancelled) ;;
  *) drift "unknown run outcome '$run_outcome'; classify it in bin/fm-nm-run-lib.sh and bin/fm-crew-state.sh before it decides an attribution" ;;
esac

if [ -z "$run_outcome" ]; then
  case "$run_status" in
    running|fixing|pending|awaiting_approval|fix_review) ;;
    *) drift "run status '$run_status' carries no outcome yet is not one fm_nm_head_binds_run treats as in-flight; an in-flight run in this state would lose attribution for its whole gate window" ;;
  esac
fi

# The end-to-end claim, and the only one a stub cannot make: for a run on the
# invoking worktree's own branch, the rule binds it. This is the assertion that
# fails if the vendor changes what `head` means, or which heads it publishes.
GUARD_BRANCH=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
if [ -n "$GUARD_BRANCH" ] && [ "$GUARD_BRANCH" = "$run_branch" ]; then
  fm_nm_head_binds_run "$PWD" "$run_head" "$run_status" "$run_outcome" \
    || drift "the run the daemon reports for this worktree's own branch '$run_branch' (status '$run_status', head '$run_head') does not bind to it, so its gate state cannot be read"
  pass "the run reported for this worktree's own branch binds under the real attribution rule"
else
  note "axi status answered for branch '$run_branch' rather than this worktree's own, so the binding assertion needs a run started here"
fi

# --- axi status is scoped to the invoking repository ------------------------
#
# This is load-bearing, not incidental. Attribution binds a run to a task by
# BRANCH, which is only sufficient because the daemon answers for the repo of the
# invoking directory and git allows a branch in just one worktree of it. If
# axi status ever began answering across repositories, a same-named branch
# elsewhere could suppress a genuine wedge here.

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-status-shape.XXXXXX")
git -C "$LAB" init --quiet -b main
git -C "$LAB" config user.email t@example.com
git -C "$LAB" config user.name t
git -C "$LAB" commit --quiet --allow-empty -m init
OUTSIDE=$(cd "$LAB" && no-mistakes axi status 2>&1 || true)

printf '%s\n' "$OUTSIDE" | grep -q '^run:' \
  && drift "axi status reported a run object from an unregistered repository, so a branch match no longer proves ownership"
printf '%s\n' "$OUTSIDE" | grep -q 'repo not initialized' \
  || drift "axi status from an unregistered repository neither refused nor reported a run; its scoping is unclear: $OUTSIDE"
pass "axi status answers only for the repository it is invoked in"

note "all assertions held against $NM_VERSION"
