#!/usr/bin/env bash
# tests/fm-liveness-source.test.sh - declared long-running external work as a
# liveness instrument (bin/fm-liveness-lib.sh, bin/fm-liveness-register.sh) and
# the wedge verdict it changes in bin/fm-watch.sh.
#
# The regression these pin: a ship task in mode=no-mistakes hands its change to
# a validation pipeline running in a separate process, and the worker is then
# told to stop polling and wait. Its pane is quiet BY DESIGN, so pane quiet used
# to re-escalate a possible wedge every wedge grace while the pipeline was
# demonstrably editing files. The two halves must hold together:
#
#   false wedge - a quiet pane whose declared external work is alive must NOT be
#                 declared stale, for as long as that work keeps progressing;
#   real wedge  - the SAME task, with that work gone dead, must still be
#                 declared stale within the ordinary grace, never later.
#
# Everything here runs on real processes and real files with no harness: the
# registered source is a real script the watcher really executes, the watcher is
# a real subprocess, and the no-mistakes reads go through a fake `no-mistakes`
# on PATH so the TOON parse is exercised against the shape the real CLI emits.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-check-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-liveness-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
REGISTER="$ROOT/bin/fm-liveness-register.sh"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
# Source the daemon's pure functions once, exactly as tests/fm-daemon.test.sh
# does, so housekeeping()'s mirrored stale-recheck wiring can be driven
# directly here alongside the watcher fixture above.
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$DAEMON"
fi

TMP_ROOT=$(fm_test_tmproot fm-liveness-source-tests)

# Write <state>/<id>.liveness.sh with <body> and register it. The mode and the
# registration are both part of the contract, so this helper does exactly what a
# worker would do and nothing more.
install_source() {  # <state> <id> <body>
  local state=$1 id=$2 body=$3
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$state/$id.liveness.sh"
  chmod 0700 "$state/$id.liveness.sh"
  FM_STATE_OVERRIDE="$state" "$REGISTER" "$id" >/dev/null
}

# A fake `no-mistakes` whose `axi status` prints $FM_FAKE_NM_STATUS verbatim.
# Nothing else is answered, so an unexpected call fails loudly rather than
# returning a plausible empty answer.
make_fake_no_mistakes() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = axi ] && [ "${2:-}" = status ] || exit 2
printf '%s\n' "${FM_FAKE_NM_STATUS:-}"
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
}

# A real git worktree on a real branch, so run attribution is exercised against
# real commits rather than a stubbed comparison.
make_repo() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init --quiet -b main
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name t
  printf 'x\n' > "$dir/f"
  git -C "$dir" add f
  git -C "$dir" commit --quiet -m init
  git -C "$dir" checkout --quiet -b "$branch"
}

# --- duration and TOON parsing ---------------------------------------------

test_duration_parsing() {
  [ "$(fm_liveness_duration_secs 25s)" = 25 ] || fail "seconds token not parsed"
  [ "$(fm_liveness_duration_secs 12m41s)" = 761 ] || fail "minutes+seconds token not parsed"
  [ "$(fm_liveness_duration_secs 1h2m3s)" = 3723 ] || fail "hours+minutes+seconds token not parsed"
  [ "$(fm_liveness_duration_secs 2d)" = 172800 ] || fail "days token not parsed"
  ! fm_liveness_duration_secs 9 >/dev/null || fail "a bare number was accepted as a duration"
  ! fm_liveness_duration_secs "" >/dev/null || fail "an empty token was accepted as a duration"
  ! fm_liveness_duration_secs "25 seconds" >/dev/null || fail "prose was accepted as a duration"
  pass "fm_liveness_duration_secs parses compact duration tokens and rejects everything else"
}

# The column values must come from the NAMED column. last_activity is a quoted
# string containing commas and colons, and active_for right beside it is another
# duration, so a naive comma split would happily return the wrong duration and
# nothing downstream could tell.
test_active_step_field_parsing() {
  local inline multi out
  inline='  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}: review,fixing,12m41s,"25s ago: log: applying, fixing 3",91959,fix 1'
  out=$(printf '%s\n' "$inline" | fm_liveness_active_step_field last_activity)
  [ "$out" = '25s ago: log: applying, fixing 3' ] \
    || fail "inline single-row last_activity not extracted: $out"
  out=$(printf '%s\n' "$inline" | fm_liveness_active_step_field active_for)
  [ "$out" = '12m41s' ] || fail "column selection is not by name: $out"

  multi=$(printf '%s\n' \
    '  active_steps[2]{step,status,active_for,last_activity,agent_pid,round}:' \
    '    review,fixing,12m41s,"quiet 6m12s: no activity",91959,fix 1' \
    '    test,running,2m1s,"3s ago: log: go test ./...",91960,round 1' \
    'outcome: none')
  out=$(printf '%s\n' "$multi" | fm_liveness_active_step_field last_activity | tr '\n' '|')
  [ "$out" = 'quiet 6m12s: no activity|3s ago: log: go test ./...|' ] \
    || fail "multi-row last_activity not extracted: $out"

  out=$(printf '%s\n' '  active_steps[1]{step,status}: review,fixing' \
    | fm_liveness_active_step_field last_activity)
  [ -z "$out" ] || fail "a table without the column produced a value: $out"
  out=$(printf '%s\n' 'run:' '  status: fixing' | fm_liveness_active_step_field last_activity)
  [ -z "$out" ] || fail "output with no active_steps table produced a value: $out"
  # The run object carries its own `status:` key, and the executing-step rule
  # reads a column of the same name. A run with no active_steps table must yield
  # no step status at all, or that scalar would read as a step that is executing.
  out=$(printf '%s\n' 'run:' '  status: running' | fm_liveness_active_step_field status)
  [ -z "$out" ] || fail "the run's own status scalar was read as an active-step status: $out"

  # An embedded escaped quote followed later by an unescaped comma is the exact
  # shape that desynced the old naive quote toggle: the escaped quote must not
  # end the field, so the comma after it stays inside last_activity rather than
  # being misread as the boundary before agent_pid.
  local esc_quote esc_bslash
  esc_quote='  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}: review,fixing,12m41s,"25s ago: log: running \"go test ./...\" with args, retrying",91959,fix 1'
  out=$(printf '%s\n' "$esc_quote" | fm_liveness_active_step_field last_activity)
  [ "$out" = '25s ago: log: running "go test ./..." with args, retrying' ] \
    || fail "escaped-quote last_activity not recovered intact: $out"
  out=$(printf '%s\n' "$esc_quote" | fm_liveness_active_step_field active_for)
  [ "$out" = '12m41s' ] || fail "active_for beside an escaped-quote last_activity not selected: $out"

  esc_bslash='  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}: review,fixing,7m3s,"12s ago: log: path C:\\tools failed, retry",91959,fix 1'
  out=$(printf '%s\n' "$esc_bslash" | fm_liveness_active_step_field last_activity)
  [ "$out" = '12s ago: log: path C:\tools failed, retry' ] \
    || fail "escaped-backslash last_activity not recovered intact: $out"
  out=$(printf '%s\n' "$esc_bslash" | fm_liveness_active_step_field active_for)
  [ "$out" = '7m3s' ] || fail "active_for beside an escaped-backslash last_activity not selected: $out"

  pass "active_steps columns are selected by name with quote-aware, backslash-escape-aware splitting"
}

