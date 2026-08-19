#!/usr/bin/env bash
# fm-liveness-lib.sh - how recently a task's DECLARED long-running external work
# last made progress.
#
# Why this exists: supervision judges staleness from the pane, and the pane
# belongs to the worker, not to the work. A ship task in mode=no-mistakes hands
# its change to a validation pipeline that runs its own agent in a separate
# process, and the worker is then instructed to stop polling and wait. Its pane
# is deliberately, correctly quiet for as long as the pipeline runs - so pane
# quiet alone reported a wedge every wedge-grace period while the pipeline was
# demonstrably editing files. The same misreading has the opposite shape when a
# worker runs a long containerized gate in the foreground: different worker
# behavior, identical wrong verdict. Widening the grace cannot fix either one,
# because it would equally delay catching a worker that really has stopped.
#
# The fix is a better clock, not a longer one: ask the work itself.
#
#   fm_liveness_age <state> <task>
#       Prints an integer age in seconds since that task's declared external
#       work last made progress, and returns 0, when at least one source
#       answered. Returns 1 and prints nothing when none did.
#
# Returning 1 does NOT mean dead. It means this task declared no external work
# supervision can read, so the caller must keep whatever reading it already had.
# Every failure here - a missing source, an unregistered or edited source, a
# timeout, an unparseable answer, a run that cannot be attributed - collapses to
# that same "no answer", which leaves existing behavior exactly as it was. The
# only thing this library can do is SUPPRESS a wedge verdict, and only on
# positive, dated evidence of progress.
#
# Two sources answer, and the freshest wins, because each is independent
# evidence about different declared work:
#
#   1. A registered per-task source, state/<task>.liveness.sh, bound to its
#      exact bytes by bin/fm-liveness-register.sh (contract in that script's
#      header, byte-binding in bin/fm-check-lib.sh). This is the project-
#      agnostic case: firstmate never learns what the work is, only how to ask.
#   2. The task's own no-mistakes validation run, with no registration at all,
#      because firstmate already records mode=no-mistakes and no-mistakes
#      already reports per-active-step `last_activity`. The overwhelmingly
#      common case should need no setup.
#
# The built-in source answers from the RUN STATE - an attributed, non-terminal
# run that is executing a step - rather than from how recently that step logged.
# An activity age only holds while a step chooses to log, and a step running a
# long silent job does not; fm_liveness_run_age below owns why that made the age
# read a systematic false alarm, and what firstmate gives up by dropping it.
#
# Cost: both sources are read only at the moment a caller is about to declare a
# wedge, never on every poll. See bin/fm-watch.sh's wedge_timer_check.
set -u

FM_LIVENESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_LIVENESS_LIB_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$FM_LIVENESS_LIB_DIR/fm-nm-run-lib.sh"

# Seconds a registered source may run before it is killed and read as no answer.
FM_LIVENESS_TIMEOUT=${FM_LIVENESS_TIMEOUT:-10}
case "$FM_LIVENESS_TIMEOUT" in ''|*[!0-9]*|0) FM_LIVENESS_TIMEOUT=10 ;; esac
# Seconds the bounded `no-mistakes axi status` read may take. Same default and
# same reason as fm-crew-state.sh's own lookup bound.
FM_LIVENESS_NM_TIMEOUT=${FM_LIVENESS_NM_TIMEOUT:-10}
case "$FM_LIVENESS_NM_TIMEOUT" in ''|*[!0-9]*|0) FM_LIVENESS_NM_TIMEOUT=10 ;; esac

# --- duration parsing -------------------------------------------------------

