#!/usr/bin/env bash
# tests/wake-helpers.sh - shared fixtures and mocks for the wake-queue,
# watcher/lock, and supervise-daemon suites. The fake tmux surfaces here encode
# watcher/daemon/composer behavior, so they live here rather than in the generic
# tests/lib.sh. Generic reporters/assertions come from lib.sh, pulled in below.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

# fm-wake-drain.sh now calls fm-guard.sh to assert watcher liveness on every
# drain. fm-guard.sh's first check warns when the firstmate PRIMARY checkout
# (FM_ROOT) sits on a feature branch; with no override FM_ROOT resolves to the
# test runner's own checkout, which during validation is on a feature branch, so
# each drain would emit a spurious worktree-tangle banner. Point the tangle check
# at a fresh non-git dir to keep it inert across these suites - the same trick the
# direct fm-guard.sh tests use. A per-call FM_ROOT_OVERRIDE still wins where a
# suite sets its own (e.g. the watcher-lock guard-banner cases).
if [ -z "${FM_ROOT_OVERRIDE:-}" ]; then
  FM_ROOT_OVERRIDE="$(fm_test_tmproot fm-wake-tangle-root)"
  export FM_ROOT_OVERRIDE
fi

# Wedge-alarm notifier recorder (safety seam). The away-mode wedge alarm fires a
# real OS-level desktop notification by default. Point its FM_WEDGE_ALARM_EXEC
# seam at a recorder for every
# daemon/wake suite, so no test - present or future - can post a real macOS,
# herdr, or command: notification: it is impossible to forget, because sourcing this harness
# installs it. The recorder is an on-disk script (a real daemon a test spawns
# inherits the path and records too). It logs "<channel>\t<summary>" to
# $FM_WEDGE_ALARM_LOG, which a test sets to its own file to assert on; unset means
# /dev/null. FM_WEDGE_ALARM_FAIL=<channel> makes the recorder exit non-zero for
# that channel, to exercise graceful degradation. Suites that do not source this
# harness still cannot fire a real notification: the daemon defaults the seam to
# "discard" whenever it is sourced (its library-mode guard).
_fm_wedge_rec_dir=$(fm_test_tmproot fm-wedge-rec)
cat > "$_fm_wedge_rec_dir/rec" <<'REC'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${FM_WEDGE_ALARM_LOG:-/dev/null}"
case " ${FM_WEDGE_ALARM_FAIL:-} " in *" ${1:-} "*) exit 1 ;; esac
exit 0
REC
chmod +x "$_fm_wedge_rec_dir/rec"
export FM_WEDGE_ALARM_EXEC="$_fm_wedge_rec_dir/rec"

# append_wake <state> <kind> <key> <payload>: append a wake record to the durable
# queue in a subshell scoped to <state>, using the production wake library.
append_wake() {
  local state=$1 kind=$2 key=$3 payload=$4 lib="$ROOT/bin/fm-wake-lib.sh"
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_wake_append "$2" "$3" "$4"
  ' _ "$lib" "$kind" "$key" "$payload"
}

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "list-windows" ]; then
  if [ -n "${FM_FAKE_TMUX_WINDOWS:-}" ]; then
    printf '%s\n' "$FM_FAKE_TMUX_WINDOWS"
  elif [ -n "${FM_FAKE_TMUX_WINDOW:-}" ]; then
    printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"
  fi
  exit 0
fi
if [ "${1:-}" = "capture-pane" ]; then
  if [ -n "${FM_FAKE_TMUX_CAPTURE_COUNT_FILE:-}" ]; then
    _capture_count=$(cat "$FM_FAKE_TMUX_CAPTURE_COUNT_FILE" 2>/dev/null || echo 0)
    printf '%s\n' "$((_capture_count + 1))" > "$FM_FAKE_TMUX_CAPTURE_COUNT_FILE"
    if [ -n "${FM_FAKE_TMUX_CAPTURE_FAIL_AFTER:-}" ] \
      && [ "$_capture_count" -ge "$FM_FAKE_TMUX_CAPTURE_FAIL_AFTER" ]; then
      exit 1
    fi
  fi
  if [ -n "${FM_FAKE_TMUX_FORBIDDEN_TARGET:-}" ]; then
    _prev=
    for _arg in "$@"; do
      if [ "$_prev" = -t ] && [ "$_arg" = "$FM_FAKE_TMUX_FORBIDDEN_TARGET" ]; then
        exit 1
      fi
      _prev=$_arg
    done
  fi
  if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ]; then
    cat "$FM_FAKE_TMUX_CAPTURE"
  fi
  exit 0
