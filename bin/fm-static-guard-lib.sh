#!/usr/bin/env bash
# fm-static-guard-lib.sh - the single owner of "discover the project's own
# pinned static check and run it against one git tree".
#
# Sourced, never executed. Two callers share it and must not drift:
#
#   bin/fm-pr-merge.sh   prevention: checks the exact squash RESULT of a PR
#                        against the current default-branch tip before merging
#   bin/fm-main-guard.sh detection: checks the default-branch tip itself after
#                        it moves, and wakes firstmate when it is red
#
# Why this exists: a project's gate validates a PR against the base it was
# rebased onto, and nothing re-validates the combination of that PR with
# whatever landed on the default branch in the meantime. Where the forge runs
# no CI, that combination is never checked by anything before it becomes the
# default branch.
#
# WHAT THIS DOES NOT CATCH. The static class only - undefined names, unused or
# misordered imports, formatting, and whatever else the project's own pinned
# checker reports. Runtime test failures, type-checker errors, and snapshot
# drift all pass it. It is a cheap guard on the one thing the gate never sees,
# never a substitute for the gate.
#
# THIS DOES NOT SURVIVE AN AIRGAPPED SITE. A project's pinned checker is
# typically fetched by its pin (for example `uvx ruff@<version>`), which needs
# the network on a cold cache, and the guard also fetches the current
# default-branch tip from the forge. At a sealed site both are unavailable and
# the guard degrades to "unguarded" rather than pretending to a verdict.
#
# TRUST. The check command is discovered ONLY from a trusted revision - the
# current default-branch tip - never from the tree under test. A pushed branch
# therefore cannot weaken, redirect, or disable the guard by editing its own
# `.no-mistakes.yaml` or `Makefile`. The tree under test is still project code
# the checker reads, exactly as the project's own gate reads it.
#
# OBJECT STORE. Callers never fetch into a project clone: firstmate does not
# run state-changing commands inside a project. Instead
# fm_static_guard_repo_prepare makes a private bare repository that borrows the
# project's object store through git alternates, which copies refs rather than
# objects, so one incremental fetch of the default branch is all the network
# this needs. `~/.no-mistakes/repos/` is deliberately NOT used: it is another
# tool's private cache, with opaque hashed directory names, several mirrors per
# repository, no documented repo-to-mirror mapping, no freshness guarantee, and
# nothing at all for a project that never ran that pipeline.
#
# GIT VERSION. Computing the merge result needs `git merge-tree --write-tree`
# (git 2.38 and later). Older git cannot compute it, which reads as no verdict
# and degrades to unguarded rather than to a silent pass.
#
# A CUT-OFF CHECK IS NOT NO-VERDICT. "unguarded" means the guard could not
# reach the check at all - nothing discoverable, no forge, no object store, a
# git too old. A check that WAS discovered, WAS launched, and was then killed
# by its budget is a different outcome and gets its own verdict, "timeout",
# because it has a way forward the unguarded cases do not: run it again with
# room. Collapsing the two is what let a killed check read as permission to
# merge on 2026-08-24.
#
# Every function returns non-zero rather than exiting, so a sourcing script
# keeps control of its own refusal path.
set -u

# Bounded execution and clone-URL safety already have owners; source them from
# the same directory as this file so a caller sources one library, not three.
FM_STATIC_GUARD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_STATIC_GUARD_LIB_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-project-origin-lib.sh
. "$FM_STATIC_GUARD_LIB_DIR/fm-project-origin-lib.sh"

FM_STATIC_GUARD_SCRATCH=
FM_STATIC_GUARD_GITDIR=
FM_STATIC_GUARD_REMOTE=
FM_STATIC_GUARD_BRANCH=
FM_STATIC_GUARD_TREE=
FM_STATIC_GUARD_VERDICT=
FM_STATIC_GUARD_DETAIL=
FM_STATIC_GUARD_OUTPUT=
FM_STATIC_CHECK_CMD=
FM_STATIC_CHECK_SOURCE=

