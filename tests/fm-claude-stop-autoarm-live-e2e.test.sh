#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the Stop-owned auto-arm
# (bin/fm-claude-stop-autoarm.sh + bin/fm-turnend-guard.sh --claude).
# Proves, against the real installed Claude Code and the real tracked hook
# registration: a fresh session with in-flight work, no watcher, and a stale
# session lock can run fm-session-start.sh first; session start reclaims the
# dead owner; at least two tokenless auto-arm and rewake cycles then complete
# with zero model-issued arm commands; and the cooperative guard consumes no
# forced continuation while the hook's launch is healthy.
# It also owns the two facts that decide whether that cooperation can work at
# all, both of which come from the vendor and so cannot be settled by a stub:
#   1. Claude runs BOTH registered Stop hooks on the same Stop, including a Stop
#      the blocking one refuses with exit 2. If a refusal pre-empted the
#      asyncRewake sibling the pair would deadlock, because the auto-arm could
#      never record the exhausted failure the guard's fail-open requires.
#   2. From the auto-arm's own silent stand-down - a home whose session lock
#      belongs to another live session - the guard still reaches its bounded
#      loud fail-open instead of blocking every turn forever.
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication. No live fleet home, worktree, or session is touched.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

if [ "${FM_CLAUDE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_LIVE_E2E=1 to run the Claude Stop auto-arm regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v claude >/dev/null 2>&1 || fail "claude not found"
command -v tmux >/dev/null 2>&1 \
  || fail "tmux not found: the interactive half of the Stop-hook concurrency check drives a real Claude TUI"
command -v jq >/dev/null 2>&1 || fail "jq not found"

CONCURRENCY_MODES_CHECKED=0
SOCKET="fm-autoarm-live-$$"
CONC_ROOT="${TMPDIR:-/tmp}/fm-autoarm-live-conc.$$"

LAB="$ROOT/.claude-autoarm-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
LIVE_OWNER_HOME="$LAB/live-owner-home"
TRANSCRIPT="$LAB/claude.jsonl"
CLAUDE_VERSION=$(claude --version)

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET" 2>/dev/null || true
  rm -rf "$LAB" "$CONC_ROOT"
}
trap cleanup EXIT

# Bounded wait on hook output rather than a fixed sleep, so a slow machine does
# not read as a missing hook while a genuinely missing one still fails loudly.
wait_for_log() {  # <log> <line> <seconds>
  local log=$1 want=$2 secs=$3 waited=0
  while [ "$waited" -lt "$secs" ]; do
    grep -Fqx "$want" "$log" 2>/dev/null && return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

mkdir -p "$LAB" "$CONC_ROOT"
# git clone of this worktree carries only committed state, so copy the
# working-tree surfaces under test (same pattern as the continuity live E2E).
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"
# The lab keeps the real tracked .claude/settings.json SessionStart nudge,
# Stop guard, and asyncRewake auto-arm registration.
# The only local hook records model-issued Bash calls without acquiring the
# session lock or otherwise changing lifecycle behavior.
cat > "$PROJECT/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/tool-logger.sh" }
        ]
      }
    ]
  }
}
JSON

cat > "$PROJECT/bin/tool-logger.sh" <<'SH'
#!/usr/bin/env bash
P=$(cat 2>/dev/null || true)
printf '%s\n' "$P" | jq -r '.tool_input.command // "unknown"' >> "$FM_HOME/state/tool-calls.log" 2>/dev/null
exit 0
SH
chmod +x "$PROJECT/bin/tool-logger.sh"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$HOME_DIR/state/task.meta"
# A numeric pid above the supported OS pid range is a demonstrably dead prior
# harness owner under fm_harness_pid_alive, matching the reproduced incident.
printf '9999999\n' > "$HOME_DIR/state/.lock"

# Rapid-death arm fixture: started plus an immediate actionable reason, the
# exact spent-Stop edge shape. Runs 1-2 close actionable; run 3 closes clean so
# a misbehaving session can never loop forever.
cat > "$PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/arm-count"
echo "arm-run=$N pid=$$" >> "$FM_HOME/state/arm-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
  printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-rapid-%s\n' "$N"
exit 0
SH
# Drain fixture: session start invokes it once, then the model invokes it once
# per rewake. The third total drain ends the in-flight need after two complete
# Stop-owned cycles.
cat > "$PROJECT/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/drain-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/drain-count"
echo "drain-run=$N" >> "$FM_HOME/state/drain-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
fi
printf 'stale: fixture-rapid drained\n'
SH
chmod +x "$PROJECT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-wake-drain.sh"

