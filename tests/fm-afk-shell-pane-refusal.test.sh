#!/usr/bin/env bash
# tests/fm-afk-shell-pane-refusal.test.sh - the away-mode supervisor pane must be
# POSITIVELY identified as a live agent pane before anything is typed into it.
#
# THE DEFECT THIS EXISTS FOR (2026-08-24). The daemon auto-discovered its
# injection target and, finding none, fell back to the tmux name "firstmate:0"
# with a warning. On a machine where firstmate runs OUTSIDE tmux while the crew
# windows live in a tmux session named `firstmate`, that guess resolved to an
# ordinary interactive shell. The composer guard did not save it: the captain's
# shell prompt is drawn by starship, whose default prompt character is `❯` - the
# same character claude draws for its own empty composer - so the shell pane
# classified as a proven-empty agent composer. Two away-mode digests carrying
# real `done:` completions were typed into that shell, executed as commands
# (`zsh: parse error near ')'`), and counted as delivered, which cleared the
# escalation buffer.
#
# No test had ever constructed a shell pane, which is why shape-only proof
# survived. So every case here builds REAL processes in a REAL tmux server on a
# private socket (`-L`), with no harness and no credentials, so it runs
# everywhere CI runs tmux.
#
# The cases deliberately drive the two signals APART and assert the divergence,
# so this cannot go quietly vacuous:
#   1. The shell pane still classifies `empty` by RENDERED shape. Asserting that
#      pins the fact that rendering alone cannot be the safeguard - if a future
#      change made the classifier reject this shape, that assertion fails and
#      whoever changed it must decide deliberately whether shape is now load
#      bearing again.
#   2. That same pane reads `dead` from the kernel's foreground-process facts,
#      injection DEFERS, the buffer SURVIVES, and nothing is typed into the shell.
#   3. The identical pane shape with a real agent-named process in the
#      foreground reads `alive` and the digest IS delivered - so the refusal is
#      a discrimination, not a blanket block.
#   4. The daemon refuses to START when no pane can be identified at all, and
#      when the identified pane is a shell.
#
# The per-harness counterpart for the process-name half is
# tests/fm-harness-liveness-drift-live-e2e.test.sh (live-harness-optin).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
BASH_BIN=$(command -v bash) || { echo "skip: bash not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-shellpane-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-shellpane.XXXXXX")

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$LAB/shim" "$LAB/bin" "$LAB/state"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# A stand-in "harness" binary: a SYMLINK to the real bash, never a copy (a
# copied platform binary fails code-signing validation and is killed on macOS
# arm64). The symlink name is the executable identity the kernel records, which
# is exactly the signal the agent-proof guard reads.
ln -s "$BASH_BIN" "$LAB/bin/claude-shim"

# The pane program, shared by BOTH the shell case and the agent case so the two
# differ in exactly one thing: which interpreter runs it. It draws a bare `❯`
# prompt - starship's default prompt character, and byte-identical to claude's
# own empty-composer glyph - and logs whatever is submitted to it, which is how
# each case proves whether anything was typed.
cat > "$LAB/pane-program.sh" <<'PROG'
#!/usr/bin/env bash
LOG="$1"
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() { [ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
_buf=
redraw() { printf '\r\033[K\xe2\x9d\xaf '; [ -n "$_buf" ] && printf '%s' "$_buf"; }
redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then
    printf '%s\n' "$_buf" >> "$LOG"; _buf=; printf '\r\033[K\n'; redraw; continue
  fi
  case "$_ch" in
    $'\r'|$'\n') printf '%s\n' "$_buf" >> "$LOG"; _buf=; printf '\r\033[K\n'; redraw ;;
    $'\177'|$'\b') _buf=${_buf%?}; redraw ;;
    *) _buf="${_buf}${_ch}"; redraw ;;
  esac
done
PROG
chmod +x "$LAB/pane-program.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s panes -x 200 -y 30
SHELL_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t panes '#{pane_id}')
"$REAL_TMUX" -L "$SOCKET" new-window -d -n agentwin -t panes
AGENT_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t panes:agentwin '#{pane_id}')