# Seconds for a compact duration token such as 25s, 12m41s, or 1h2m3s. Prints
# the total and returns 0; returns 1 for anything that is not exactly one such
# token, so unparsed text can never be mistaken for a fresh age.
fm_liveness_duration_secs() {  # <token>
  local t=$1 total=0 n u
  [ -n "$t" ] || return 1
  case "$t" in *[!0-9dhms]*) return 1 ;; esac
  while [ -n "$t" ]; do
    n=${t%%[dhms]*}
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    t=${t#"$n"}
    u=${t%"${t#?}"}
    t=${t#?}
    case "$u" in
      d) total=$((total + n * 86400)) ;;
      h) total=$((total + n * 3600)) ;;
      m) total=$((total + n * 60)) ;;
      s) total=$((total + n)) ;;
      *) return 1 ;;
    esac
  done
  printf '%s' "$total"
}

# --- registered per-task source --------------------------------------------

# Age reported by state/<task>.liveness.sh, or 1 if it did not answer. The
# source is executed only from a verified private snapshot of its registered
# bytes, under a hard time bound, exactly like a custom watcher check: it is
# arbitrary code, so it gets the same proof. Requires bin/fm-pr-lib.sh and
# bin/fm-check-lib.sh to be sourced by the caller (both already are, everywhere
# this is used).
fm_liveness_registered_age() {  # <state> <task>
  local state=$1 task=$2 out rc value
  command -v fm_task_script_snapshot_prepare >/dev/null 2>&1 || return 1
  fm_task_script_snapshot_prepare "$state" "$task" liveness || return 1
  # Run as `bash <snapshot>`, exactly as the watcher runs a custom check: the
  # verified snapshot is deliberately mode 0600, so it is never made executable
  # to be read.
  out=$(fm_run_timed "$FM_LIVENESS_TIMEOUT" bash "$FM_TASK_SCRIPT_SNAPSHOT" 2>/dev/null)
  rc=$?
  fm_task_script_snapshot_cleanup
  [ "$rc" -eq 0 ] || return 1
  out=$(printf '%s' "$out" | head -1)
  out=${out%"${out##*[![:space:]]}"}
  out=${out#"${out%%[![:space:]]*}"}
  case "$out" in
    alive) printf '0'; return 0 ;;
    age:*)
      value=${out#age:}
      value=${value#"${value%%[![:space:]]*}"}
      case "$value" in ''|*[!0-9]*) return 1 ;; esac
      printf '%s' "$value"
      return 0
      ;;
  esac
  return 1
}

# --- built-in no-mistakes validation-run source ----------------------------

fm_liveness_meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Values of the <field> column of the active_steps table in captured `axi
# status` TOON on stdin, one per row. TOON renders a one-row table inline after
# the header and multi-row tables as following lines, so both are read. Splitting
# is quote-aware because last_activity is a quoted string that contains commas
# and colons; positional splitting on bare commas would slice it apart and could
# return the neighbouring active_for duration instead. Escaping matches the
# encoder (bin/fm-bearings-snapshot.sh's `q` filter): inside a quoted field a
# backslash escapes the following character, so a backslash-quote pair is a
# literal quote that does not end the field and a backslash-backslash pair is a
# literal backslash - only an unescaped quote toggles quoting and only an
# unescaped comma outside quotes separates fields. An active_steps header
# without the requested column yields nothing rather than a guessed position.
fm_liveness_active_step_field() {  # <field>
  awk -v want="$1" '
    function emit(line,   i, ch, inq, esc, cur, f, nf) {
      if (idx == 0) return
      nf = 0; cur = ""; inq = 0; esc = 0
      for (i = 1; i <= length(line); i++) {
        ch = substr(line, i, 1)
        if (esc) { cur = cur ch; esc = 0; continue }
        if (inq && ch == "\\") { esc = 1; continue }
        if (ch == "\"") { inq = !inq; continue }
        if (ch == "," && !inq) { f[++nf] = cur; cur = ""; continue }
        cur = cur ch
      }
      f[++nf] = cur
      if (nf >= idx) print f[idx]
    }
    !intable && match($0, /^[ \t]*active_steps\[[0-9]+\]\{[^}]*\}:/) {
      header = substr($0, RSTART, RLENGTH)
      rest = substr($0, RSTART + RLENGTH)
      cols = header
      sub(/^[^{]*\{/, "", cols)
      sub(/\}:$/, "", cols)
      n = split(cols, names, ",")
      idx = 0
      for (i = 1; i <= n; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", names[i])
        if (names[i] == want) idx = i
      }
      intable = 1
      if (rest ~ /[^ \t]/) emit(rest)
      next
    }
    intable {
      if ($0 !~ /,/) { intable = 0; next }
      if ($0 ~ /^[ \t]*[A-Za-z_][A-Za-z0-9_]*(\[[0-9]+\]\{[^}]*\})?:/) { intable = 0; next }
      emit($0)
    }
  '
}

