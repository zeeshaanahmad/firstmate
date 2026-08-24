#!/usr/bin/env bash
# Detect a red default branch: watch one managed repository's default-branch
# SHA and, whenever it moves, run that project's OWN pinned static check
# against the new tip, waking firstmate with one line when it is red.
#
# This is the backstop to the merge-time guard in bin/fm-pr-merge.sh. It covers
# what prevention cannot: a merge performed on the forge by hand, and the
# seconds-wide race between the merge-time check and the merge call itself.
# Both share bin/fm-static-guard-lib.sh, which is the single owner of
# discovering and running a project's static check against a tree, so the two
# can never disagree about what "red" means.
#
# WHAT THIS DOES NOT CATCH. The static class only - undefined names, imports,
# formatting, and whatever else the project's own checker reports. Runtime test
# failures, type-checker errors, and snapshot drift all pass it.
#
# THIS DOES NOT SURVIVE AN AIRGAPPED SITE. It reads the default-branch tip from
# the forge, and a pinned checker fetched by its pin needs the network on a cold
# cache. With neither available the poll reaches no verdict, stays silent, and
# does not record the tip, so it simply retries.
#
# Usage:
#   fm-main-guard.sh arm <check-id> <project-dir> [--remote <url>] [--branch <b>]
#   fm-main-guard.sh disarm <check-id>
#   fm-main-guard.sh poll --config <path>      (run by the armed check only)
#   fm-main-guard.sh --help
#
# arm is run once per repository, not once per task: pick a stable <check-id>
# such as main-guard-<project>. It writes the private configuration sidecar
# state/<check-id>.main-guard, writes state/<check-id>.check.sh as an ordinary
# single-link mode-0700 file whose whole body execs this script's poll, and
# binds those bytes through bin/fm-check-lib.sh's registrar - the same contract
# every custom watcher check follows. arm REFUSES when the project has no
# discoverable static check, because an armed guard that can never reach a
# verdict is worse than none.
#
# STATE. The last evaluated tip lives in state/<check-id>.main-guard-seen, one
# line, beside the configuration rather than inside the check: the check's bytes
# are hash-bound and so cannot carry moving state. It is recorded only after a
# verdict is actually reached, so a green tip is never re-run and an unreachable
# forge simply retries. The full checker output of a red tip is kept at
# state/<check-id>.main-guard-output for firstmate to read; the wake line names
# it rather than carrying it, because a wake line is one line.
#
# A KILLED CHECK IS NOT A GREEN TIP. A checker that exceeds
# FM_MAIN_GUARD_BUDGET reaches no verdict, so the tip is left unrecorded and the
# next poll retries. Unlike the merge-time half, this one grants nothing on a
# timeout, so it has nothing to refuse; see docs/merge-time-static-guard.md.
#
# TIMING. The watcher allows FM_CHECK_TIMEOUT (default 30s) per check. The
# common poll is one `git ls-remote` on an unchanged branch. A poll that does
# find a new tip adds a private object-store preparation, one incremental fetch,
# writing the tree out, and the checker itself, which for a pinned linter is a
# few seconds in total. The checker's own budget is capped at
# FM_MAIN_GUARD_BUDGET (default 20s) so a slow checker reports a bounded
# no-verdict instead of being killed mid-poll. A project whose checker cannot
# finish inside that budget needs FM_CHECK_TIMEOUT and FM_MAIN_GUARD_BUDGET
# raised together in the watcher's environment - or should not be armed here at
# all, because a check that always times out is a check that never reports.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-static-guard-lib.sh
. "$SCRIPT_DIR/fm-static-guard-lib.sh"

CONFIG_VERSION=fm-main-guard-v1
MAIN_GUARD_BUDGET=${FM_MAIN_GUARD_BUDGET:-20}

usage() {
  sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-main-guard.sh" | sed '$d' | sed 's/^# \{0,1\}//'
}

