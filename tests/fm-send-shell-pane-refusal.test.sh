#!/usr/bin/env bash
# tests/fm-send-shell-pane-refusal.test.sh - a steer must never be reported
# delivered when the endpoint's terminal is held by a shell instead of an agent.
#
# THE DEFECT THIS EXISTS FOR (2026-08-25). bin/fm-composer-lib.sh deliberately
# classifies a bare shell prompt as an empty agent composer, and that is not the
# bug: rendered shape cannot establish who owns a pane, which is why the
# away-mode injector was taught to corroborate the `empty` verdict with the
# kernel's own foreground-process facts (PR #23,
# docs/verification/runtime-backends.md "Away-mode supervisor pane
# identification"). The tmux submit path was the OTHER caller that ACTS on that
# verdict: it types the steer, sends Enter, and reads the composer back, so a
# crewmate whose agent had exited to a shell answered with a redrawn shell
# prompt, which read as a cleared composer, and bin/fm-send.sh exited 0. The
# steer had in fact been typed into a dead shell and executed there as a
# command, while firstmate recorded the instruction as landed.
#
# Every case here builds REAL processes in a REAL tmux server on a private
# socket (`-L`), with no harness and no credentials, so it runs everywhere CI
# runs tmux. The per-harness counterpart, which proves a genuinely live agent
# pane is never refused by the corroboration, is
# tests/fm-send-agent-pane-live-e2e.test.sh (live-harness-optin).
#
# The cases deliberately drive the two signals APART and assert the divergence,
# so this cannot go quietly vacuous:
#   1. The shell pane still classifies `empty` by RENDERED shape while the
#      foreground-process facts read `dead`. Asserting both pins the fact that
#      the rendered verdict is not, and must not become, the safeguard here.
#   2. An ORDINARY steer to that pane rides the durable steering inbox
#      (bin/fm-task-inbox-lib.sh): it is recorded rather than typed, so it
#      exits 0 - the record is the delivery. Neither the instruction nor the
#      doorbell line reaches the shell, and because the exit status no longer
#      carries the warning, the RESULT TEXT must say the endpoint has no live
#      agent and the record is waiting for one. A HARNESS-NATIVE steer ("/...")
#      has no record substitute - it must reach the harness's own parser - so
#      it stays on the typed plane and is still refused nonzero, untyped.
#   3. The identical pane shape with a real agent-named process in the
#      foreground still receives the steer and still exits 0, so the refusal is
#      a discrimination, not a blanket block.
#   4. An agent that exits to a shell BETWEEN the typing and the read-back -
#      the window the submit confirmation itself owns - is refused too, and the
#      composer verdict alone is asserted to still say `empty` at that moment.
set -u

# This suite does not source tests/lib.sh, so exempt its real fm-send.sh
# subprocess from the gate-lifecycle refusal (bin/fm-gate-refuse-lib.sh) the way
# lib.sh does for the rest of the suite: the no-mistakes gate runs this suite
# from a gate worktree, which the guard would otherwise refuse.
export FM_GATE_REFUSE_BYPASS=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEND="$ROOT/bin/fm-send.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
BASH_BIN=$(command -v bash) || { echo "skip: bash not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-sendshell-$$"
RIGHT_SOCKET="fm-sendshell-right-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-sendshell.XXXXXX")
ORIG_PATH=$PATH
# A short, top-level tmp dir - NOT nested under $LAB - because a scoped
# TMUX_TMPDIR's socket path is `<dir>/tmux-<uid>/default`, and $LAB's own
# deeply-nested mktemp path plus that suffix can exceed AF_UNIX's ~104-byte
# sun_path limit (measured: 106 bytes nested under $LAB, "File name too long").
WRONG_TMPDIR=$(mktemp -d "/tmp/fm-wrongtmux.XXXXXX")

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  "$REAL_TMUX" -L "$RIGHT_SOCKET" kill-server >/dev/null 2>&1 || true
  TMUX_TMPDIR="$WRONG_TMPDIR" "$REAL_TMUX" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
  [ -n "${WRONG_TMPDIR:-}" ] && rm -rf "$WRONG_TMPDIR"
}
trap cleanup_all EXIT

