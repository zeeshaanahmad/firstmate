#!/usr/bin/env bash
# tests/fm-away-delivery-bound-live-e2e.test.sh - the live away-delivery-bound
# guard (live-harness-optin family; task away-digest-truncates-long-escalations).
#
# INJECT_MAX_BYTES_DEFAULT in bin/fm-supervise-daemon.sh is a vendor-measured
# number, not a derived one: it is the largest single literal send that a real
# harness was observed to receive whole. Above it, a receiving harness that
# keeps only the last of several stdin reads drops everything before it, and
# that cut takes the FRONT of the message - marker included. Per
# .agents/skills/firstmate-coding-guidelines a bound that comes from vendor
# behavior must be proven against the real harness, because a stub can only
# confirm the assumption already written into the stub. The portable regression
# (tests/fm-afk-inject-e2e.test.sh scenarios D and E, tests/fm-daemon.test.sh,
# tests/fm-operational-input.test.sh) pins the LOGIC everywhere CI runs tmux;
# this guard re-measures the NUMBER after a harness upgrade.
#
# It submits real prompts, so unlike the other live guards it does spend model
# tokens - a few short turns per harness. That is the cost of a measured bound
# rather than a guessed one. Run explicitly with FM_AWAY_BOUND_LIVE=1.
#
# Method: type a position-encoded payload into an idle harness composer with a
# single `tmux send-keys -l`, exactly as the daemon does, then ask the harness
# to report the first characters and total length of the message it received.
# The block ids identify the byte offset the surviving text starts at, so a
# front cut is visible as a nonzero start offset.
#
# An installed harness with no readback recipe here is reported as NOT covered
# rather than silently skipped; an absent harness is reported absent; a run that
# measured nothing fails instead of passing vacuously. Refresh
# docs/verification/supervision.md "Away-mode delivery bound" from this output.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${FM_AWAY_BOUND_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_AWAY_BOUND_LIVE=1 to run the live away-delivery-bound guard"
  exit 0
fi

command -v tmux >/dev/null 2>&1 \
  || { echo "not ok - FM_AWAY_BOUND_LIVE=1 but tmux is not installed" >&2; exit 1; }

# The bound comes from its owner, so this guard cannot drift from the shipped
# default.
# shellcheck source=bin/fm-supervise-daemon.sh
. "$ROOT/bin/fm-supervise-daemon.sh"
BOUND=$INJECT_MAX_BYTES_DEFAULT

SOCKET="fm-awaybound-live-$$"
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-awaybound.XXXXXX")
MEASURED=0
FAILED=0

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

# Position-encoded payload: every 8 bytes name their own block index, so the
# first surviving block identifies the byte offset the delivery starts at.
payload() {  # <bytes>
  awk -v n="$(( ${1} / 8 ))" 'BEGIN{ for (i = 0; i < n; i++) printf "%07d ", i }'
}

