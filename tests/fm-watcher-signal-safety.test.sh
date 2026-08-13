#!/usr/bin/env bash
# tests/fm-watcher-signal-safety.test.sh - a signal landing while a lock
# critical section is open must never cost the process either its consistency or
# its ability to stop.
#
# The defect these pin: firstmate's locks are not reentrant, and the long-running
# supervision processes trap HUP/INT/TERM into an exit whose cleanup re-enters
# the same locks. A signal mid-section unwound the shell out of a critical
# section and straight back into it, which produced a watcher holding
# .watch.lock and .wake-queue.lock with a frozen beacon that only a session
# restart could clear.
#
# Everything here uses real processes, real signals, and real locks - no harness
# and no fake agent, because the failure lives in signal disposition and lock
# ownership, which a stub can only restate rather than test. Determinism comes
# from pinning the target inside the section with an EXTERNAL lock holder rather
# than racing a signal against a section that is normally sub-millisecond.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

TMP_ROOT=$(fm_test_tmproot fm-watcher-signal-safety-tests)

EXTERNAL_HOLDER_PID=

# fail() exits the suite immediately, so without this a case that fails while a
# holder is live leaves that holder running - inheriting the runner's stdout and
# turning a clean failure into a hung run.
# shellcheck disable=SC2317,SC2329 # Invoked by the EXIT trap below.
stop_stray_holder() {
  [ -n "${EXTERNAL_HOLDER_PID:-}" ] || return 0
  kill "$EXTERNAL_HOLDER_PID" 2>/dev/null || true
  kill -s KILL "$EXTERNAL_HOLDER_PID" 2>/dev/null || true
}
trap stop_stray_holder EXIT