# --- deterministic mechanism checks run FIRST ---------------------------------
#
# Everything below this point up to the credentialed section depends only on
# real processes and the real scripts, so it always reports. The credentialed
# model-driven cycle runs last because its assertions depend on how the model
# chooses to spend its turns, and a flaky turn there must not hide these.

# Live-owner negative control: a separate supported-harness process owns a
# second isolated home while another Stop hook fires from the same primary
# project. The competing hook must not replace the session lock, arm, write an
# epoch, or rewake.
FAKE_CLAUDE="$LAB/claude"
ln -s /bin/bash "$FAKE_CLAUDE"
mkdir -p "$LIVE_OWNER_HOME/state" "$LIVE_OWNER_HOME/config"
printf 'project=fixture\n' > "$LIVE_OWNER_HOME/state/task.meta"
"$FAKE_CLAUDE" -c 'sleep 3; :' &
LIVE_OWNER_PID=$!
printf '%s\n' "$LIVE_OWNER_PID" > "$LIVE_OWNER_HOME/state/.lock"
LIVE_OWNER_RC=0
printf '%s\n' '{"session_id":"live-owner-control"}' \
  | FM_HOME="$LIVE_OWNER_HOME" FM_ROOT_OVERRIDE="$PROJECT" "$FAKE_CLAUDE" -c '"$FM_ROOT_OVERRIDE/bin/fm-claude-stop-autoarm.sh"' \
      >"$LAB/live-owner.out" 2>"$LAB/live-owner.err" || LIVE_OWNER_RC=$?
[ "$LIVE_OWNER_RC" -eq 0 ] || fail "competing Stop hook returned $LIVE_OWNER_RC while another live session owned the home"
[ "$(cat "$LIVE_OWNER_HOME/state/.lock")" = "$LIVE_OWNER_PID" ] || fail "competing Stop hook replaced the live session owner"
[ ! -e "$LIVE_OWNER_HOME/state/arm-ran" ] || fail "competing Stop hook armed while another live session owned the home"
[ ! -e "$LIVE_OWNER_HOME/state/.claude-autoarm-epoch" ] || fail "competing Stop hook wrote an epoch while another live session owned the home"
[ ! -s "$LAB/live-owner.out" ] && [ ! -s "$LAB/live-owner.err" ] || fail "competing Stop hook produced a rewake while another live session owned the home"
wait "$LIVE_OWNER_PID"

# --- the stood-down home still reaches a loud fail-open -----------------------
#
# The control above proves the auto-arm records NOTHING here, which is correct.
# The cooperative guard must still resolve that state: three bounded blocks, then
# one loud attended fail-open naming non-participation and the reason this
# session cannot recover supervision - never an indefinite block and never a
# manual arm instruction.
"$FAKE_CLAUDE" -c 'sleep 90; :' &
STUCK_OWNER_PID=$!
printf '%s\n' "$STUCK_OWNER_PID" > "$LIVE_OWNER_HOME/state/.lock"
rm -f "$LIVE_OWNER_HOME/state/.turnend-claude-blocks" \
  "$LIVE_OWNER_HOME/state/.claude-autoarm-absent" \
  "$LIVE_OWNER_HOME/state/.claude-autoarm-failure-alarmed"
printf 'project=fixture\n' > "$LIVE_OWNER_HOME/state/task.meta"

run_stood_down_stop() {
  printf '%s\n' '{"session_id":"stood-down","stop_hook_active":true}' \
    | FM_HOME="$LIVE_OWNER_HOME" FM_ROOT_OVERRIDE="$PROJECT" \
      FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=200 "$FAKE_CLAUDE" -c \
        '"$FM_ROOT_OVERRIDE/bin/fm-turnend-guard.sh" --claude' 2>&1
}

for i in 1 2 3; do
  # Both hooks fire on every real Stop, so drive both here too.
  printf '%s\n' '{"session_id":"stood-down","stop_hook_active":true}' \
    | FM_HOME="$LIVE_OWNER_HOME" FM_ROOT_OVERRIDE="$PROJECT" "$FAKE_CLAUDE" -c \
        '"$FM_ROOT_OVERRIDE/bin/fm-claude-stop-autoarm.sh"' >/dev/null 2>&1 || true
  STUCK_OUT=$(run_stood_down_stop) && STUCK_RC=0 || STUCK_RC=$?
  [ "$STUCK_RC" -eq 2 ] \
    || fail "stop $i on a stood-down home returned $STUCK_RC, expected a bounded block: $STUCK_OUT"