# 0 when <status> is a run status that is still going. An allow-list rather than
# a denial list, so a newly invented terminal value cannot quietly read as alive;
# the cost is that a newly invented active value goes silent, which is the safe
# direction and is what tests/fm-nm-status-shape-live-e2e.test.sh watches for.
fm_liveness_status_is_live() {  # <status>
  case "$1" in
    running|fixing|pending) return 0 ;;
  esac
  return 1
}

# 0 when <step-status> means that step is EXECUTING right now, which is stricter
# than the run-level test above.
#
# This is the whole liveness claim for a running pipeline, so what it excludes
# matters as much as what it admits. A step that is merely queued says nothing
# about whether anything is moving, and a step parked at an approval or
# fix-review gate is waiting on FIRSTMATE - exactly the case supervision must
# still surface - so neither may read as executing. An allow-list is what keeps
# that true: a gate or terminal state no-mistakes invents later goes silent
# rather than quietly reading as alive. The same drift guard watches this list.
fm_liveness_step_is_executing() {  # <step-status>
  case "$1" in
    running|fixing) return 0 ;;
  esac
  return 1
}

# Age since the task's own no-mistakes validation run last made progress, or 1
# if there is no such evidence.
#
# Three independent things must all hold before an age is reported, because each
# closes a different way this read could suppress a wedge it has no business
# suppressing:
#
#   1. The run is on THIS task's branch. `axi status` answers for the repo of the
#      invoking directory, not for that worktree's own branch, so it happily
#      reports a sibling lane's run to a lane that has none. Within a repo git
#      allows a branch in only one worktree, so the branch match is what binds
#      the run to this task.
#   2. The reported head is consistent with this worktree owning an in-flight run
#      (fm_nm_head_allows_inflight in bin/fm-nm-run-lib.sh, the ONE owner of run
#      attribution). Note that a running pipeline's head is normally NOT
#      resolvable here; that owner explains why, and why demanding otherwise made
#      this whole source silent for the entire review step.
#   3. The run is not terminal, and it is executing a step. A stopped or parked
#      run must never read as alive however busy the detail printed beside it, so
#      both the run status and the step status are allow-lists of live values
#      rather than denial lists a new terminal or gate value could slip past. All
#      identity and state fields are read from the run object itself, never from
#      the deeper branch_sync block that repeats their names.
#
# An executing step answers with NO AGE at all, and that is the point. An
# activity age answers "has this step's agent stalled?", which only works while
# the step chooses to log. Two steps measured on 2026-08-19 prove that it does
# not: the `ci` step has no agent and emits one forge heartbeat every few
# minutes, and a `test` step driving a containerized gate logs once at start and
# then nothing until the container exits. Both are silent for far longer than the
# wedge grace while working perfectly, so an age read escalated provably healthy
# work as a possible wedge on every validating lane - and a systematic false
# alarm is how a real one later gets waved through. Any step running a long
# silent job defeats an activity age, so the fix can be neither a list of such
# steps nor a wider threshold; a wider threshold only makes the alarm later
# rather than correct, and delays a genuinely wedged step by the same amount.
#
# The run state is the one signal that does not depend on a step choosing to log,
# and it is read live from the daemon that owns the run every single time, so the
# claim cannot outlive the work: the moment the run stops or parks, the very next
# read says so and the ordinary pane-quiet timer resumes within one grace period.
# What firstmate gives up is spotting a step whose agent died while the daemon
# still reports it running - deliberately, because an activity age cannot tell
# that apart from a healthy silent job, and the pipeline's own step bounds are
# what end such a run. Prefer a source that goes quiet too early over one that
# speaks too long: a missing claim costs a turn, a false one costs the alarm.
#
# A dated activity age still answers as a fallback for a non-terminal run with no
# step executing yet, so nothing the earlier reading covered is lost.
fm_liveness_run_age() {  # <state> <task>
  local state=$1 task=$2 meta wt kind mode branch out run_branch run_status
  local step_status value token age best=
  meta="$state/$task.meta"
  [ -f "$meta" ] || return 1
  kind=$(fm_liveness_meta_value "$meta" kind)
  [ -z "$kind" ] || [ "$kind" = ship ] || return 1
  mode=$(fm_liveness_meta_value "$meta" mode)
  [ "$mode" = no-mistakes ] || return 1
  wt=$(fm_liveness_meta_value "$meta" worktree)
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  command -v no-mistakes >/dev/null 2>&1 || return 1
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  [ -n "$branch" ] || return 1
  out=$(fm_nm_run_checked "$wt" "$FM_LIVENESS_NM_TIMEOUT" axi status) || return 1
  [ -n "$out" ] || return 1
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_run_field "$out" branch)")
  [ "$run_branch" = "$branch" ] || return 1
  fm_nm_head_allows_inflight "$wt" "$(fm_nm_strip_quotes "$(fm_nm_run_field "$out" head)")" || return 1
  run_status=$(fm_nm_strip_quotes "$(fm_nm_run_field "$out" status)")
  fm_liveness_status_is_live "$run_status" || return 1
  # Reported as 0, the same "alive, no useful age" value a registered source's
  # `alive` maps to, and the freshest answer possible - so it short-circuits the
  # fallback scan below rather than competing with it. Read separately from that
  # scan, so an active_steps table without a status column loses only this rule
  # and leaves the age reading exactly as it was.
  while IFS= read -r step_status; do
    if fm_liveness_step_is_executing "$step_status"; then
      printf '0'
      return 0
    fi
  done <<EOF
