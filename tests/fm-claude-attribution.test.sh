#!/usr/bin/env bash
# tests/fm-claude-attribution.test.sh - the claude spawn must launch its worker
# with commit and PR attribution suppressed.
#
# AGENTS.md section 1 forbids an agent name as a commit co-author, but claude
# states the opposite in its own Bash tool description ("End git commit messages
# with: Co-Authored-By: ..."). That instruction outranks a brief, a project
# AGENTS.md and the captain's global memory, so the only reliable control is a
# launch-time setting. fm-spawn passes it with --settings.
#
# These are the PORTABLE regressions: they run the real fm-spawn.sh against a
# fake tmux and a fake claude, with no harness installed and no credentials, so
# CI enforces them everywhere. They pin what fm-spawn can be held to on its own:
#   1. The launch it sends carries attribution settings that suppress the commit
#      trailer, the PR footer and the session URL.
#   2. Those settings survive shell quoting: evaluating the launch line reaches
#      claude's argv as --settings plus ONE well-formed JSON argument.
#   3. The suppression is ADDITIONAL settings, so the per-worktree
#      .claude/settings.local.json carrying the busy-state hooks still applies.
#   4. Only claude is fitted with it - no other adapter is handed a claude flag.
#
# Whether the installed claude still BINDS that settings key is a harness fact no
# fake can answer; tests/fm-claude-attribution-live-e2e.test.sh is its live guard
# and docs/verification/runtime-backends.md records the dated result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-attribution)

# Fake tmux: answers the pane-path query and logs each `send-keys` payload, one
# per line, so the launch command line is observable without a real pane. The
# fake claude alongside it dumps its own argv, which is what turns the logged
# launch TEXT into the argv a real shell would build from it.
make_spawn_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) continue ;;
          Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_FAKE_ARGV_LOG:-}" ]; then
  for a in "$@"; do printf '%s\n' "$a" >> "$FM_FAKE_ARGV_LOG"; done
fi
exit 0
SH
  chmod +x "$fakebin/claude"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {  # <name> [harness]
  local name=$1 harness=${2:-claude} case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  id=$name-z1
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog|$id|$case_dir"
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG CASE_ID CASE_DIR <<FMREC
$1
FMREC
}

run_spawn() {  # <home> <wt> <fakebin> <launchlog> <spawn args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  env -u FM_TRACE_CONTEXT \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode no-mistakes --yolo off 2>&1
}

# The launch command is the LAST payload the spawn sends: every preparatory
# export is typed into the pane before it. Selecting by position rather than by
# matching a harness name keeps this helper from being fooled by a fixture path
# that happens to contain one.
launch_line() {  # <launchlog>
  grep -v '^[[:space:]]*$' -- "$1" 2>/dev/null | tail -n 1
}

# Evaluate the launch line against the fake claude and return its argv, one
# argument per line. This is what proves the settings JSON survives the shell as
# a single argument rather than splitting on its spaces or losing its quotes.
launch_argv() {  # <launch-line> <fakebin> <workdir>
  local line=$1 fakebin=$2 workdir=$3 argv_log
  argv_log="$workdir/argv.log"
  : > "$argv_log"
  (
    cd "$workdir" || exit 1
    PATH="$fakebin:$PATH" FM_FAKE_ARGV_LOG="$argv_log" \
      bash -c "$line" >/dev/null 2>&1
  ) || true
  cat "$argv_log"
}

# --- 1. the launch carries suppressing attribution settings -----------------

test_claude_launch_suppresses_attribution() {
  local rec out line settings
  rec=$(make_spawn_case claudeattr)
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" "$PROJ_DIR") || fail "spawn failed: $out"

  line=$(launch_line "$LAUNCH_LOG")
  [ -n "$line" ] || fail "no launch command was sent"
  case "$line" in
    *--settings*) ;;
    *) fail "the claude launch carries no --settings: $(cat "$LAUNCH_LOG")" ;;
  esac

  settings=$(launch_argv "$line" "$FAKEBIN_DIR" "$CASE_DIR" \
    | awk '$0 == "--settings" { getline; print; exit }')
  [ -n "$settings" ] || fail "--settings did not reach claude's argv with a value"

  # One well-formed JSON argument, not a shell-split fragment.
  printf '%s' "$settings" | python3 -c '
import json, sys
s = json.load(sys.stdin)
a = s.get("attribution")
assert isinstance(a, dict), "attribution is not an object: %r" % (s,)
assert a.get("commit") == "", "commit attribution is not empty: %r" % (a,)
assert a.get("pr") == "", "pr attribution is not empty: %r" % (a,)
assert a.get("sessionUrl") is False, "sessionUrl is not disabled: %r" % (a,)
' || fail "the settings claude receives do not suppress attribution: $settings"

  pass "the claude launch reaches claude's argv with one well-formed --settings JSON suppressing commit, PR and session-URL attribution"
}

# --- 2. the busy-state hook settings still apply ----------------------------
#
# --settings loads ADDITIONAL settings. If it were ever swapped for a form that
# REPLACES them, the per-worktree .claude/settings.local.json carrying the
# UserPromptSubmit/Stop/StopFailure/SessionEnd hooks would stop being the local
# settings source and the semantic busy-state contract would go dark with no
# other test noticing.

test_worktree_hook_settings_still_written() {
  local rec out local_settings
  rec=$(make_spawn_case claudehooks)
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" "$PROJ_DIR") || fail "spawn failed: $out"

  local_settings="$WT_DIR/.claude/settings.local.json"
  [ -f "$local_settings" ] || fail "the worktree settings file was not written"
  python3 - "$local_settings" <<'PY' || fail "the worktree hook settings are not intact"
import json, sys
s = json.load(open(sys.argv[1]))
hooks = s.get("hooks") or {}
for event in ("UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"):
    assert event in hooks, "%s hook is missing: %r" % (event, sorted(hooks))
PY
  pass "the per-worktree busy-state hook settings are still written alongside the launch-time attribution suppression"
}

# --- 3. the suppression is fitted to claude only ----------------------------

test_other_adapters_get_no_claude_settings_flag() {
  local rec out line
  rec=$(make_spawn_case opencodeattr opencode)
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" "$PROJ_DIR") || fail "spawn failed: $out"

  line=$(launch_line "$LAUNCH_LOG")
  [ -n "$line" ] || fail "no launch command was sent"
  case "$line" in
    *opencode*) ;;
    *) fail "the opencode case did not launch opencode: $line" ;;
  esac
  case "$line" in
    *'"attribution"'*) fail "a non-claude adapter was handed claude's attribution settings: $line" ;;
  esac
  pass "a non-claude adapter is launched without claude's attribution settings"
}

test_claude_launch_suppresses_attribution
test_worktree_hook_settings_still_written
test_other_adapters_get_no_claude_settings_flag

echo "# all fm-claude-attribution tests passed"
