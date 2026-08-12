#!/usr/bin/env bash
# Byte-binding for the task-scoped executables the watcher is allowed to run.
#
# ONE owner for the rule that a task-scoped script firstmate wrote is executed
# only from a private snapshot whose bytes still match the trust record its
# registrar wrote. Two kinds share this binding, because they share exactly this
# contract and differ only in what their output means:
#
#   check     state/<id>.check.sh     prints a line when firstmate should wake
#   liveness  state/<id>.liveness.sh  reports declared external work still alive
#
# Both are arbitrary code the watcher executes, so both need the same proof. A
# second copy of the binding for the second kind is what the one-owner rule
# exists to prevent: the copies drift, and one ends up weaker than the other.
#
# The on-disk trust version strings are per kind and must stay stable: live
# homes carry already-registered records written under them.

FM_TASK_SCRIPT_HASH=
FM_TASK_SCRIPT_SNAPSHOT=
FM_TASK_SCRIPT_FILE=
FM_TASK_SCRIPT_TRUST=
FM_TASK_SCRIPT_VERSION=

# Resolve a kind's artifact paths and trust version for <state>/<id>. Any
# unknown kind is refused rather than defaulted, so a typo cannot silently bind
# a script under another kind's version string.
fm_task_script_resolve() {  # <state> <id> <kind>
  local state=$1 id=$2 kind=$3
  FM_TASK_SCRIPT_FILE=
  FM_TASK_SCRIPT_TRUST=
  FM_TASK_SCRIPT_VERSION=
  case "$kind" in
    check)
      FM_TASK_SCRIPT_FILE="$state/$id.check.sh"
      FM_TASK_SCRIPT_TRUST="$state/$id.check-trust"
      FM_TASK_SCRIPT_VERSION=fm-custom-check-v1
      ;;
    liveness)
      FM_TASK_SCRIPT_FILE="$state/$id.liveness.sh"
      FM_TASK_SCRIPT_TRUST="$state/$id.liveness-trust"
      FM_TASK_SCRIPT_VERSION=fm-liveness-source-v1
      ;;
    *) return 1 ;;
  esac
}

fm_task_script_sha256() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

fm_task_script_trust_read() {  # <state> <id> <kind>
  local state=$1 id=$2 kind=$3 state_device version hash
  FM_TASK_SCRIPT_HASH=
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  fm_task_script_resolve "$state" "$id" "$kind" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$FM_TASK_SCRIPT_TRUST" 600 "$state_device" || return 1
  exec 9< "$FM_TASK_SCRIPT_TRUST" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r hash <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = "$FM_TASK_SCRIPT_VERSION" ] || return 1
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  FM_TASK_SCRIPT_HASH=$hash
}

fm_task_script_registered() {  # <state> <id> <kind>
  local state=$1 id=$2 kind=$3 hash state_device
  fm_task_script_trust_read "$state" "$id" "$kind" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$FM_TASK_SCRIPT_FILE" 700 "$state_device" || return 1
  hash=$(fm_task_script_sha256 "$FM_TASK_SCRIPT_FILE") || return 1
  [ "$hash" = "$FM_TASK_SCRIPT_HASH" ]
}

fm_task_script_snapshot_prepare() {  # <state> <id> <kind>
  local state=$1 id=$2 kind=$3 hash state_device
  fm_task_script_snapshot_cleanup
  fm_task_script_trust_read "$state" "$id" "$kind" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$FM_TASK_SCRIPT_FILE" 700 "$state_device" || return 1
  FM_TASK_SCRIPT_SNAPSHOT=$(mktemp "$state/.fm-task-script.XXXXXX") || return 1
  cp "$FM_TASK_SCRIPT_FILE" "$FM_TASK_SCRIPT_SNAPSHOT" || { fm_task_script_snapshot_cleanup; return 1; }
  chmod 0600 "$FM_TASK_SCRIPT_SNAPSHOT" || { fm_task_script_snapshot_cleanup; return 1; }
  [ -f "$FM_TASK_SCRIPT_SNAPSHOT" ] && [ ! -L "$FM_TASK_SCRIPT_SNAPSHOT" ] \
    || { fm_task_script_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_mode "$FM_TASK_SCRIPT_SNAPSHOT")" = 600 ] \
    || { fm_task_script_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_device "$FM_TASK_SCRIPT_SNAPSHOT")" = "$state_device" ] \
    || { fm_task_script_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_link_count "$FM_TASK_SCRIPT_SNAPSHOT")" = 1 ] \
    || { fm_task_script_snapshot_cleanup; return 1; }
  hash=$(fm_task_script_sha256 "$FM_TASK_SCRIPT_SNAPSHOT") \
    || { fm_task_script_snapshot_cleanup; return 1; }
  [ "$hash" = "$FM_TASK_SCRIPT_HASH" ] || { fm_task_script_snapshot_cleanup; return 1; }
}

