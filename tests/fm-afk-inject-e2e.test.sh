#!/usr/bin/env bash
# tests/fm-afk-inject-e2e.test.sh - private-socket end-to-end test for the afk
# daemon's injection path. It covers three operator-visible injection contracts:
#
#   Scenario A (human-partial-input): a partial line is typed into the
#     supervisor pane with NO Enter, then an escalation fires. The daemon must
#     DEFER (not merge the digest into the human's text). After the pane goes
#     idle, the digest arrives as a separate, clean submission.
#
#   Scenario B (swallowed-Enter): the first Enter the daemon sends is dropped.
#     The daemon must retry Enter (NOT retype the digest) and deliver exactly
#     ONE clean submission: no concatenation, no duplicate.
#
#   Scenario C (normal digest): no human input and no swallowed Enter.
#     A captain-relevant status must deliver exactly ONE sentinel-prefixed,
#     single-line digest with no duplicate or spurious user submission.
#
#   Scenario D (front-cut delivery): the delivery arrives with its head missing,
#     so the leading marker is gone. It must STILL classify as an injection, or
#     away mode ends on a delivery defect and the escalation is dropped. Real
#     captain prose in the same pane must still classify as a captain message.
#
#   Scenario E (oversized escalation): a digest past the single-send delivery
#     bound must arrive cut by us - marked at both ends, carrying the shared
#     truncation marker and a pointer to its durable full text - or be refused
#     with the buffer preserved. Never an unmarked fragment.
#
# Isolation: all test tmux runs on a dedicated socket (tmux -L afk-e2e-<pid>).
# A tmux shim first on PATH redirects the daemon's bare `tmux` calls to the
# private socket. The daemon points at a throwaway state dir (FM_STATE_OVERRIDE)
# and the test pane (FM_SUPERVISOR_TARGET). Nothing touches the live fleet.
# FM_SUPERVISOR_BACKEND=tmux is passed explicitly (not left to auto-detection):
# this test's own process may itself be running inside herdr (HERDR_ENV=1 is
# inherited by every process herdr manages a pane for), which would otherwise
# leak into the spawned daemon subprocess and misdetect backend=herdr against
# what is actually a tmux pane on the private socket.
#
# Assert on submitted CONTENT (logged verbatim by the supervisor pane), not pane
# appearance - terminal line-wrapping looks like newlines but isn't.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

# Skip gracefully if tmux is not installed.
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="afk-e2e-$$"
STATE_DIR=
TMUX_SHIM_DIR=
LOG_FILE=
DAEMON_PID=
SUPERVISOR_PANE=
LOOP_SCRIPT=

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup_all() {
  if [ -n "${DAEMON_PID:-}" ]; then
    afk_exit "${STATE_DIR:-}" 2>/dev/null || true
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if [ -n "${SOCKET:-}" ] && [ -n "${REAL_TMUX:-}" ]; then
    "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  fi
  rm -rf "${TMUX_SHIM_DIR:-}" 2>/dev/null || true
  rm -rf "${STATE_DIR:-}" 2>/dev/null || true
}
trap cleanup_all EXIT

# --- setup ------------------------------------------------------------------

STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-e2e.XXXXXX")
mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/submitted.log"
: > "$LOG_FILE"

# Source the daemon to get FM_INJECT_MARK, afk_enter, afk_exit.
# shellcheck source=/dev/null
. "$DAEMON"

# Private tmux server with a supervisor session.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s supervisor -x 200 -y 50
SUPERVISOR_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t supervisor '#{pane_id}')

# Supervisor pane loop: a small deterministic composer that logs each submitted
# line verbatim (hex + text + classification). It draws the in-progress input
# itself instead of relying on the terminal driver's canonical-mode echo, because
# tmux cursor placement for that echo varies across CI environments.
# The loop runs under an AGENT-NAMED interpreter, not a bare `bash`. Away-mode
# injection now requires positive, non-rendered proof that a live verified
# harness owns the supervisor pane before it types anything into it
# (bin/fm-supervise-daemon.sh's POSITIVE TARGET IDENTIFICATION), and that proof
# is the pane's foreground process identity. A bare `bash` loop is exactly the
# dead-shell pane the daemon must refuse, so the fixture must carry a real
# process the kernel names as a harness. A SYMLINK, never a copy: a copied
# platform binary fails code-signing validation and is killed on macOS arm64;
# the symlink name is what the kernel records. The refusal side of this contract
# is owned by tests/fm-afk-shell-pane-refusal.test.sh.
AGENT_SHIM="$STATE_DIR/claude-shim"
ln -s "$(command -v bash)" "$AGENT_SHIM"