# Hold <lock> from a separate live process until <release-flag> appears, then let
# go. Acquire and release must happen in the SAME process, because fm_lock_release
# only releases a hold its own pid owns. Sets EXTERNAL_HOLDER_PID; returns 1 if
# the holder never got the lock.
#
# Readiness is the holder's OWN acquisition, announced by the holder, never the
# lock path appearing: the watcher takes and drops these same locks every poll,
# so waiting on the path can return while the watcher holds it and the holder is
# still queued behind it - which silently un-contends the case it was meant to
# pin.
start_external_holder() {  # <state> <lock> <release-flag>
  local state=$1 lock=$2 flag=$3 ready i=0
  ready="$state/.holder-ready"
  rm -f "$ready"
  # Its own output goes to a file, never to the suite's stdout: a holder that
  # outlives a failing case would otherwise keep the runner's pipe open and turn
  # a clean failure into a hang.
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_lock_acquire_wait "$2"
    : > "$4"
    while [ ! -e "$3" ]; do sleep 0.05; done
    fm_lock_release "$2"
  ' _ "$LIB" "$lock" "$flag" "$ready" >"$state/.holder.log" 2>&1 &
  EXTERNAL_HOLDER_PID=$!
  while [ "$i" -lt 300 ]; do
    [ -e "$ready" ] && return 0
    is_live_non_zombie "$EXTERNAL_HOLDER_PID" || return 1
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

# 0 if <pid> exited within <limit> 0.1s ticks, 1 if it outlived them. Never
# signals anything: callers use it to measure a shutdown they already triggered.
exited_within() {  # <pid> <limit-ticks>
  local pid=$1 limit=$2 i=0
  while [ "$i" -lt "$limit" ]; do
    is_live_non_zombie "$pid" || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Unconditional teardown so one failing case cannot strand a process or hang the
# suite. Distinct from wake-helpers' reap: this reports nothing and runs only
# after a case has already made its assertions.
force_stop() {  # <pid>
  local pid=${1:-}
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null || true
  exited_within "$pid" 20 || kill -s KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# 0 once <pid> holds <lock>, which is the observable proof it is inside the
# critical section - never a slice of wall clock, which turns a strict assertion
# into a flaky one on a loaded host.
wait_lock_taken() {  # <lock> <pid> [limit-ticks]
  local lock=$1 pid=$2 limit=${3:-300} i=0
  while [ "$i" -lt "$limit" ]; do
    { [ -e "$lock" ] || [ -L "$lock" ]; } && return 0
    is_live_non_zombie "$pid" || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_first_beat() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-200} i=0
  while [ "$i" -lt "$limit" ]; do
    [ -e "$state/.last-watcher-beat" ] && return 0
    is_live_non_zombie "$pid" || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# --- the deferral primitive itself -------------------------------------------
#
# Asserted directly, with the divergence made visible so the case cannot go
# quietly vacuous: the signal must NOT act while the section is open, and MUST
# act the moment it closes, through the caller's own disposition rather than a
# default the library assumed. A case that only checked "the process eventually
# exits" would pass just as happily with no deferral at all.
test_deferred_signal_waits_for_the_section_then_fires() {
  local dir prog pid status i=0
  dir="$TMP_ROOT/defer-primitive"
  mkdir -p "$dir/state"
  prog="$dir/prog.sh"
  cat > "$prog" <<'SH'
#!/usr/bin/env bash
set -u
# shellcheck disable=SC1090,SC1091
. "$1"
DIR=$2
trap ': > "$DIR/caller-handler-ran"; exit 7' TERM
fm_signal_defer_begin
: > "$DIR/in-section"
# The test, not the fixture, decides when the section ends, so "still open" is a
# state the assertions can observe rather than a race they have to win.
while [ ! -e "$DIR/release-section" ]; do sleep 0.05; done
printf '%s\n' "$FM_SIGNAL_DEFERRED" > "$DIR/deferred-signal"
: > "$DIR/section-completed"
fm_signal_defer_end
: > "$DIR/ran-past-section"
sleep 30
SH
  chmod +x "$prog"
  FM_STATE_OVERRIDE="$dir/state" "$prog" "$LIB" "$dir" &
  pid=$!
  while [ "$i" -lt 100 ] && [ ! -e "$dir/in-section" ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$dir/in-section" ] || { force_stop "$pid"; fail "the deferral fixture never entered its section"; }

  kill -TERM "$pid" 2>/dev/null || true
  if exited_within "$pid" 20; then
    fail "a signal inside a deferred section unwound the process instead of being held"
  fi
  [ ! -e "$dir/section-completed" ] \
    || { force_stop "$pid"; fail "the fixture left its section early, so nothing was actually deferred"; }

  : > "$dir/release-section"
  if ! exited_within "$pid" 100; then
    force_stop "$pid"
    fail "the deferred signal was swallowed: the process outlived the section it arrived in"
  fi
  wait "$pid" 2>/dev/null
  status=$?
  [ "$status" -eq 7 ] \
    || fail "the re-raised signal did not run the caller's own disposition (exit $status, wanted 7)"
  [ -e "$dir/caller-handler-ran" ] || fail "the caller's own TERM handler never ran"
  [ "$(cat "$dir/deferred-signal" 2>/dev/null || true)" = TERM ] \
    || fail "the section did not record which signal it was holding"
  [ ! -e "$dir/ran-past-section" ] \
    || fail "the process carried on past the section it was signalled in"
  pass "a signal inside a deferred section is held, lets the section finish, then fires through the caller's own handler"
}

# --- the watcher, signalled while pinned inside a marker critical section -----
#
# The deadlock, driven deterministically. Every watcher poll runs
# resurface_after_downtime -> the recovery-marker arm check, the one place two of
# these locks are held at once. An external holder of the marker lock pins the
# watcher there: queue lock taken, marker lock contended. The holder starts only
# after the first completed poll, so the watcher is pinned in its LOOP with the
# exit path fully installed, not in the pre-trap startup check.
#
# Before the redesign the TERM unwound into watcher_cleanup, which asked for the
# marker lock the external holder still had, and the watcher sat there holding
# both .watch.lock and .wake-queue.lock with a frozen beacon - the reported wild
# symptom. The external holder is deliberately NOT released until after the
# watcher has already exited, because "exits while another process still holds
# the lock" is the entire claim.
test_watcher_signalled_in_critical_section_exits_and_releases() {
  local dir state out err marker_lock queue_lock flag pid
  dir="$TMP_ROOT/watcher-pinned"
  mkdir -p "$dir/state" "$dir/fakebin"
  state="$dir/state"; out="$dir/watch.out"; err="$dir/watch.err"
  marker_lock="$state/.watcher-down.lock"
  queue_lock="$state/.wake-queue.lock"
  flag="$dir/release-holder"

  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" &
  pid=$!
  wait_first_beat "$state" "$pid" \
    || { force_stop "$pid"; fail "the watcher never completed a poll: $(cat "$err")"; }

  start_external_holder "$state" "$marker_lock" "$flag" || {
    force_stop "$pid"; force_stop "$EXTERNAL_HOLDER_PID"
    fail "the external holder never took the marker lock"
  }
  if ! wait_lock_taken "$queue_lock" "$pid"; then
    force_stop "$pid"; : > "$flag"; force_stop "$EXTERNAL_HOLDER_PID"
    fail "the watcher never entered the contended marker critical section"
  fi

  kill -TERM "$pid" 2>/dev/null || true
  if ! exited_within "$pid" 150; then
    force_stop "$pid"; : > "$flag"; force_stop "$EXTERNAL_HOLDER_PID"
    fail "a watcher signalled inside a contended critical section never exited (self-deadlock)"
  fi
  wait "$pid" 2>/dev/null || true

  is_live_non_zombie "$EXTERNAL_HOLDER_PID" \
    || fail "the external holder died first, so the watcher was never actually contended"
  [ ! -e "$queue_lock" ] && [ ! -L "$queue_lock" ] \
    || fail "the signalled watcher abandoned the wake-queue lock mid-section"
  # It could not persist recovery state against a foreign holder, so it keeps its
  # documented stale-lock evidence - but it must SAY so rather than go dark, and
  # the next arm reclaims that lock through the ordinary dead-holder path.
  [ -s "$err" ] || fail "the watcher exited silently instead of reporting why recovery state was not persisted"
  : > "$flag"
  force_stop "$EXTERNAL_HOLDER_PID"
  pass "a watcher signalled inside a contended critical section exits, reports why, and abandons no queue lock"
}

# --- TERM stops the watcher from every loop position -------------------------
#
# The specific risk in deferring signals at all is the mirror-image defect: a
# process TERM can no longer stop. Deferral is scoped to short library sections
# rather than installed process-wide precisely to avoid that, and this is the
# check that keeps it honest.
#
# Rather than assert one hand-picked instant, the signal is walked across the
# poll cycle in offsets that do not divide evenly into it, so successive rounds
# land in different phases - including inside the marker arm check that runs on
# every poll. Each round must exit within the bound AND free the singleton lock.
#
# Two details keep the sweep meaningful rather than decorative. Each round gets
# its own state, because a stopped watcher leaves a downtime marker that makes
# the NEXT one resurface and exit on its own before any offset elapses. And each
# round waits for a completed poll first, so the offset is measured from inside
# the loop: a signal delivered during startup, before the exit path is installed,
# is a different (and self-healing) path than the one under test here.
test_term_stops_the_watcher_from_every_loop_position() {
  local dir state out offset pid round=0
  dir="$TMP_ROOT/term-every-position"
  mkdir -p "$dir/fakebin"

  for offset in 0 0.05 0.13 0.27 0.41 0.58 0.73 0.94 1.17 1.36; do
    round=$((round + 1))
    state="$dir/state-$round"
    mkdir -p "$state"
    out="$dir/watch-$round.out"
    PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
    pid=$!
    wait_first_beat "$state" "$pid" \
      || { force_stop "$pid"; fail "round $round: the watcher never reached its loop: $(cat "$out")"; }
    sleep "$offset"
    is_live_non_zombie "$pid" \
      || { wait "$pid" 2>/dev/null || true; fail "round $round: the watcher exited on its own at +${offset}s: $(cat "$out")"; }
    kill -TERM "$pid" 2>/dev/null || true
    if ! exited_within "$pid" 100; then
      force_stop "$pid"
      fail "round $round: TERM at +${offset}s into the poll cycle did not stop the watcher"
    fi
    wait "$pid" 2>/dev/null || true
    { [ ! -e "$state/.watch.lock" ] && [ ! -L "$state/.watch.lock" ]; } \
      || fail "round $round: TERM at +${offset}s left the singleton lock held, so no re-arm can take over"
  done
  pass "TERM stops the watcher and frees its singleton lock from every position in the poll cycle"
}

# --- the exit path is bounded even against a holder that never lets go --------
#
# The liveness backstop, kept deliberately separate from the correctness fix. The
# watcher here is signalled while IDLE - not inside any section - so the deferral
# is not involved at all and the unwind goes straight into cleanup, which meets a
# foreign holder of the marker lock. That is the shape a future missed section
# would also take, and it must terminate: bounded and loud, never silently dark.
# Proven against a holder that is never released.
test_cleanup_is_bounded_against_a_permanent_lock_holder() {
  local dir state out err flag pid
  dir="$TMP_ROOT/cleanup-bounded"
  mkdir -p "$dir/state" "$dir/fakebin"
  state="$dir/state"; out="$dir/watch.out"; err="$dir/watch.err"
  flag="$dir/never-released"

  # A long poll keeps the watcher asleep between cycles, so the TERM below lands
  # outside every critical section.
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=30 FM_SIGNAL_GRACE=1 \
    FM_WATCHER_CLEANUP_LOCK_TICKS=5 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2> "$err" &
  pid=$!
  wait_first_beat "$state" "$pid" \
    || { force_stop "$pid"; fail "the watcher never completed a poll: $(cat "$err")"; }
  start_external_holder "$state" "$state/.watcher-down.lock" "$flag" || {
    force_stop "$pid"; force_stop "$EXTERNAL_HOLDER_PID"
    fail "the external holder never took the marker lock"
  }

  kill -TERM "$pid" 2>/dev/null || true
  if ! exited_within "$pid" 150; then
    force_stop "$pid"; force_stop "$EXTERNAL_HOLDER_PID"
    fail "shutdown blocked indefinitely on a marker lock held by another live process"
  fi
  wait "$pid" 2>/dev/null || true
  is_live_non_zombie "$EXTERNAL_HOLDER_PID" \
    || fail "the permanent holder died on its own, so the bound was never exercised"
  [ -s "$err" ] \
    || fail "the bounded shutdown gave up silently instead of reporting it; stdout was: $(cat "$out")"
  force_stop "$EXTERNAL_HOLDER_PID"
  pass "watcher shutdown stays bounded and loud against a marker lock another live process never releases"
}

# --- the daemon must not inherit its child's worst case -----------------------
#
# The away-mode daemon reaped its watcher child with a plain `kill; wait`, so a
# child that did not act on TERM blocked the daemon's own shutdown indefinitely
# and the operator had to kill both by hand before the return gate would clear -
# the same root cause reaching a second surface. Proven against a real child that
# really ignores TERM, so the bound cannot go vacuous, plus an ordinary child as
# the control so the bound is distinguishable from always escalating.
test_daemon_child_stop_is_bounded_against_a_term_ignoring_child() {
  local child started elapsed i rc LOG
  # Library mode: the daemon guards its executed path, so sourcing exposes the
  # shutdown helper without starting a daemon. The bound itself lives in the wake
  # library the daemon loads at runtime, so load that first - this also proves
  # the daemon delegates rather than carrying its own copy.
  # shellcheck disable=SC1090,SC1091
  . "$LIB"
  # shellcheck disable=SC1090
  . "$DAEMON"
  # LOG set to a real file so log()'s printf actually runs: with LOG unset,
  # log() short-circuits to a no-op and its own status would stand in for
  # stop_watcher_child's, hiding a wrapper that lets that status leak through.
  # shellcheck disable=SC2034 # read by log() in the sourced DAEMON via dynamic scope
  LOG="$TMP_ROOT/daemon-child-stop.log"

  bash -c 'trap "" TERM; while :; do sleep 0.1; done' &
  child=$!
  i=0
  while [ "$i" -lt 100 ] && ! pgrep -P "$child" >/dev/null 2>&1; do sleep 0.1; i=$((i + 1)); done
  pgrep -P "$child" >/dev/null 2>&1 \
    || { force_stop "$child"; fail "the TERM-ignoring child never installed its disposition"; }
  started=$(date +%s)
  FM_DAEMON_CHILD_STOP_TICKS=5 stop_watcher_child "$child"
  rc=$?
  elapsed=$(( $(date +%s) - started ))
  is_live_non_zombie "$child" && { force_stop "$child"; fail "daemon shutdown left a TERM-ignoring child alive"; }
  [ "$elapsed" -lt 30 ] || fail "daemon shutdown took ${elapsed}s to bound a TERM-ignoring child"
  [ "$rc" -ne 0 ] \
    || fail "stop_watcher_child reported success (rc=0) for a child that ignored TERM and needed KILL"

  bash -c 'while :; do sleep 0.1; done' &
  child=$!
  i=0
  while [ "$i" -lt 100 ] && ! pgrep -P "$child" >/dev/null 2>&1; do sleep 0.1; i=$((i + 1)); done
  started=$(date +%s)
  FM_DAEMON_CHILD_STOP_TICKS=50 stop_watcher_child "$child"
  rc=$?
  elapsed=$(( $(date +%s) - started ))
  is_live_non_zombie "$child" && { force_stop "$child"; fail "daemon shutdown left an ordinary child alive"; }
  [ "$elapsed" -lt 3 ] \
    || fail "an ordinary child took ${elapsed}s to stop, so TERM is not being tried before the escalation"
  [ "$rc" -eq 0 ] \
    || fail "stop_watcher_child reported an escalation (rc=$rc) for a child that stopped on TERM alone (zombie/kill-0 regression)"
  pass "daemon shutdown bounds a TERM-ignoring watcher child and still stops an ordinary one on TERM alone"
}

test_deferred_signal_waits_for_the_section_then_fires
test_watcher_signalled_in_critical_section_exits_and_releases
test_term_stops_the_watcher_from_every_loop_position
test_cleanup_is_bounded_against_a_permanent_lock_holder
test_daemon_child_stop_is_bounded_against_a_term_ignoring_child