$(printf '%s\n' "$out" | fm_liveness_active_step_field status)
EOF
  while IFS= read -r value; do
    # last_activity reads like "25s ago: log: ..." and, once no-mistakes has
    # flagged the step quiet, "quiet 6m12s: ...". Anchor the token at the start
    # of the field so a number inside the log prose can never be read as an age.
    token=$(printf '%s' "$value" \
      | grep -oE '^[[:space:]]*(quiet[[:space:]]+)?([0-9]+[dhms])+' \
      | grep -oE '([0-9]+[dhms])+$' | head -1)
    age=$(fm_liveness_duration_secs "$token") || continue
    if [ -z "$best" ] || [ "$age" -lt "$best" ]; then best=$age; fi
  done <<EOF
$(printf '%s\n' "$out" | fm_liveness_active_step_field last_activity)
EOF
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# --- combined answer -------------------------------------------------------

# Seconds since <task>'s declared long-running external work last made progress.
# Freshest answering source wins: each source speaks for different declared
# work, and any one of them showing recent progress is enough to say the task is
# waiting rather than wedged.
fm_liveness_age() {  # <state> <task>
  local state=$1 task=$2 age best=
  [ -n "$task" ] || return 1
  if age=$(fm_liveness_registered_age "$state" "$task"); then best=$age; fi
  if age=$(fm_liveness_run_age "$state" "$task"); then
    if [ -z "$best" ] || [ "$age" -lt "$best" ]; then best=$age; fi
  fi
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}