mkdir -p "$LAB/shim" "$LAB/bin" "$LAB/home/state"
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
# is exactly the signal the corroboration reads.
ln -s "$BASH_BIN" "$LAB/bin/claude-shim"

# The pane program, shared by every case so the panes differ in exactly one
# thing: which interpreter runs it. It draws a bare `❯` prompt - starship's
# default prompt character, and byte-identical to claude's own empty-composer
# glyph - and logs whatever is submitted to it, which is how each case proves
# whether anything was typed.
#
# The `handoff` mode is how case 4 constructs an agent that dies to a shell
# DURING a send, deterministically rather than by racing a timer: on the
# trigger character (which the test appends to the steer, and only there) it
# discards its buffer, redraws the empty prompt, and re-execs itself under the
# real bash - so from that instant the pane renders a cleared composer while
# the kernel names a shell as its foreground process.
#
# `handoff-first` is the same technique for the RING (doorbell) path: the
# doorbell line is a fixed, backend-generated constant the test cannot append
# its own trigger character to, so instead of matching a character this mode
# fires on the very first character read at all - the doorbell's literal send
# arrives as one shot, so this still guarantees the handoff completes before
# Enter is confirmed, exactly like `handoff`'s `~` trigger did for a
# caller-supplied message.
cat > "$LAB/pane-program.sh" <<'PROG'
#!/usr/bin/env bash
LOG="$1"
MODE="${2:-plain}"
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() { [ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
_buf=
redraw() { printf '\r\033[K\xe2\x9d\xaf '; [ -n "$_buf" ] && printf '%s' "$_buf"; }
redraw
while IFS= read -r -n 1 _ch; do
  if [ "$MODE" = handoff-first ]; then
    _buf=; redraw
    exec "$(command -v bash)" "$0" "$LOG" plain
  fi
  if [ "$MODE" = handoff ] && [ "$_ch" = '~' ]; then
    _buf=; redraw
    exec "$(command -v bash)" "$0" "$LOG" plain
  fi
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
"$REAL_TMUX" -L "$SOCKET" new-window -d -n losswin -t panes
LOSS_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t panes:losswin '#{pane_id}')
"$REAL_TMUX" -L "$SOCKET" new-window -d -n ringlosswin -t panes
RING_LOSS_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t panes:ringlosswin '#{pane_id}')

# The real, absolute socket path this private server actually lives at - what
# bin/fm-spawn.sh now records as tmux_socket= alongside window=, so every meta
# below binds fm-send.sh to THIS server explicitly rather than depending on
# the PATH shim surviving (see the wrong-server case near the bottom, which
# proves the shim alone is not load-bearing for isolation once this is set).
SOCK_PATH=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t panes '#{socket_path}')

SHELL_LOG="$LAB/shell-submitted.log"; : > "$SHELL_LOG"
AGENT_LOG="$LAB/agent-submitted.log"; : > "$AGENT_LOG"
LOSS_LOG="$LAB/loss-submitted.log"; : > "$LOSS_LOG"
RING_LOSS_LOG="$LAB/ring-loss-submitted.log"; : > "$RING_LOSS_LOG"

# The SHELL pane: a real interactive bash, the pane program running under its
# own kernel identity. This is the crewmate whose agent has exited.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SHELL_PANE" \
  "exec '$BASH_BIN' '$LAB/pane-program.sh' '$SHELL_LOG'" Enter
# The AGENT pane: the same program, same drawn shape, run by a process the
# kernel names as a verified harness.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$AGENT_PANE" \
  "exec '$LAB/bin/claude-shim' '$LAB/pane-program.sh' '$AGENT_LOG'" Enter