# Seconds allowed for one git network call and for one whole check run. Both
# are overridable so a slower project or a slower link can be accommodated
# without editing this file.
#
# THE CHECK BUDGET IS A HANG BOUND, NOT A PERFORMANCE TARGET. Its only job is
# to stop a wedged checker from hanging a merge forever, so it must clear the
# slowest check that genuinely finishes. The original 180s was sized against a
# fast linter (ruff, ~2s) and was marginal for a project whose own gate is
# slower: firstmate's own shellcheck gate measured 439s and 507s across two runs
# on one machine, so 180s killed a check that was in fact green. 900s clears
# that with headroom for the observed run-to-run spread; docs/verification/
# merge-time-static-guard.md holds the measurement. A project slower than this
# raises FM_STATIC_CHECK_TIMEOUT for that merge - the refusal names the knob.
FM_STATIC_GUARD_FETCH_TIMEOUT=${FM_STATIC_GUARD_FETCH_TIMEOUT:-60}
FM_STATIC_CHECK_TIMEOUT=${FM_STATIC_CHECK_TIMEOUT:-900}

# Private refs the guard writes into its own bare repository. They never touch
# the project clone, so their names only have to be stable here.
# shellcheck disable=SC2034 # Consumed by the sourcing guards' own refspecs.
FM_STATIC_GUARD_BASE_REF=refs/heads/fm-static-guard-base
# shellcheck disable=SC2034 # Consumed by bin/fm-pr-merge.sh's PR-head refspec.
FM_STATIC_GUARD_HEAD_REF=refs/heads/fm-static-guard-head

fm_static_guard_scratch_new() {  # sets FM_STATIC_GUARD_SCRATCH
  fm_static_guard_cleanup
  FM_STATIC_GUARD_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-static-guard.XXXXXX") || {
    FM_STATIC_GUARD_SCRATCH=
    return 1
  }
  chmod 0700 "$FM_STATIC_GUARD_SCRATCH" 2>/dev/null || true
}