# --- registered per-task source --------------------------------------------

test_registered_source_answers() {
  local dir state
  dir="$TMP_ROOT/registered"; state="$dir/state"; mkdir -p "$state"

  install_source "$state" alive 'echo alive'
  [ "$(fm_liveness_registered_age "$state" alive)" = 0 ] \
    || fail "an alive source did not report zero age"

  install_source "$state" aged 'echo "age: 90"'
  [ "$(fm_liveness_registered_age "$state" aged)" = 90 ] \
    || fail "an age: source did not report its age"

  install_source "$state" quiet 'exit 0'
  ! fm_liveness_registered_age "$state" quiet >/dev/null \
    || fail "a silent source was read as an answer"

  install_source "$state" failing 'echo alive; exit 1'
  ! fm_liveness_registered_age "$state" failing >/dev/null \
    || fail "a non-zero exit was read as an answer"

  install_source "$state" garbage 'echo "definitely running"'
  ! fm_liveness_registered_age "$state" garbage >/dev/null \
    || fail "unrecognized output was read as an answer"

  install_source "$state" negative 'echo "age: -5"'
  ! fm_liveness_registered_age "$state" negative >/dev/null \
    || fail "a non-numeric age was read as an answer"

  ! fm_liveness_registered_age "$state" absent >/dev/null \
    || fail "a task with no source produced an answer"
  pass "a registered source answers only with alive or age: <seconds>, and fails to no answer otherwise"
}

# The source is arbitrary code the watcher executes, so it gets the same
# byte-binding proof as a custom check: unregistered bytes never run, and an
# edit after registration invalidates the binding.
test_registered_source_requires_binding() {
  local dir state
  dir="$TMP_ROOT/binding"; state="$dir/state"; mkdir -p "$state"

  printf '#!/usr/bin/env bash\necho alive\n' > "$state/loose.liveness.sh"
  chmod 0700 "$state/loose.liveness.sh"
  ! fm_liveness_registered_age "$state" loose >/dev/null \
    || fail "an unregistered source was executed"

  install_source "$state" edited 'echo alive'
  [ "$(fm_liveness_registered_age "$state" edited)" = 0 ] \
    || fail "the registered fixture did not answer before editing"
  printf '#!/usr/bin/env bash\necho alive\n# changed\n' > "$state/edited.liveness.sh"
  chmod 0700 "$state/edited.liveness.sh"
  ! fm_liveness_registered_age "$state" edited >/dev/null \
    || fail "a source edited after registration was still executed"

  printf '#!/usr/bin/env bash\necho alive\n' > "$state/loose2.liveness.sh"
  chmod 0755 "$state/loose2.liveness.sh"
  ! FM_STATE_OVERRIDE="$state" "$REGISTER" loose2 >/dev/null 2>&1 \
    || fail "registration accepted a world-readable source"
  [ ! -e "$state/loose2.liveness-trust" ] \
    || fail "a refused registration left a trust record"
  pass "a liveness source runs only from registered, unmodified, private bytes"
}

# A source that hangs must not hold the watcher: it is killed at the bound and
# read as no answer, which leaves the pane-based reading in force.
test_registered_source_is_time_bounded() {
  local dir state started elapsed
  dir="$TMP_ROOT/timeout"; state="$dir/state"; mkdir -p "$state"
  install_source "$state" slow 'sleep 30; echo alive'
  started=$(date +%s)
  ! FM_LIVENESS_TIMEOUT=1 fm_liveness_registered_age "$state" slow >/dev/null \
    || fail "a source that outran its bound still answered"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 15 ] || fail "the source bound was not enforced (waited ${elapsed}s)"
  pass "a hanging liveness source is killed at its bound and read as no answer"
}

# --- built-in no-mistakes validation-run source ----------------------------

nm_status_toon() {  # <branch> <head> <last_activity> [run_status] [step_status]
  printf 'run:\n  id: "01TEST"\n  branch: %s\n  status: %s\n  head: %s\n' "$1" "${4:-fixing}" "$2"
  printf '  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}: review,%s,12m41s,"%s",91959,fix 1\n' "${5:-fixing}" "$3"
}

# The same run object with caller-supplied active_steps rows, so a step other
# than the agent-driven `review` above can be exercised. Rows are passed already
# rendered, exactly as `axi status` prints them.
nm_status_toon_rows() {  # <branch> <head> <run_status> <row>...
  local branch=$1 head=$2 run_status=$3
  shift 3
  printf 'run:\n  id: "01TEST"\n  branch: %s\n  status: %s\n  head: %s\n' \
    "$branch" "$run_status" "$head"
  printf '  active_steps[%d]{step,status,active_for,last_activity,agent_pid,round}:\n' "$#"
  printf '    %s\n' "$@"
}

# The same output with the cached branch_sync block `axi status` appends when
# relevant. It repeats branch, status, and head at a deeper indent, so a reader
# that matches those keys at any depth can read a sibling value instead of the
# run's own - the fail-open direction this fixture pins shut.
nm_status_toon_with_sync() {  # <branch> <head> <last_activity> <run_status> <sync_status>
  nm_status_toon "$1" "$2" "$3" "$4"
  printf 'branch_sync:\n  next_action: none\n  pipeline:\n    branch: %s\n    status: %s\n    head: %s\n' \
    "$1" "$5" "$2"
}

# A real commit in a DIFFERENT repository, so it is guaranteed absent from the
# task worktree's object store. This is what an in-flight run's head really is:
# no-mistakes runs the pipeline in its own gate repo under ~/.no-mistakes/repos
# and does not push until the push step, so from the first auto-fix round until
# then `git rev-parse` in the crew worktree cannot resolve the reported head.
make_unpushed_pipeline_head() {  # <dir>
  local dir=$1
  make_repo "$dir" fm/gate
  printf 'pipeline fix\n' > "$dir/f"
  git -C "$dir" commit --quiet -am 'no-mistakes: apply review fixes'
  git -C "$dir" rev-parse HEAD
}

