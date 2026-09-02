#!/usr/bin/env bash
# Opt-in credentialed Claude live guard for commit/PR attribution suppression.
#
# fm-spawn launches every claude worker with attribution text set empty, because
# claude states the co-author trailer in its OWN Bash tool description and no
# brief, project AGENTS.md or captain memory can remove an instruction from
# there. Whether that settings key still exists, is still spelled this way, and
# still means what it meant is a fact the vendor owns: a stub can only confirm
# the assumption already written into the stub. So this guard drives the real
# installed claude and reads real git output.
#
# Two arms, differing ONLY in the attribution text, so the difference between
# them is the assertion:
#   1. BOUND - attribution.commit set to a unique probe trailer. The commit the
#      worker makes must carry that probe. This is what proves the key is still
#      live in the installed build: only a harness that reads attribution.commit
#      and appends it could put a nonce this test invented into a commit message.
#      If claude renames or drops the key, this arm goes quiet and fails, naming
#      the harness and version, instead of arm 2 passing for the wrong reason.
#   2. SUPPRESSED - the shipped value, empty commit and pr text plus sessionUrl
#      off. The commit must carry no agent co-author trailer, no session URL,
#      and none of arm 1's probe.
#
# Arm 1 is deliberately NOT the real co-author trailer: a neutral probe string
# cannot collide with an operator's own "never sign commits" memory, so the arm
# that must produce output is the one nothing else is arguing against.
#
# The project and config are isolated; claude keeps using its existing managed
# authentication. No live fleet home, worktree, or session is touched.
# Record the dated result in docs/verification/runtime-backends.md.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

if [ "${FM_CLAUDE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_LIVE_E2E=1 to run the Claude attribution guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh" || exit 1

CLAUDE_BIN=$(fm_test_resolve_harness_binary claude) \
  || fail "claude not found: this guard must exercise the installed harness, and reporting a pass without one would check nothing"
CLAUDE_VERSION=$("$CLAUDE_BIN" --version 2>&1 | head -1)

LAB=$(fm_test_tmproot fm-claude-attribution-live)
PROBE="X-Fm-Attribution-Probe-$$-$RANDOM"

# One arm: a fresh repo, the given attribution settings, and a real worker asked
# to commit. The resulting commit message is left in ARM_MESSAGE.
#
# Deliberately NOT a command substitution: `fail` exits, and inside `$(...)` it
# would exit only the subshell, leaving the caller to read an empty message. An
# arm whose worker never committed would then sail through "contains no
# trailer" and report a pass having measured nothing.
ARM_MESSAGE=
run_arm() {  # <name> <attribution-json>
  local name=$1 settings=$2 repo="$LAB/$1" out
  ARM_MESSAGE=
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name 'Firstmate Tests'
  git -C "$repo" config user.email 'tests@example.invalid'
  printf 'arm %s\n' "$name" > "$repo/file.txt"
  if ! out=$(cd "$repo" && "$CLAUDE_BIN" -p --dangerously-skip-permissions \
    --settings "$settings" \
    'Stage file.txt and create one git commit whose subject line is exactly "test: attribution guard". Then stop.' \
    < /dev/null 2>&1); then
    printf '%s\n' "$out" >&2
    fail "claude $CLAUDE_VERSION: the $name arm's worker exited non-zero"
  fi
  if ! ARM_MESSAGE=$(git -C "$repo" log -1 --format=%B 2>/dev/null) \
    || [ -z "${ARM_MESSAGE//[[:space:]]/}" ]; then
    printf '%s\n' "$out" >&2
    fail "claude $CLAUDE_VERSION: the $name arm's worker left no commit message, so this guard measured nothing"
  fi
}

# --- arm 1: the settings key is still bound ---------------------------------

test_attribution_key_is_still_bound() {
  local msg
  run_arm bound "{\"attribution\":{\"commit\":\"$PROBE: bound\"}}"
  msg=$ARM_MESSAGE
  case "$msg" in
    *"$PROBE"*) ;;
    *) fail "claude $CLAUDE_VERSION no longer applies attribution.commit: a commit made with that text set to '$PROBE: bound' does not contain it, so fm-spawn's suppression is being silently ignored and every worker is free to sign its commits again. Re-check the installed build's settings schema and update bin/fm-spawn.sh's claude launch. Commit message was: $msg" ;;
  esac
  pass "claude $CLAUDE_VERSION still binds attribution.commit and applies it to a real commit"
}

# --- arm 2: the shipped value suppresses ------------------------------------

test_shipped_settings_suppress_attribution() {
  local msg
  run_arm suppressed '{"attribution":{"commit":"","pr":"","sessionUrl":false}}'
  msg=$ARM_MESSAGE
  case "$msg" in
    *Co-Authored-By:*|*Co-authored-by:*)
      fail "claude $CLAUDE_VERSION: a worker launched with attribution suppressed still produced a co-author trailer, which AGENTS.md section 1 forbids. Commit message was: $msg" ;;
  esac
  case "$msg" in
    *Claude-Session:*|*claude.ai/code/session*)
      fail "claude $CLAUDE_VERSION: a worker launched with sessionUrl off still produced a session URL. Commit message was: $msg" ;;
  esac
  case "$msg" in
    *"$PROBE"*)
      fail "claude $CLAUDE_VERSION: the suppressed arm leaked the bound arm's probe, so the two arms are not isolated and neither result can be trusted" ;;
  esac
  pass "claude $CLAUDE_VERSION applies empty attribution as no trailer: a real commit carries no agent co-author and no session URL"
}

test_attribution_key_is_still_bound
test_shipped_settings_suppress_attribution

echo "# all fm-claude-attribution-live-e2e tests passed (claude $CLAUDE_VERSION)"
