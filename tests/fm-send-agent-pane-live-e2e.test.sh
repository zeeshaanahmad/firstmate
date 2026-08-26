#!/usr/bin/env bash
# tests/fm-send-agent-pane-live-e2e.test.sh - opt-in guard proving the tmux
# submit path's agent corroboration behaves correctly against every INSTALLED
# harness, in both directions:
#
#   - a genuinely live agent pane is never refused by the corroboration, so a
#     real steer still reaches a real worker, and
#   - once that harness has exited and left a shell in the pane, the same steer
#     is refused instead of being typed into the shell and reported delivered.
#
# Why this file exists: the corroboration reads the pane's foreground-process
# identity (bin/backends/tmux.sh), which is a surface each harness vendor
# controls and changes without notice - Claude Code already began reporting its
# version string as its process name once. A harness that stops being
# attributable would start reading `dead` and every steer to it would be
# refused, which a stubbed agent can never reveal. The portable counterpart,
# tests/fm-send-shell-pane-refusal.test.sh, pins the logic in CI with real
# processes but no harness.
#
# Standard CI has no harness binaries or credentials, so this real-harness guard
# is opt-in and on-demand. Run it after any harness upgrade and before trusting
# refreshed per-harness evidence in
# docs/verification/runtime-backends.md "Shell panes under an acting caller".
#
# Unlike the liveness drift guard, this one does submit one short message to
# each installed harness, because the acting path it guards is the submit
# itself. That is a small, deliberate token cost per installed harness.
set -u

if [ "${FM_SEND_AGENT_PANE_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_SEND_AGENT_PANE_LIVE=1 to run the installed-harness steer corroboration guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || fail "tmux not found"
BASH_BIN=$(command -v bash) || fail "bash not found"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-send-agent-pane-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-send-agent-pane.XXXXXX")
SESSION=steer

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
  fm_test_cleanup
}
trap cleanup_all EXIT

mkdir -p "$LAB/shim" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "$ROOT/bin/fm-cursor-lib.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$LAB/wt" -x 200 -y 50 \
  || fail "could not start the private tmux server"

# Each probe steer carries a marker no harness would print on its own. The two
# markers differ because the live steer legitimately stays in the pane's
# scrollback after the harness exits, so only a marker that has never been
# delivered can prove the refused steer was not typed.
PROBE_LIVE="reply with the single word ok (fm-live-marker-$$)"
MARKER_REFUSED="fm-refused-marker-$$"
PROBE_REFUSED="reply with the single word ok ($MARKER_REFUSED)"