test_run_source_reads_its_own_run_activity() {
  local dir state wt head behind
  dir="$TMP_ROOT/run-source"; state="$dir/state"; mkdir -p "$state" "$dir/fakebin"
  make_fake_no_mistakes "$dir/fakebin"
  wt="$dir/wt"
  make_repo "$wt" fm/task
  # A second commit, so HEAD~1 is a real head this worktree can resolve but that
  # local work has already advanced past.
  printf 'local advance\n' > "$wt/f"
  git -C "$wt" commit --quiet -am 'local advance'
  head=$(git -C "$wt" rev-parse HEAD)
  behind=$(git -C "$wt" rev-parse HEAD~1)
  fm_write_meta "$state/task.meta" "window=t:fm-task" "worktree=$wt" "kind=ship" "mode=no-mistakes"

  export PATH="$dir/fakebin:$PATH"
  FM_FAKE_NM_STATUS=$(nm_status_toon fm/task "$head" "25s ago: log: applying")
  export FM_FAKE_NM_STATUS
  [ "$(fm_liveness_run_age "$state" task)" = 0 ] \
    || fail "an attributed run executing a step did not answer alive"

  # The activity-age fallback, on a run with nothing executing: it is the only
  # path that still parses last_activity, so its two shapes are pinned here.
  FM_FAKE_NM_STATUS=$(nm_status_toon fm/task "$head" "25s ago: log: applying" pending pending)
  [ "$(fm_liveness_run_age "$state" task)" = 25 ] \
    || fail "an attributed run's last_activity was not read"

  FM_FAKE_NM_STATUS=$(nm_status_toon fm/task "$head" "quiet 6m12s: no activity" pending pending)
  [ "$(fm_liveness_run_age "$state" task)" = 372 ] \
    || fail "a quiet-prefixed last_activity was not read"

  # Another branch's run must never suppress this task's wedge: axi status falls
  # back to displaying some other branch's run when this branch has none.
  FM_FAKE_NM_STATUS=$(nm_status_toon fm/other "$head" "1s ago: log: x")
  ! fm_liveness_run_age "$state" task >/dev/null \
    || fail "another branch's run was attributed to this task"

  # Same branch, resolvable head that local work has advanced past: the run is
  # validating superseded code, so it is not this code's run. An UNRESOLVABLE
  # head is a different case entirely and is covered by
  # test_run_source_reads_an_in_flight_pipeline_head below.
  FM_FAKE_NM_STATUS=$(nm_status_toon fm/task "$behind" "1s ago: log: x")
  ! fm_liveness_run_age "$state" task >/dev/null \
    || fail "a run behind this worktree's own head was attributed to this task"

  # A head that is not a commit-ish token at all cannot bind anything, so it must
  # never be read as the in-flight case below.
  FM_FAKE_NM_STATUS=$(nm_status_toon fm/task "not-a-sha" "1s ago: log: x")
  ! fm_liveness_run_age "$state" task >/dev/null \
    || fail "a non-commit head token was attributed to this task"

  FM_FAKE_NM_STATUS='run:
  id: "01TEST"
  branch: fm/task
  status: running'
  ! fm_liveness_run_age "$state" task >/dev/null \
    || fail "a run with no active_steps table produced an age"

  fm_write_meta "$state/task.meta" "window=t:fm-task" "worktree=$wt" "kind=ship" "mode=direct-PR"
  FM_FAKE_NM_STATUS=$(nm_status_toon fm/task "$head" "1s ago: log: x")
  ! fm_liveness_run_age "$state" task >/dev/null \
    || fail "a task whose recorded mode is not no-mistakes consulted the run"

  fm_write_meta "$state/scout.meta" "window=t:fm-scout" "worktree=$wt" "kind=scout"
  ! fm_liveness_run_age "$state" scout >/dev/null \
    || fail "a scout consulted the validation run"
  unset FM_FAKE_NM_STATUS
  pass "the built-in source reads only a run attributed to this task's branch and current code"
}

# THE REGRESSION THIS TASK EXISTS FOR. A no-mistakes run is documented as
# suppressing a wedge with no declaration at all, but it never did once the
# pipeline had made a single fix commit. no-mistakes runs the pipeline in its own
# gate repo and does not push until the push step, so from the first auto-fix
# round until then `axi status` reports a head the crew worktree cannot resolve.
# Requiring that head to resolve locally turned the overwhelmingly common case -
# a long review step with auto-fix rounds - into no answer, and the wedge
# escalator then fired every grace on provably healthy work.
#
# The two-lane cases below are the other half: the daemon reports the repo's
# active-or-most-recent run, not the invoking worktree's, so a lane with no run
# of its own is offered a sibling lane's activity. A single-lane fixture cannot
# tell a correctly-bound implementation from an unbound one.
test_run_source_reads_an_in_flight_pipeline_head() {
  local dir state wt local_head gate_head st
  dir="$TMP_ROOT/inflight"; state="$dir/state"; mkdir -p "$state" "$dir/fakebin"
  make_fake_no_mistakes "$dir/fakebin"
  wt="$dir/wt"
  make_repo "$wt" fm/task
  local_head=$(git -C "$wt" rev-parse HEAD)
  gate_head=$(make_unpushed_pipeline_head "$dir/gate")
  [ "$gate_head" != "$local_head" ] || fail "the fixture did not produce a distinct pipeline head"
  git -C "$wt" rev-parse --verify --quiet "${gate_head}^{commit}" >/dev/null 2>&1 \
    && fail "the fixture's pipeline head is resolvable in the task worktree, so it proves nothing"
  fm_write_meta "$state/task.meta" "window=t:fm-task" "worktree=$wt" "kind=ship" "mode=no-mistakes"
  export PATH="$dir/fakebin:$PATH"

  FM_FAKE_NM_STATUS=$(nm_status_toon fm/task "$gate_head" "25s ago: log: applying")
  export FM_FAKE_NM_STATUS
  [ "$(fm_liveness_run_age "$state" task)" = 0 ] \
    || fail "an in-flight run whose head is an unpushed pipeline commit did not answer"

  # TWO LANES, and this task has no run of its own. The sibling's activity must
  # never answer here, whether or not its head happens to resolve locally.
  FM_FAKE_NM_STATUS=$(nm_status_toon fm/other "$gate_head" "1s ago: log: x")
  ! fm_liveness_run_age "$state" task >/dev/null \
    || fail "a sibling lane's in-flight run answered for this task"
  FM_FAKE_NM_STATUS=$(nm_status_toon fm/other "$local_head" "1s ago: log: x")
  ! fm_liveness_run_age "$state" task >/dev/null \
    || fail "a sibling lane's run on a locally-known head answered for this task"

  # A run that has genuinely stopped is not evidence of liveness, however fresh
  # the activity rendered beside it. Prefer no claim over a wrong one.
  for st in completed failed cancelled aborted; do
    FM_FAKE_NM_STATUS=$(nm_status_toon fm/task "$gate_head" "1s ago: log: x" "$st")
    ! fm_liveness_run_age "$state" task >/dev/null \
      || fail "a $st run was read as evidence of liveness"
  done

  # branch_sync repeats branch, status, and head deeper in the same output. The
  # run's own terminal status must win over a nested `status: running`.
  FM_FAKE_NM_STATUS=$(nm_status_toon_with_sync fm/task "$gate_head" "1s ago: log: x" completed running)
  ! fm_liveness_run_age "$state" task >/dev/null \
    || fail "a nested branch_sync status was read as the run's own status"

  # ...and the run's own live status must still be read correctly when a nested
  # terminal one sits below it, so the anchoring is not just rejecting always.
  FM_FAKE_NM_STATUS=$(nm_status_toon_with_sync fm/task "$gate_head" "30s ago: log: x" running completed)
  [ "$(fm_liveness_run_age "$state" task)" = 0 ] \
    || fail "a live run was rejected because branch_sync carried a terminal status"

  unset FM_FAKE_NM_STATUS
  pass "an in-flight run answers on its own unpushed pipeline head, and no sibling lane, stopped run, or nested field ever does"
}

