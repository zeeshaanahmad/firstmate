#!/usr/bin/env bash
# Pin the Pi/OpenCode recovery-loop fix: one announcement per generation, and a
# handling successor that keeps supervising instead of going blind.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh" || exit 1

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-recovery-loop)
export NODE_NO_WARNINGS=1

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox" \
    "$repo/bin"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

# T1: a lost --handling-delivered handshake must not re-announce forever.
# The real Pi extension drives the real arm/watcher, with only the handshake
# RPC forced to fail. After the first recovery follow-up, wait past the old
# ~52s loop period so a regression would emit a second follow-up.
test_unacknowledged_recovery_is_announced_once_per_generation() {
  local repo home plugin fakebin out status lock_pid messages
  repo="$TMP_ROOT/t1-root"
  home="$TMP_ROOT/t1-home"
  fakebin="$TMP_ROOT/t1-fakebin"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$fakebin"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$repo/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --handling-delivered ]; then
  exit 1
fi
export FM_ROOT_OVERRIDE="$ROOT"
export PATH="$fakebin:\$PATH"
exec "$ROOT/bin/fm-watch-arm.sh" "\$@"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  : > "$home/state/seed.meta"
  printf 'pending:downtime:seed.1.aaa\n' > "$home/state/.watcher-down"
  chmod 600 "$home/state/.watcher-down"
  printf '%s\t1\tcheck\tseed\tcheck: seed recovery\n' "$(date +%s)" > "$home/state/.wake-queue"
  out=$(
    PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
      FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" \
      FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(String(message));
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");
await tool.execute("tool-call-t1", {}, undefined, undefined, {});
const deadline = Date.now() + 75000;
let firstAt = 0;
while (Date.now() < deadline) {
  const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
  if (rearm.length > 1) {
    throw new Error(`unbounded recovery loop: ${rearm.length} rearm-resurface follow-ups`);
  }
  if (rearm.length === 1 && firstAt === 0) firstAt = Date.now();
  if (firstAt && Date.now() - firstAt >= 55000) break;
  await new Promise((resolve) => setTimeout(resolve, 200));
}
const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
if (rearm.length !== 1) {
  throw new Error(`expected exactly one recovery follow-up, got ${rearm.length}: ${prompts.join(" || ")}`);
}
const lockPid = existsSync(`${process.env.FM_HOME}/state/.watch.lock/pid`)
  ? readFileSync(`${process.env.FM_HOME}/state/.watch.lock/pid`, "utf8").trim()
  : "";
if (!/^[0-9]+$/.test(lockPid)) throw new Error("successor watcher lock pid missing");
try {
  process.kill(Number(lockPid), 0);
} catch {
  throw new Error(`successor watcher ${lockPid} is not alive`);
}
const marker = readFileSync(`${process.env.FM_HOME}/state/.watcher-down`, "utf8").trim();
if (!marker.startsWith("announced:") && !marker.startsWith("pending:")) {
  throw new Error(`successor did not keep a live recovery episode: ${marker}`);
}
console.log(`T1_MESSAGES=${rearm.length}`);
console.log(`T1_LOCK_PID=${lockPid}`);
console.log(`T1_MARKER=${marker}`);
process.exit(0);
EOF
  )
  status=$?
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '%s\n' "$out"
  fi
  lock_pid=$(sed -n 's/^T1_LOCK_PID=//p' <<<"$out" | tail -1)
  messages=$(sed -n 's/^T1_MESSAGES=//p' <<<"$out" | tail -1)
  if [ -n "$lock_pid" ]; then
    kill -TERM "$lock_pid" 2>/dev/null || true
  fi
  expect_code 0 "$status" "an unacknowledged recovery must be announced at most once per generation: $out"
  [ "$messages" = 1 ] || fail "T1 did not report a single recovery follow-up: $out"
  pass "unacknowledged recovery is announced at most once per generation and the successor stays alive"
}

# T2: a handling successor must enter its poll loop and surface a real crew
# event within a bounded startup-and-poll budget instead of sitting in a
# pre-loop wait that refreshes the liveness beacon and then exits with a
# synthetic rearm-resurface.
test_handling_successor_does_not_go_blind() {
  local dir home state fakebin child event_start now out
  dir=$(make_case recovery-gap-successor)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  : > "$state/crew.meta"
  printf 'pending:downtime:gap.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not take the watcher lock"; }
  sleep 0.4
  printf 'done: crew finished its task\n' >> "$state/crew.status"
  event_start=$(date +%s)
  now=0
  while [ "$now" -lt 20 ]; do
    if grep -q '^signal:' "$out" 2>/dev/null; then
      break
    fi
    sleep 0.5
    now=$((now + 1))
  done
  if ! grep -q '^signal:' "$out" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor did not surface the crew event within the bounded startup-and-poll budget (waited $(( $(date +%s) - event_start ))s): $(cat "$out")"
  fi
  grep -F 'crew.status' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not name the crew status file: $(cat "$out")"; }
  grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not enqueue a durable row for the crew event"; }
  ! grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor emitted synthetic recovery instead of supervising: $(cat "$out")"; }
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'T2_WATCH_OUTPUT=%s\n' "$(tr '\n' ' ' < "$out")"
    printf 'T2_QUEUE_ROW=%s\n' "$(grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" | tail -1)"
  fi
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  pass "a resurfacing handling successor stays alive and supervises instead of going blind"
}