done
STUCK_OUT=$(run_stood_down_stop) && STUCK_RC=0 || STUCK_RC=$?
kill "$STUCK_OWNER_PID" 2>/dev/null || true
wait "$STUCK_OWNER_PID" 2>/dev/null || true
[ "$STUCK_RC" -eq 0 ] \
  || fail "a home the auto-arm permanently stands down from never reached the bounded fail-open (rc=$STUCK_RC): $STUCK_OUT"
case "$STUCK_OUT" in
  *'FIRSTMATE SUPERVISION IS GENUINELY DOWN'*) : ;;
  *) fail "the stood-down fail-open was not loud: $STUCK_OUT" ;;
esac
case "$STUCK_OUT" in
  *'never participated'*) : ;;
  *) fail "the stood-down fail-open did not name non-participation: $STUCK_OUT" ;;
esac
case "$STUCK_OUT" in
  *'does NOT own the home lock'*) : ;;
  *) fail "the stood-down fail-open did not name why this session cannot recover supervision: $STUCK_OUT" ;;
esac
case "$STUCK_OUT" in
  *fm-watch-arm.sh*) fail "the stood-down fail-open directed a manual watcher arm: $STUCK_OUT" ;;
esac
[ -e "$LIVE_OWNER_HOME/state/.claude-autoarm-absent" ] \
  || fail "the stood-down fail-open recorded no non-participation episode"
printf 'ok - Claude %s live E2E: a home the auto-arm permanently stands down from blocks exactly three times and then fails open loudly, naming non-participation\n' "$CLAUDE_VERSION"

# --- vendor fact: a refused Stop still runs its asyncRewake sibling -----------
#
# The whole cooperative contract assumes both registered Stop hooks run on the
# same Stop, including one the blocking hook refuses. That is Claude's own
# scheduling, so it is measured against the installed binary rather than assumed.
# Both modes run: headless is cheap and covers the scheduling, while interactive
# is the mode firstmate primaries actually run and the only one where the real
# refuse-and-continue loop exists.
make_concurrency_lab() {  # <name> <blocks> -> echoes lab dir
  local name=$1 blocks=$2
  # Outside the repo on purpose. A lab nested inside this checkout inherits the
  # parent CLAUDE.md, and Claude then opens an external-import consent dialog
  # before the first turn - a second prompt that silently swallows the probe
  # keystrokes and would look identical to a Stop hook that stopped firing.
  local dir="$CONC_ROOT/$name"
  mkdir -p "$dir/bin" "$dir/.claude"
  git init -q -b main "$dir"
  git -C "$dir" -c user.email=fmtest@example.invalid -c user.name=fmtest \
    commit -q --allow-empty -m init
  printf '# Stop-hook concurrency lab\n' > "$dir/AGENTS.md"
  cat > "$dir/bin/sync-hook.sh" <<SH
#!/usr/bin/env bash
set -u
cat >/dev/null 2>&1 || true
n=\$(grep -c '^sync ' "\$FM_STOPCONC_LOG" 2>/dev/null | tr -d ' ')
printf 'sync %s\n' "\$n" >> "\$FM_STOPCONC_LOG"
if [ "\$n" -lt $blocks ]; then
  printf 'stop-concurrency probe: refusing this stop (%s)\n' "\$n" >&2
  exit 2
fi
exit 0
SH
  cat > "$dir/bin/async-hook.sh" <<'SH'
#!/usr/bin/env bash
set -u
cat >/dev/null 2>&1 || true
n=$(grep -c '^async-start ' "$FM_STOPCONC_LOG" 2>/dev/null | tr -d ' ')
printf 'async-start %s\n' "$n" >> "$FM_STOPCONC_LOG"
# The real auto-arm foregrounds a long-running arm, so a body that returned
# instantly would not show whether a refused stop lets the sibling finish.
sleep 2
printf 'async-done %s\n' "$n" >> "$FM_STOPCONC_LOG"
exit 0
SH
  chmod +x "$dir/bin/sync-hook.sh" "$dir/bin/async-hook.sh"
  cat > "$dir/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/sync-hook.sh" },
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/async-hook.sh", "asyncRewake": true, "timeout": 600 }
        ]
      }
    ]
  }
}
JSON
  : > "$dir/hooks.log"
  printf '%s\n' "$dir"
}