# THE RESIDUAL GAP THIS TASK EXISTS FOR, left behind by the fix above. That fix
# made an in-flight run answer at all; the answer it gave was derived from the
# active step's `last_activity`, which measures only whether that step chose to
# log recently. Two steps measured on 2026-08-19 defeat that:
#
#   ci   - no agent at all. It is the daemon watching the forge, and it emits one
#          heartbeat every few minutes, so its freshest evidence is already past
#          the wedge grace by the time supervision reads it.
#   test - a containerized gate. It logs one line when it starts and then nothing
#          at all until the container exits.
#
# Both are working perfectly while silent, and both escalated as a possible
# wedge, every grace, on every validating lane. The rows below are the shapes
# measured on those two runs.
SILENT_CI_ROW='ci,running,45m16s,"5m6s ago: log: CI checks running, waiting for results...","",starting'
SILENT_TEST_ROW='test,running,18m2s,"14m51s ago: log: ci/local/gate.sh starting",91960,round 1'
# The grace the watcher escalates at, matching run_wedge_watcher's own setting.
WEDGE_GRACE=240

# The age a row's own last_activity parses to, so a case can prove it is really
# past the grace rather than asserting into a fixture that quietly went fresh.
row_activity_age() {  # <toon-output>
  fm_liveness_duration_secs "$(printf '%s\n' "$1" \
    | fm_liveness_active_step_field last_activity \
    | grep -oE '^[0-9]+[dhms]([0-9]+[dhms])*' | head -1)"
}

test_run_source_answers_on_the_run_state_not_an_activity_age() {
  local dir state wt head toon age st
  dir="$TMP_ROOT/silent-step"; state="$dir/state"; mkdir -p "$state" "$dir/fakebin"
  make_fake_no_mistakes "$dir/fakebin"
  wt="$dir/wt"
  make_repo "$wt" fm/task
  head=$(git -C "$wt" rev-parse HEAD)
  fm_write_meta "$state/task.meta" "window=t:fm-task" "worktree=$wt" "kind=ship" "mode=no-mistakes"
  export PATH="$dir/fakebin:$PATH"
  export FM_FAKE_NM_STATUS

  # Neither case may go quietly vacuous: each row's own activity age must really
  # be past the grace, or "answers without an age" would prove nothing.
  for toon in "$SILENT_CI_ROW" "$SILENT_TEST_ROW"; do
    FM_FAKE_NM_STATUS=$(nm_status_toon_rows fm/task "$head" running "$toon")
    age=$(row_activity_age "$FM_FAKE_NM_STATUS")
    [ "$age" -gt "$WEDGE_GRACE" ] \
      || fail "row '$toon' parses to ${age}s, not past the ${WEDGE_GRACE}s grace, so this case proves nothing"
    [ "$(fm_liveness_run_age "$state" task)" = 0 ] \
      || fail "an executing but silent step did not answer alive on the run state: $toon"
  done

  # Not a special case for those two steps: ANY executing step answers, with the
  # staleness of its own log irrelevant either way.
  FM_FAKE_NM_STATUS=$(nm_status_toon_rows fm/task "$head" fixing \
    'review,fixing,12m41s,"quiet 9m2s: no activity",91959,fix 2')
  [ "$(fm_liveness_run_age "$state" task)" = 0 ] \
    || fail "a step no-mistakes had itself flagged quiet did not answer alive"

  # A run with NOTHING executing keeps the earlier reading: a dated activity age
  # still answers, so this rule only ever added an answer.
  FM_FAKE_NM_STATUS=$(nm_status_toon_rows fm/task "$head" pending \
    'review,pending,0s,"45s ago: log: queued",,round 1')
  [ "$(fm_liveness_run_age "$state" task)" = 45 ] \
    || fail "a run with no executing step lost its activity-age fallback"

  # THE CASE THAT MUST STILL SURFACE. A run parked at an approval or fix-review
  # gate is waiting on FIRSTMATE, so it is not alive however recently it logged.
  # If this ever answers, the rule has disarmed the alarm it was meant to keep
  # honest rather than fix.
  for st in awaiting_approval fix_review; do
    FM_FAKE_NM_STATUS=$(nm_status_toon_rows fm/task "$head" running \
      "review,$st,12m41s,\"3s ago: log: awaiting decision\",91959,fix 1")
    [ "$(fm_liveness_run_age "$state" task)" = 3 ] \
      || fail "a step parked at the $st gate was read as executing rather than falling back to its age"
    FM_FAKE_NM_STATUS=$(nm_status_toon_rows fm/task "$head" "$st" \
      "review,$st,12m41s,\"3s ago: log: awaiting decision\",91959,fix 1")
    ! fm_liveness_run_age "$state" task >/dev/null \
      || fail "a run parked at the $st gate answered as alive"
  done

  # A stopped run is not alive however busy its steps are rendered beside it.
  for st in completed failed cancelled aborted; do
    FM_FAKE_NM_STATUS=$(nm_status_toon_rows fm/task "$head" "$st" "$SILENT_CI_ROW")
    ! fm_liveness_run_age "$state" task >/dev/null \
      || fail "a $st run with an executing step was read as evidence of liveness"
  done

  # Attribution is unchanged: a sibling lane's executing step must not answer
  # here, or the rule would become a way around the branch match.
  FM_FAKE_NM_STATUS=$(nm_status_toon_rows fm/other "$head" running "$SILENT_CI_ROW")
  ! fm_liveness_run_age "$state" task >/dev/null \
    || fail "a sibling lane's executing step answered for this task"

  # An active_steps table with no status column loses only this rule; the
  # activity age keeps answering exactly as it did before.
  FM_FAKE_NM_STATUS=$(printf 'run:\n  id: "01TEST"\n  branch: fm/task\n  status: running\n  head: %s\n  active_steps[1]{step,active_for,last_activity}: ci,45m16s,"30s ago: log: x"\n' "$head")
  [ "$(fm_liveness_run_age "$state" task)" = 30 ] \
    || fail "dropping the status column broke the activity-age reading"

  unset FM_FAKE_NM_STATUS
  pass "an executing step answers alive on the run state whatever it last logged, and a stopped, parked, queued, or unattributed one never does"
}