# Scratch removal is the only recursive delete here. It refuses an empty path
# and refuses anything that is not the directory mktemp handed us, so no
# composed path can widen it.
fm_static_guard_cleanup() {
  if [ -n "$FM_STATIC_GUARD_SCRATCH" ] \
    && [ -d "$FM_STATIC_GUARD_SCRATCH" ] && [ ! -L "$FM_STATIC_GUARD_SCRATCH" ]; then
    case "$FM_STATIC_GUARD_SCRATCH" in
      /*/fm-static-guard.*) rm -rf -- "$FM_STATIC_GUARD_SCRATCH" ;;
    esac
  fi
  FM_STATIC_GUARD_SCRATCH=
  FM_STATIC_GUARD_GITDIR=
}

# Remove one plain file the guard created inside its own scratch directory.
fm_static_guard_scratch_file_remove() {  # <path>
  local path=${1-}
  [ -n "$path" ] && [ -n "$FM_STATIC_GUARD_SCRATCH" ] || return 1
  case "$path" in
    "$FM_STATIC_GUARD_SCRATCH"/?*) ;;
    *) return 1 ;;
  esac
  [ -e "$path" ] || [ -L "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  rm -f -- "$path"
}

# Make a private bare repository that shares <source-repo>'s objects through
# git alternates. <source-repo> is any local checkout or worktree of the
# project - firstmate records one as `worktree=` in a task's metadata and keeps
# another under projects/. The private repository is where every later fetch,
# merge-tree, and index write goes, so the project itself is never written to.
# The borrowed objects are only borrowed for the seconds this lives: nothing
# here holds them against a concurrent gc in the source repository.
fm_static_guard_repo_prepare() {  # <source-repo>; sets FM_STATIC_GUARD_GITDIR
  local src=$1 dest
  FM_STATIC_GUARD_GITDIR=
  [ -n "$FM_STATIC_GUARD_SCRATCH" ] || return 1
  [ -n "$src" ] && [ -d "$src" ] || return 1
  git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || return 1
  dest="$FM_STATIC_GUARD_SCRATCH/objects.git"
  [ ! -e "$dest" ] || return 1
  git clone --bare --shared --local --quiet "$src" "$dest" >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2034 # The private object store every caller then reads.
  FM_STATIC_GUARD_GITDIR=$dest
}

# Choose which remote of <source-repo> serves <owner>/<repo>. A lane pushes its
# branch to `origin` and opens the PR there, so origin is the answer in the
# ordinary case; the scan exists so a checkout that also carries an upstream
# remote still fetches the default branch of the repository the PR is actually
# on. A remote URL that fm_project_origin_safe refuses is never returned.
fm_static_guard_remote_pick() {  # <source-repo> [<owner/repo>]; sets FM_STATIC_GUARD_REMOTE
  local src=$1 slug=${2:-} name url fallback=
  FM_STATIC_GUARD_REMOTE=
  [ -n "$src" ] && [ -d "$src" ] || return 1
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    url=$(git -C "$src" remote get-url "$name" 2>/dev/null) || continue
    fm_project_origin_safe "$url" || continue
    if [ -n "$slug" ]; then
      case "${url%.git}" in
        *"/$slug"|*":$slug") FM_STATIC_GUARD_REMOTE=$url; return 0 ;;
      esac
    fi
    [ "$name" = origin ] && fallback=$url
  done < <(git -C "$src" remote 2>/dev/null)
  [ -n "$fallback" ] || return 1
  # shellcheck disable=SC2034 # Read by the caller that asked which remote to use.
  FM_STATIC_GUARD_REMOTE=$fallback
}

# Read the default branch a remote advertises for HEAD. Used only when the
# forge could not tell us the PR's actual base branch.
fm_static_guard_default_branch() {  # <remote-url>; sets FM_STATIC_GUARD_BRANCH
  local url=$1 line ref
  FM_STATIC_GUARD_BRANCH=
  fm_project_origin_safe "$url" || return 1
  line=$(fm_run_timed "$FM_STATIC_GUARD_FETCH_TIMEOUT" \
    git ls-remote --symref "$url" HEAD 2>/dev/null | head -1) || return 1
  case "$line" in
    "ref: refs/heads/"*) ;;
    *) return 1 ;;
  esac
  ref=${line#ref: refs/heads/}
  ref=${ref%%[[:space:]]*}
  fm_static_guard_ref_name_safe "$ref" || return 1
  # shellcheck disable=SC2034 # Read by the caller that asked for the default branch.
  FM_STATIC_GUARD_BRANCH=$ref
}

# A branch name that can be pasted into a refspec without becoming an option, a
# traversal, or a second argument.
fm_static_guard_ref_name_safe() {  # <name>
  local name=${1-}
  case "$name" in
    ''|-*|*[[:space:]]*|*[[:cntrl:]]*|*'..'*|*'~'*|*'^'*|*':'*|*'?'*|*'*'*|*'['*|*[\\]*) return 1 ;;
    */) return 1 ;;
  esac
}

fm_static_guard_sha_valid() {  # <sha>
  local sha=${1-}
  case "$sha" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  [ "${#sha}" = 40 ]
}

fm_static_guard_fetch() {  # <gitdir> <remote-url> <refspec>...
  local gitdir=$1 url=$2
  shift 2
  [ "$#" -ge 1 ] || return 1
  fm_project_origin_safe "$url" || return 1
  fm_run_timed "$FM_STATIC_GUARD_FETCH_TIMEOUT" \
    git --git-dir="$gitdir" fetch --no-tags --quiet --force "$url" "$@" >/dev/null 2>&1
}

# Compute the exact tree a squash merge of <head> onto <base> would produce.
# Returns 0 and sets FM_STATIC_GUARD_TREE on a clean merge, 2 when the merge
# conflicts (which is a refusal reason in its own right - a conflicted merge is
# not a mergeable PR), and 1 when the merge could not be computed at all.
fm_static_guard_merge_tree() {  # <gitdir> <base> <head>
  local gitdir=$1 base=$2 head=$3 out rc=0
  FM_STATIC_GUARD_TREE=
  out=$(git --git-dir="$gitdir" merge-tree --write-tree "$base" "$head" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 1 ] && return 2
    return 1
  fi
  out=${out%%$'\n'*}
  git --git-dir="$gitdir" rev-parse --verify --quiet "$out^{tree}" >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2034 # The merged tree the caller then evaluates.
  FM_STATIC_GUARD_TREE=$out
}