# Counts, not ordering: the two hooks race by design and only their presence and
# completion on a refused stop are contractual.
assert_hooks_paired() {  # <log> <mode> <min-stops>
  local log=$1 mode=$2 min=$3 sync_n start_n done_n
  sync_n=$(grep -c '^sync ' "$log" 2>/dev/null | tr -d ' ')
  start_n=$(grep -c '^async-start ' "$log" 2>/dev/null | tr -d ' ')
  done_n=$(grep -c '^async-done ' "$log" 2>/dev/null | tr -d ' ')
  [ "${sync_n:-0}" -ge "$min" ] \
    || fail "Claude $CLAUDE_VERSION ($mode): only $sync_n stop(s) reached the blocking hook, so the refusal path was never exercised and nothing was measured"
  [ "$start_n" = "$sync_n" ] \
    || fail "Claude $CLAUDE_VERSION ($mode): a refused Stop pre-empted its asyncRewake sibling ($sync_n blocking fires, $start_n async fires); the Stop-owned auto-arm can no longer record a failure on a blocked stop, so the cooperative contract in docs/turnend-guard.md no longer holds"
  [ "$done_n" = "$sync_n" ] \
    || fail "Claude $CLAUDE_VERSION ($mode): $start_n async hook(s) started but only $done_n finished, so a refused stop kills the auto-arm mid-run"
  CONCURRENCY_MODES_CHECKED=$((CONCURRENCY_MODES_CHECKED + 1))
  printf 'ok - Claude %s (%s): all %s refused stop(s) also ran the asyncRewake hook to completion\n' \
    "$CLAUDE_VERSION" "$mode" "$sync_n"
}

CONC_HEADLESS=$(make_concurrency_lab conc-headless 2)
(
  cd "$CONC_HEADLESS" || exit 1
  FM_STOPCONC_LOG="$CONC_HEADLESS/hooks.log" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    claude -p 'Reply with only: OK' --dangerously-skip-permissions --effort low
) >/dev/null 2>&1 || true
wait_for_log "$CONC_HEADLESS/hooks.log" 'async-done 2' 30 || true
assert_hooks_paired "$CONC_HEADLESS/hooks.log" 'headless claude -p' 3

CONC_TUI=$(make_concurrency_lab conc-tui 5)
tmux -L "$SOCKET" new-session -d -s conc -x 200 -y 50 -c "$CONC_TUI" \
  "FM_STOPCONC_LOG='$CONC_TUI/hooks.log' claude --dangerously-skip-permissions"
conc_pane() { tmux -L "$SOCKET" capture-pane -p -t conc -S -60 2>/dev/null || true; }

# Accept the folder-trust prompt, then wait for a composer that is actually
# ready. A fixed sleep races TUI startup and the keystrokes are silently
# dropped, which would look identical to a hook that stopped firing.
TRUST_WAIT=0
while [ "$TRUST_WAIT" -lt 60 ]; do
  case "$(conc_pane)" in
    *'I trust this folder'*)
      tmux -L "$SOCKET" send-keys -t conc Down
      sleep 1
      tmux -L "$SOCKET" send-keys -t conc Enter
      ;;
    *'bypass permissions on'*) break ;;
  esac
  sleep 1
  TRUST_WAIT=$((TRUST_WAIT + 1))
done
case "$(conc_pane)" in
  *'bypass permissions on'*) : ;;
  *) fail "Claude $CLAUDE_VERSION (interactive TUI): the session never reached a ready composer, so nothing was measured" ;;
esac
# A dialog still on screen would swallow the probe keystrokes and read exactly
# like a Stop hook that stopped firing, so name it instead of typing into it.
case "$(conc_pane)" in
  *'Enter to confirm'*)
    fail "Claude $CLAUDE_VERSION (interactive TUI): an unexpected consent dialog is holding the session before the first turn, so nothing was measured: $(conc_pane | grep -v '^$' | tail -8)"
    ;;
esac

# Type, then CONFIRM the text reached the composer before submitting, retrying
# a bounded number of times. Only then is an empty hook log real evidence.
CONC_PROMPT='Reply with only: OK'
TYPE_TRY=0
while [ "$TYPE_TRY" -lt 5 ]; do
  tmux -L "$SOCKET" send-keys -t conc -l "$CONC_PROMPT"
  sleep 2
  case "$(conc_pane)" in
    *"$CONC_PROMPT"*) break ;;
  esac
  TYPE_TRY=$((TYPE_TRY + 1))
  sleep 3
done
case "$(conc_pane)" in
  *"$CONC_PROMPT"*) : ;;
  *) fail "Claude $CLAUDE_VERSION (interactive TUI): the probe prompt never reached the composer, so nothing was measured" ;;