# Each source speaks for different declared work, so any one of them showing
# recent progress answers; the freshest wins.
test_combined_answer_takes_the_freshest_source() {
  local dir state wt head
  dir="$TMP_ROOT/combined"; state="$dir/state"; mkdir -p "$state" "$dir/fakebin"
  make_fake_no_mistakes "$dir/fakebin"
  wt="$dir/wt"
  make_repo "$wt" fm/task
  head=$(git -C "$wt" rev-parse HEAD)
  fm_write_meta "$state/task.meta" "window=t:fm-task" "worktree=$wt" "kind=ship" "mode=no-mistakes"
  export PATH="$dir/fakebin:$PATH"
  # A run with nothing executing yet, so the run source reports an AGE and the
  # freshest-source comparison below has two ages to choose between. An executing
  # step answers 0, which no other source can beat, and is covered on its own in
  # test_run_source_answers_on_the_run_state_not_an_activity_age.
  FM_FAKE_NM_STATUS=$(nm_status_toon fm/task "$head" "5m ago: log: applying" pending pending)
  export FM_FAKE_NM_STATUS

  [ "$(fm_liveness_age "$state" task)" = 300 ] \
    || fail "the run source alone did not answer"
  install_source "$state" task 'echo "age: 12"'
  [ "$(fm_liveness_age "$state" task)" = 12 ] \
    || fail "the fresher registered source did not win"
  install_source "$state" task 'echo "age: 900"'
  [ "$(fm_liveness_age "$state" task)" = 300 ] \
    || fail "the fresher run source did not win"

  rm -f "$state/task.liveness.sh" "$state/task.liveness-trust"
  fm_write_meta "$state/task.meta" "window=t:fm-task" "worktree=$wt" "kind=ship" "mode=local-only"
  ! fm_liveness_age "$state" task >/dev/null \
    || fail "a task with no declared external work produced an answer"
  ! fm_liveness_age "$state" "" >/dev/null || fail "an empty task id produced an answer"
  unset FM_FAKE_NM_STATUS
  pass "fm_liveness_age takes the freshest answering source and reports no answer when none does"
}

# --- watcher verdict --------------------------------------------------------
#
# One fixture, three verdicts. Each case sets a provably-working crew on a quiet
# pane and backdates the wedge timer past the grace - the exact state that used
# to escalate - and differs ONLY in what the declared work reports.

WEDGE_DIR=; WEDGE_STATE=; WEDGE_FAKEBIN=; WEDGE_WINDOW=; WEDGE_KEY=; WEDGE_PID=
# The watcher's own demand-deep-inspection threshold, so the seeded count below
# is the loudest tier by construction rather than by a copied literal.
FM_WEDGE_DEMAND_INSPECT_COUNT_SEED=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}

make_wedge_case() {  # <name> - sets the WEDGE_* globals
  WEDGE_DIR=$(make_case "$1")
  WEDGE_STATE="$WEDGE_DIR/state"
  WEDGE_FAKEBIN="$WEDGE_DIR/fakebin"
  WEDGE_WINDOW="test:fm-quiet"
  WEDGE_KEY=$(printf '%s' "$WEDGE_WINDOW" | tr ':/.' '___')
  WEDGE_PID=
  printf 'idle building output' > "$WEDGE_DIR/pane.txt"
  fm_write_meta "$WEDGE_STATE/quiet.meta" "window=$WEDGE_WINDOW" "kind=ship" "mode=no-mistakes"
  printf 'working: handed to validation\n' > "$WEDGE_STATE/quiet.status"
  printf '%s' "$(seen_sig "$WEDGE_STATE/quiet.status")" > "$WEDGE_STATE/.seen-quiet_status"
  printf '%s' "$(hash_text 'idle building output')" > "$WEDGE_STATE/.hash-$WEDGE_KEY"
  printf '1\n' > "$WEDGE_STATE/.count-$WEDGE_KEY"
  # Already classified as a provably-working stale, with the wedge timer aged
  # past the grace: the very next poll decides escalate or defer.
  printf '%s' "$(hash_text 'idle building output')" > "$WEDGE_STATE/.stale-$WEDGE_KEY"
  echo $(( $(date +%s) - 500 )) > "$WEDGE_STATE/.stale-since-$WEDGE_KEY"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (fixing)'
}

# Start the watcher as a direct child of this shell, so wait/reap really own it.
run_wedge_watcher() {
  PATH="$WEDGE_FAKEBIN:$PATH" FM_FAKE_TMUX_WINDOW="$WEDGE_WINDOW" \
    FM_FAKE_TMUX_CAPTURE="$WEDGE_DIR/pane.txt" \
    FM_STATE_OVERRIDE="$WEDGE_STATE" FM_CREW_STATE_BIN="$WEDGE_FAKEBIN/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$WEDGE_DIR/watch.out" &
  WEDGE_PID=$!
}

# Never leave a watcher behind, however a case ends.
trap '[ -z "${WEDGE_PID:-}" ] || kill "$WEDGE_PID" 2>/dev/null; fm_test_cleanup' EXIT