# Paths interpolated into the generated check must not be able to end the
# argument they sit in, so an unusual home or project path is refused at arm
# time rather than producing a check nobody can reason about.
path_literal_safe() {  # <path>
  local p=${1-}
  case "$p" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$p" in
    *[[:space:]]*|*[[:cntrl:]]*|*'"'*|*"'"*|*'$'*|*'`'*|*[\\]*) return 1 ;;
  esac
}

config_path() { printf '%s/%s.main-guard\n' "$STATE" "$1"; }
seen_path() { printf '%s/%s.main-guard-seen\n' "$STATE" "$1"; }
output_path() { printf '%s/%s.main-guard-output\n' "$STATE" "$1"; }

# Remove one of this guard's own state artifacts, and nothing else. Every
# removal goes through here so an empty state directory or an empty id can
# never compose a root-relative path, and so a target that is not a plain
# regular file sitting directly in the state directory is left alone rather
# than deleted. Absence is success; anything unexpected is a refusal.
state_artifact_remove() {  # <id> <suffix>
  local id=${1-} suffix=${2-} target
  [ -n "$id" ] && [ -n "$suffix" ] || return 1
  [ -n "${STATE:-}" ] || return 1
  fm_task_id_path_safe "$id" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  target="$STATE/$id$suffix"
  [ -e "$target" ] || [ -L "$target" ] || return 0
  [ -f "$target" ] && [ ! -L "$target" ] || return 1
  rm -f -- "$target"
}

# Remove a temporary file this script created, refusing an empty path.
tmp_remove() {  # <path>
  local tmp=${1-}
  [ -n "$tmp" ] || return 0
  [ -f "$tmp" ] && [ ! -L "$tmp" ] || return 0
  rm -f -- "$tmp"
}

# Read a validated configuration sidecar into MG_PROJECT/MG_REMOTE/MG_BRANCH.
MG_PROJECT=
MG_REMOTE=
MG_BRANCH=
config_read() {  # <config-path>
  local file=$1 version line
  MG_PROJECT=
  MG_REMOTE=
  MG_BRANCH=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 8< "$file" || return 1
  IFS= read -r version <&8 || { exec 8<&-; return 1; }
  [ "$version" = "$CONFIG_VERSION" ] || { exec 8<&-; return 1; }
  while IFS= read -r line <&8; do
    case "$line" in
      project=*) MG_PROJECT=${line#project=} ;;
      remote=*) MG_REMOTE=${line#remote=} ;;
      branch=*) MG_BRANCH=${line#branch=} ;;
      *) exec 8<&-; return 1 ;;
    esac
  done
  exec 8<&-
  [ -n "$MG_PROJECT" ] && [ -n "$MG_REMOTE" ] && [ -n "$MG_BRANCH" ] || return 1
  fm_project_origin_safe "$MG_REMOTE" || return 1
  fm_static_guard_ref_name_safe "$MG_BRANCH" || return 1
}

remote_branch_sha() {  # <remote-url> <branch>; prints the tip SHA
  local url=$1 branch=$2 line sha
  line=$(fm_run_timed "$FM_STATIC_GUARD_FETCH_TIMEOUT" \
    git ls-remote "$url" "refs/heads/$branch" 2>/dev/null | head -1) || return 1
  sha=${line%%[[:space:]]*}
  fm_static_guard_sha_valid "$sha" || return 1
  printf '%s\n' "$sha"
}