fi
if [ "${1:-}" = "display-message" ]; then
  case "$*" in
    *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;;
  esac
fi
exit 1
SH
  chmod +x "$fakebin/tmux"
  make_fake_crew_state "$fakebin" >/dev/null
  printf '%s\n' "$dir"
}

# Install a hermetic fake fm-crew-state.sh into <fakebin> and echo its path. The
# watcher's absorb-only-when-provably-working triage calls this (via
# FM_CREW_STATE_BIN) to read a crew's current state on no-verb signal and stale
# paths; the fake returns a canned "state: <s> · source: <src> · <detail>"
# verdict line so a test can fix the provably-working decision without a real
# worktree or no-mistakes.
# A per-id override FM_FAKE_CREW_STATE_<sanitized-id> wins; otherwise the shared
# FM_FAKE_CREW_STATE; otherwise an unknown verdict (NOT provably working), the
# safe default so a test that forgets to set one surfaces rather than absorbs.
make_fake_crew_state() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
key=$(printf '%s' "$id" | tr -c 'A-Za-z0-9' '_')
var="FM_FAKE_CREW_STATE_$key"
val=${!var:-${FM_FAKE_CREW_STATE:-}}
printf '%s\n' "${val:-state: unknown · source: none · fake default}"
exit 0
SH
  chmod +x "$fakebin/fm-crew-state.sh"
  printf '%s\n' "$fakebin/fm-crew-state.sh"
}

# Prime <file>'s .seen-* marker to its CURRENT signature through the production
# signature owner (bin/fm-wake-lib.sh), so a test can declare "everything in
# this file was already surfaced or deliberately absorbed" before exercising
# the next wake, self-announced append, or annotation decision.
prime_status_seen() {  # <state> <file>
  FM_STATE_OVERRIDE="$1" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}

# Print the generation from a recovery marker token of any status/kind.
recovery_marker_generation() {  # <marker-file>
  sed -n 's/^[^:]*:[^:]*:\(.*\)$/\1/p' "$1"
}

# Acknowledge a drain from its captured stderr (the WAKE_ACK_REQUIRED line).
ack_drain_err() {  # <state> <stderr-file>
  local state=$1 err=$2 sequence generation
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" \
    --ack-through "$sequence" --recovery-generation "$generation"
}

make_supercase() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_PANE_ALIVE:-1}" = "1" ] || exit 1
    _print=0
    # Return cursor_y when the format asks for it (pane_input_pending), and the
    # pane's process identity when the away-mode agent-proof guard asks for it.
    # That guard requires a live agent to own the pane before anything is typed
    # into it, so this fake stands in for a pane running the primary harness
    # these tests configure (FM_DAEMON_PRIMARY_HARNESS=claude). Override
    # FM_FAKE_TMUX_PANE_COMMAND to construct the shell/unowned pane instead.
    # pane_tty stays a non-/dev name so the `ps` half of the probe is skipped
    # and the fake never describes a real process on the host.
    for _a in "$@"; do
      case "$_a" in
        *cursor_y*) printf '%s\n' "${FM_FAKE_TMUX_CURSOR_Y:-0}"; exit 0 ;;
        *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_PANE_COMMAND:-claude}"; exit 0 ;;
        *pane_tty*) printf '%s\n' "${FM_FAKE_TMUX_PANE_TTY:-fakepane}"; exit 0 ;;
      esac
      [ "$_a" = "-p" ] && _print=1
    done
    [ "$_print" = 1 ] && printf 'fakepane\n'
    exit 0 ;;
  list-windows)
    [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
    exit 0 ;;
  capture-pane)
    # Honor a single-line band capture (-S N -E M, both non-negative) for the
    # composer reader's non-bordered compatibility fallback; otherwise (e.g. its
    # structural full-pane scan or fm_pane_is_busy's "-S -40" tail) return the whole capture. -e is accepted and
    # ignored: this fake emits plain text, which the dim-stripper passes through.
    _S=""; _E=""; shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -S) _S="${2:-}"; shift 2; continue ;;
        -E) _E="${2:-}"; shift 2; continue ;;
        *) shift ;;
      esac
    done
    [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] || exit 0
    if [ -n "$_S" ] && [ -n "$_E" ]; then
      case "$_S$_E" in
        *[!0-9]*) cat "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null ;;
        *) sed -n "$((_S + 1)),$((_E + 1))p" "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null ;;
      esac
    else
      cat "$FM_FAKE_TMUX_CAPTURE" 2>/dev/null
    fi
    exit 0 ;;
  send-keys)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -l) shift; [ "$#" -gt 0 ] && {
          printf '%s\n' "$1" >> "${FM_FAKE_TMUX_SENT:-/dev/null}"
          # Reflect sent text into capture so pane_input_pending sees it as
          # pending input (text in the composer).
          [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && printf '%s\n' "$1" >> "$FM_FAKE_TMUX_CAPTURE"
        } ;;
        Enter)
          # Optionally swallow Enter (file-based flag) to test the retry path.
          if [ -n "${FM_FAKE_TMUX_SWALLOW_FILE:-}" ] && [ -f "$FM_FAKE_TMUX_SWALLOW_FILE" ]; then
            rm -f "$FM_FAKE_TMUX_SWALLOW_FILE"
          else
            printf '[ENTER]\n' >> "${FM_FAKE_TMUX_SENT:-/dev/null}"
            # Enter submits: clear the last line (the typed text) from the
            # capture, simulating the composer being cleared on submit.
            if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && [ -s "$FM_FAKE_TMUX_CAPTURE" ]; then
              _tmp=$(mktemp 2>/dev/null) || _tmp="${FM_FAKE_TMUX_CAPTURE}.tmp"
              sed '$d' "$FM_FAKE_TMUX_CAPTURE" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$FM_FAKE_TMUX_CAPTURE"
              rm -f "$_tmp" 2>/dev/null
            fi
          fi
          ;;
      esac
      shift
    done
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

