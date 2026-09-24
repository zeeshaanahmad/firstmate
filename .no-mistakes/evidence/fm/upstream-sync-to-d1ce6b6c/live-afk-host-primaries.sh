#!/usr/bin/env bash
# Live drive of the merged "/afk on a supervision-host primary" behavior
# (upstream #5503): the REAL bin/fm-afk-launch.sh CLI (enter/start/stop) and the
# REAL bin/fm-afk-contract.sh against a REAL tmux server. Isolation: private
# TMUX_TMPDIR, lab homes under /tmp, a sleeper standing in for the away daemon
# (the launcher's documented FM_AFK_LAUNCH_ENTRY seam), and the primary harness
# pinned through fm-harness.sh's documented supervision-branch pin. No model is
# contacted and nothing outside the lab is touched.
set -u
ROOT=${1:?worktree root}
LAB=$(mktemp -d /tmp/fm-live-afk.XXXXXX)
export TMUX_TMPDIR="$LAB/tmuxdir"
mkdir -p "$TMUX_TMPDIR"
unset TMUX
cleanup() { tmux kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT

printf '#!/usr/bin/env bash\nexec sleep 600\n' > "$LAB/sleeper.sh"; chmod +x "$LAB/sleeper.sh"
tmux new-session -d -s captain -x 120 -y 40 || { echo "tmux failed"; exit 1; }
CAP_PANE=$(tmux display-message -p -t captain '#{pane_id}')
LAUNCH="$ROOT/bin/fm-afk-launch.sh"

# afk <home> <harness> <args...>: one CLI call as that primary.
afk() {
  local home=$1 harness=$2; shift 2
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_ROOT_OVERRIDE="$ROOT" TMUX_TMPDIR="$TMUX_TMPDIR" \
    FM_SUPERVISION_ACTOR=branch FM_SUPERVISION_PRIMARY_HARNESS="$harness" \
    FM_SUPERVISOR_TARGET="$CAP_PANE" FM_SUPERVISOR_BACKEND=tmux FM_AFK_LAUNCH_ENTRY="$LAB/sleeper.sh" \
    "$LAUNCH" "$@" 2>&1
}
new_home() { local h="$LAB/home-$1"; mkdir -p "$h/state" "$h/config" "$h/data"; printf '%s' "$h"; }
sessions() { tmux list-sessions -F '#S' | tr '\n' ' '; }

echo "captain session panes: $(tmux list-panes -t captain | wc -l | tr -d ' ')   sessions=[$(sessions)]"

echo
echo "=== A. opted-in home (config/supervision-host present), AWAY mode: no daemon on every host primary"
for h in claude cursor opencode omp grok codex; do
  home=$(new_home "A-$h"); : > "$home/config/supervision-host"; echo claude > "$home/config/supervision-host"
  afk "$home" "$h" enter >/dev/null; rc_enter=$?
  out=$(afk "$home" "$h" start); rc=$?
  rec=$([ -e "$home/state/.afk-daemon-terminal" ] && echo yes || echo no)
  posture=$([ -e "$home/state/.afk-contract" ] && echo recorded || echo MISSING)
  printf '%-9s enter rc=%s posture=%s | start rc=%s daemon-terminal-record=%s sessions=[%s]\n' "$h" "$rc_enter" "$posture" "$rc" "$rec" "$(sessions)"
  printf '          %s\n' "$(printf '%s' "$out" | grep -m1 'not launched\|no longer launched\|error' | cut -c1-200)"
  afk "$home" "$h" stop >/dev/null
done

echo
echo "=== B. same harnesses, home WITHOUT config/supervision-host: daemon still launched in its own detached tmux session, closed by exact id on stop"
for h in codex opencode; do
  home=$(new_home "B-$h")
  afk "$home" "$h" enter >/dev/null
  before=$(tmux list-panes -t captain | wc -l | tr -d ' ')
  afk "$home" "$h" start >/dev/null; rc=$?
  rec=$(cut -f2 "$home/state/.afk-daemon-terminal" 2>/dev/null || true)
  printf '%-9s start rc=%s record=%s has-session=%s captain-panes %s->%s\n' "$h" "$rc" "${rec:-<none>}" "$(tmux has-session -t "${rec:-nope}" 2>/dev/null && echo yes || echo no)" "$before" "$(tmux list-panes -t captain | wc -l | tr -d ' ')"
  afk "$home" "$h" stop >/dev/null
  printf '          after stop: session-gone=%s record-cleared=%s .afk-cleared=%s\n' "$(tmux has-session -t "${rec:-nope}" 2>/dev/null && echo NO || echo yes)" "$([ ! -e "$home/state/.afk-daemon-terminal" ] && echo yes || echo NO)" "$([ ! -e "$home/state/.afk" ] && echo yes || echo NO)"
done

echo
echo "=== C. adversarial: opted-in home, QUIET mode still launches the daemon; kimi (no arm owner) keeps the daemon even opted in"
home=$(new_home "C-quiet"); echo claude > "$home/config/supervision-host"
afk "$home" codex enter >/dev/null
FM_AFK_MODE=quiet afk "$home" codex start >/dev/null; rc=$?
rec=$(cut -f2 "$home/state/.afk-daemon-terminal" 2>/dev/null || true)
printf 'codex opted-in QUIET: start rc=%s daemon session=%s (running: %s)\n' "$rc" "${rec:-<none>}" "$(tmux has-session -t "${rec:-nope}" 2>/dev/null && echo yes || echo no)"
afk "$home" codex stop >/dev/null
home=$(new_home "C-kimi"); echo claude > "$home/config/supervision-host"
afk "$home" kimi enter >/dev/null
afk "$home" kimi start >/dev/null; rc=$?
rec=$(cut -f2 "$home/state/.afk-daemon-terminal" 2>/dev/null || true)
printf 'kimi opted-in AWAY:  start rc=%s daemon session=%s (running: %s)\n' "$rc" "${rec:-<none>}" "$(tmux has-session -t "${rec:-nope}" 2>/dev/null && echo yes || echo no)"
afk "$home" kimi stop >/dev/null

echo
echo "=== D. enter says so when the host has no engine for the primary, and stays quiet otherwise"
home=$(new_home "D-noengine"); : > "$home/config/supervision-host"
printf 'cursor + empty config/supervision-host   -> %s\n' "$(afk "$home" cursor enter | grep -m1 'Supervision host' | cut -c1-190)"
afk "$home" cursor stop >/dev/null
home=$(new_home "D-engine"); echo claude > "$home/config/supervision-host"
printf 'cursor + "claude" engine named           -> [%s]\n' "$(afk "$home" cursor enter | grep -m1 'Supervision host')"
afk "$home" cursor stop >/dev/null
home=$(new_home "D-nofile")
printf 'cursor + no config/supervision-host       -> [%s]\n' "$(afk "$home" cursor enter | grep -m1 'Supervision host')"
afk "$home" cursor stop >/dev/null
echo
echo "sessions left at end: [$(sessions)] (only 'captain' expected)"
