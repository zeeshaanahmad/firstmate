#!/usr/bin/env bash
# Usage: classify-real-captures.sh <path-to-composer-lib.sh> <label>
# Reads the real tmux/herdr captures the way each backend adapter does and prints the verdict.
set -u
LIB=$1; LABEL=$2
ROOT=/Users/muhammadzahmed/.no-mistakes/worktrees/c3eda0adcf59/01M39QN1ZKE64VD0TWCB885DZX
CAP=$ROOT/tests/captures/claude-titled-composer-rule
# shellcheck source=/dev/null
. "$LIB"
CAPS_TMUX=$'styled=1\ncursor=1\nidentity=1\nrows=0'
CAPS_STYLED=$'styled=1\ncursor=0\nidentity=1\nrows=20'
CAPS_STYLED_NOID=$'styled=1\ncursor=0\nidentity=0\nrows=20'
CAPS_PLAIN=$'styled=0\ncursor=0\nidentity=0\nrows=20'
idle=$(printf 'claude\tidle')
row() { printf '%-30s %-22s %s\n' "$1" "$2" "$3"; }
echo "=== $LABEL ($LIB) ==="
printf '%-30s %-22s %s\n' CAPTURE ADAPTER VERDICT
for f in herdr-resumed-named-idle tmux-named-idle tmux-renamed-idle tmux-plain-idle tmux-named-draft; do
  s=$(cat "$CAP/$f.ansi")
  cur=''; case $f in tmux-*) cur=16;; esac
  row "$f" herdr        "$(fm_composer_classify_screen "$CAPS_STYLED" "$s" '' "$idle")"
  row "$f" zellij       "$(fm_composer_classify_screen "$CAPS_STYLED_NOID" "$s")"
  row "$f" cmux/orca    "$(fm_composer_classify_screen "$CAPS_PLAIN" "$s")"
  [ -n "$cur" ] && row "$f" tmux "$(fm_composer_classify_screen "$CAPS_TMUX" "$s" 16 probe-absent)"
done
echo "--- non-composer panes (must NOT read empty) ---"
s=$(cat "$CAP/tmux-exited-to-shell.ansi"); row tmux-exited-to-shell herdr "$(fm_composer_classify_screen "$CAPS_STYLED" "$s" '' probe-absent)"
s=$(cat "$CAP/tmux-shell-decorative-running.ansi"); row tmux-shell-decorative-running herdr "$(fm_composer_classify_screen "$CAPS_STYLED" "$s" '' probe-absent)"
s=$(cat "$CAP/tmux-shell-decorative-running.ansi"); row tmux-shell-decorative-running cmux/orca "$(fm_composer_classify_screen "$CAPS_PLAIN" "$s")"
echo "--- real composer under decorative titled separators in transcript (should read empty on the fix) ---"
s=$(cat "$CAP/tmux-named-decorative-scrollback.ansi"); row tmux-named-decorative-scrollback herdr "$(fm_composer_classify_screen "$CAPS_STYLED" "$s" '' probe-absent)"