make_bordered_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"; fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$dir/composer"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?FM_FAKE_COMPOSER unset}"
write_composer() {
  text=$1
  width=$((${#text} + 4))
  border=
  i=0
  while [ "$i" -lt "$width" ]; do
    border="${border}─"
    i=$((i + 1))
  done
  printf '╭%s╮\n│ > %s │\n╰%s╯\n' "$border" "$text" "$border" > "$COMPOSER"
}
case "${1:-}" in
  display-message)
    print=0
    # cursor_y for the composer reader; pane identity for the away-mode
    # agent-proof guard (see make_supercase's fake for the contract).
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_PANE_COMMAND:-claude}"; exit 0 ;;
        *pane_tty*) printf '%s\n' "${FM_FAKE_TMUX_PANE_TTY:-fakepane}"; exit 0 ;;
      esac
    done
    for a in "$@"; do [ "$a" = "-p" ] && print=1; done
    [ "$print" = 1 ] && printf 'fakepane\n'
    exit 0 ;;
  capture-pane) cat "$COMPOSER" 2>/dev/null; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    shift
    text=""; is_enter=0; lit=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift ;;
        -l) lit=1 ;;
        Enter) is_enter=1 ;;
        *) [ "$lit" = 1 ] && text="$1" ;;
      esac
      shift
    done
    if [ "$is_enter" = 1 ]; then
      if [ -n "${FM_FAKE_SWALLOW:-}" ] && [ -f "$FM_FAKE_SWALLOW" ]; then
        [ "${FM_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$FM_FAKE_SWALLOW"
      else
        [ -n "${FM_FAKE_SENT:-}" ] && printf '[ENTER]\n' >> "$FM_FAKE_SENT"
        write_composer ""
      fi
    elif [ "$lit" = 1 ]; then
      [ "${FM_FAKE_SEND_FAIL:-0}" = 1 ] && exit 1
      [ -n "${FM_FAKE_SENT:-}" ] && printf '%s\n' "$text" >> "$FM_FAKE_SENT"
      write_composer "$text"
    fi
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if
# it died. The complement of wait_for_exit, for asserting a wake was ABSORBED.
#
# This is a fixed wall-clock slice: use it only for a genuine short race
# (proving a process is still blocked RIGHT NOW, e.g. the drain/marker-commit
# race in test_procevent_surface_serializes_with_drain). Never use it to prove
# an absorb DECISION landed - the work between a poll starting and that
# decision committing is real subprocess time (tmux captures, crew-state
# lookups...) that stretches arbitrarily under CPU contention, which is exactly
# what turned a fixed "stay alive for N ticks, then assert markers" gate into a
# load-flaky one. wait_absorbed and wait_watcher_settled below are the
# artifact-based replacements for that shape.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

# Generous default ceiling (0.1s ticks) for the condition-based waits below.
# These gates wait on a real artifact rather than a blind sleep, so a large
# ceiling only lengthens genuine hangs - never a healthy case - while too small
# a ceiling reproduces the exact fixed-wall-clock flake this exists to avoid
# under CPU contention. Override via FM_TEST_WAIT_TICKS on a slower host.
FM_TEST_WAIT_TICKS=${FM_TEST_WAIT_TICKS:-600}

# Set by wait_absorbed/wait_watcher_settled just before they return non-zero,
# to the reason a caller's fail message should report: the watcher actually
# exited (rc 1), or it is still alive at the wait ceiling - a genuine hang (rc
# 2). A caller that hardcodes "watcher exited" in its fail message is wrong
# half the time; interpolate wait_fail_word() instead so the message matches
# what actually happened.
FM_WAIT_OUTCOME=
wait_fail_word() {
  printf '%s' "${FM_WAIT_OUTCOME:-exited}"
}

# Wait until watcher <pid> exits, or <predicate> (a `[ ... ]`-shaped condition,
# passed as one string and eval'd) becomes true while <pid> is still alive,
# whichever happens first. Polls every 0.1s up to <limit> ticks (default
# $FM_TEST_WAIT_TICKS).
#
# Returns 0 once <predicate> is true and <pid> is still alive (the wake was
# absorbed AND the specific decision under test has actually landed); 1 if
# <pid> exited before <predicate> became true (an actionable wake surfaced -
# not absorbed, the same failure wait_live's "died early" case reported); 2 if
# <limit> is spent with <pid> still alive and <predicate> still false (a
# genuine hang - never silently converted into an unbounded wait).
#
# Use this, never a fixed slice of wall clock, wherever a case needs "the
# specific state I'm about to assert has actually been written" - waiting on
# the real artifact instead of a blind sleep is what makes the gate tolerant of
# a slow, loaded host without ever tolerating a genuine wedge.
wait_absorbed() {  # <pid> <predicate> [limit-ticks]
  local pid=$1 predicate=$2 limit=${3:-$FM_TEST_WAIT_TICKS} i=0
  while [ "$i" -lt "$limit" ]; do
    is_live_non_zombie "$pid" || { FM_WAIT_OUTCOME="exited"; return 1; }
    eval "$predicate" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  if is_live_non_zombie "$pid"; then
    FM_WAIT_OUTCOME="still alive at the wait ceiling (genuine hang)"
    return 2
  fi
  FM_WAIT_OUTCOME="exited"
  return 1
}

# Wait until watcher <pid> has fully COMPLETED at least one poll pass beyond
# <baseline> (state/.last-watcher-beat's epoch mtime captured BEFORE <pid> was
# spawned, or "" for a fresh case with no beacon file yet), proven by that
# beacon advancing a SECOND time. The beacon is touched at the very top of
# every pass (bin/fm-watch.sh), before that pass's own absorb-or-surface
# decisions run, so seeing it advance once only proves a pass STARTED - not
# that its decision finished. A second advance can only happen once the
# sequential poll loop reaches its next iteration, which it cannot do until the
# prior pass's entire body - including any wake()/exit - already ran to
# completion.
#
# Use this only when no more specific artifact exists for what the case is
# proving (e.g. a window whose per-pass body is a no-op this round, or a
# decision that leaves no marker of its own either way); prefer wait_absorbed
# with the actual state the case goes on to assert wherever one exists, since
# that is a strictly stronger proof. Returns 0 once settled, 1 if the watcher
# exited first, 2 on a genuine hang past <limit> ticks (default
# $FM_TEST_WAIT_TICKS).
wait_watcher_settled() {  # <state> <pid> [baseline-epoch] [limit-ticks]
  local state=$1 pid=$2 baseline=${3:-} limit=${4:-$FM_TEST_WAIT_TICKS} i=0 beat first=
  while [ "$i" -lt "$limit" ]; do
    is_live_non_zombie "$pid" || { FM_WAIT_OUTCOME="exited"; return 1; }
    beat=$(file_mtime "$state/.last-watcher-beat")
    if [ -n "$beat" ]; then
      if [ -z "$first" ]; then
        { [ -z "$baseline" ] || [ "$beat" -gt "$baseline" ]; } && first=$beat
      elif [ "$beat" -gt "$first" ]; then
        return 0
      fi
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if is_live_non_zombie "$pid"; then
    FM_WAIT_OUTCOME="still alive at the wait ceiling (genuine hang)"
    return 2
  fi
  FM_WAIT_OUTCOME="exited"
  return 1
}

# Signature a primed .seen-* marker must hold so the per-poll signal scan does
# not fire on a pre-existing status (mirrors fm-watch.sh's stat_sig exactly).
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

# Stop a watcher this shell owns, without ever hanging on it.
#
# TERM, wait a bounded time, then KILL, so no case can hang the whole suite on a
# process that will not die. Sets FM_REAP_NEEDED_KILL=1 when TERM was ignored.
#
# A watcher reaching that escalation is a REGRESSION, not a tolerated condition:
# a signal delivered mid-critical-section is held until the section closes and
# then re-raised (bin/fm-wake-lib.sh), and the exit path is bounded
# (bin/fm-watch.sh), so TERM stops a watcher from every position in its loop -
# pinned by tests/fm-watcher-signal-safety.test.sh. Cases that reap a watcher
# assert on this flag rather than tolerating it; the KILL escalation stays only
# so that a future regression fails loudly instead of hanging CI.
# shellcheck disable=SC2034  # read by sourcing suites, not by this harness
FM_REAP_NEEDED_KILL=
reap() {  # <pid> [term-wait-ticks]
  local pid=$1 limit=${2:-50} i=0
  FM_REAP_NEEDED_KILL=
  kill "$pid" 2>/dev/null || true
  while [ "$i" -lt "$limit" ]; do
    is_live_non_zombie "$pid" || { wait "$pid" 2>/dev/null || true; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  # shellcheck disable=SC2034  # read by sourcing suites, not by this harness
  FM_REAP_NEEDED_KILL=1
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 0
}

# Assert the reap above stopped its watcher with TERM alone. <what> names the
# case so a regression says which position in the loop stopped honouring TERM.
assert_reaped_on_term() {  # <what>
  [ -z "$FM_REAP_NEEDED_KILL" ] \
    || fail "$1: the watcher ignored TERM and had to be killed (signal/lock self-deadlock regression)"
}

# Portable mtime in epoch seconds. Platform-detected, never the
# `stat -f || stat -c` fallback (which writes a partial filesystem dump on
# Linux; see fm-watch.sh).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Wait until watcher <pid> has actually COMPLETED a poll, evidenced by its
# liveness beacon (state/.last-watcher-beat, touched every poll including while
# absorbing) appearing or advancing past <baseline>. Returns 0 once that
# happens, 1 if the watcher exits first or <limit> 0.1s ticks pass.
#
# Use this, never a fixed slice of wall clock, wherever a case needs "one poll
# has run before I look". A watcher poll does real startup work (queue drain,
# reconciliation sweeps) whose duration is machine-speed dependent, so a fixed
# slice turns a strict assertion into a flaky one on a loaded host: the case
# reaps the watcher before its first poll and then reads state that was never
# written.
# Wait until watcher <pid> has COMPLETED at least <passes> stale-triage passes
# over the window keyed <key>, evidenced by that window's .count-<key>. Returns
# 0 once reached, 1 if the watcher exits first (it woke), 2 on timeout.
#
# The +1 is load-bearing: fm-watch.sh rewrites .count-<key> at the START of a
# pass, before that pass decides anything, so the NEXT increment is the only
# proof the decision in between actually ran. Waiting on the counter's first
# change - or on any fixed slice of wall clock - reaps the watcher mid-decision
# on a loaded host and leaves the case asserting over state nobody wrote.
wait_stale_passes() {  # <state> <key> <pid> <baseline> [passes] [limit-ticks]
  local state=$1 key=$2 pid=$3 baseline=${4:-0} passes=${5:-1} limit=${6:-$FM_TEST_WAIT_TICKS} i=0 cur
  case "$baseline" in ''|*[!0-9]*) baseline=0 ;; esac
  while [ "$i" -lt "$limit" ]; do
    cur=$(cat "$state/.count-$key" 2>/dev/null || echo 0)
    case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
    [ "$cur" -ge "$(( baseline + passes + 1 ))" ] && return 0
    is_live_non_zombie "$pid" || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 2
}

wait_watcher_beat() {  # <state> <pid> [baseline-epoch] [limit-ticks]
  local state=$1 pid=$2 baseline=${3:-} limit=${4:-150} i=0 beat
  while [ "$i" -lt "$limit" ]; do
    beat=$(file_mtime "$state/.last-watcher-beat")
    if [ -n "$beat" ] && { [ -z "$baseline" ] || [ "$beat" -gt "$baseline" ]; }; then
      return 0
    fi
    is_live_non_zombie "$pid" || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_exit() {
  local pid=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! is_live_non_zombie "$pid"; then
      wait "$pid"
      return "$?"
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 124
}

is_live_non_zombie() {
  local pid=$1 stat
  kill -0 "$pid" 2>/dev/null || return 1
  stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$stat" in
    Z*) return 1 ;;
  esac
  return 0
}

hash_text() {
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5 -q
  else
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  fi
}

dead_pid() {
  local p=999999
  while kill -0 "$p" 2>/dev/null; do
    p=$((p + 1))
  done
  printf '%s\n' "$p"
}