# The LOSS pane: starts as a live agent and becomes a shell mid-send.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$LOSS_PANE" \
  "exec '$LAB/bin/claude-shim' '$LAB/pane-program.sh' '$LOSS_LOG' handoff" Enter
# The RING-LOSS pane: starts as a live agent and becomes a shell the instant
# the doorbell's literal send starts arriving (handoff-first), so its agent is
# gone before the ring's own Enter can be confirmed.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$RING_LOSS_PANE" \
  "exec '$LAB/bin/claude-shim' '$LAB/pane-program.sh' '$RING_LOSS_LOG' handoff-first" Enter

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
wait_for_prompt "$LOSS_PANE" || fail "the handoff pane never drew its prompt"
wait_for_prompt "$RING_LOSS_PANE" || fail "the ring-handoff pane never drew its prompt"

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

# The steers are sent through the real bin/fm-send.sh against recorded task
# endpoints, which is exactly how firstmate steers a crewmate. tmux_socket=
# pins every one of these to this private server explicitly (bin/fm-spawn.sh
# now records this at spawn time); it is not merely redundant with the PATH
# shim above - the wrong-server case below proves fm-send.sh honors it even
# when ambient resolution points elsewhere.
HOME_DIR="$LAB/home"
printf 'window=%s\nbackend=tmux\ntmux_socket=%s\nkind=ship\nharness=claude\n' "$SHELL_PANE" "$SOCK_PATH" > "$HOME_DIR/state/deadmate.meta"
printf 'window=%s\nbackend=tmux\ntmux_socket=%s\nkind=ship\nharness=claude\n' "$AGENT_PANE" "$SOCK_PATH" > "$HOME_DIR/state/livemate.meta"
printf 'window=%s\nbackend=tmux\ntmux_socket=%s\nkind=ship\nharness=claude\n' "$LOSS_PANE" "$SOCK_PATH" > "$HOME_DIR/state/lossmate.meta"
printf 'window=%s\nbackend=tmux\ntmux_socket=%s\nkind=ship\nharness=claude\n' "$RING_LOSS_PANE" "$SOCK_PATH" > "$HOME_DIR/state/ringlossmate.meta"

send_steer() {  # <task-id> <text> -> exit status, output in SEND_OUT
  local id=$1 text=$2 rc=0
  FM_HOME="$HOME_DIR" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0.3 \
    "$SEND" "$id" "$text" > "$LAB/send.out" 2>&1 || rc=$?
  # fm-send always runs the supervision guard first; its banner is about this
  # checkout, not this send, so keep it out of the failure messages below.
  SEND_OUT=$(grep -v '^●' "$LAB/send.out" || true)
  return "$rc"
}

