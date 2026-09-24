#!/usr/bin/env bash
# Live drive of the merged secondmate endpoint auto-relaunch (upstream #5496):
# the REAL bin/fm-watch.sh + bin/fm-secondmate-liveness-lib.sh + bin/fm-spawn.sh
# against a REAL tmux server. Isolation: a private TMUX_TMPDIR (own socket dir),
# a lab FM_HOME under /tmp, and a fake `claude` binary so no model is contacted.
# Nothing here touches the operator's tmux server, Herdr, or fleet state.
set -u
ROOT=${1:?worktree root}
LAB=$(mktemp -d /tmp/fm-live-sm.XXXXXX)
export TMUX_TMPDIR="$LAB/tmuxdir"
mkdir -p "$TMUX_TMPDIR" "$LAB/fakebin" "$LAB/home/state" "$LAB/home/config" "$LAB/home/data" \
  "$LAB/mate/bin" "$LAB/mate/data" "$LAB/mate/state" "$LAB/mate/config" "$LAB/mate/projects"
unset TMUX
STATE="$LAB/home/state"

cleanup() {
  tmux kill-server 2>/dev/null || true
  [ -z "${WPID:-}" ] || kill -TERM "$WPID" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

# Fake harness: never contacts a model, just idles as a long sleep.
printf '#!/bin/bash\nexec -a claude /bin/sleep 600\n' > "$LAB/fakebin/claude"
chmod +x "$LAB/fakebin/claude"
cat > "$LAB/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: unknown · source: none · live lab\n'
SH
chmod +x "$LAB/fakebin/fm-crew-state.sh"

printf 'sm1\n' > "$LAB/mate/.fm-secondmate-home"
printf '# Firstmate\n' > "$LAB/mate/AGENTS.md"
printf 'charter\n' > "$LAB/mate/data/charter.md"
printf 'claude\n' > "$LAB/home/config/crew-harness"
printf 'window=firstmate:fm-sm1\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' "$LAB/mate" > "$STATE/sm1.meta"

# Real tmux server; the fake harness dir is on the server's PATH so a relaunch
# started by fm-spawn resolves `claude` to it.
PATH="$LAB/fakebin:$PATH" tmux new-session -d -s firstmate -n main -x 120 -y 40 || { echo "tmux failed"; exit 1; }
say() { printf '\n== %s\n' "$*"; }
pane_pid() { tmux list-panes -t firstmate:fm-sm1 -F '#{pane_pid}' 2>/dev/null | head -1; }
pane_cmd() { tmux display-message -p -t firstmate:fm-sm1 '#{pane_current_command}' 2>/dev/null; }
windows() { tmux list-windows -t firstmate -F '#W' | tr '\n' ' '; }

# One watcher leg: env mirrors the repo's own wake-queue harness, but tmux is REAL.
leg() { # <tag> [NAME=VALUE...]
  local tag=$1; shift
  env PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$LAB/fakebin/fm-crew-state.sh" \
    TMUX='' FM_BACKEND=tmux TMUX_TMPDIR="$TMUX_TMPDIR" FM_SECONDMATE_LIVENESS_SECS=1 \
    FM_GATE_REFUSE_BYPASS=${LAB_GATE_BYPASS:-1} \
    FM_SECONDMATE_LIVENESS_TIMEOUT=60 \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$@" "$ROOT/bin/fm-watch.sh" > "$LAB/watch-$tag.out" 2> "$LAB/watch-$tag.err" &
  WPID=$!
}
wait_leg() { # <seconds>
  local i=0
  while kill -0 "$WPID" 2>/dev/null && [ "$i" -lt $(( $1 * 5 )) ]; do sleep 0.2; i=$((i+1)); done
  if kill -0 "$WPID" 2>/dev/null; then kill -TERM "$WPID" 2>/dev/null; sleep 0.5; kill -KILL "$WPID" 2>/dev/null; echo "(watcher did not wake within $1s; stopped)"; return 1; fi
  wait "$WPID" 2>/dev/null; return 0
}
drain_ack() {
  local err seq gen
  FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$LAB/drain.err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\).*$/\1/p' "$LAB/drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\).*$/\1/p' "$LAB/drain.err")
  [ -n "$seq" ] && [ -n "$gen" ] || return 0
  FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 || true
}
ledger() { [ -f "$STATE/.secondmate-relaunch-sm1" ] && awk -F '\t' '{print "   ledger: " $2}' "$STATE/.secondmate-relaunch-sm1" | tr '\n' ';' ; echo; }