# THE FALSE WEDGE. The pipeline agent reported activity seconds ago, so the
# quiet pane is a worker correctly waiting, not a wedge.
test_live_declared_work_is_not_declared_stale() {
  local anchor now anchor_baseline
  make_wedge_case liveness-false-wedge
  install_source "$WEDGE_STATE" quiet 'echo "age: 20"'
  # shellcheck disable=SC2034 # read inside the wait_absorbed predicate string below
  anchor_baseline=$(cat "$WEDGE_STATE/.stale-since-$WEDGE_KEY" 2>/dev/null || true)

  run_wedge_watcher
  # shellcheck disable=SC2016 # deliberately deferred: wait_absorbed evals this, not this shell
  if ! wait_absorbed "$WEDGE_PID" '[ "$(cat "$WEDGE_STATE/.stale-since-$WEDGE_KEY" 2>/dev/null || true)" != "$anchor_baseline" ]'; then
    reap "$WEDGE_PID"; fail "watcher escalated a wedge while declared external work was alive (watcher $(wait_fail_word)): $(cat "$WEDGE_DIR/watch.out")"
  fi
  [ ! -s "$WEDGE_DIR/watch.out" ] || { reap "$WEDGE_PID"; fail "live declared work still printed a wake reason: $(cat "$WEDGE_DIR/watch.out")"; }
  [ ! -s "$WEDGE_STATE/.wake-queue" ] || { reap "$WEDGE_PID"; fail "live declared work still enqueued a wake"; }
  [ ! -e "$WEDGE_STATE/.wedge-escalations-$WEDGE_KEY" ] \
    || { reap "$WEDGE_PID"; fail "live declared work still counted a wedge escalation"; }
  anchor=$(cat "$WEDGE_STATE/.stale-since-$WEDGE_KEY" 2>/dev/null || true)
  reap "$WEDGE_PID"; WEDGE_PID=
  case "$anchor" in ''|*[!0-9]*) fail "the wedge timer lost its anchor: '$anchor'" ;; esac
  now=$(date +%s)
  [ "$(( now - anchor ))" -lt 240 ] \
    || fail "the wedge timer was not re-anchored on the work's own progress ($(( now - anchor ))s)"
  [ "$(( now - anchor ))" -ge 15 ] \
    || fail "the wedge timer was reset to now instead of anchored on last progress"
  pass "a quiet pane whose declared external work is alive is not declared stale, and its timer anchors on that work"
}

# The escalation counter drives the demand-deep-inspection tier, which tells the
# handler not to re-absorb on pane state alone. Dated evidence of progress breaks
# the run of escalations it counts, so a deferral must clear it rather than let
# the next genuine escalation open at an inflated tier claiming a consecutiveness
# that did not happen.
test_live_declared_work_resets_the_escalation_count() {
  make_wedge_case liveness-escalation-reset
  install_source "$WEDGE_STATE" quiet 'echo "age: 20"'
  # This pane has already escalated to the loudest tier before the work answered.
  printf '%s\n' "$FM_WEDGE_DEMAND_INSPECT_COUNT_SEED" > "$WEDGE_STATE/.wedge-escalations-$WEDGE_KEY"

  run_wedge_watcher
  # Gate on the counter itself, not on the timer anchor: the anchor is written
  # just before the counter is cleared, so waiting on the anchor can observe the
  # deferral one step early and reap mid-way through it.
  # shellcheck disable=SC2016 # deliberately deferred: wait_absorbed evals this, not this shell
  if ! wait_absorbed "$WEDGE_PID" '[ ! -e "$WEDGE_STATE/.wedge-escalations-$WEDGE_KEY" ]'; then
    reap "$WEDGE_PID"
    fail "an affirmative liveness answer left the escalation count at $(cat "$WEDGE_STATE/.wedge-escalations-$WEDGE_KEY" 2>/dev/null) (watcher $(wait_fail_word)): $(cat "$WEDGE_DIR/watch.out")"
  fi
  reap "$WEDGE_PID"; WEDGE_PID=
  [ ! -s "$WEDGE_DIR/watch.out" ] || fail "the deferral still printed a wake reason: $(cat "$WEDGE_DIR/watch.out")"
  pass "affirmative declared-work progress clears the wedge escalation count"
}

# THE REAL WEDGE, same fixture. The declared work has stopped answering, so the
# ordinary pane-based reading stands and escalation happens within the grace.
test_dead_declared_work_still_escalates() {
  local drain_out
  make_wedge_case liveness-real-wedge
  install_source "$WEDGE_STATE" quiet 'exit 0'

  run_wedge_watcher
  wait_for_exit "$WEDGE_PID" 80 \
    || fail "watcher did not escalate a wedge once declared external work went dead: $(cat "$WEDGE_DIR/watch.out")"
  WEDGE_PID=
  grep -F "stale: $WEDGE_WINDOW" "$WEDGE_DIR/watch.out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$WEDGE_DIR/watch.out" >/dev/null || fail "escalation did not flag a possible wedge"
  [ ! -e "$WEDGE_STATE/.stale-since-$WEDGE_KEY" ] || fail "the wedge timer survived escalation"
  drain_out="$WEDGE_DIR/drain.out"
  FM_STATE_OVERRIDE="$WEDGE_STATE" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the wedge escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$WEDGE_WINDOW" >/dev/null \
    || fail "the wedge escalation was not queued"
  pass "the same task escalates within the ordinary grace once its declared work stops answering"
}

# Declared work that answers but has itself gone quiet past the grace must not
# suppress anything: the anchor is evidence of progress, not a mute button.
test_stalled_declared_work_escalates() {
  make_wedge_case liveness-stalled-work
  install_source "$WEDGE_STATE" quiet 'echo "age: 3000"'

  run_wedge_watcher
  wait_for_exit "$WEDGE_PID" 80 \
    || fail "watcher did not escalate when declared work had itself stalled: $(cat "$WEDGE_DIR/watch.out")"
  WEDGE_PID=
  grep -F "possible wedge" "$WEDGE_DIR/watch.out" >/dev/null \
    || fail "a stalled declared-work escalation omitted its wedge reason"
  pass "declared work whose own last progress is past the grace escalates normally"
}