# Measure one send size against one live harness. Echoes "<start-offset>" or
# "unreadable". A start offset of 0 means the message arrived whole.
measure_send() {  # <harness-cmd> <bytes>
  local cmd=$1 bytes=$2 session reply head
  session="ab$$$bytes"
  tmux -L "$SOCKET" kill-session -t "$session" 2>/dev/null || true
  tmux -L "$SOCKET" new-session -d -s "$session" -x 200 -y 50 -c "$WORKDIR" "$cmd"
  sleep 12
  # A first run in a fresh directory can open a folder-trust prompt, which is a
  # dialog rather than a composer. Answer it once so the measurement reaches the
  # composer; a harness that shows no such prompt is unaffected.
  if tmux -L "$SOCKET" capture-pane -p -t "$session" 2>/dev/null | grep -qi 'trust'; then
    tmux -L "$SOCKET" send-keys -t "$session" Down
    sleep 1
    tmux -L "$SOCKET" send-keys -t "$session" Enter
    sleep 10
  fi
  tmux -L "$SOCKET" send-keys -t "$session" -l "$(payload "$bytes")" 2>/dev/null || {
    printf 'send-refused'; tmux -L "$SOCKET" kill-session -t "$session" 2>/dev/null; return 0; }
  sleep 3
  tmux -L "$SOCKET" send-keys -t "$session" -l \
    " REPORT: reply with exactly one line and nothing else: HEAD=<first 8 characters of this message>. No tools, no preamble."
  sleep 3
  tmux -L "$SOCKET" send-keys -t "$session" Enter
  sleep 35
  reply=$(tmux -L "$SOCKET" capture-pane -p -S - -t "$session" 2>/dev/null \
    | grep -o 'HEAD=[0-9 ]*' | tail -1)
  tmux -L "$SOCKET" kill-session -t "$session" 2>/dev/null || true
  [ -n "$reply" ] || { printf 'unreadable'; return 0; }
  head=${reply#HEAD=}
  # The reported head is a slice of the payload; find where it starts.
  awk -v h="$head" -v n="$(( bytes / 8 ))" 'BEGIN{
    full=""; for (i = 0; i < n; i++) full = full sprintf("%07d ", i)
    gsub(/^ +| +$/, "", h)
    if (h == "") { print "unreadable"; exit }
    p = index(full, h)
    if (p == 0) { print "unreadable"; exit }
    print p - 1
  }'
}

check_harness() {  # <name> <command>
  local name=$1 cmd=$2 at_bound over_bound version
  if ! command -v "${cmd%% *}" >/dev/null 2>&1; then
    note "$name: NOT INSTALLED - bound not measured for this harness"
    return 0
  fi
  version=$("${cmd%% *}" --version 2>/dev/null | head -1 | tr -d '\n')
  at_bound=$(measure_send "$cmd" "$BOUND")
  case "$at_bound" in
    0) : ;;
    unreadable|send-refused)
      note "$name ${version:-unknown}: could not read back a delivery ($at_bound); bound NOT measured"
      return 0 ;;
    *)
      FAILED=1
      printf 'not ok - %s %s: a %s-byte send lost its first %s bytes; INJECT_MAX_BYTES_DEFAULT is above this harness real bound\n' \
        "$name" "${version:-unknown}" "$BOUND" "$at_bound" >&2
      return 0 ;;
  esac
  MEASURED=$((MEASURED + 1))
  pass "$name ${version:-unknown}: a ${BOUND}-byte send - the configured bound - arrives whole"

  # And show the failure this bound exists to avoid is still real above it. A
  # harness that has since been fixed reports 0 here, which is not a failure:
  # it is a signal that the bound could be raised, recorded as a note.
  over_bound=$(measure_send "$cmd" $(( BOUND * 2 )))
  case "$over_bound" in
    0) note "$name ${version:-unknown}: a $(( BOUND * 2 ))-byte send ALSO arrived whole; the bound may be raisable, re-measure before changing it" ;;
    unreadable|send-refused) note "$name ${version:-unknown}: over-bound probe was $over_bound" ;;
    *) note "$name ${version:-unknown}: a $(( BOUND * 2 ))-byte send lost its first $over_bound bytes, which is the failure the bound avoids" ;;
  esac
}

# Verified primary harnesses. A harness gets a row once it has a scriptable
# readback recipe; one without a row is reported as not covered, never assumed.
check_harness claude claude
check_harness codex "codex"
for uncovered in opencode pi pi-signed grok kimi cursor muse; do
  note "$uncovered: no readback recipe in this guard - bound NOT measured for this harness"
done

[ "$FAILED" -eq 0 ] || { echo "not ok - the configured away-mode delivery bound is unsafe on at least one installed harness" >&2; exit 1; }
[ "$MEASURED" -gt 0 ] \
  || { echo "not ok - FM_AWAY_BOUND_LIVE=1 measured no harness at all; a guard that checked nothing must not pass" >&2; exit 1; }
printf 'ok - away-mode delivery bound measured whole on %s harness(es)\n' "$MEASURED"