fm_task_script_snapshot_cleanup() {
  [ -z "$FM_TASK_SCRIPT_SNAPSHOT" ] || rm -f -- "$FM_TASK_SCRIPT_SNAPSHOT"
  FM_TASK_SCRIPT_SNAPSHOT=
}

# Bind <state>/<id>'s <kind> script to its CURRENT bytes. Writes the trust
# record atomically, then re-verifies through the same read path the watcher
# uses, so a registration that cannot be read back leaves nothing behind.
# Prints "registered: state/<file>" on success; diagnostics go to stderr.
# FM_TASK_SCRIPT_TRUST_TMP holds the in-flight temp path so a caller that can be
# signalled mid-write cleans it up from its own trap; it is cleared once the
# temp file is either renamed into place or removed.
FM_TASK_SCRIPT_TRUST_TMP=
fm_task_script_trust_tmp_discard() {
  [ -z "$FM_TASK_SCRIPT_TRUST_TMP" ] || rm -f -- "$FM_TASK_SCRIPT_TRUST_TMP"
  FM_TASK_SCRIPT_TRUST_TMP=
}
fm_task_script_register() {  # <state> <id> <kind>
  local state=$1 id=$2 kind=$3 state_device hash
  fm_pr_task_id_valid "$id" || { echo "error: invalid $kind registration" >&2; return 2; }
  fm_task_script_resolve "$state" "$id" "$kind" || { echo "error: unknown registration kind: $kind" >&2; return 2; }
  [ -d "$state" ] && [ ! -L "$state" ] || { echo "error: state directory is unavailable" >&2; return 1; }
  [ -f "$FM_TASK_SCRIPT_FILE" ] && [ ! -L "$FM_TASK_SCRIPT_FILE" ] \
    || { echo "error: $kind script is unavailable" >&2; return 1; }
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$FM_TASK_SCRIPT_FILE" 700 "$state_device" \
    || { echo "error: $kind script is unavailable" >&2; return 1; }
  fm_pr_regular_destination_on_device_or_absent "$FM_TASK_SCRIPT_TRUST" "$state_device" \
    || { echo "error: $kind trust path is unavailable" >&2; return 1; }
  hash=$(fm_task_script_sha256 "$FM_TASK_SCRIPT_FILE") \
    || { echo "error: $kind script hash is unavailable" >&2; return 1; }
  umask 077
  FM_TASK_SCRIPT_TRUST_TMP=$(mktemp "$state/.fm-task-script-trust.XXXXXX") || return 1
  printf '%s\n%s\n' "$FM_TASK_SCRIPT_VERSION" "$hash" > "$FM_TASK_SCRIPT_TRUST_TMP" \
    || { fm_task_script_trust_tmp_discard; return 1; }
  chmod 0600 "$FM_TASK_SCRIPT_TRUST_TMP" \
    || { fm_task_script_trust_tmp_discard; return 1; }
  fm_pr_regular_destination_on_device_or_absent "$FM_TASK_SCRIPT_TRUST" "$state_device" \
    || { fm_task_script_trust_tmp_discard; return 1; }
  mv -f -- "$FM_TASK_SCRIPT_TRUST_TMP" "$FM_TASK_SCRIPT_TRUST" \
    || { fm_task_script_trust_tmp_discard; return 1; }
  FM_TASK_SCRIPT_TRUST_TMP=
  fm_task_script_registered "$state" "$id" "$kind" \
    || { rm -f -- "$FM_TASK_SCRIPT_TRUST"; return 1; }
  printf 'registered: state/%s\n' "$(basename "$FM_TASK_SCRIPT_FILE")"
}