SHELL_LOG="$LAB/shell-submitted.log"; : > "$SHELL_LOG"
AGENT_LOG="$LAB/agent-submitted.log"; : > "$AGENT_LOG"

# The SHELL pane: a real interactive bash, the pane program running under its
# own kernel identity. This is the incident pane.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SHELL_PANE" \
  "exec '$BASH_BIN' '$LAB/pane-program.sh' '$SHELL_LOG'" Enter
# The AGENT pane: the same program, same drawn shape, run by a process the
# kernel names as a verified harness.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$AGENT_PANE" \
  "exec '$LAB/bin/claude-shim' '$LAB/pane-program.sh' '$AGENT_LOG'" Enter

wait_for_prompt() {  # <pane>
  local pane=$1 i=0
  while [ "$i" -lt 100 ]; do
    "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$pane" 2>/dev/null | grep -q '❯' && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
wait_for_prompt "$SHELL_PANE" || fail "the shell pane never drew its prompt"
wait_for_prompt "$AGENT_PANE" || fail "the agent pane never drew its prompt"

# shellcheck source=bin/fm-supervise-daemon.sh
. "$DAEMON"
FM_DAEMON_PRIMARY_HARNESS=claude
export FM_DAEMON_PRIMARY_HARNESS
FM_WEDGE_ALARM_EXEC=discard
export FM_WEDGE_ALARM_EXEC

STATE="$LAB/state"

# --- 1 + 2: the incident pane ----------------------------------------------
test_shell_pane_is_refused_and_the_escalation_survives() {
  local composer agent_state buf

  # The DIVERGENCE this whole defect turned on, asserted explicitly: the
  # rendered classifier reads this real shell as a proven-empty agent composer.
  composer=$(fm_backend_composer_state tmux "$SHELL_PANE")
  [ "$composer" = empty ] || fail \
    "the shell pane no longer renders as an empty composer (got '$composer'); the two signals no longer diverge, so this case would prove nothing - re-derive what still makes shape-only proof unsafe before weakening it"

  # The independent, non-rendered signal disagrees, and it is the one that
  # decides.
  agent_state=$(fm_backend_pane_agent_state tmux "$SHELL_PANE")
  [ "$agent_state" = dead ] || fail \
    "a bare interactive shell should read 'dead' from the foreground process group, got '$agent_state'"

  afk_enter "$STATE"
  escalate_add "$STATE" "task-a.status: done: closed all three _KNOWN_GAPS entries (pre-read)"
  escalate_add "$STATE" "task-b.status: done: contract published, committed 68222d90"

  if FM_SUPERVISOR_TARGET="$SHELL_PANE" FM_SUPERVISOR_BACKEND=tmux \
     FM_ESCALATE_BATCH_SECS=0 escalate_flush "$STATE"; then
    fail "escalate_flush reported delivery into a bare shell pane"
  fi

  # Nothing reached the shell. Assert on SUBMITTED CONTENT, not pane appearance.
  [ ! -s "$SHELL_LOG" ] || fail \
    "text was submitted into the shell pane: $(cat "$SHELL_LOG")"

  # And the escalation is still on the books for the next cycle or catch-up.
  buf="$STATE/.subsuper-escalations"
  [ -s "$buf" ] || fail "the deferred escalation buffer was consumed instead of preserved"
  grep -F '_KNOWN_GAPS' "$buf" >/dev/null || fail "the first buffered completion was lost"
  grep -F '68222d90' "$buf" >/dev/null || fail "the second buffered completion was lost"

  pass "a bare shell pane that renders as an empty composer is refused, and the escalation survives"
}

# --- 3: the refusal discriminates, it does not blanket-block -----------------
test_agent_pane_with_the_same_shape_is_delivered() {
  local agent_state buf
  agent_state=$(fm_backend_pane_agent_state tmux "$AGENT_PANE")
  [ "$agent_state" = alive ] || fail \
    "a pane whose foreground process is named as a verified harness should read 'alive', got '$agent_state'"

  afk_enter "$STATE"
  if ! FM_SUPERVISOR_TARGET="$AGENT_PANE" FM_SUPERVISOR_BACKEND=tmux \
       FM_ESCALATE_BATCH_SECS=0 FM_INJECT_CONFIRM_SLEEP=0.3 \
       FM_INJECT_CONFIRM_RETRIES=8 escalate_flush "$STATE"; then
    fail "escalate_flush refused a pane with a live agent in the foreground: $(cat "$STATE/.supervise-daemon.log" 2>/dev/null | tail -3)"
  fi

  grep -F '_KNOWN_GAPS' "$AGENT_LOG" >/dev/null || fail \
    "the digest never reached the agent pane: $(cat "$AGENT_LOG")"
  buf="$STATE/.subsuper-escalations"
  [ ! -s "$buf" ] || fail "the buffer was not cleared after a confirmed delivery"

  pass "the same pane shape with a live agent in the foreground still receives the digest"
}

# --- 4: the daemon refuses to start rather than guessing ---------------------
run_daemon_expecting_refusal() {  # <state-dir> <env-assignments...>
  local state=$1; shift
  ( env FM_STATE_OVERRIDE="$state" "$@" "$DAEMON" ) >"$state/out" 2>"$state/err"
}

test_daemon_refuses_to_start_with_no_identifiable_pane() {
  local state status
  state="$LAB/state-notarget"; mkdir -p "$state"
  set +e
  run_daemon_expecting_refusal "$state" TMUX_PANE= HERDR_ENV= HERDR_PANE_ID= FM_SUPERVISOR_TARGET=
  status=$?
  set -e 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "the daemon started with no identifiable supervisor pane"
  [ ! -f "$state/.supervise-daemon.pid" ] || fail "a refusing daemon left a pid file behind"
  grep -F 'not running inside a tmux or herdr pane' "$state/err" >/dev/null || fail \
    "the refusal did not plainly say firstmate is not in a supported pane: $(cat "$state/err")"
  # Away mode can already be armed when this refusal happens (the harness-hosted
  # entry arms it first), so the refusal must leave a durable trace rather than
  # dying into an unwatched background job's stderr.
  [ -s "$state/.subsuper-inject-wedged" ] || fail \
    "the startup refusal left no durable undelivered-escalation marker"
  grep -F 'REFUSED TO START' "$state/.subsuper-inject-wedged" >/dev/null || fail \
    "the durable marker does not say the daemon refused to start: $(cat "$state/.subsuper-inject-wedged")"
  pass "the daemon refuses to start when no supervisor pane can be identified, and says so durably"
}

test_daemon_refuses_to_start_against_a_shell_pane() {
  local state status
  state="$LAB/state-shelltarget"; mkdir -p "$state"
  set +e
  run_daemon_expecting_refusal "$state" TMUX_PANE= HERDR_ENV= HERDR_PANE_ID= \
    FM_SUPERVISOR_TARGET="$SHELL_PANE" FM_SUPERVISOR_BACKEND=tmux
  status=$?
  set -e 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "the daemon started against a bare shell pane"
  [ ! -f "$state/.supervise-daemon.pid" ] || fail "a refusing daemon left a pid file behind"
  grep -F 'no live agent process owns it' "$state/err" >/dev/null || fail \
    "the refusal did not name the missing agent: $(cat "$state/err")"
  [ ! -s "$SHELL_LOG" ] || fail \
    "the refusing daemon still typed into the shell pane: $(cat "$SHELL_LOG")"
  # Away mode can already be armed when this refusal happens (the harness-hosted
  # entry arms it first), so the refusal must leave a durable trace rather than
  # dying into an unwatched background job's stderr.
  [ -s "$state/.subsuper-inject-wedged" ] || fail \
    "the startup refusal left no durable undelivered-escalation marker"
  grep -F 'REFUSED TO START' "$state/.subsuper-inject-wedged" >/dev/null || fail \
    "the durable marker does not say the daemon refused to start: $(cat "$state/.subsuper-inject-wedged")"
  pass "the daemon refuses to start when the identified pane holds no live agent, and says so durably"
}

test_shell_pane_is_refused_and_the_escalation_survives
test_agent_pane_with_the_same_shape_is_delivered
test_daemon_refuses_to_start_with_no_identifiable_pane
test_daemon_refuses_to_start_against_a_shell_pane

echo "all away-mode shell-pane refusal tests passed"
