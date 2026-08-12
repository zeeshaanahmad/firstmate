#!/usr/bin/env bash
# Bind an intentional custom watcher check to its current bytes.
# Usage: fm-check-register.sh <id>
#
# The watcher refuses to execute state/<id>.check.sh until this has bound its
# exact bytes, and refuses again after any later edit, so re-run it whenever the
# check changes. The binding rule itself lives in bin/fm-check-lib.sh, shared
# with the liveness-source registrar.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

[ "$#" -eq 1 ] || { echo "usage: fm-check-register.sh <id>" >&2; exit 2; }

trap '[ -z "${FM_TASK_SCRIPT_TRUST_TMP:-}" ] || rm -f -- "$FM_TASK_SCRIPT_TRUST_TMP"' EXIT HUP INT TERM
fm_task_script_register "$STATE" "$1" check