LOOP_SCRIPT="$STATE_DIR/supervisor-loop.sh"
cat > "$LOOP_SCRIPT" <<'LOOP'
#!/usr/bin/env bash
LOG="$1"
# Classify each submitted line through the SHIPPING predicate, not a local copy
# of it. The away-exit contract is exactly this question - is what landed in the
# pane machine-generated operational input, or the captain talking - so the
# fixture must ask the owner rather than re-implement a leading-marker test that
# a front-cut delivery would answer wrongly in the test and rightly in
# production, or the other way round.
# shellcheck source=/dev/null
. "$2"
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() {
  [ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

_buf=
# The drawn composer row carries a real agent prompt glyph, matching the
# production supervisor pane this daemon injects into: under the strict
# container-proof rule (captain decision blank-row-injection-posture) a bare
# unidentified row is never a safe injection target, so the fixture must
# render the shape the classifier positively proves - "❯ " when idle,
# "❯ <buffer>" while input is pending. The glyph is rendering only; it never
# enters the buffer, so submitted-content assertions are unchanged.
redraw() {
  printf '\r\033[K\xe2\x9d\xaf %s' "$_buf"
}
submit_line() {
  local _line=$_buf _c _hex _kind
  if fm_operational_input_kind "$_line" _kind; then
    _c="injection"
  else
    _c="user"
  fi
  _hex=$(printf '%s' "$_line" | od -An -tx1 | tr -d ' \n')
  printf '%s\t%s\t%s\n' "$_hex" "$_line" "$_c" >> "$LOG"
  _buf=
  printf '\r\033[K\n'
  redraw
}

redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then
    submit_line
    continue
  fi
  case "$_ch" in
    $'\r'|$'\n') submit_line ;;
    $'\177'|$'\b') _buf=${_buf%?}; redraw ;;
    *) _buf="${_buf}${_ch}"; redraw ;;
  esac
done
LOOP
chmod +x "$LOOP_SCRIPT"

# Start the loop in the supervisor pane.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" \
  "'$AGENT_SHIM' '$LOOP_SCRIPT' '$LOG_FILE' '$ROOT/bin/fm-operational-input.sh'" Enter
sleep 1  # let the loop start and settle

# tmux shim: redirects bare `tmux` to the private socket. Optionally swallows
# the first Enter (file-based flag) for Scenario B.
TMUX_SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-shim.XXXXXX")
cat > "$TMUX_SHIM_DIR/tmux" <<SHIM
#!/usr/bin/env bash
# FRONT-CUT mode (Scenario D): reproduce the measured delivery failure in which
# the receiving terminal keeps only the tail of a fast literal send and drops
# everything before it, taking the leading marker with it. The file's contents
# are how many trailing characters survive.
if [ "\${1:-}" = "send-keys" ] && [ "\${2:-}" = "-t" ] && [ "\${4:-}" = "-l" ] \\
   && [ -f "$STATE_DIR/.front-cut" ]; then
  _keep=\$(cat "$STATE_DIR/.front-cut")
  _text=\${5:-}
  exec "$REAL_TMUX" -L "$SOCKET" send-keys -t "\${3:-}" -l "\${_text: -\$_keep}"
fi
if [ "\${1:-}" = "send-keys" ] && [ -f "$STATE_DIR/.swallow-enter" ]; then
  shift
  _args=()
  for _arg in "\$@"; do
    if [ "\$_arg" = "Enter" ] && [ -f "$STATE_DIR/.swallow-enter" ]; then
      rm -f "$STATE_DIR/.swallow-enter"
      continue
    fi
    _args+=("\$_arg")
  done
  exec "$REAL_TMUX" -L "$SOCKET" send-keys "\${_args[@]}"
fi
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SHIM
chmod +x "$TMUX_SHIM_DIR/tmux"

# Create a fake crewmate window (the watcher lists fm-* windows for stale
# detection). The pane is an inert shell - it just needs to exist.
"$REAL_TMUX" -L "$SOCKET" new-window -d -n fm-fake-c1 -t supervisor