esac
tmux -L "$SOCKET" send-keys -t conc Enter

wait_for_log "$CONC_TUI/hooks.log" 'sync 0' 120 \
  || fail "Claude $CLAUDE_VERSION (interactive TUI): the submitted turn never produced a first Stop, so the registration did not fire and nothing was measured"
wait_for_log "$CONC_TUI/hooks.log" 'sync 5' 240 \
  || fail "Claude $CLAUDE_VERSION (interactive TUI): the blocking Stop hook never reached its sixth stop, so the refuse-and-continue loop did not run and nothing was measured"
wait_for_log "$CONC_TUI/hooks.log" 'async-done 5' 60 || true
assert_hooks_paired "$CONC_TUI/hooks.log" 'interactive TUI' 6

[ "$CONCURRENCY_MODES_CHECKED" -eq 2 ] \
  || fail "only $CONCURRENCY_MODES_CHECKED of 2 Stop-hook concurrency modes were measured; this guard must not pass without both"


# --- credentialed model-driven cycle (runs last) ------------------------------

PROMPT='Run exactly `bin/fm-session-start.sh` with Bash as your first tool call. After reading its complete digest, reply with exactly CYCLE0 and stop. Whenever a Stop hook feedback message wakes you, run exactly `bin/fm-wake-drain.sh` once with Bash, then reply with exactly ACK and stop. Never run bin/fm-watch-arm.sh or any other arm command, and never use any other tool.'

(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    claude -p "$PROMPT" --dangerously-skip-permissions --effort low --output-format stream-json --verbose
) > "$TRANSCRIPT" 2>&1 || fail "Claude credentialed auto-arm session failed: $(tail -20 "$TRANSCRIPT")"

ARM_RUNS=$(wc -l < "$HOME_DIR/state/arm-ran" 2>/dev/null | tr -d ' ')
[ "$ARM_RUNS" = 2 ] || fail "expected exactly 2 hook-owned arm cycles, got $ARM_RUNS: $(cat "$HOME_DIR/state/arm-ran" 2>/dev/null)"
DRAIN_RUNS=$(wc -l < "$HOME_DIR/state/drain-ran" 2>/dev/null | tr -d ' ')
[ "$DRAIN_RUNS" = 3 ] || fail "expected one session-start drain plus two model wake drains, got $DRAIN_RUNS drains"
REWAKES=$(grep -c 'Stop hook feedback' "$TRANSCRIPT" 2>/dev/null || true)
[ "$REWAKES" -ge 2 ] || fail "expected at least 2 exit-2 rewake deliveries, got $REWAKES"
grep -q 'stale: fixture-rapid-1' "$TRANSCRIPT" || fail "first rapid rewake reason missing from the transcript"
grep -q 'stale: fixture-rapid-2' "$TRANSCRIPT" || fail "second rapid rewake reason missing from the transcript"
[ "$(sed -n '1p' "$HOME_DIR/state/tool-calls.log" 2>/dev/null)" = 'bin/fm-session-start.sh' ] \
  || fail "fresh Claude session did not run session start first: $(cat "$HOME_DIR/state/tool-calls.log" 2>/dev/null)"
[ "$(cat "$HOME_DIR/state/.lock" 2>/dev/null)" != 9999999 ] \
  || fail "session start did not reclaim the stale dead-owner lock"
if [ -f "$HOME_DIR/state/tool-calls.log" ]; then
  ! grep -q 'fm-watch-arm.sh' "$HOME_DIR/state/tool-calls.log" \
    || fail "model issued an arm command despite Stop-owned continuity: $(cat "$HOME_DIR/state/tool-calls.log")"
  ! grep -q '&' "$HOME_DIR/state/tool-calls.log" \
    || fail "model used a shell ampersand: $(cat "$HOME_DIR/state/tool-calls.log")"
fi
! grep -q 'TURN WOULD END BLIND' "$TRANSCRIPT" \
  || fail "cooperative guard consumed a forced continuation while the auto-arm launch was healthy"
[ "$(sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$HOME_DIR/state/.claude-autoarm-epoch" 2>/dev/null)" = rewake ] \
  || fail "auto-arm epoch ledger must record the rewake outcome"
[ ! -e "$HOME_DIR/state/.claude-autoarm.lock" ] || fail "auto-arm owner lock was left behind"

printf 'ok - Claude %s live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, and preserved the competing-live-owner boundary\n' "$CLAUDE_VERSION"
