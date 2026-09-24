#!/usr/bin/env bash
# The intent's one-variable bisection, replayed on the real supervisor (herdr) and worker (tmux) captures.
set -u
LIB=$1; LABEL=$2
ROOT=/Users/muhammadzahmed/.no-mistakes/worktrees/c3eda0adcf59/01M39QN1ZKE64VD0TWCB885DZX
CAP=$ROOT/tests/captures/claude-titled-composer-rule
. "$LIB"
CAPS_STYLED=$'styled=1\ncursor=0\nidentity=1\nrows=20'
idle=$(printf 'claude\tidle')
# replace zero-based row N with TEXT
with_row() { local screen=$1 n=$2 text=$3 line i=0 out=''; while IFS= read -r line; do [ "$i" -eq "$n" ] && line=$text; out="$out$line"$'\n'; i=$((i+1)); done <<<"$screen"; printf '%s' "$out"; }
v() { fm_composer_classify_screen "$CAPS_STYLED" "$1" '' "$idle"; }
echo "=== $LABEL ==="
sup=$(cat "$CAP/herdr-resumed-named-idle.ansi")
wrk=$(cat "$CAP/tmux-plain-idle.ansi")
plainrule=$(printf '%*s' 200 '' | tr ' ' '─')
printf '%-72s %s\n' "1a supervisor capture as-is (titled top rule)"               "$(v "$sup")"
printf '%-72s %s\n' "1b supervisor, title in TOP rule replaced by plain ─"         "$(v "$(with_row "$sup" 3 "$plainrule")")"
printf '%-72s %s\n' "2a worker capture as-is (plain rules)"                        "$(v "$wrk")"
printf '%-72s %s\n' "2b worker, single-char title 'x' inserted into TOP rule"      "$(v "$(with_row "$wrk" 15 "──────────────────────────────────────────────── x ─")")"
printf '%-72s %s\n' "3  worker, same title inserted into BOTTOM rule only"          "$(v "$(with_row "$wrk" 17 "──────────────────────────────────────────────── x ─")")"