start_daemon() {
  PATH="$TMUX_SHIM_DIR:$PATH" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_SUPERVISOR_TARGET="$SUPERVISOR_PANE" \
  FM_SUPERVISOR_BACKEND=tmux \
  FM_ESCALATE_BATCH_SECS=0 \
  FM_HOUSEKEEPING_TICK=1 \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 \
  FM_INJECT_CONFIRM_SLEEP=0.3 \
  FM_INJECT_CONFIRM_RETRIES=5 \
  FM_STALE_ESCALATE_SECS=999999 \
  nohup "$DAEMON" >"$STATE_DIR/daemon.out" 2>"$STATE_DIR/daemon.err" &
  DAEMON_PID=$!
  # Wait for the daemon to start and acquire the lock.
  local i=0
  while [ "$i" -lt 30 ]; do
    [ -f "$STATE_DIR/.supervise-daemon.pid" ] && break
    sleep 0.2
    i=$((i + 1))
  done
  [ -f "$STATE_DIR/.supervise-daemon.pid" ] || {
    echo "daemon stderr:" >&2; cat "$STATE_DIR/daemon.err" >&2
    fail "daemon did not start (no pid file after 6s)"
  }
}

stop_daemon() {
  [ -n "${DAEMON_PID:-}" ] || return 0
  afk_exit "$STATE_DIR" 2>/dev/null || true
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
  sleep 1
}