# THE RESIDUAL GAP AS SUPERVISION ACTUALLY MEETS IT: a quiet pane, no registered
# source at all, and a validation run executing a step that has gone silent. This
# is the case that escalated repeatedly in one night across every validating
# lane, so it is pinned at the watcher rather than only at the library.
test_silent_executing_step_is_not_declared_stale() {
  local dir wt head anchor_baseline
  make_wedge_case liveness-silent-step
  [ ! -e "$WEDGE_STATE/quiet.liveness.sh" ] || fail "the silent-step fixture installed a source"
  dir="$WEDGE_DIR"
  wt="$dir/wt"
  make_repo "$wt" fm/quiet
  head=$(git -C "$wt" rev-parse HEAD)
  fm_write_meta "$WEDGE_STATE/quiet.meta" "window=$WEDGE_WINDOW" "worktree=$wt" \
    "kind=ship" "mode=no-mistakes"
  make_fake_no_mistakes "$WEDGE_FAKEBIN"
  FM_FAKE_NM_STATUS=$(nm_status_toon_rows fm/quiet "$head" running "$SILENT_TEST_ROW")
  export FM_FAKE_NM_STATUS
  # shellcheck disable=SC2034 # read inside the wait_absorbed predicate string below
  anchor_baseline=$(cat "$WEDGE_STATE/.stale-since-$WEDGE_KEY" 2>/dev/null || true)

  run_wedge_watcher
  # shellcheck disable=SC2016 # deliberately deferred: wait_absorbed evals this, not this shell
  if ! wait_absorbed "$WEDGE_PID" '[ "$(cat "$WEDGE_STATE/.stale-since-$WEDGE_KEY" 2>/dev/null || true)" != "$anchor_baseline" ]'; then
    reap "$WEDGE_PID"; fail "watcher escalated a wedge while the run was executing a silent step (watcher $(wait_fail_word)): $(cat "$WEDGE_DIR/watch.out")"
  fi
  [ ! -s "$WEDGE_DIR/watch.out" ] || { reap "$WEDGE_PID"; fail "a silent executing step still printed a wake reason: $(cat "$WEDGE_DIR/watch.out")"; }
  [ ! -s "$WEDGE_STATE/.wake-queue" ] || { reap "$WEDGE_PID"; fail "a silent executing step still enqueued a wake"; }
  reap "$WEDGE_PID"; WEDGE_PID=
  unset FM_FAKE_NM_STATUS
  pass "a quiet pane whose validation run is executing a long silent step is not declared stale"
}

# THE REAL WEDGE, same fixture and the same silent step: once the run stops, the
# claim stops with it and the ordinary pane reading escalates within the grace.
# This is what keeps the rule above from being a way to silence the alarm.
test_finished_run_on_a_silent_step_still_escalates() {
  local wt head
  make_wedge_case liveness-silent-step-finished
  wt="$WEDGE_DIR/wt"
  make_repo "$wt" fm/quiet
  head=$(git -C "$wt" rev-parse HEAD)
  fm_write_meta "$WEDGE_STATE/quiet.meta" "window=$WEDGE_WINDOW" "worktree=$wt" \
    "kind=ship" "mode=no-mistakes"
  make_fake_no_mistakes "$WEDGE_FAKEBIN"
  FM_FAKE_NM_STATUS=$(nm_status_toon_rows fm/quiet "$head" completed "$SILENT_TEST_ROW")
  export FM_FAKE_NM_STATUS

  run_wedge_watcher
  wait_for_exit "$WEDGE_PID" 80 \
    || fail "a stopped run on a silent step stopped escalating: $(cat "$WEDGE_DIR/watch.out")"
  WEDGE_PID=
  grep -F "possible wedge" "$WEDGE_DIR/watch.out" >/dev/null \
    || fail "the escalation for a stopped run lost its wedge reason"
  unset FM_FAKE_NM_STATUS
  pass "a stopped run rendering an executing step still escalates within the ordinary grace"
}

# The specific case is added AHEAD of the pane reading, not in place of it: a
# task that declared nothing behaves exactly as before.
test_undeclared_work_keeps_pane_reading() {
  make_wedge_case liveness-undeclared
  [ ! -e "$WEDGE_STATE/quiet.liveness.sh" ] || fail "the undeclared fixture installed a source"

  run_wedge_watcher
  wait_for_exit "$WEDGE_PID" 80 \
    || fail "a task with no declared external work stopped escalating: $(cat "$WEDGE_DIR/watch.out")"
  WEDGE_PID=
  grep -F "possible wedge" "$WEDGE_DIR/watch.out" >/dev/null \
    || fail "the unchanged pane-based escalation lost its wedge reason"
  pass "a task that declared no external work keeps the existing pane-based staleness reading"
}

# --- away-mode daemon verdict ------------------------------------------------
#
# bin/fm-supervise-daemon.sh's housekeeping() consults the same fm_liveness_age
# clock in its own stale-persistence recheck, so away mode reaches the same
# verdict on the same evidence as the always-on watcher above. One fixture,
# reused across all three cases, mirrors the watcher fixture: it differs only
# in what the declared work reports.

DAEMON_DIR=; DAEMON_STATE=; DAEMON_WIN=; DAEMON_TASK=; DAEMON_KEY=

make_daemon_stale_case() {  # <name> - sets the DAEMON_* globals
  DAEMON_DIR=$(make_case "$1")
  DAEMON_STATE="$DAEMON_DIR/state"
  DAEMON_WIN="test:fm-quiet"
  DAEMON_TASK=quiet
  DAEMON_KEY=$(_stale_key "$DAEMON_TASK")
  fm_write_meta "$DAEMON_STATE/$DAEMON_TASK.meta" "window=$DAEMON_WIN" "kind=ship" "backend=tmux"
  printf 'working: handed to validation\n' > "$DAEMON_STATE/$DAEMON_TASK.status"
  # Already past the grace: the very next housekeeping tick decides
  # suppress-and-reanchor or escalate.
  echo $(( $(date +%s) - 500 )) > "$DAEMON_STATE/.subsuper-stale-$DAEMON_KEY"
}

# THE FALSE WEDGE, away-mode side. The registered source reported progress 20s
# ago, so housekeeping must defer the wedge, re-anchor the marker on that
# progress (not reset it to now), and log the suppression with the reported age
# so an away-mode defer is debuggable from the daemon log.
test_housekeeping_live_declared_work_defers_and_reanchors() {
  local anchor now log_out
  make_daemon_stale_case daemon-liveness-live
  install_source "$DAEMON_STATE" "$DAEMON_TASK" 'echo "age: 20"'

  LOG="$DAEMON_DIR/daemon.log" FM_STATE_OVERRIDE="$DAEMON_STATE" FM_STALE_ESCALATE_SECS=240 \
    housekeeping "$DAEMON_STATE"

  [ ! -s "$DAEMON_STATE/.subsuper-escalations" ] \
    || fail "away-mode housekeeping escalated a wedge while declared external work was alive"
  [ -e "$DAEMON_STATE/.subsuper-stale-$DAEMON_KEY" ] \
    || fail "away-mode housekeeping dropped the stale marker instead of re-anchoring it"
  anchor=$(cat "$DAEMON_STATE/.subsuper-stale-$DAEMON_KEY")
  case "$anchor" in ''|*[!0-9]*) fail "the daemon's wedge timer lost its anchor: '$anchor'" ;; esac
  now=$(date +%s)
  [ "$(( now - anchor ))" -lt 240 ] \
    || fail "the daemon's wedge timer was not re-anchored on the work's own progress ($(( now - anchor ))s)"
  [ "$(( now - anchor ))" -ge 15 ] \
    || fail "the daemon's wedge timer was reset to now instead of anchored on last progress"
  log_out=$(cat "$DAEMON_DIR/daemon.log" 2>/dev/null || true)
  printf '%s\n' "$log_out" | grep -F "declared external work made progress 20s ago" >/dev/null \
    || fail "away-mode housekeeping did not log the stale-absorb suppression: $log_out"
  printf '%s\n' "$log_out" | grep -F "$DAEMON_WIN" >/dev/null \
    || fail "away-mode housekeeping's stale-absorb log omitted the window: $log_out"
  pass "away-mode housekeeping defers a stale wedge whose declared external work is alive, re-anchors, and logs it"
}

