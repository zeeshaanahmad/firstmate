#!/usr/bin/env bash
# Live check: real Claude Code (named vs unnamed) in a private tmux server, read by the real adapters.
set -u
ROOT=/Users/muhammadzahmed/.no-mistakes/worktrees/c3eda0adcf59/01M39QN1ZKE64VD0TWCB885DZX
SCRATCH=$1
SOCKET="fm-titled-live-$$"
SHIM=$(mktemp -d "${TMPDIR:-/tmp}/fm-titled-shim.XXXXXX")
REAL_TMUX=$(command -v tmux)
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$SHIM/tmux"; chmod +x "$SHIM/tmux"
PATH="$SHIM:$PATH"
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$SHIM"; }
trap cleanup EXIT
. "$ROOT/bin/fm-tmux-lib.sh"     # real tmux adapter (fm_tmux_composer_state / _capture / _identity)
TARGET_LIB="$ROOT/bin/fm-composer-lib.sh"; BASE_LIB="$SCRATCH/base-composer-lib.sh"
CWD=/Users/muhammadzahmed/dev/firstmate    # a folder claude already trusts (no trust dialog)
"$REAL_TMUX" -L "$SOCKET" new-session -d -s live -x 220 -y 50 -c "$CWD"

wait_idle() {  # <target> -> waits for tmux-adapter verdict empty
  local i=0; while [ $i -lt 60 ]; do [ "$(fm_tmux_composer_state "$1")" = empty ] && return 0; i=$((i+1)); sleep 1; done; return 1
}
cursorless() {  # <lib> <target> : the read herdr/zellij/cmux/orca perform (no cursor)
  ( . "$1"; pane=$(fm_tmux_composer_capture "$2"); caps=$(printf 'styled=1\ncursor=0\nidentity=1\nrows=0')
    v=$(fm_composer_classify_screen "$caps" "$pane"); if [ "$v" = need-identity ]; then
      id=$(fm_tmux_composer_identity "$2") || id=; [ -n "$id" ] || id=probe-absent
      v=$(fm_composer_classify_screen "$caps" "$pane" '' "$id"); [ "$v" != need-identity ] || v=unknown; fi
    printf '%s' "$v" )
}
tmuxread() { ( . "$1"; fm_tmux_composer_state "$2" ); }
report() {  # <label> <target>
  printf '%-34s tmux-adapter(base)=%-8s tmux-adapter(fix)=%-8s cursorless(base)=%-8s cursorless(fix)=%s\n' "$1" \
    "$(tmuxread "$BASE_LIB" "$2")" "$(tmuxread "$TARGET_LIB" "$2")" "$(cursorless "$BASE_LIB" "$2")" "$(cursorless "$TARGET_LIB" "$2")"
}
launch() { "$REAL_TMUX" -L "$SOCKET" new-window -d -t live: -n "$1" -c "$CWD" -- "${@:2}"; }

launch plain claude
launch named claude --name 'fm composer title probe'
launch renamed-long claude --name 'Main Firstmate session: away supervision and captain relay'
for w in plain named renamed-long; do wait_idle "live:$w" || echo "WARN: $w never reached tmux-empty"; done
sleep 2
echo "### live verdicts on real Claude Code $(claude --version 2>/dev/null | head -1)"
report "plain (no name)" live:plain
report "--name 'fm composer title probe'" live:named
report "--name <60-char descriptive name>" live:renamed-long
# a draft typed (never submitted) under the titled rule: must never read empty
"$REAL_TMUX" -L "$SOCKET" send-keys -t live:named -l 'draft text not sent'; sleep 1
echo "### after typing an unsent draft into the named session"
report "named + unsent draft" live:named
# Show the actual panes
for w in named renamed-long; do
  echo; echo "### real pane, window $w (tmux capture-pane -p, non-blank rows)"
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "live:$w" | grep '[^[:space:]]' | tail -6 | sed 's/^/| /'
done