# --- 1 + 2: the crewmate whose agent has exited -----------------------------
test_shell_pane_steer_is_refused() {
  local composer agent_state rc=0

  # The DIVERGENCE this whole defect turns on, asserted explicitly: the
  # rendered classifier reads this real shell as a proven-empty agent composer.
  composer=$(fm_backend_composer_state tmux "$SHELL_PANE")
  [ "$composer" = empty ] || fail \
    "the shell pane no longer renders as an empty composer (got '$composer'); the two signals no longer diverge, so this case would prove nothing - re-derive what still makes shape-only proof unsafe before weakening it"

  # The independent, non-rendered signal disagrees, and it is the one that
  # decides.
  agent_state=$(fm_backend_pane_agent_state tmux "$SHELL_PANE")
  [ "$agent_state" = dead ] || fail \
    "a bare interactive shell should read 'dead' from the foreground process group, got '$agent_state'"

  # ORDINARY STEER - the inbox plane. The durable record IS the delivery, so
  # this exits 0 and the instruction is never typed anywhere; the doorbell that
  # WOULD have been typed is refused by the same no-agent verdict. What the
  # exit status no longer carries, the output must: firstmate reading this
  # result must not be left believing a dead worker read the instruction.
  send_steer deadmate 'rebase onto main and re-run the gate' || rc=$?
  [ "$rc" -eq 0 ] || fail \
    "an ordinary steer is durably recorded, so it must not fail (exit $rc): $SEND_OUT"

  # Assert on SUBMITTED CONTENT, not pane appearance: nothing reached the shell.
  # Neither the instruction nor the doorbell line may be typed into a dead shell.
  [ ! -s "$SHELL_LOG" ] || fail \
    "something was typed into the shell pane: $(cat "$SHELL_LOG")"

  # The steer is not lost: it is durably recorded for whatever agent comes back.
  [ -s "$HOME_DIR/state/deadmate.inbox/001.msg" ] || fail \
    "the steer was neither typed nor durably recorded, so it is simply gone"
  grep -F 'rebase onto main' "$HOME_DIR/state/deadmate.inbox/001.msg" >/dev/null || fail \
    "the durable record does not carry the steer text"

  # The report must say the agent was ABSENT and that the record is waiting,
  # because the next move is recovering the worker, not resending.
  case "$SEND_OUT" in
    *"no live agent"*) ;;
    *) fail "the result did not say the endpoint has no live agent: $SEND_OUT" ;;
  esac
  case "$SEND_OUT" in
    *"waits for a live agent"*) ;;
    *) fail "the result did not say the record is waiting for a live agent: $SEND_OUT" ;;
  esac

  pass "an ordinary steer to a shell-held endpoint is recorded, never typed, and reported as reaching no live agent"
}

# --- 2: the TYPED plane still refuses outright ------------------------------
# A harness-native invocation must reach the harness's own parser, so it has no
# durable-record substitute: it is typed or it is nothing. That is where the
# no-agent verdict still decides delivery, and where a nonzero exit is the only
# honest answer.
test_shell_pane_typed_plane_is_refused() {
  local rc=0

  send_steer deadmate '/status' || rc=$?
  [ "$rc" -ne 0 ] || fail \
    "fm-send reported a harness-native steer into a bare shell pane as delivered (exit 0): $SEND_OUT"

  [ ! -s "$SHELL_LOG" ] || fail \
    "the harness-native steer was typed into the shell pane: $(cat "$SHELL_LOG")"

  case "$SEND_OUT" in
    *no-agent*) ;;
    *) fail "the refusal did not name the shell-held endpoint: $SEND_OUT" ;;
  esac

  pass "a harness-native steer to that same pane is refused outright and never typed"
}

# --- 3: the refusal discriminates, it does not blanket-block -----------------
test_agent_pane_steer_is_delivered() {
  local agent_state
  agent_state=$(fm_backend_pane_agent_state tmux "$AGENT_PANE")
  [ "$agent_state" = alive ] || fail \
    "a pane whose foreground process is named as a verified harness should read 'alive', got '$agent_state'"

  send_steer livemate 'rebase onto main and re-run the gate' || fail \
    "fm-send refused a steer to a pane with a live agent in the foreground: $SEND_OUT"

  # The discriminating fact, on the plane the steer now rides: the DOORBELL
  # reaches this pane, where the identical shape holding a shell got nothing at
  # all. Both endpoints record the steer; only this one is rung.
  [ -s "$AGENT_LOG" ] || fail \
    "the doorbell never reached the agent pane, so the refusal is a blanket block rather than a discrimination"
  grep -F 'Firstmate instruction waiting' "$AGENT_LOG" >/dev/null || fail \
    "what reached the agent pane was not the doorbell line: $(cat "$AGENT_LOG")"
  grep -F 'rebase onto main' "$HOME_DIR/state/livemate.inbox/001.msg" >/dev/null || fail \
    "the steer was rung but not durably recorded for the live agent"

  # And the report carries no absent-agent warning, so that line stays a signal.
  case "$SEND_OUT" in
    *"no live agent"*) fail "a live agent pane was reported as having no live agent: $SEND_OUT" ;;
  esac

  pass "the same pane shape with a live agent in the foreground is rung, not refused"
}