# THE REAL WEDGE, away-mode side, same fixture. The registered source has gone
# dead, so the ordinary pane-based reading stands and escalation happens within
# the grace exactly as it did before this task declared anything.
test_housekeeping_dead_declared_work_still_escalates() {
  local pane
  make_daemon_stale_case daemon-liveness-dead
  install_source "$DAEMON_STATE" "$DAEMON_TASK" 'exit 0'
  pane="$DAEMON_DIR/pane.txt"
  printf 'idle prompt $\n' > "$pane"

  PATH="$DAEMON_DIR/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$DAEMON_WIN" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$DAEMON_STATE" FM_STALE_ESCALATE_SECS=240 housekeeping "$DAEMON_STATE"

  [ -s "$DAEMON_STATE/.subsuper-escalations" ] \
    || fail "away-mode housekeeping did not escalate once declared external work went dead"
  grep -F "possible wedge" "$DAEMON_STATE/.subsuper-escalations" >/dev/null \
    || fail "away-mode escalation did not flag a possible wedge"
  [ ! -e "$DAEMON_STATE/.subsuper-stale-$DAEMON_KEY" ] \
    || fail "away-mode wedge marker survived escalation"
  pass "away-mode housekeeping escalates within the ordinary grace once declared work goes dead"
}

# The specific case is added AHEAD of the pane reading, not in place of it: a
# task that declared nothing behaves exactly as before under away mode too.
test_housekeeping_undeclared_work_keeps_pane_reading() {
  local pane
  make_daemon_stale_case daemon-liveness-undeclared
  pane="$DAEMON_DIR/pane.txt"
  printf 'idle prompt $\n' > "$pane"
  [ ! -e "$DAEMON_STATE/$DAEMON_TASK.liveness.sh" ] \
    || fail "the undeclared fixture installed a liveness source"

  PATH="$DAEMON_DIR/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$DAEMON_WIN" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$DAEMON_STATE" FM_STALE_ESCALATE_SECS=240 housekeeping "$DAEMON_STATE"

  [ -s "$DAEMON_STATE/.subsuper-escalations" ] \
    || fail "a task with no declared external work stopped escalating under away-mode housekeeping"
  grep -F "possible wedge" "$DAEMON_STATE/.subsuper-escalations" >/dev/null \
    || fail "the unchanged away-mode escalation lost its wedge reason"
  pass "away-mode housekeeping keeps the unchanged pane-based reading for a task that declared no external work"
}

# --- reap must bound a TERM-ignoring process ---------------------------------
#
# The suites reap real watchers, and one that ignores TERM would hang the whole
# run forever. A watcher can no longer do that (tests/fm-watcher-signal-safety.test.sh
# pins it), but the harness must stay able to report the day one does instead of
# hanging CI - so reap bounds the wait, escalates, and sets the flag that
# assert_reaped_on_term turns into a named failure. Proven against a real process
# that really ignores TERM, so the bound cannot go vacuous.
# 0 once <pid> has spawned a child, which proves it finished exec'ing and reached
# its loop body - and therefore that any signal disposition it sets is installed.
# Signalling before that races the exec and the signal is simply lost.
wait_process_ready() {  # <pid> [limit-ticks]
  local pid=$1 limit=${2:-100} i=0
  while [ "$i" -lt "$limit" ]; do
    pgrep -P "$pid" >/dev/null 2>&1 && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_reap_bounds_a_term_ignoring_process() {
  local pid started elapsed
  bash -c 'trap "" TERM; while :; do sleep 0.1; done' &
  pid=$!
  wait_process_ready "$pid" || { reap "$pid"; fail "the TERM-ignoring fixture never started"; }
  started=$(date +%s)
  reap "$pid" 10
  elapsed=$(( $(date +%s) - started ))
  is_live_non_zombie "$pid" && fail "reap left a TERM-ignoring process alive"
  [ -n "$FM_REAP_NEEDED_KILL" ] || fail "reap did not report that TERM was ignored"
  [ "$elapsed" -lt 30 ] || fail "reap took ${elapsed}s to bound a TERM-ignoring process"
  # The flag is only useful if it becomes a named failure, so assert the reporter
  # built on it fires rather than leaving the escalation silent.
  ( assert_reaped_on_term "fixture" 2>/dev/null ) \
    && fail "assert_reaped_on_term passed over a process that ignored TERM"

  # A process that exits on TERM is the control: it must NOT be reported as
  # needing KILL, or every reap would look like a signal-handling regression.
  bash -c 'while :; do sleep 0.1; done' &
  pid=$!
  wait_process_ready "$pid" || { reap "$pid"; fail "the ordinary fixture never started"; }
  reap "$pid"
  [ -z "$FM_REAP_NEEDED_KILL" ] || fail "an ordinary process was misreported as ignoring TERM"
  assert_reaped_on_term "ordinary fixture"
  pass "reap bounds a TERM-ignoring process, turns it into a named failure, and stays quiet for ordinary exits"
}

test_duration_parsing
test_active_step_field_parsing
test_registered_source_answers
test_registered_source_requires_binding
test_registered_source_is_time_bounded
test_run_source_reads_its_own_run_activity
test_run_source_reads_an_in_flight_pipeline_head
test_run_source_answers_on_the_run_state_not_an_activity_age
test_combined_answer_takes_the_freshest_source
test_live_declared_work_is_not_declared_stale
test_live_declared_work_resets_the_escalation_count
test_dead_declared_work_still_escalates
test_stalled_declared_work_escalates
test_silent_executing_step_is_not_declared_stale
test_finished_run_on_a_silent_step_still_escalates
test_undeclared_work_keeps_pane_reading
test_housekeeping_live_declared_work_defers_and_reanchors
test_housekeeping_dead_declared_work_still_escalates
test_housekeeping_undeclared_work_keeps_pane_reading
test_reap_bounds_a_term_ignoring_process
