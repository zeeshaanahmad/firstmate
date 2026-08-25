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
#   2. A steer to that pane is refused, exits nonzero, and never types the
#      instruction into the shell.
#   3. The identical pane shape with a real agent-named process in the
#      foreground still receives the steer and still exits 0, so the refusal is
#      a discrimination, not a blanket block.
#   4. An agent that exits to a shell BETWEEN the typing and the read-back -
#      the window the submit confirmation itself owns - is refused too, and the
#      composer verdict alone is asserted to still say `empty` at that moment.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEND="$ROOT/bin/fm-send.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
BASH_BIN=$(command -v bash) || { echo "skip: bash not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-sendshell-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-sendshell.XXXXXX")

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
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

SHELL_LOG="$LAB/shell-submitted.log"; : > "$SHELL_LOG"
AGENT_LOG="$LAB/agent-submitted.log"; : > "$AGENT_LOG"
LOSS_LOG="$LAB/loss-submitted.log"; : > "$LOSS_LOG"

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

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

# The steers are sent through the real bin/fm-send.sh against recorded task
# endpoints, which is exactly how firstmate steers a crewmate.
HOME_DIR="$LAB/home"
printf 'window=%s\nbackend=tmux\nkind=ship\nharness=claude\n' "$SHELL_PANE" > "$HOME_DIR/state/deadmate.meta"
printf 'window=%s\nbackend=tmux\nkind=ship\nharness=claude\n' "$AGENT_PANE" > "$HOME_DIR/state/livemate.meta"
printf 'window=%s\nbackend=tmux\nkind=ship\nharness=claude\n' "$LOSS_PANE" > "$HOME_DIR/state/lossmate.meta"

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

  send_steer deadmate 'rebase onto main and re-run the gate' || rc=$?
  [ "$rc" -ne 0 ] || fail \
    "fm-send reported a steer into a bare shell pane as delivered (exit 0): $SEND_OUT"

  # Assert on SUBMITTED CONTENT, not pane appearance: nothing reached the shell.
  [ ! -s "$SHELL_LOG" ] || fail \
    "the steer was typed into the shell pane: $(cat "$SHELL_LOG")"

  # The refusal must say what is actually wrong, because the next move is
  # recovering the worker, not resending.
  case "$SEND_OUT" in
    *no-agent*) ;;
    *) fail "the refusal did not name the shell-held endpoint: $SEND_OUT" ;;
  esac

  pass "a steer to a pane whose agent exited to a shell is refused and never typed"
}

# --- 3: the refusal discriminates, it does not blanket-block -----------------
test_agent_pane_steer_is_delivered() {
  local agent_state
  agent_state=$(fm_backend_pane_agent_state tmux "$AGENT_PANE")
  [ "$agent_state" = alive ] || fail \
    "a pane whose foreground process is named as a verified harness should read 'alive', got '$agent_state'"

  send_steer livemate 'rebase onto main and re-run the gate' || fail \
    "fm-send refused a steer to a pane with a live agent in the foreground: $SEND_OUT"

  grep -F 'rebase onto main' "$AGENT_LOG" >/dev/null || fail \
    "the steer never reached the agent pane: $(cat "$AGENT_LOG")"

  pass "the same pane shape with a live agent in the foreground still receives the steer"
}

# --- 4: the agent dies between the typing and the read-back -----------------
test_agent_lost_during_send_is_not_reported_delivered() {
  local rc=0 composer agent_state
  [ "$(fm_backend_pane_agent_state tmux "$LOSS_PANE")" = alive ] || fail \
    "the handoff pane should start as a live agent pane"

  # The trailing `~` is the handoff trigger: the pane's agent process re-execs
  # as a shell the moment it arrives, i.e. after the steer is typed and before
  # Enter is read back.
  send_steer lossmate 'rebase onto main and re-run the gate~' || rc=$?

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
  ! grep -F 'rebase onto main' "$LOSS_LOG" >/dev/null || fail \
    "the steer was submitted into the pane after its agent exited: $(cat "$LOSS_LOG")"
  case "$SEND_OUT" in
    *agent-lost*) ;;
    *) fail "the refusal did not name the lost agent: $SEND_OUT" ;;
  esac

  pass "an agent that exits to a shell mid-send is never reported as having received the steer"
}

test_shell_pane_steer_is_refused
test_agent_pane_steer_is_delivered
test_agent_lost_during_send_is_not_reported_delivered

echo "all fm-send shell-pane refusal tests passed"