# --- 4: the agent dies between the typing and the read-back -----------------
test_agent_lost_during_send_is_not_reported_delivered() {
  local rc=0 composer agent_state
  [ "$(fm_backend_pane_agent_state tmux "$LOSS_PANE")" = alive ] || fail \
    "the handoff pane should start as a live agent pane"

  # The trailing `~` is the handoff trigger: the pane's agent process re-execs
  # as a shell the moment it arrives, i.e. after the steer is typed and before
  # Enter is read back. This is a HARNESS-NATIVE steer on purpose: the read-back
  # window only exists where text is actually typed, and an ordinary steer now
  # rides the durable record instead, so sending one here would never type the
  # trigger and the case would go vacuous.
  send_steer lossmate '/status~' || rc=$?

  # The window this case owns, asserted so it cannot go vacuous: at read-back
  # time the pane renders a cleared composer and the process facts say shell.
  composer=$(fm_backend_composer_state tmux "$LOSS_PANE")
  agent_state=$(fm_backend_pane_agent_state tmux "$LOSS_PANE")
  [ "$composer" = empty ] || fail \
    "the handoff pane did not end up rendering a cleared composer (got '$composer'), so this case never exercised the submit read-back"
  [ "$agent_state" = dead ] || fail \
    "the handoff pane did not end up owned by a shell (got '$agent_state'), so this case never exercised the submit read-back"

  [ "$rc" -ne 0 ] || fail \
    "fm-send reported delivery after the agent exited to a shell mid-send: $SEND_OUT"
  # The Enter itself still reaches the pane - it was already in flight - so the
  # claim under test is that the INSTRUCTION was never submitted to anything.
  ! grep -F '/status' "$LOSS_LOG" >/dev/null || fail \
    "the steer was submitted into the pane after its agent exited: $(cat "$LOSS_LOG")"
  case "$SEND_OUT" in
    *agent-lost*) ;;
    *) fail "the refusal did not name the lost agent: $SEND_OUT" ;;
  esac

  pass "an agent that exits to a shell mid-send is never reported as having received the steer"
}