# ---------------------------------------------------------------- Leg 1
say "LEG 1: agent exited, endpoint alive as a bare shell (recovery-grade 'dead')"
tmux new-window -d -t firstmate -n fm-sm1 'exec bash --noprofile --norc'
sleep 0.5
echo "before: windows=[$(windows)] fm-sm1 foreground=$(pane_cmd) pid=$(pane_pid)"
OLD_PID=$(pane_pid)
leg dead
wait_leg 90; echo "watcher exit wake line:"; sed 's/^/   /' "$LAB/watch-dead.out"
sleep 1
echo "after:  windows=[$(windows)] fm-sm1 foreground=$(pane_cmd) pid=$(pane_pid) (old pid $OLD_PID replaced: $([ "$OLD_PID" != "$(pane_pid)" ] && echo yes || echo NO))"
ledger
echo "queue rows: $(grep -c 'secondmate-relaunch-sm1-' "$STATE/.wake-queue" 2>/dev/null)"
drain_ack

# ---------------------------------------------------------------- Leg 2
say "LEG 2 (adversarial): live pane running an UNKNOWN foreground process must NOT be touched"
tmux kill-window -t firstmate:fm-sm1 2>/dev/null
tmux new-window -d -t firstmate -n fm-sm1 'exec /bin/sleep 900'
sleep 0.5
OLD_PID=$(pane_pid)
: > "$STATE/.secondmate-liveness-tick"; touch -t 200001010000 "$STATE/.secondmate-liveness-tick"
echo "before: foreground=$(pane_cmd) pid=$OLD_PID ledger rows so far: $(wc -l < "$STATE/.secondmate-relaunch-sm1" | tr -d ' ')"
leg ambiguous
wait_leg 8 || true
echo "after:  foreground=$(pane_cmd) pid=$(pane_pid) untouched: $([ "$OLD_PID" = "$(pane_pid)" ] && echo yes || echo NO)"
echo "ledger rows after: $(wc -l < "$STATE/.secondmate-relaunch-sm1" | tr -d ' ')"
echo "watcher stdout (must be empty of relaunch wake): [$(cat "$LAB/watch-ambiguous.out")]"
echo "triage log:"; grep -h "secondmate sm1" "$STATE"/*.log "$STATE"/.watch-triage* 2>/dev/null | tail -2 | sed 's/^/   /'
drain_ack

# ---------------------------------------------------------------- Leg 3
say "LEG 3: endpoint window gone entirely (recovery-grade 'missing')"
tmux kill-window -t firstmate:fm-sm1 2>/dev/null
echo "before: windows=[$(windows)]"
touch -t 200001010000 "$STATE/.secondmate-liveness-tick"
leg missing
wait_leg 90; echo "watcher exit wake line:"; sed 's/^/   /' "$LAB/watch-missing.out"
sleep 1
echo "after:  windows=[$(windows)] pid=$(pane_pid)"
ledger
drain_ack

# ---------------------------------------------------------------- Leg 4
say "LEG 4 (adversarial): a mate that keeps dying is bounded (MAX_ATTEMPTS=3 within the window), then parked"
for n in 1 2 3 4; do
  tmux kill-window -t firstmate:fm-sm1 2>/dev/null
  touch -t 200001010000 "$STATE/.secondmate-liveness-tick"
  leg bound$n FM_SECONDMATE_LIVENESS_MAX_ATTEMPTS=3
  wait_leg 90 >/dev/null; printf 'kill #%s -> wake: %s\n' "$n" "$(head -1 "$LAB/watch-bound$n.out" | cut -c1-170)"
  drain_ack
done
printf 'park marker present: %s\n' "$([ -e "$STATE/.secondmate-relaunch-bound-sm1" ] && echo yes || echo NO)"
echo "windows while parked: [$(windows)] (no new fm-sm1 expected after the 4th kill)"
ledger

# ---------------------------------------------------------------- Leg 5
say "LEG 5: manual recovery lifts the park (live probe -> 'rearmed' row, marker cleared)"
tmux new-window -d -t firstmate -n fm-sm1 'exec bash --noprofile --norc'
tmux kill-window -t firstmate:fm-sm1 2>/dev/null
# A pane whose foreground argv0 is an agent name reads alive (the classifier checks comm and argv0).
tmux new-window -d -t firstmate -n fm-sm1 "bash -c 'exec -a claude /bin/sleep 900'"
sleep 0.7
echo "manual endpoint foreground=$(pane_cmd)"
touch -t 200001010000 "$STATE/.secondmate-liveness-tick"
leg rearm
sleep 6
kill -TERM "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
printf 'park marker present after live probe: %s\n' "$([ -e "$STATE/.secondmate-relaunch-bound-sm1" ] && echo yes || echo no)"
ledger
grep -h "auto-relaunch pause cleared" "$STATE"/*.log "$STATE"/.watch-triage* 2>/dev/null | tail -1 | sed 's/^/   triage: /'
echo
echo "watcher stderr across legs (should be free of liveness errors):"
cat "$LAB"/watch-*.err | grep -i "liveness" | sed 's/^/   /' | head -5
echo "(none above means clean)"
