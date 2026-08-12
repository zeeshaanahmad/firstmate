#!/usr/bin/env bash
# Bind a task's liveness source to its current bytes.
# Usage: fm-liveness-register.sh <id>
#
# A liveness source declares that task <id> is waiting on long-running external
# work that supervision cannot see from the pane, and answers one question:
# how long ago did that work last make progress. Supervision consults it before
# declaring the task wedged, so a worker correctly idling while its declared
# work runs is not reported as stuck, while a worker whose declared work has
# stopped progressing still is - within the ordinary staleness grace.
#
# Write state/<id>.liveness.sh, then register it:
#
#   cat > "$FM_HOME/state/<id>.liveness.sh" <<'SH'
#   #!/usr/bin/env bash
#   docker ps --format '{{.Image}}' | grep -qx my-gate-image && echo alive
#   SH
#   chmod 0700 "$FM_HOME/state/<id>.liveness.sh"
#   bin/fm-liveness-register.sh <id>
#
# Source contract, enforced by bin/fm-liveness-lib.sh:
#   - an ordinary single-link mode-0700 regular file in the state directory,
#     run as `bash <verified snapshot>` like a custom watcher check, so any
#     other shebang is ignored
#   - prints exactly one line and exits 0 when the work is alive:
#       alive              the work made progress just now
#       age: <seconds>     the work last made progress <seconds> ago
#   - prints nothing (or exits non-zero) when it cannot show the work alive
#   - finishes before FM_LIVENESS_TIMEOUT
# Anything else is read as no answer, which leaves the ordinary pane-based
# staleness reading in force.
#
# The watcher refuses to execute the source until this has bound its exact
# bytes, and refuses again after any later edit, so re-run it whenever the
# source changes. Retiring a task's declared work is a plain `rm` of the source
# and its trust record; teardown removes both.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

[ "$#" -eq 1 ] || { echo "usage: fm-liveness-register.sh <id>" >&2; exit 2; }

trap '[ -z "${FM_TASK_SCRIPT_TRUST_TMP:-}" ] || rm -f -- "$FM_TASK_SCRIPT_TRUST_TMP"' EXIT HUP INT TERM
fm_task_script_register "$STATE" "$1" liveness