# --- 5: the agent dies DURING THE RING ITSELF (ordinary/inbox plane) --------
# Case 4 proves the typed (harness-native) plane refuses an agent lost between
# typing and read-back. This proves the SAME race on the RING (doorbell) path
# that an ordinary steer now rides: fm_task_inbox_ring's own outcome 4
# (bin/fm-task-inbox-lib.sh), reported by bin/fm-send.sh, is a distinct code
# path from case 4's - it is reached via fm_task_inbox_ring, never via a
# direct fm_backend_send_text_submit call - and had no coverage before this.
test_ring_agent_lost_during_doorbell_is_not_reported_delivered() {
  local composer agent_state
  [ "$(fm_backend_pane_agent_state tmux "$RING_LOSS_PANE")" = alive ] || fail \
    "the ring-handoff pane should start as a live agent pane"

  # An ORDINARY steer: it never types the instruction text itself (that rides
  # the durable record), only the constant doorbell line, so handoff-first is
  # what makes the agent die mid-ring without depending on message content.
  send_steer ringlossmate 'rebase onto main and re-run the gate' || fail \
    "an ordinary steer is durably recorded, so it must not fail: $SEND_OUT"

  # The window this case owns, asserted so it cannot go vacuous: at read-back
  # time the pane renders a cleared composer and the process facts say shell.
  composer=$(fm_backend_composer_state tmux "$RING_LOSS_PANE")
  agent_state=$(fm_backend_pane_agent_state tmux "$RING_LOSS_PANE")
  [ "$composer" = empty ] || fail \
    "the ring-handoff pane did not end up rendering a cleared composer (got '$composer'), so this case never exercised the ring's submit read-back"
  [ "$agent_state" = dead ] || fail \
    "the ring-handoff pane did not end up owned by a shell (got '$agent_state'), so this case never exercised the ring's submit read-back"

  # The steer is still durably recorded: the record IS the delivery.
  grep -F 'rebase onto main' "$HOME_DIR/state/ringlossmate.inbox/001.msg" >/dev/null || fail \
    "the durable record does not carry the steer text"

  # The doorbell line itself was never actually submitted: handoff-first
  # discards its buffer on the very first character, so the LEADING byte of
  # the doorbell's literal send is lost to the exec - the same "Enter was
  # already in flight" leftover case 4 accepts, not a claim that the pane
  # received nothing byte-for-byte. Asserting on the exact leading text (as
  # opposed to a completely empty log) is what keeps this equivalent to case
  # 4's `! grep -F '/status'` check rather than a stricter, more fragile one.
  ! grep -F 'Firstmate instruction waiting' "$RING_LOSS_LOG" >/dev/null || fail \
    "the doorbell line was submitted into the pane after its agent exited: $(cat "$RING_LOSS_LOG")"

  # The report must name this exact outcome - typed, Enter sent, then lost -
  # distinctly from outcome 3's never-typed wording.
  case "$SEND_OUT" in
    *"the doorbell line was typed there but its agent exited to a shell before the submission could be confirmed"*) ;;
    *) fail "the result did not report the doorbell-typed-then-agent-lost outcome: $SEND_OUT" ;;
  esac
  case "$SEND_OUT" in
    *"waits for a live agent"*) ;;
    *) fail "the result did not say the record is waiting for a live agent: $SEND_OUT" ;;
  esac

  pass "an agent that exits to a shell during the ring itself is never reported as having received the doorbell"
}

