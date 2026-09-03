#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1
#
# The `|| exit 1` is load-bearing, not style. This path only resolves for a file
# that actually lives in tests/, and bash treats a failed `.` as an ordinary
# non-zero return rather than a fatal error, so without it a file run from
# anywhere else keeps executing with every helper below undefined - and
# `TMP_ROOT=$(fm_test_tmproot prefix)` quietly becomes the empty string.
# tests/fm-test-fixture-cleanup.test.sh pins that every file in this directory
# refuses instead of continuing.
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, bounded waits,
# self-cleaning removal helpers, and the common string/exit-code/file
# assertions. Shared fake-toolchain and spawn-world builders live in
# tests/fixtures.sh; wake-queue mocks in wake-helpers.sh; secondmate-lifecycle
# mocks in secondmate-helpers.sh. Suite-specific fakes that encode a single
# test's terminal or lifecycle assumptions still belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh, fixtures.sh) source this library for ROOT/fail/pass, and the
# test that includes them may also source it directly. Re-sourcing must not wipe
# the registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on EXIT/INT/TERM. A test file that needs extra teardown (e.g. killing a
# daemon) should define its own EXIT trap and call fm_test_cleanup from inside
# it so registered dirs are still removed.
#
# The call site is almost always `TMP_ROOT=$(fm_test_tmproot prefix)`, which
# forks a subshell to capture stdout. Anything that function does to the
# current shell's state - an array append, a trap - dies with that subshell
# and never reaches the real caller, so registration cannot go through
# in-process state. `$$` is the one thing bash keeps stable across that
# boundary (it always resolves to the invoking shell's PID, not the
# subshell's - see `man bash` on `$$`), so fm_test_tmproot records the
# directory in a `$$`-keyed registry file instead, and the trap that reaps
# that file is armed once, here, at source time - which always runs in the
# real caller, never a subshell.

FM_TEST_CLEANUP_DIRS=()
FM_TEST_CLEANUP_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/.fm-test-cleanup.$$.XXXXXX") || return 1

fm_test_pid_identity() {
  local pid=$1
  FM_STATE_OVERRIDE="${TMPDIR:-/tmp}" bash -c \
    '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid"
}

FM_TEST_OWNER_IDENTITY=$(fm_test_pid_identity "$$") || {
  rm -f "$FM_TEST_CLEANUP_REGISTRY"
  return 1
}

# --- guarded fixture removal ------------------------------------------------
#
# fm_test_rmtree <path>... is the ONE recursive-removal path for a fixture root
# in this suite. The registry reaper, the orphan sweep, and the teardown trap of
# every test file that sources this library all go through it, so the guard is
# written once here instead of at the 112 call sites that own a fixture root.
#
# It refuses, loudly and without removing anything, unless <path> resolves
# strictly inside the temp root fm_test_tmproot allocates from, or was declared
# through fm_test_own_fixture. Emptiness and containment are checked separately
# because they fail independently: an unset TMP_ROOT is empty, but
# `TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)` - a real idiom in this suite - turns that
# empty value into $PWD, since `cd ""` succeeds as a no-op. A non-empty path is
# not a safe one.
#
# A fixture cannot always live under the temp root: tests/fm-lint.test.sh's
# source-boundary parity case needs a path REPO-RELATIVE to $ROOT, so it creates
# one there. fm_test_own_fixture is how such a root is declared, and it is guarded
# itself - it refuses the repo root, the working directory, and any ancestor of
# it, which are exactly the shapes the silent degradation above produces. So the
# escape hatch cannot become the incident.

# Physical form of the temp root in force when this library loaded. Captured
# here as well as re-read per call so a fixture rooted under the original TMPDIR
# is still removable after a test exports a narrower one.
FM_TEST_TMP_ROOT_AT_SOURCE=$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || FM_TEST_TMP_ROOT_AT_SOURCE=

# Set when a removal was refused, so the teardown that swallowed the refusal
# still fails the file rather than passing with a fixture left behind.
FM_TEST_RMTREE_REFUSED=

