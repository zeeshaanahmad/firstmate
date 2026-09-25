#!/usr/bin/env bash
# Live driver: read a Claude-style composer pane through the REAL Herdr backend
# (bin/backends/herdr.sh -> fm_backend_herdr_composer_state) inside a throwaway
# fm-lab-* Herdr session provisioned only via bin/fm-herdr-lab.sh.
#
# Usage: drive-composer-herdr-lab.sh <repo-root> <label>
#   repo-root  tree whose bin/ is exercised (the change under test, or the base
#              commit extracted with `git archive` for the before/after contrast)
#
# Each case replays a composer shape into a real Herdr pane, then asks the
# backend for its verdict exactly as fm-send / the away injector do.
set -u

REPO=${1:?repo root}
LABEL=${2:?label}
LAB_HELPER="$REPO/bin/fm-herdr-lab.sh"
[ -x "$LAB_HELPER" ] || { echo "no lab helper at $LAB_HELPER" >&2; exit 1; }

# The change under test must use ITS OWN lab helper, but the tripwire/refuse
# logic is identical in both trees; both are the sole lifecycle owner.
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
export FM_GATE_REFUSE_BYPASS=1

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name "$LABEL")
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-composer-lab.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
SHAPES="$TMP_ROOT/shapes"
mkdir -p "$FAKEBIN" "$SHAPES"

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    echo "TEARDOWN FAILED for $SESSION" >&2
    rc=1
  else
    echo "teardown ok: $SESSION (default-session tripwire verified identical)"
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

# --- composer shapes (structure taken from real claude 2.1.281 captures: a `─`
# rule, `❯`+NBSP, a `─` rule, then footer rows) -------------------------------
cat > "$SHAPES/lib.sh" <<'EOF'
rule() { printf '\033[38;2;136;136;136m'; local i; for ((i = 0; i < $1; i++)); do printf '─'; done; }
footer() { printf '\033[39m  \033[38;2;153;153;153mHaiku 4.5\033[39m\n  \033[38;2;153;153;153m⏵ manual mode on · ↓ for agents\033[39m\n'; }
transcript() { printf 'assistant: earlier transcript row\n\n\n'; }
EOF
cat > "$SHAPES/plain-idle.sh" <<'EOF'
. "$(dirname "$0")/lib.sh"; clear; transcript
rule 60; printf '\033[39m\n'; printf '❯ \n'; rule 60; printf '\033[39m\n'; footer; sleep 900
EOF
cat > "$SHAPES/titled-idle.sh" <<'EOF'
. "$(dirname "$0")/lib.sh"; clear; transcript
rule 48; printf ' Fresh named ─\033[39m\n'; printf '❯ \n'; rule 60; printf '\033[39m\n'; footer; sleep 900
EOF
cat > "$SHAPES/titled-draft.sh" <<'EOF'
. "$(dirname "$0")/lib.sh"; clear; transcript
rule 48; printf ' Fresh named ─\033[39m\n'; printf '❯ draft text not sent\n'; rule 60; printf '\033[39m\n'; footer; sleep 900
EOF
# a long name eats the rule: fewer than 8 leading rule glyphs remain
cat > "$SHAPES/titled-longname.sh" <<'EOF'
. "$(dirname "$0")/lib.sh"; clear; transcript
rule 4; printf ' a-very-long-session-name-that-ate-the-rule-glyphs ─\033[39m\n'; printf '❯ \n'; rule 60; printf '\033[39m\n'; footer; sleep 900
EOF

"$LAB_HELPER" provision "$SESSION" || { echo "could not provision lab" >&2; exit 1; }
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$REPO/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$TMP_ROOT" --label fm-compose-lab --no-focus) \
  || { echo "workspace create failed" >&2; exit 1; }
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') || { echo "no pane id" >&2; exit 1; }
TARGET="$SESSION:$PANE"
echo "lab=$SESSION target=$TARGET repo=$REPO herdr=$(PATH="$ORIGINAL_PATH" herdr --version | head -1)"

show_case() { # <case> <expected>
  local name=$1 want=$2 verdict tail
  lab pane run "$PANE" "bash $SHAPES/$name.sh" >/dev/null || { echo "could not run shape $name" >&2; return 1; }
  local i=0
  while [ "$i" -lt 30 ]; do
    tail=$(lab pane read "$PANE" --source visible 2>/dev/null)
    case "$tail" in *"manual mode on"*) break ;; esac
    sleep 0.3; i=$((i + 1))
  done
  verdict=$(fm_backend_herdr_composer_state "$TARGET")
  printf '%-16s verdict=%-8s (expected %-8s) %s\n' "$name" "$verdict" "$want" "$([ "$verdict" = "$want" ] && echo MATCH || echo MISMATCH)"
  printf '%s\n' "$tail" | grep -v '^[[:space:]]*$' | tail -6 | sed 's/^/    | /'
  # stop the shape so the next case starts from a clean pane
  lab pane send-keys "$PANE" C-c >/dev/null 2>&1 || true
  sleep 0.5
  RESULTS="${RESULTS:-}${name}=${verdict};"
}

echo "== $LABEL =="
EXPECT_TITLED_IDLE=${EXPECT_TITLED_IDLE:-unknown}
EXPECT_TITLED_DRAFT=${EXPECT_TITLED_DRAFT:-unknown}
EXPECT_TITLED_LONG=${EXPECT_TITLED_LONG:-unknown}
show_case plain-idle empty
show_case titled-idle "$EXPECT_TITLED_IDLE"
show_case titled-draft "$EXPECT_TITLED_DRAFT"
show_case titled-longname "$EXPECT_TITLED_LONG"
echo "RESULTS: $RESULTS"