cmd_arm() {
  local id=${1-} project=${2-} remote='' branch='' config tmp check sha
  shift 2 2>/dev/null || { echo "usage: fm-main-guard.sh arm <check-id> <project-dir>" >&2; return 2; }
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --remote) remote=${2-}; shift 2 || return 2 ;;
      --branch) branch=${2-}; shift 2 || return 2 ;;
      *) echo "error: unknown argument: $1" >&2; return 2 ;;
    esac
  done
  fm_pr_task_id_valid "$id" || { echo "error: invalid check id" >&2; return 2; }
  [ -n "$project" ] && [ -d "$project" ] || { echo "error: project directory is unavailable" >&2; return 1; }
  project=$(cd "$project" && pwd -P) || return 1
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 \
    || { echo "error: $project is not a git repository" >&2; return 1; }
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; return 1; }
  path_literal_safe "$project" || { echo "error: project path cannot be embedded safely" >&2; return 1; }
  path_literal_safe "$STATE" || { echo "error: state path cannot be embedded safely" >&2; return 1; }
  path_literal_safe "$FM_ROOT/bin/fm-main-guard.sh" \
    || { echo "error: firstmate path cannot be embedded safely" >&2; return 1; }

  if [ -z "$remote" ]; then
    fm_static_guard_remote_pick "$project" \
      || { echo "error: $project has no usable remote" >&2; return 1; }
    remote=$FM_STATIC_GUARD_REMOTE
  fi
  fm_project_origin_safe "$remote" || { echo "error: unusable remote URL" >&2; return 1; }
  if [ -z "$branch" ]; then
    fm_static_guard_default_branch "$remote" \
      || { echo "error: the default branch of $remote could not be read" >&2; return 1; }
    branch=$FM_STATIC_GUARD_BRANCH
  fi
  fm_static_guard_ref_name_safe "$branch" || { echo "error: unusable branch name" >&2; return 1; }

  # Prove the guard can actually reach a verdict before arming it.
  trap 'fm_static_guard_cleanup' EXIT
  fm_static_guard_scratch_new || { echo "error: no scratch directory" >&2; return 1; }
  fm_static_guard_repo_prepare "$project" \
    || { echo "error: a private object store could not be prepared" >&2; return 1; }
  fm_static_guard_fetch "$FM_STATIC_GUARD_GITDIR" "$remote" \
    "+refs/heads/$branch:$FM_STATIC_GUARD_BASE_REF" \
    || { echo "error: $branch could not be fetched from $remote" >&2; return 1; }
  sha=$(git --git-dir="$FM_STATIC_GUARD_GITDIR" rev-parse --verify --quiet "$FM_STATIC_GUARD_BASE_REF" 2>/dev/null) \
    || { echo "error: the tip of $branch could not be read" >&2; return 1; }
  fm_static_check_discover "$FM_STATIC_GUARD_GITDIR" "$sha" || {
    echo "error: no static check discovered for $project - nothing to arm" >&2
    echo "the guard reads commands.lint from .no-mistakes.yaml, then a Makefile lint: target" >&2
    return 1
  }

  umask 077
  config=$(config_path "$id")
  tmp=$(mktemp "$STATE/.fm-main-guard.XXXXXX") || return 1
  {
    printf '%s\n' "$CONFIG_VERSION"
    printf 'project=%s\n' "$project"
    printf 'remote=%s\n' "$remote"
    printf 'branch=%s\n' "$branch"
  } > "$tmp" || { tmp_remove "$tmp"; return 1; }
  chmod 0600 "$tmp" || { tmp_remove "$tmp"; return 1; }
  mv -f -- "$tmp" "$config" || { tmp_remove "$tmp"; return 1; }

  check="$STATE/$id.check.sh"
  tmp=$(mktemp "$STATE/.fm-main-guard-check.XXXXXX") || return 1
  {
    printf '#!/usr/bin/env bash\n'
    printf '# firstmate default-branch static guard; see bin/fm-main-guard.sh.\n'
    printf 'exec "%s" poll --config "%s"\n' "$FM_ROOT/bin/fm-main-guard.sh" "$config"
  } > "$tmp" || { tmp_remove "$tmp"; return 1; }
  chmod 0700 "$tmp" || { tmp_remove "$tmp"; return 1; }
  mv -f -- "$tmp" "$check" || { tmp_remove "$tmp"; return 1; }
  state_artifact_remove "$id" .main-guard-seen || return 1
  state_artifact_remove "$id" .main-guard-output || return 1

  fm_task_script_register "$STATE" "$id" check || return 1
  printf 'armed: %s %s@%s via %s (%s)\n' "$id" "$branch" "${sha:0:12}" \
    "$FM_STATIC_CHECK_SOURCE" "$FM_STATIC_CHECK_CMD"
}