# Write <tree-ish> out as ordinary files under <dest> without touching any
# working copy: a private index is built with read-tree and emptied into <dest>
# with checkout-index.
fm_static_guard_materialize() {  # <gitdir> <tree-ish> <dest>
  local gitdir=$1 treeish=$2 dest=$3 index
  [ -n "$FM_STATIC_GUARD_SCRATCH" ] || return 1
  index="$FM_STATIC_GUARD_SCRATCH/index.$$"
  fm_static_guard_scratch_file_remove "$index" || return 1
  mkdir -p "$dest" || return 1
  GIT_DIR="$gitdir" GIT_INDEX_FILE="$index" \
    git read-tree "$treeish" >/dev/null 2>&1 || { fm_static_guard_scratch_file_remove "$index"; return 1; }
  GIT_DIR="$gitdir" GIT_WORK_TREE="$dest" GIT_INDEX_FILE="$index" \
    git checkout-index -a --prefix="$dest/" >/dev/null 2>&1 || { fm_static_guard_scratch_file_remove "$index"; return 1; }
  fm_static_guard_scratch_file_remove "$index"
}

# Pull `commands.lint` out of a `.no-mistakes.yaml`. Deliberately narrow: one
# single-line scalar under a top-level `commands:` mapping, plain or quoted.
# A block scalar, an anchor, an alias, or a flow collection is not a command
# this can run, and reading one wrong is worse than reading none, so anything
# else yields nothing and the caller degrades to unguarded.
fm_static_check_parse_nm_lint() {  # reads YAML on stdin, prints the command
  awk '
    /^[^[:space:]#]/ { in_cmds = ($0 ~ /^commands:[[:space:]]*$/) ? 1 : 0; next }
    in_cmds && /^[[:space:]]+lint:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]+lint:[[:space:]]*/, "", line)
      print line
      exit
    }
  '
}

# Reduce one YAML scalar to the shell command it denotes, or nothing.
fm_static_check_scalar() {  # <raw>; prints the command
  local raw=${1-}
  case "$raw" in
    ''|'|'*|'>'*|'&'*|'*'*|'['*|'{'*|'#'*) return 1 ;;
  esac
  case "$raw" in
    "'"*"'")
      raw=${raw#\'}
      raw=${raw%\'}
      ;;
    '"'*'"')
      raw=${raw#\"}
      raw=${raw%\"}
      ;;
    *)
      # A plain YAML scalar ends at an unquoted " #" comment.
      case "$raw" in
        *' #'*) raw=${raw%% \#*} ;;
      esac
      ;;
  esac
  # Trailing whitespace is not part of the command.
  raw=${raw%"${raw##*[![:space:]]}"}
  case "$raw" in
    ''|*[[:cntrl:]]*) return 1 ;;
  esac
  printf '%s\n' "$raw"
}

# Discover the project's own static check from a TRUSTED revision. Sources are
# tried in order and the first that yields a command wins:
#   1. `.no-mistakes.yaml` -> commands.lint, the exact pinned command the
#      project's own gate runs
#   2. a `Makefile` with a `lint:` target -> `make lint`
# Sets FM_STATIC_CHECK_CMD and FM_STATIC_CHECK_SOURCE, or returns 1 so the
# caller can say plainly that it found nothing.
fm_static_check_discover() {  # <gitdir> <trusted-rev>
  local gitdir=$1 rev=$2 raw cmd
  FM_STATIC_CHECK_CMD=
  FM_STATIC_CHECK_SOURCE=
  raw=$(git --git-dir="$gitdir" show "$rev:.no-mistakes.yaml" 2>/dev/null \
    | fm_static_check_parse_nm_lint) || raw=
  if [ -n "$raw" ] && cmd=$(fm_static_check_scalar "$raw"); then
    FM_STATIC_CHECK_CMD=$cmd
    FM_STATIC_CHECK_SOURCE=.no-mistakes.yaml
    return 0
  fi
  # A `lint:` rule, not a `lint:=` variable assignment.
  if git --git-dir="$gitdir" show "$rev:Makefile" 2>/dev/null \
    | grep -qE '^lint:([^=]|$)'; then
    FM_STATIC_CHECK_CMD='make lint'
    FM_STATIC_CHECK_SOURCE=Makefile
    return 0
  fi
  return 1
}