# fm_test_removal_path <path>: echo <path> with its PARENT resolved physically
# and its own last component appended verbatim. Resolving the parent rather than
# the path itself matches `rm -rf` semantics, which unlink a symlink instead of
# following it, and works for a path that is a file or does not exist.
fm_test_removal_path() {
  local path=$1 parent base
  parent=$(dirname -- "$path")
  base=$(basename -- "$path")
  case "$base" in
    '' | . | .. | /) return 1 ;;
  esac
  parent=$(cd "$parent" 2>/dev/null && pwd -P) || return 1
  [ "$parent" = / ] && parent=
  printf '%s/%s\n' "$parent" "$base"
}

# fm_test_removal_allowed <resolved-path>: true when the path sits strictly
# below a temp root - never at one, so the root itself can never be the target.
# The accepted roots are exactly the ones fm_test_tmproot can allocate from: the
# one in force when this library loaded, and the one in force right now. Nothing
# wider, so a path that merely looks temporary is still refused.
fm_test_removal_allowed() {
  local resolved=$1 candidate root
  for candidate in "$FM_TEST_TMP_ROOT_AT_SOURCE" "${TMPDIR:-/tmp}"; do
    [ -n "$candidate" ] || continue
    root=$(cd "$candidate" 2>/dev/null && pwd -P) || continue
    [ -n "$root" ] && [ "$root" != / ] || continue
    case "$resolved" in
      "$root"/?*) return 0 ;;
    esac
  done
  return 1
}

# fm_test_owned_fixture <resolved-path>: true when this shell's fixture registry
# records the path, which is the record of what this library was given to own.
fm_test_owned_fixture() {
  local resolved=$1 recorded line
  [ -f "$FM_TEST_CLEANUP_REGISTRY" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    recorded=$(fm_test_removal_path "$line") || continue
    [ "$recorded" = "$resolved" ] && return 0
  done < "$FM_TEST_CLEANUP_REGISTRY"
  return 1
}

# fm_test_own_fixture <dir>: declare a fixture root this suite created outside the
# temp root, so its teardown is permitted. Refuses the shapes a degraded TMP_ROOT
# takes - empty, the repo root, the working directory, or an ancestor of it - so
# declaring can never authorize the deletion this guard exists to prevent.
fm_test_own_fixture() {
  local dir=${1-} resolved root_resolved cwd
  if [ -z "$dir" ]; then
    printf 'not ok - fm_test_own_fixture refused an empty fixture path\n' >&2
    return 1
  fi
  if ! resolved=$(fm_test_removal_path "$dir"); then
    printf 'not ok - fm_test_own_fixture could not resolve fixture path %s\n' "$dir" >&2
    return 1
  fi
  root_resolved=$(cd "$ROOT" 2>/dev/null && pwd -P) || root_resolved=
  cwd=$(pwd -P)
  case "$cwd/" in
    "$resolved"/*)
      printf 'not ok - fm_test_own_fixture refused %s: it is the working directory or an ancestor of it\n' "$resolved" >&2
      return 1
      ;;
  esac
  if [ -n "$root_resolved" ] && [ "$resolved" = "$root_resolved" ]; then
    printf 'not ok - fm_test_own_fixture refused %s: that is the repo root\n' "$resolved" >&2
    return 1
  fi
  printf '%s\n' "$dir" >> "$FM_TEST_CLEANUP_REGISTRY" || return 1
}

fm_test_rmtree() {  # <path>...
  local path resolved rc=0
  if [ "$#" -eq 0 ]; then
    FM_TEST_RMTREE_REFUSED=1
    printf 'not ok - fm_test_rmtree was called with no fixture path; nothing removed\n' >&2
    return 1
  fi
  for path in "$@"; do
    if [ -z "$path" ]; then
      FM_TEST_RMTREE_REFUSED=1
      printf 'not ok - fm_test_rmtree refused an empty fixture path; nothing removed\n' >&2
      rc=1
      continue
    fi
    if ! resolved=$(fm_test_removal_path "$path"); then
      FM_TEST_RMTREE_REFUSED=1
      printf 'not ok - fm_test_rmtree could not resolve fixture path %s; nothing removed\n' "$path" >&2
      rc=1
      continue
    fi
    if ! fm_test_removal_allowed "$resolved" && ! fm_test_owned_fixture "$resolved"; then
      FM_TEST_RMTREE_REFUSED=1
      printf 'not ok - fm_test_rmtree refused %s: outside the fixture temp root and not a declared fixture; nothing removed\n' "$resolved" >&2
      rc=1
      continue
    fi
    rm -rf -- "$path"
  done
  return "$rc"
}

fm_test_cleanup() {
  local d
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && fm_test_rmtree "$d"
  done
  if [ -f "$FM_TEST_CLEANUP_REGISTRY" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && fm_test_rmtree "$d"
    done < "$FM_TEST_CLEANUP_REGISTRY"
    rm -f "$FM_TEST_CLEANUP_REGISTRY"
  fi
  if [ -n "$FM_TEST_RMTREE_REFUSED" ]; then
    exit 1
  fi
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX") || return 1
  if ! printf '%s\n%s\n' "$$" "$FM_TEST_OWNER_IDENTITY" > "$root/.fm-test-fixture" ||
    ! printf '%s\n' "$root" >> "$FM_TEST_CLEANUP_REGISTRY"; then
    rm -rf "$root"
    return 1
  fi
  printf '%s\n' "$root"
}

trap fm_test_cleanup EXIT
trap 'fm_test_cleanup; exit 130' INT
trap 'fm_test_cleanup; exit 143' TERM

# fm_test_reap_orphans: best-effort sweep for fixture roots left behind by a
# prior run that was killed hard enough to skip the traps above (e.g. a
# SIGKILL timeout). Only removes directories carrying the .fm-test-fixture
# marker fm_test_tmproot writes, so it never touches unrelated fm-* tmp dirs
# from real (non-test) firstmate commands. The marker identifies the owning
# shell across PID reuse, so the same live owner always wins over the age
# fallback for dead or unowned roots.
FM_TEST_ORPHAN_MAX_AGE_SECONDS=${FM_TEST_ORPHAN_MAX_AGE_SECONDS:-3600}

fm_test_reap_orphans() {
  local marker dir mtime now owner_pid owner_identity current_identity
  now=$(date +%s)
  for marker in "${TMPDIR:-/tmp}"/fm-*/.fm-test-fixture; do
    [ -e "$marker" ] || continue
    owner_pid=$(sed -n '1p' "$marker" 2>/dev/null) || owner_pid=
    owner_identity=$(sed -n '2,$p' "$marker" 2>/dev/null) || owner_identity=
    case "$owner_pid" in
      '' | *[!0-9]*) ;;
      *)
        current_identity=$(fm_test_pid_identity "$owner_pid" 2>/dev/null) || current_identity=
        if [ -n "$owner_identity" ] && [ "$current_identity" = "$owner_identity" ]; then
          continue
        fi
        ;;
    esac
    mtime=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null) || continue
    [ $((now - mtime)) -ge "$FM_TEST_ORPHAN_MAX_AGE_SECONDS" ] || continue
    dir=$(dirname "$marker")
    fm_test_rmtree "$dir"
  done
}