cmd_disarm() {
  local id=${1-} suffix
  fm_pr_task_id_valid "$id" || { echo "error: invalid check id" >&2; return 2; }
  for suffix in .check.sh .check-trust .main-guard .main-guard-seen .main-guard-output; do
    state_artifact_remove "$id" "$suffix" || {
      echo "error: $STATE/$id$suffix is not a plain guard artifact; leaving it in place" >&2
      return 1
    }
  done
  printf 'disarmed: %s\n' "$id"
}

cmd_poll() {
  local config=${2-} id sha seen out
  [ "${1-}" = --config ] && [ -n "$config" ] || { echo "usage: fm-main-guard.sh poll --config <path>" >&2; return 2; }
  config_read "$config" || return 0
  # The armed check names its own configuration, so the poll takes the state
  # directory from that path rather than from an environment the watcher does
  # not promise to hand a custom check.
  STATE=$(cd "$(dirname "$config")" && pwd -P) || return 0
  id=$(basename "$config" .main-guard)
  fm_pr_task_id_valid "$id" || return 0
  # Everything this poll writes is private state.
  umask 077
  sha=$(remote_branch_sha "$MG_REMOTE" "$MG_BRANCH") || return 0
  seen=$(cat "$(seen_path "$id")" 2>/dev/null || true)
  [ "$seen" = "$sha" ] && return 0
  [ -d "$MG_PROJECT" ] || return 0

  trap 'fm_static_guard_cleanup' EXIT
  fm_static_guard_scratch_new || return 0
  fm_static_guard_repo_prepare "$MG_PROJECT" || return 0
  fm_static_guard_fetch "$FM_STATIC_GUARD_GITDIR" "$MG_REMOTE" \
    "+refs/heads/$MG_BRANCH:$FM_STATIC_GUARD_BASE_REF" || return 0
  sha=$(git --git-dir="$FM_STATIC_GUARD_GITDIR" rev-parse --verify --quiet "$FM_STATIC_GUARD_BASE_REF" 2>/dev/null) || return 0
  fm_static_guard_sha_valid "$sha" || return 0
  [ "$seen" = "$sha" ] && return 0

  fm_static_guard_evaluate_tree "$FM_STATIC_GUARD_GITDIR" "$sha" "$sha^{tree}" "$MAIN_GUARD_BUDGET"
  case "$FM_STATIC_GUARD_VERDICT" in
    green)
      printf '%s\n' "$sha" > "$(seen_path "$id")" 2>/dev/null || true
      state_artifact_remove "$id" .main-guard-output || true
      ;;
    red)
      out=$(output_path "$id")
      if [ -n "$FM_STATIC_GUARD_OUTPUT" ] && [ -s "$FM_STATIC_GUARD_OUTPUT" ]; then
        cp "$FM_STATIC_GUARD_OUTPUT" "$out" 2>/dev/null || out=
      else
        out=
      fi
      printf '%s\n' "$sha" > "$(seen_path "$id")" 2>/dev/null || true
      if [ -n "$out" ]; then
        printf '%s %s@%s fails the project static check; output in %s\n' \
          "$(basename "$MG_PROJECT")" "$MG_BRANCH" "${sha:0:12}" "$out"
      else
        printf '%s %s@%s fails the project static check\n' \
          "$(basename "$MG_PROJECT")" "$MG_BRANCH" "${sha:0:12}"
      fi
      ;;
    *)
      # No verdict, whether the check was unreachable or was killed by
      # MAIN_GUARD_BUDGET before it answered. Stay silent and do not record the
      # tip, so the next poll tries again instead of treating either as green.
      # Detection needs no separate timeout refusal the way bin/fm-pr-merge.sh
      # does: this half authorizes nothing, so the worst a killed check costs
      # here is a repeated poll. A project whose checker cannot finish inside
      # this budget is the arming-time problem the header describes.
      ;;
  esac
}

case "${1:---help}" in
  arm) shift; cmd_arm "$@" ;;
  disarm) shift; cmd_disarm "$@" ;;
  poll) shift; cmd_poll "$@" ;;
  --help|-h|help) usage ;;
  *) echo "error: unknown subcommand: $1" >&2; usage >&2; exit 2 ;;
esac
