#!/usr/bin/env bash
set -u
LIB=$1; LABEL=$2
ROOT=/Users/muhammadzahmed/.no-mistakes/worktrees/c3eda0adcf59/01M39QN1ZKE64VD0TWCB885DZX
CAP=$ROOT/tests/captures/claude-titled-composer-rule
. "$LIB"
CAPS_STYLED=$'styled=1\ncursor=0\nidentity=1\nrows=20'
CAPS_PLAIN=$'styled=0\ncursor=0\nidentity=0\nrows=20'
idle=$(printf 'claude\tidle')
with_row() { local screen=$1 n=$2 text=$3 line i=0 out=''; while IFS= read -r line; do [ "$i" -eq "$n" ] && line=$text; out="$out$line"$'\n'; i=$((i+1)); done <<<"$screen"; printf '%s' "$out"; }
named=$(cat "$CAP/tmux-named-idle.ansi")
rule() { printf '%*s' "$1" '' | tr ' ' '─'; }
echo "=== $LABEL ==="
printf '%-9s %-11s %-9s %s\n' COLS TITLE_LEN LEAD_RULE VERDICT_herdr/cmux
for spec in "120 50" "120 60" "120 80" "80 30" "80 38" "60 22" "60 34"; do
  set -- $spec; cols=$1; tl=$2
  title=$(printf 'n%.0s' $(seq 1 "$tl"))
  lead=$((cols - tl - 4)); [ $lead -lt 1 ] && lead=1
  top="$(rule "$lead") $title ─"
  s=$(with_row "$named" 15 "$top")
  printf '%-9s %-11s %-9s %s / %s\n' "$cols" "$tl" "$lead" "$(fm_composer_classify_screen "$CAPS_STYLED" "$s" '' "$idle")" "$(fm_composer_classify_screen "$CAPS_PLAIN" "$s")"
done
# name so long that <8 leading rule glyphs remain: must stay unknown by design
top="$(rule 5) $(printf 'n%.0s' $(seq 1 110)) ─"
s=$(with_row "$named" 15 "$top")
printf '%-9s %-11s %-9s %s / %s   (fewer than 8 leading glyphs: stays unknown by design)\n' 120 110 5 "$(fm_composer_classify_screen "$CAPS_STYLED" "$s" '' "$idle")" "$(fm_composer_classify_screen "$CAPS_PLAIN" "$s")"