fm_test_reap_orphans

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir. fm_fake_version_tool drops a stub for a tool
# whose installed version bootstrap gates, so a fixture cannot be reported as an
# unparseable build simply for answering `--version` with nothing.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# fm_fake_version_tool <fakebin> <tool> <override-env-var> <default-version>
# The stub answers `--version` with <override-env-var> when that variable is set
# and non-empty, and with <default-version> otherwise; every other invocation
# exits 0. A case that needs to drive a version floor exports the variable.
fm_fake_version_tool() {
  local fakebin=$1 tool=$2 override=$3 default=$4
  cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' "\${$override:-$default}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: initialize <repo> with one commit
# and a local bare origin, then add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  fm_git_add_origin "$repo" "$repo.origin.git"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects] [harness]: write the
# standard kind=secondmate meta block used across the secondmate suites. Window
# defaults to firstmate:fm-<id>, projects defaults to alpha, and harness defaults
# to echo to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 id window projects=${4:-alpha} harness=${5:-echo}
  id=$(basename "$file" .meta)
  window=${3:-firstmate:fm-$id}
  fm_write_meta "$file" \
    "window=$window" \
    "endpoint_task_id=$id" \
    "worktree=$home" \
    "project=$home" \
    "harness=$harness" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- installed-harness resolution (live opt-in guards) ----------------------

# fm_test_resolve_harness_binary <harness>: echo the executable a live guard
# should launch for <harness>, or return 1 when it is not installed here.
# Mirrors bin/fm-spawn.sh's own resolution order so a guard covers the same
# binary firstmate would actually launch. Requires bin/fm-cursor-lib.sh to be
# sourced by the caller, which is where Cursor's verified resolver lives.
fm_test_resolve_harness_binary() {  # <harness>
  local harness=$1 candidate
  # cursor first, and NEVER by its own name: bin/fm-spawn.sh resolves it only
  # through the verified owner below, because `cursor` on PATH is commonly the
  # Cursor IDE launcher rather than the Cursor Agent CLI (which installs as
  # `cursor-agent` plus the far-too-generic legacy alias `agent`, routinely
  # outside a non-interactive PATH). Looking the name up first would hand a
  # guard a binary firstmate would never launch.
  if [ "$harness" = cursor ]; then
    fm_cursor_resolve_binary 2>/dev/null && return 0
    return 1
  fi
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  # Kimi is not required to be on PATH.
  if [ "$harness" = kimi ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    printf '%s\n' "$HOME/.kimi-code/bin/kimi"
    return 0
  fi
  return 1
}

# --- bounded waits ----------------------------------------------------------
#
# A test that blocks forever on a process it expected to exit reports nothing.
# CI cancels the whole job at its timeout, the runner reaps the surviving
# processes as orphans, and the log ends mid-suite with no diagnosis of which
# wait never returned.
# Every wait on a process whose exit a test cannot guarantee belongs in one of
# these, so an unexpected outcome fails that test loudly, names the wait, and
# stops the process tree instead of leaking it past the test.

# fm_test_pid_exits_within <pid> <seconds>: 0 once <pid> is gone, 1 on expiry.
fm_test_pid_exits_within() {
  local pid=$1 deadline
  deadline=$(( $(date +%s) + $2 ))
  while kill -0 "$pid" 2>/dev/null; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

# fm_test_kill_tree <pid>: stop <pid>, and every process in its group when it
# leads one of its own. A process started under `set -m` leads its own group, so
# this reaches a supervisor's children too rather than only the pid a test holds.
fm_test_kill_tree() {
  local pid=$1 pgid
  pgid=$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d '[:space:]')
  if [ -n "$pgid" ] && [ "$pgid" = "$pid" ]; then
    kill -KILL -- "-$pgid" 2>/dev/null || true
  fi
  kill -KILL "$pid" 2>/dev/null || true
}

# fm_test_wait_pid_bounded <pid> <seconds> <what>: wait for a background pid this
# test started, failing with <what> once the bound expires. Sets
# FM_TEST_BOUNDED_RC to the exit status when the process did finish in time.
# FM_TEST_BOUNDED_RC is read by the sourcing test, not by this library, so it
# reads as "unused" here.
# shellcheck disable=SC2034
fm_test_wait_pid_bounded() {
  local pid=$1 secs=$2 what=$3
  if ! fm_test_pid_exits_within "$pid" "$secs"; then
    fm_test_kill_tree "$pid"
    wait "$pid" 2>/dev/null || true
    fail "$what did not finish within ${secs}s; its process tree was stopped"
  fi
  # Captured through the || branch so a non-zero status is recorded rather than
  # aborting a caller that runs under errexit.
  FM_TEST_BOUNDED_RC=0
  wait "$pid" 2>/dev/null || FM_TEST_BOUNDED_RC=$?
  return 0
}

# fm_test_run_bounded <seconds> <what> <command> [args...]: run <command> in its
# own process group under the same bound. <command> may be a shell function, so
# the caller keeps its own redirections and environment assignments.
fm_test_run_bounded() {
  local secs=$1 what=$2 pid monitor
  shift 2
  # Job control makes the command lead its own process group, so the bound can
  # stop a whole supervisor tree. Restored rather than cleared, so a caller that
  # was already running with it keeps it.
  case "$-" in *m*) monitor=1 ;; *) monitor=0 ;; esac
  set -m
  "$@" &
  pid=$!
  [ "$monitor" -eq 1 ] || set +m
  fm_test_wait_pid_bounded "$pid" "$secs" "$what"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}
