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

case "$run_status" in
  running|fixing|pending|completed|failed|cancelled|aborted) ;;
  *) drift "unknown run status '$run_status'; classify it in bin/fm-liveness-lib.sh before it is read as alive or silently ignored" ;;
esac
pass "the reported run status is a value firstmate classifies"

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