# Run a discovered command inside <dir> with a hard bound, collecting stdout and
# stderr into <out-file>. Returns 0 green, 1 red, 2 the bound was hit.
fm_static_check_run() {  # <command> <dir> <seconds> <out-file>
  local cmd=$1 dir=$2 secs=$3 out=$4 rc=0
  : > "$out" || return 1
  ( cd "$dir" && fm_run_timed "$secs" bash -c "$cmd" ) > "$out" 2>&1 || rc=$?
  [ "$rc" -eq 124 ] && return 2
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# The shared verdict: discover the project's static check from <trusted-rev>
# and run it against <tree-ish>. Sets:
#   FM_STATIC_GUARD_VERDICT  green | red | timeout | unguarded
#   FM_STATIC_GUARD_DETAIL   one line naming what happened
#   FM_STATIC_GUARD_OUTPUT   file holding the checker's output, or empty
# Neither "unguarded" nor "timeout" is a pass. "unguarded" means the check was
# never reached; "timeout" means it was reached, launched, and killed before it
# could answer. Callers own what each one costs - the merge-time guard refuses a
# timeout and proceeds loudly on unguarded - but no caller may read either as
# green.
fm_static_guard_evaluate_tree() {  # <gitdir> <trusted-rev> <tree-ish> [<seconds>]
  local gitdir=$1 rev=$2 treeish=$3 secs=${4:-$FM_STATIC_CHECK_TIMEOUT} dir rc=0
  # shellcheck disable=SC2034 # VERDICT/DETAIL/OUTPUT are this function's whole
  # result; bin/fm-pr-merge.sh and bin/fm-main-guard.sh read all three.
  FM_STATIC_GUARD_VERDICT=unguarded
  FM_STATIC_GUARD_DETAIL=
  FM_STATIC_GUARD_OUTPUT=
  if ! fm_static_check_discover "$gitdir" "$rev"; then
    FM_STATIC_GUARD_DETAIL='no static check discovered'
    return 0
  fi
  [ -n "$FM_STATIC_GUARD_SCRATCH" ] || { FM_STATIC_GUARD_DETAIL='no scratch directory'; return 0; }
  dir="$FM_STATIC_GUARD_SCRATCH/tree"
  [ ! -e "$dir" ] || { FM_STATIC_GUARD_DETAIL='the scratch directory is already occupied'; return 0; }
  if ! fm_static_guard_materialize "$gitdir" "$treeish" "$dir"; then
    FM_STATIC_GUARD_DETAIL='the tree under test could not be written out'
    return 0
  fi
  FM_STATIC_GUARD_OUTPUT="$FM_STATIC_GUARD_SCRATCH/check.out"
  rc=0
  fm_static_check_run "$FM_STATIC_CHECK_CMD" "$dir" "$secs" "$FM_STATIC_GUARD_OUTPUT" || rc=$?
  case "$rc" in
    0)
      FM_STATIC_GUARD_VERDICT=green
      FM_STATIC_GUARD_DETAIL="$FM_STATIC_CHECK_SOURCE: $FM_STATIC_CHECK_CMD"
      ;;
    1)
      # shellcheck disable=SC2034 # Read by both guards; see the note above.
      FM_STATIC_GUARD_VERDICT=red
      FM_STATIC_GUARD_DETAIL="$FM_STATIC_CHECK_SOURCE: $FM_STATIC_CHECK_CMD"
      ;;
    2)
      # The check was killed with its answer still unwritten. Whatever partial
      # output it left measured nothing, so it is not offered as evidence.
      # shellcheck disable=SC2034 # Read by both guards; see the note above.
      FM_STATIC_GUARD_VERDICT=timeout
      FM_STATIC_GUARD_DETAIL="the static check did not finish within ${secs}s"
      FM_STATIC_GUARD_OUTPUT=
      ;;
    *)
      # The check could not be started at all, which is the unguarded class.
      # shellcheck disable=SC2034 # Read by both guards; see the note above.
      FM_STATIC_GUARD_DETAIL='the static check could not be run'
      FM_STATIC_GUARD_OUTPUT=
      ;;
  esac
  return 0
}