reset_state() {
  # Clear daemon and watcher state for a fresh scenario.
  rm -f "$STATE_DIR"/*.status \
         "$STATE_DIR"/.subsuper-* \
         "$STATE_DIR"/.wake-queue* \
         "$STATE_DIR"/.watch.lock* \
         "$STATE_DIR"/.watcher-down* \
         "$STATE_DIR"/.last-* \
         "$STATE_DIR"/.hash-* \
         "$STATE_DIR"/.count-* \
         "$STATE_DIR"/.stale-* \
         "$STATE_DIR"/.seen-* \
         "$STATE_DIR"/.heartbeat-streak \
         "$STATE_DIR"/.swallow-enter \
         "$STATE_DIR"/.front-cut \
         2>/dev/null || true
  : > "$LOG_FILE"
}

# --- pane_input_pending environment self-check ------------------------------
# Verify that pane_input_pending (which uses cursor_y + capture-pane) can detect
# typed text in this tmux environment. If it can't, the e2e cannot prove the
# operator-visible injection contracts it owns.

selfcheck_pane_input_pending() {
  local check_text="selfcheck-marker-12345"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" -l "$check_text"
  if wait_for_pane_input_pending; then
    # Detected - clean up the text and proceed.
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" Enter
    sleep 0.3
    return 0
  fi
  # Not detected - print diagnostics and fail.
  echo "pane_input_pending cannot detect typed text in this tmux environment" >&2
  local _cy _line
  _cy=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SUPERVISOR_PANE" '#{cursor_y}' 2>/dev/null)
  echo "  cursor_y=$_cy" >&2
  echo "  pane capture (first 10 lines):" >&2
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SUPERVISOR_PANE" 2>/dev/null | head -10 | sed 's/^/    /' >&2
  _line=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SUPERVISOR_PANE" 2>/dev/null | sed -n "$((_cy + 1))p")
  echo "  cursor line: '$_line'" >&2
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" Enter
  fail "pane_input_pending self-check failed"
}

wait_for_pane_input_pending() {
  local i=0
  while [ "$i" -lt 30 ]; do
    if PATH="$TMUX_SHIM_DIR:$PATH" pane_input_pending "$SUPERVISOR_PANE"; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

selfcheck_pane_input_pending

# --- Scenario A: human-partial-input ----------------------------------------

test_scenario_a() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon

  # Type partial text into the supervisor pane with NO Enter. This simulates the
  # captain returning and starting to type before afk has been cleared.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" -l "human draft text"
  wait_for_pane_input_pending \
    || fail "Scenario A: human draft text did not become detectable as pending input"

  # Write a captain-relevant status to trigger a real escalation through the
  # real watcher child.
  echo "done: PR https://example.test/pr/100" > "$STATE_DIR/fake-c1.status"

  # Wait for the watcher to detect the change and the daemon to attempt inject.
  sleep 6

  # Assert: the digest was NOT injected while the pane had pending input.
  if grep -q 'Supervisor escalate' "$LOG_FILE"; then
    fail "Scenario A: daemon injected while pane had pending input (merged with human text?)"
  fi

  # Assert: no merged line (human text + digest) was submitted.
  if grep -q 'human draft text.*Supervisor escalate' "$LOG_FILE" 2>/dev/null || \
     grep -q 'Supervisor escalate.*human draft text' "$LOG_FILE" 2>/dev/null; then
    fail "Scenario A: human text and digest were merged into one line"
  fi

  # Now submit the human's text (Enter). The pane goes idle.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" Enter
  sleep 0.5

  # Wait for the daemon to retry injection (housekeeping tick = 1s).
  sleep 6

  # Assert: human text was submitted alone (as a user message).
  grep -q 'human draft text' "$LOG_FILE" \
    || fail "Scenario A: human text not in log after submit"

  # Assert: digest arrived after the pane went idle.
  grep -q 'Supervisor escalate' "$LOG_FILE" \
    || fail "Scenario A: digest not injected after pane went idle"

  # Assert: human text and digest are on SEPARATE lines (never merged).
  if grep -q 'human draft text.*Supervisor escalate' "$LOG_FILE" || \
     grep -q 'Supervisor escalate.*human draft text' "$LOG_FILE"; then
    fail "Scenario A: human text and digest merged into one line (after idle)"
  fi

  # Assert: the human text line is classified as "user", not "injection".
  local human_line
  human_line=$(grep 'human draft text' "$LOG_FILE" | head -1)
  case "$human_line" in
    *user) ;;  # correct
    *) fail "Scenario A: human text misclassified (expected user): $human_line" ;;
  esac

  # Assert: the digest line is classified as "injection".
  local digest_line
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  case "$digest_line" in
    *injection) ;;  # correct
    *) fail "Scenario A: digest misclassified (expected injection): $digest_line" ;;
  esac

  stop_daemon
  pass "Scenario A: partial input defers injection; digest arrives clean after idle"
}

# --- Scenario B: swallowed-Enter --------------------------------------------

test_scenario_b() {
  reset_state
  afk_enter "$STATE_DIR"

  # Arm the swallow: the daemon's first Enter will be dropped by the shim.
  touch "$STATE_DIR/.swallow-enter"

  start_daemon

  # Write a captain-relevant status to trigger a real escalation.
  echo "done: PR https://example.test/pr/200" > "$STATE_DIR/fake-c1.status"

  # Wait for the daemon to process the escalation and attempt inject (with the
  # swallowed Enter, the retry path fires).
  sleep 8

  # Assert: exactly ONE envelope in the log (no duplicate, no loss). One envelope
  # carries two U+2063 markers - the leading header and the trailing terminator
  # that keeps a front-cut delivery identifiable - so a retyped or concatenated
  # digest shows up as four.
  local marker_count injection_count
  marker_count=$(awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }' "$LOG_FILE")
  [ "$marker_count" -eq 2 ] \
    || fail "Scenario B: expected exactly 1 envelope (2 U+2063 markers), got $marker_count markers (duplicate or lost)"
  injection_count=$(grep -c $'\tinjection$' "$LOG_FILE" || true)
  [ "$injection_count" -eq 1 ] \
    || fail "Scenario B: expected exactly 1 injected digest, got $injection_count"

  # Assert: the digest line is classified as "injection" and starts with the
  # terminal-safe sentinel marker (hex starts with e281a3).
  local digest_line digest_hex
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  digest_hex=$(printf '%s' "$digest_line" | cut -f1)
  case "$digest_hex" in
    e281a3*) ;;  # correct: starts with the terminal-safe sentinel marker
    *) fail "Scenario B: digest does not start with sentinel marker (hex: $digest_hex)" ;;
  esac

  # Assert: exactly ONE user-message line was submitted (no spurious empty lines
  # from extra Enters). The log should have exactly 1 injection line and 0 user
  # lines.
  local user_count
  user_count=$(grep -c $'\tuser$' "$LOG_FILE" || true)
  [ "$user_count" -eq 0 ] \
    || fail "Scenario B: expected 0 user lines, got $user_count (spurious Enter submitted empty line?)"

  stop_daemon
  pass "Scenario B: swallowed Enter produces exactly one clean digest"
}

# --- Scenario C: normal status, single clean digest -------------------------
# No human input, no swallowed Enter: a captain-relevant status must produce
# exactly ONE sentinel-prefixed, single-line digest, submitted once. This owns
# the marker + single-line + no-duplicate operator contract that the deleted
# fake-tmux units used to assert via internal send-keys counts.

test_scenario_c() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon

  echo "done: PR https://example.test/pr/300" > "$STATE_DIR/fake-c1.status"
  sleep 6

  # Exactly one envelope in the submitted log (no duplicate, no loss): its
  # leading header and trailing terminator are two U+2063 markers together.
  local marker_count injection_count
  marker_count=$(awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }' "$LOG_FILE")
  [ "$marker_count" -eq 2 ] \
    || fail "Scenario C: expected exactly 1 envelope (2 U+2063 markers), got $marker_count markers"
  injection_count=$(grep -c $'\tinjection$' "$LOG_FILE" || true)
  [ "$injection_count" -eq 1 ] \
    || fail "Scenario C: expected exactly 1 injected digest, got $injection_count"

  # The digest is classified as an injection and starts with the sentinel byte.
  local digest_line digest_hex
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  case "$digest_line" in
    *injection) ;;
    *) fail "Scenario C: digest misclassified (expected injection): $digest_line" ;;
  esac
  digest_hex=$(printf '%s' "$digest_line" | cut -f1)
  case "$digest_hex" in
    e281a3*) ;;
    *) fail "Scenario C: digest does not start with sentinel marker (hex: $digest_hex)" ;;
  esac

  # The digest was submitted as ONE line (a multi-line digest would log >1 line),
  # and no spurious user-classified lines were submitted.
  local user_count
  user_count=$(grep -c $'\tuser$' "$LOG_FILE" || true)
  [ "$user_count" -eq 0 ] \
    || fail "Scenario C: expected 0 user lines, got $user_count (spurious submission?)"

  stop_daemon
  pass "Scenario C: a normal captain status injects exactly one clean single-line sentinel digest"
}

# --- Scenario D: front-cut delivery -----------------------------------------
# The 2026-08-31 failure. A digest was delivered with its head missing: the
# leading operational marker was gone, and the surviving tail read like a person
# talking. Under the away-exit contract an unmarked message means the captain
# returned, so the delivery defect became a wrong safety verdict - away mode
# would end, this daemon would stop, and the decision the escalation carried
# would be dropped, with the captain away by construction.
#
# The cut is forced through the tmux shim rather than reasoned about, so this
# runs anywhere tmux does. The two signals are driven apart deliberately: the
# SAME pane, the SAME classifier, a cut escalation and real captain prose, and
# the divergence is asserted so the case cannot pass vacuously.

test_scenario_d() {
  reset_state
  afk_enter "$STATE_DIR"

  # Keep only the last 60 characters of whatever the daemon types. That is past
  # the envelope header and into the digest body, exactly the shape observed.
  printf '60' > "$STATE_DIR/.front-cut"
  start_daemon
  # A submission from the preceding scenario can land in the pane loop just
  # after reset_state truncated the log. Settle, then start from a clean log so
  # every line below belongs to this scenario.
  sleep 1
  : > "$LOG_FILE"

  echo "needs-decision: retry policy A or B" > "$STATE_DIR/fake-c1.status"
  sleep 8

  # The digest is identified by the terminator, not by its framing prose: the
  # cut removes the framing, which is the whole point of the scenario.
  local line hex
  line=$(grep 'FIRSTMATE_OP_END' "$LOG_FILE" | head -1)
  [ -n "$line" ] \
    || fail "Scenario D: no escalation was delivered, so the cut path was never exercised"

  # The cut really happened: the delivered line does not begin with the sentinel.
  hex=$(printf '%s' "$line" | cut -f1)
  case "$hex" in
    e281a3*) fail "Scenario D: the front cut did not remove the leading marker; the test proves nothing" ;;
  esac

  # And the headless fragment is STILL not captain speech.
  case "$line" in
    *injection) ;;
    *) fail "Scenario D: a front-cut escalation was classified as a captain message: $line" ;;
  esac
  local user_count
  user_count=$(grep -c $'\tuser$' "$LOG_FILE" || true)
  [ "$user_count" -eq 0 ] \
    || fail "Scenario D: a front-cut escalation landed as $user_count captain-classified line(s)"

  # Divergence: with the cut disarmed, real captain prose in the same pane, read
  # by the same classifier, must still be captain prose.
  rm -f "$STATE_DIR/.front-cut"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" -l "any news on the deploy?"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" Enter
  sleep 2
  local captain_line
  captain_line=$(grep 'any news on the deploy' "$LOG_FILE" | head -1)
  [ -n "$captain_line" ] || fail "Scenario D: captain control message never landed"
  case "$captain_line" in
    *user) ;;
    *) fail "Scenario D: real captain prose was misclassified as an injection: $captain_line" ;;
  esac

  stop_daemon
  pass "Scenario D: a front-cut escalation stays an injection while real captain prose in the same pane stays a captain message"
}

# --- Scenario E: oversized escalation ---------------------------------------
# Past the single-send delivery bound a literal send stops being guaranteed to
# arrive whole, and the way it fails is the front cut above. An escalation that
# large must therefore never be handed to the pane as-is: it either arrives cut
# BY US - still marked at both ends, carrying the shared truncation marker and a
# pointer to the durable full text - or it is refused and left buffered for the
# wedge alarm. What it must never be is an unmarked fragment.

test_scenario_e() {
  local _w
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon
  sleep 1
  : > "$LOG_FILE"

  # Many captain-relevant statuses with long notes: the batched digest they
  # produce is far past the bound.
  local i
  i=1
  while [ "$i" -le 12 ]; do
    printf 'needs-decision: worker %s wants option A or option B for the checkout retry policy and the refund window\n' "$i" \
      > "$STATE_DIR/fake-c$i.status"
    i=$((i + 1))
  done
  # Bounded condition wait, not a fixed sleep. This scenario's outcome is either
  # a delivered digest or a preserved buffer, and how long the daemon needs to
  # reach one scales with how much classification work the fleet's status logs
  # cost: span classification against the shared presentation cursor made twelve
  # simultaneous captain-relevant statuses measurably slower than the constant
  # this scenario used to assume (8-9s before, 14s after, against a 12s sleep),
  # so a constant here re-breaks the moment either side of that changes again.
  # The bound still fails loudly - past it both assertions below run against the
  # same empty log and empty buffer they always did.
  # Wait on a TERMINAL outcome, not on the buffer. escalate_add fills the buffer
  # before escalate_flush ever attempts delivery, so a buffered escalation is
  # mid-flight, not a result - waiting on it races the flush and reads the log
  # before the daemon has written anything about why.
  # The two terminal states are: something reached the pane (LOG_FILE), or the
  # daemon refused the send and said so ("refused undelivered", the message
  # inject_msg logs when it turns an oversized digest into a preserved buffer).
  _w=0
  while [ "$_w" -lt 90 ]; do
    [ -s "$LOG_FILE" ] && break
    grep -q 'refused undelivered' "$STATE_DIR/.supervise-daemon.log" 2>/dev/null && break
    sleep 1
    _w=$((_w + 1))
  done
  # Settle: let an in-flight inject finish writing before the log is read.
  sleep 2

  local user_count
  user_count=$(grep -c $'\tuser$' "$LOG_FILE" || true)
  [ "$user_count" -eq 0 ] \
    || fail "Scenario E: an oversized escalation landed as $user_count captain-classified line(s)"

  if [ -s "$LOG_FILE" ]; then
    # Delivered: it must be within the bound and self-describing.
    local line text bytes
    line=$(grep 'FIRSTMATE_OP_END' "$LOG_FILE" | head -1)
    [ -n "$line" ] || fail "Scenario E: something was delivered but no digest line: $(cat "$LOG_FILE")"
    case "$line" in
      *injection) ;;
      *) fail "Scenario E: the delivered digest was not classified as an injection: $line" ;;
    esac
    text=$(printf '%s' "$line" | cut -f2)
    bytes=$(printf '%s' "$text" | wc -c | tr -d ' ')
    [ "$bytes" -le "$INJECT_MAX_BYTES_DEFAULT" ] \
      || fail "Scenario E: delivered $bytes bytes, over the ${INJECT_MAX_BYTES_DEFAULT}-byte bound"
    case "$text" in
      *"$FM_LINE_CAP_SUFFIX"*) ;;
      *) fail "Scenario E: the digest was cut but carries no truncation marker: $text" ;;
    esac
    case "$text" in
      *.supervise-daemon.log*) ;;
      *) fail "Scenario E: the cut digest does not say where the full text is: $text" ;;
    esac
  else
    # Refused: loudly, with the buffer preserved so nothing is lost.
    [ -s "$STATE_DIR/.subsuper-escalations" ] \
      || fail "Scenario E: nothing delivered and no buffered escalation preserved"
    grep -q 'delivery bound' "$STATE_DIR/.supervise-daemon.log" \
      || fail "Scenario E: nothing delivered and the daemon log says nothing about why"
  fi

  stop_daemon
  pass "Scenario E: an oversized escalation is delivered marked and bounded, or refused loudly, but never as an unmarked fragment"
}

test_scenario_a
test_scenario_b
test_scenario_c
test_scenario_d
test_scenario_e

echo "all e2e injection tests passed"