# The pane's foreground process group, which is the harness while it runs and
# the hosting shell once it exits.
foreground_pgid() {  # <target>
  local target=$1 tty
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 1
  case "$tty" in /dev/*) ;; *) return 1 ;; esac
  LC_ALL=C ps -t "${tty#/dev/}" -o pgid=,tpgid= 2>/dev/null \
    | while read -r pgid tpgid; do
        [ -n "$tpgid" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        printf '%s\n' "$pgid"
        break
      done
}

# Any process on the pane's tty whose name or argv[0] carries the launched
# binary, foreground or not. It is what separates "the harness exited" (nothing
# left to steer, so this guard cannot observe its subject) from "the harness is
# still running but no longer owns the terminal" (a real misclassification that
# would refuse every steer to it).
harness_still_on_tty() {  # <target> <bin-path>
  local target=$1 base tty ps_out pid comm args
  base=$(basename -- "$2")
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 1
  case "$tty" in /dev/*) ;; *) return 1 ;; esac
  ps_out=$(LC_ALL=C ps -t "${tty#/dev/}" -o pid=,comm=,args= 2>/dev/null)
  while IFS= read -r pid comm args; do
    [ -n "$pid" ] || continue
    case "$comm" in *"$base"*) return 0 ;; esac
    case "$args" in *"$base"*) return 0 ;; esac
  done <<EOF
$ps_out
EOF
  return 1
}

wait_for_composer() {  # <target> <wanted> <polls>
  local target=$1 wanted=$2 budget=$3 i=0 verdict=
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_backend_composer_state tmux "$target")
    [ "$verdict" = "$wanted" ] && { printf '%s' "$verdict"; return 0; }
    sleep 0.2
    i=$((i + 1))
  done
  printf '%s' "$verdict"
  return 1
}

wait_for_state() {  # <target> <wanted> <deciseconds>
  local target=$1 wanted=$2 budget=$3 i=0 state=
  while [ "$i" -lt "$budget" ]; do
    state=$(fm_backend_pane_agent_state tmux "$target")
    [ "$state" = "$wanted" ] && { printf '%s' "$state"; return 0; }
    sleep 0.2
    i=$((i + 1))
  done
  printf '%s' "$state"
  return 1
}

CHECKED=0
SKIPPED=

# The verified adapters, in the order .agents/skills/harness-adapters/SKILL.md
# records them. An adapter that gains a verified launch path belongs here too.
for harness in claude codex opencode pi pi-signed grok kimi cursor muse; do
  if ! bin_path=$(fm_test_resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its steer path is unverified here"
    continue
  fi

  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"

  # The harness runs as a JOB of an interactive shell, not as the pane command,
  # so the pane survives its exit exactly the way a real crewmate pane does
  # when its agent quits - which is the state this guard exists for. That
  # shell's prompt is starship's default prompt character, which is what makes
  # the abandoned pane dangerous rather than merely idle: it is byte-identical
  # to claude's empty-composer glyph, so the pane renders as a cleared composer
  # and the rendered verdict alone would confirm a steer nobody received.
  target="$SESSION:$harness"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$harness" -c "$LAB/wt" \
    -e 'PS1=❯ ' -- "$BASH_BIN" --norc -i \
    || fail "$harness ($version): could not launch a window for the steer probe"
  launch_args=""
  # cursor blocks on a workspace-trust prompt in a directory it has never seen;
  # --trust is the same flag fm-spawn passes for the same reason.
  [ "$harness" = cursor ] && launch_args=" --trust"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" "'$bin_path'$launch_args" Enter

  state=$(wait_for_state "$target" alive 300) || fail \
    "$harness ($version): the harness never became a live agent pane (last state '$state'); tests/fm-harness-liveness-drift-live-e2e.test.sh owns that signal"

  # A harness that starts and immediately quits (an unsupported launch flag, a
  # failed update check) leaves nothing to steer, so this guard cannot observe
  # its subject at all. That is reported as unverified, exactly like an absent
  # harness, rather than passing or being blamed on the classifier.
  sleep 2
  if [ "$(fm_backend_pane_agent_state tmux "$target")" != alive ] \
    && ! harness_still_on_tty "$target" "$bin_path"; then
    SKIPPED="$SKIPPED $harness"
    note "UNVERIFIED: $harness ($version) exited immediately after launch, so its steer path could not be exercised. Pane tail: $("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$target" | grep -v '^ *$' | tail -3 | tr '\n' '|')"
    continue
  fi

  # DIRECTION 1: the corroboration must not stand between a real steer and a
  # real agent. Any composer verdict is acceptable here - an unauthenticated or
  # slow harness may legitimately leave the submit unconfirmed - but the two
  # refusals are not, because they claim no agent owns this pane.
  verdict=$(fm_backend_send_text_submit tmux "$target" "$PROBE_LIVE" 3 0.5 0.3)
  case "$verdict" in
    no-agent|agent-lost)
      harness_still_on_tty "$target" "$bin_path" && fail \
        "$harness ($version): a live agent pane was refused as agent-free (verdict=$verdict, foreground=[$(fm_backend_tmux_foreground_comms "$target" | tr '\n' ' ')]). Every steer to this harness would now fail; teach bin/backends/tmux.sh's fm_backend_tmux_classify_process_name the identity this release reports."
      SKIPPED="$SKIPPED $harness"
      note "UNVERIFIED: $harness ($version) stopped running during the steer probe, so its live-pane behavior could not be exercised. Pane tail: $("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$target" | grep -v '^ *$' | tail -3 | tr '\n' '|')"
      continue
      ;;
  esac
  note "$harness $version: live-pane submit verdict=$verdict"

  # DIRECTION 2: the harness exits and the hosting shell takes the pane back.
  pgid=$(foreground_pgid "$target") || fail "$harness ($version): could not read the pane's foreground process group"
  [ -n "$pgid" ] || fail "$harness ($version): the pane reported no foreground process group"
  kill -TERM -"$pgid" 2>/dev/null || true
  if ! state=$(wait_for_state "$target" dead 100); then
    kill -KILL -"$pgid" 2>/dev/null || true
    state=$(wait_for_state "$target" dead 100) || fail \
      "$harness ($version): the pane never returned to its hosting shell after the harness was stopped (last state '$state')"
  fi

  # Clear the harness's leftover TUI residue, which is incidental to the state
  # under test (a version banner or a half-drawn dialog can leave the pane
  # unclassifiable for reasons that have nothing to do with who owns it) and
  # would make the divergence below depend on what the harness last drew.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" ' clear' Enter
  "$REAL_TMUX" -L "$SOCKET" clear-history -t "$target" 2>/dev/null || true

  # The divergence this guard turns on, asserted so the refusal below cannot
  # pass vacuously: the abandoned pane renders as a proven-empty agent
  # composer, which is exactly what the rendered verdict alone would confirm a
  # steer against.
  composer=$(wait_for_composer "$target" empty 50)
  [ "$composer" = empty ] || fail \
    "$harness ($version): the abandoned pane no longer renders as an empty composer (got '$composer'), so the refusal below would prove nothing - re-derive what still makes shape-only proof unsafe before weakening it"

  verdict=$(fm_backend_send_text_submit tmux "$target" "$PROBE_REFUSED" 2 0.3 0.2)
  [ "$verdict" = no-agent ] || fail \
    "$harness ($version): a steer into the pane's own shell was not refused (verdict=$verdict, composer=$composer, foreground=[$(fm_backend_tmux_foreground_comms "$target" | tr '\n' ' ')])"
  pane=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$target" -S -50 2>/dev/null || true)
  case "$pane" in
    *"$MARKER_REFUSED"*) fail "$harness ($version): the steer was typed into the pane's shell after the harness exited" ;;
  esac

  pass "steer corroboration: $harness $version delivers while live and refuses once its pane is a shell"
  CHECKED=$((CHECKED + 1))
done

[ "$CHECKED" -gt 0 ] || fail \
  "no verified harness is installed here, so this run proved nothing; install at least one harness before trusting a pass"

if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed):$SKIPPED"
fi
note "checked $CHECKED installed harness(es)"

cleanup_all
trap - EXIT