# A recovery episode exists so a wake buried by watcher downtime is presented
# once more. A cycle that delivered no wake and left no queued row buried
# nothing, so minting a generation for it makes the NEXT arm announce
# "check: rearm-resurface" over an empty queue - a recovery turn with nothing to
# recover. Every silent watcher death cost one of those.
#
# The readiness wait below checks pid-identity, not just pid: fm_lock_claim
# writes the lock's pid file the moment the lock is claimed, well before
# bin/fm-watch.sh installs `trap watcher_cleanup EXIT` (it still has recovery-
# marker reopen/arm-check and side-band publication to do first). pid-identity
# is written right after that trap is installed. Waiting on pid alone races
# that gap: a TERM landing in it hits no trap at all, so watcher_cleanup never
# runs and .watcher-down is left exactly as this fixture seeded it - which
# looks identical to "closed with nothing to recover" and made this fixture
# flaky under load. Waiting for pid-identity ensures the TERM below always
# lands after the trap is live, matching the mid-poll death this simulates.
watcher_close_marker_after() {  # <state> <marker-token> [queue-row]
  local state=$1 token=$2 row=${3:-} pid i
  printf '%s\n' "$token" > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  if [ -n "$row" ]; then
    printf '%s\n' "$row" > "$state/.wake-queue"
    printf '1\n' > "$state/.wake-queue.seq"
  fi
  FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$state/../watch.out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] \
      && [ -s "$state/.watch.lock/pid-identity" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] \
    && [ -s "$state/.watch.lock/pid-identity" ] || {
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  }
  sleep 0.5
  # Stop it without a delivery: the shape of a silent mid-poll death.
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# What the NEXT non-successor arm would do, through the real startup sequence
# (reopen an announced-but-unacked episode, then arm-check).
next_arm_action() {  # <state>
  local state=$1
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_recovery_marker_reopen_announced "$2" >/dev/null 2>&1
    fm_recovery_marker_arm_check "$2" >/dev/null 2>&1
    printf "%s\n" "$FM_RECOVERY_MARKER_ACTION"
  ' _ "$ROOT" "$state/.watcher-down"
}

test_quiet_watcher_close_mints_no_recovery_generation() {
  local dir state marker action
  dir=$(make_case quiet-close-no-generation)
  state="$dir/state"
  : > "$state/crew.meta"
  watcher_close_marker_after "$state" 'acked:downtime:already.acked.gen' \
    || fail "the watcher did not take its lock in the quiet-close fixture"
  marker=$(cat "$state/.watcher-down" 2>/dev/null || echo ABSENT)
  case "$marker" in
    acked:downtime:already.acked.gen) ;;
    *) fail "a close that delivered nothing and queued nothing republished the recovery marker as '$marker'" ;;
  esac
  action=$(next_arm_action "$state")
  [ "$action" = none ] \
    || fail "the next arm would announce recovery ('$action') after a close with nothing to recover"
  pass "a watcher close that delivered nothing and queued nothing mints no recovery generation"
}

# The other half, which must NOT change: a close leaving an undrained row is
# exactly the gap recovery exists for, so that arm must still be told.
test_close_with_queued_rows_still_recovers() {
  local dir state action
  dir=$(make_case quiet-close-with-rows)
  state="$dir/state"
  : > "$state/crew.meta"
  watcher_close_marker_after "$state" 'acked:downtime:already.acked.gen' \
    "$(date +%s)$(printf '\t')1$(printf '\t')signal$(printf '\t')crew.status$(printf '\t')signal: crew.status" \
    || fail "the watcher did not take its lock in the queued-row fixture"
  case "$(cat "$state/.watcher-down" 2>/dev/null || echo ABSENT)" in
    pending:*|announced:*) ;;
    *) fail "a close leaving an undrained row did not open a recovery episode" ;;
  esac
  action=$(next_arm_action "$state")
  [ "$action" = recover ] \
    || fail "an undrained queued row lost its recovery announcement (action '$action')"
  pass "a watcher close that leaves rows queued still opens the recovery episode"
}

# The third thing a drain presents, and the one an empty-queue test alone would
# miss: a captain call that is still open. Such a down interval legitimately has
# no queue rows at all, so "queue is empty" must never be read as "nothing to
# recover" - otherwise an unanswered decision silently stops being re-presented.
test_close_with_an_open_decision_still_recovers() {
  local dir state action
  dir=$(make_case quiet-close-open-decision)
  state="$dir/state"
  : > "$state/ios.meta"
  # An opened, unresolved captain call. Nothing else is pending: no delivery,
  # and the durable queue stays empty for the whole fixture. Priming the seen
  # marker declares the decision already surfaced (see the same idiom in
  # tests/fm-watch-arm.test.sh), so a cold watcher does not treat it as a new
  # signal and queue it - which would defeat this fixture's isolation.
  printf 'needs-decision [key=remote-signoff]: remote secondmate is held for captain sign-off\n' \
    > "$state/ios.status"
  prime_status_seen "$state" "$state/ios.status" \
    || fail "could not prime the open-decision fixture as already surfaced"
  watcher_close_marker_after "$state" 'acked:downtime:already.acked.gen' \
    || fail "the watcher did not take its lock in the open-decision fixture"
  [ ! -s "$state/.wake-queue" ] \
    || fail "the open-decision fixture queued a row and no longer isolates the decision path"
  case "$(cat "$state/.watcher-down" 2>/dev/null || echo ABSENT)" in
    pending:*|announced:*) ;;
    *) fail "a close with an open captain call did not open a recovery episode" ;;
  esac
  action=$(next_arm_action "$state")
  [ "$action" = recover ] \
    || fail "an open captain call lost its recovery announcement (action '$action')"
  pass "a watcher close with an open captain call still opens the recovery episode"
}

test_handling_successor_does_not_go_blind
test_unacknowledged_recovery_is_announced_once_per_generation
test_quiet_watcher_close_mints_no_recovery_generation
test_close_with_queued_rows_still_recovers
test_close_with_an_open_decision_still_recovers