# --- 6: a same-id pane on a DIFFERENT tmux server must never be touched -----
# THE DEFECT THIS EXISTS FOR (2026-09-04): a task's recorded window= is a bare
# pane id or session:window with no server identity, so a caller whose ambient
# `tmux` resolves a DIFFERENT server than the one the id was allocated on
# cannot tell its target from a same-id pane over there - pane ids are
# per-server counters, so a fresh server's first pane is always the same id as
# any other fresh server's first pane. This drove a real doorbell into a real
# operator's primary tmux pane during this branch's own testing. tmux_socket=
# (bin/fm-spawn.sh) is the fix: it pins the exact server, so ambient
# resolution drifting elsewhere cannot matter.
test_wrong_server_pane_is_never_touched() {
  local right_pane wrong_pane right_sock rc=0

  # Two BRAND NEW servers, so each one's first pane is "%0" - the exact
  # collision the defect depends on. RIGHT is reached only through -L (the
  # same mechanism the rest of this suite uses); WRONG is reached only through
  # bare `tmux`'s OWN ambient default-socket resolution under a scoped
  # TMUX_TMPDIR, with NO -L, no -S, and NO PATH shim in effect - i.e. exactly
  # the unshimmed, ambient invocation a lost isolation seam would fall back to.
  "$REAL_TMUX" -L "$RIGHT_SOCKET" new-session -d -s rightpanes -x 80 -y 24
  right_pane=$("$REAL_TMUX" -L "$RIGHT_SOCKET" display-message -p -t rightpanes '#{pane_id}')
  right_sock=$("$REAL_TMUX" -L "$RIGHT_SOCKET" display-message -p -t rightpanes '#{socket_path}')
  TMUX_TMPDIR="$WRONG_TMPDIR" "$REAL_TMUX" new-session -d -s wrongpanes -x 80 -y 24
  wrong_pane=$(TMUX_TMPDIR="$WRONG_TMPDIR" "$REAL_TMUX" display-message -p -t wrongpanes '#{pane_id}')

  [ "$right_pane" = "$wrong_pane" ] || fail \
    "the two fresh servers' first panes must collide on id to exercise the defect (right=$right_pane wrong=$wrong_pane)"

  WRONG_LOG="$LAB/wrong-server-submitted.log"; : > "$WRONG_LOG"
  RIGHT_LOG="$LAB/right-server-submitted.log"; : > "$RIGHT_LOG"
  # Both panes are shaped as live agents: if the wrong-server pane received
  # anything, it would look exactly as deliverable as the right one, so a
  # false "reached" here could not hide behind a shell-refusal instead.
  TMUX_TMPDIR="$WRONG_TMPDIR" "$REAL_TMUX" send-keys -t "$wrong_pane" \
    "exec '$LAB/bin/claude-shim' '$LAB/pane-program.sh' '$WRONG_LOG'" Enter
  "$REAL_TMUX" -L "$RIGHT_SOCKET" send-keys -t "$right_pane" \
    "exec '$LAB/bin/claude-shim' '$LAB/pane-program.sh' '$RIGHT_LOG'" Enter

  wait_for_wrong_prompt() {
    local i=0
    while [ "$i" -lt 100 ]; do
      TMUX_TMPDIR="$WRONG_TMPDIR" "$REAL_TMUX" capture-pane -p -t "$wrong_pane" 2>/dev/null | grep -q '❯' && return 0
      sleep 0.1
      i=$((i + 1))
    done
    return 1
  }
  wait_for_right_prompt() {
    local i=0
    while [ "$i" -lt 100 ]; do
      "$REAL_TMUX" -L "$RIGHT_SOCKET" capture-pane -p -t "$right_pane" 2>/dev/null | grep -q '❯' && return 0
      sleep 0.1
      i=$((i + 1))
    done
    return 1
  }
  wait_for_wrong_prompt || fail "the wrong-server pane never drew its prompt"
  wait_for_right_prompt || fail "the right-server pane never drew its prompt"

  printf 'window=%s\nbackend=tmux\ntmux_socket=%s\nkind=ship\nharness=claude\n' \
    "$right_pane" "$right_sock" > "$HOME_DIR/state/wrongservermate.meta"

  # Ambient resolution for this one call is deliberately pointed at the WRONG
  # server (TMUX_TMPDIR set, no -S, no -L, and the unshimmed real PATH so the
  # suite's own -L shim cannot rescue this call either) - the meta's
  # tmux_socket= is the ONLY thing that can route this correctly.
  rc=0
  env PATH="$ORIG_PATH" TMUX_TMPDIR="$WRONG_TMPDIR" \
    FM_HOME="$HOME_DIR" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0.3 \
    "$SEND" wrongservermate 'rebase onto main and re-run the gate' \
    > "$LAB/send.out" 2>&1 || rc=$?
  SEND_OUT=$(grep -v '^●' "$LAB/send.out" || true)
  [ "$rc" -eq 0 ] || fail \
    "an ordinary steer is durably recorded, so it must not fail (exit $rc): $SEND_OUT"

  [ ! -s "$WRONG_LOG" ] || fail \
    "the doorbell reached a same-id pane on the WRONG tmux server: $(cat "$WRONG_LOG")"
  [ -s "$RIGHT_LOG" ] || fail \
    "the doorbell never reached the CORRECT server's pane either - this proves nothing, re-derive the fixture"
  grep -F 'Firstmate instruction waiting' "$RIGHT_LOG" >/dev/null || fail \
    "what reached the right-server pane was not the doorbell line: $(cat "$RIGHT_LOG")"

  pass "a doorbell bound to one tmux server never reaches a same-id pane on another"
}

test_shell_pane_steer_is_refused
test_shell_pane_typed_plane_is_refused
test_agent_pane_steer_is_delivered
test_agent_lost_during_send_is_not_reported_delivered
test_ring_agent_lost_during_doorbell_is_not_reported_delivered
test_wrong_server_pane_is_never_touched

echo "all fm-send shell-pane refusal tests passed"
