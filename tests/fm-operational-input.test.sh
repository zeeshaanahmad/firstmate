#!/usr/bin/env bash
# Canonical current and isolated legacy operational-input protocol matrices.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

OWNER="$ROOT/bin/fm-operational-input.sh"
# shellcheck source=/dev/null
. "$OWNER"

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

classify_cli() {
  printf '%s' "$1" | "$OWNER" classify 2>/dev/null
}

kind_cli() {
  printf '%s' "$1" | "$OWNER" kind 2>/dev/null
}

truncated_cli() {
  printf '%s' "$1" | "$OWNER" truncated 2>/dev/null
}

test_current_generic_matrix() {
  local kind body encoded parsed stripped prefix_hex
  prefix_hex=$(printf '%s' "$FM_OPERATIONAL_PREFIX" | od -An -tx1 | tr -d ' \n')
  [ "$prefix_hex" = e281a346495253544d4154455f4f503a20 ] \
    || fail "current operational prefix lost the landed U+2063 FIRSTMATE_OP bytes: $prefix_hex"

  for kind in session-start watcher turn-end-guard away-supervisor launch-brief branch-outcome; do
    body="CURRENT_BODY_FOR_${kind}"
    fm_operational_input_encode "$kind" "$body" encoded \
      || fail "could not encode current $kind fixture"
    fm_operational_input_kind "$encoded" parsed \
      || fail "could not parse current $kind fixture"
    [ "$parsed" = "$kind" ] \
      || fail "current $kind fixture became $parsed"
    [ "$(kind_cli "$encoded")" = "$kind" ] \
      || fail "cross-language CLI lost current $kind"
    [ "$(classify_cli "$encoded")" = "$kind" ] \
      || fail "classifier lost current $kind"
    fm_operational_input_body "$encoded" stripped \
      || fail "could not recover current $kind body"
    [ "$stripped" = "$body" ] \
      || fail "current $kind body changed during encode/parse"
  done
  pass "operational input: every current generic envelope retains its exact structured kind"
}

test_current_from_firstmate_carrier() {
  local encoded parsed separator
  separator=$(printf '\342\201\243')
  fm_message_mark_from_firstmate "corr=0123456789abcdef inspect the report" encoded
  [ "${encoded#"[fm-from-firstmate]$separator"}" != "$encoded" ] \
    || fail "from-firstmate lost its live-charter-compatible leading carrier"
  fm_operational_input_kind "$encoded" parsed \
    || fail "from-firstmate current carrier did not parse"
  [ "$parsed" = from-firstmate ] \
    || fail "from-firstmate current carrier became $parsed"
  [ "$(classify_cli "$encoded")" = from-firstmate ] \
    || fail "cross-language classifier lost from-firstmate"
  pass "operational input: the established from-firstmate carrier remains structurally typed and byte-compatible"
}

test_landed_untyped_prefix_is_explicitly_legacy() {
  local untyped parsed
  untyped="${FM_OPERATIONAL_PREFIX}body whose historical subtype is unknowable"
  fm_legacy_operational_input_kind "$untyped" parsed \
    || fail "landed untyped FIRSTMATE_OP input was not retained"
  [ "$parsed" = legacy-operational ] \
    || fail "landed untyped FIRSTMATE_OP input falsely became $parsed"
  ! fm_operational_input_kind "$untyped" parsed \
    || fail "untyped FIRSTMATE_OP input passed the current typed parser"
  [ "$(classify_cli "$untyped")" = legacy-operational ] \
    || fail "CLI did not expose the untyped prefix as legacy-operational"
  pass "operational input: untyped landed FIRSTMATE_OP transcripts are explicit legacy-operational input"
}

test_isolated_legacy_matrix() {
  local watcher turnend away parsed
  watcher="${FM_LEGACY_WATCHER_PREFIX}signal: legacy${FM_LEGACY_WATCHER_SUFFIX}"
  turnend="${FM_LEGACY_TURNEND_PREFIX}watcher: FAILED - legacy"
  away="${FM_LEGACY_AWAY_PREFIX}1 event(s)): done: legacy"

  for fixture in \
    "session-start|$FM_LEGACY_SESSIONSTART" \
    "watcher|$watcher" \
    "turn-end-guard|$turnend" \
    "away-supervisor|$away"
  do
    expected=${fixture%%|*}
    message=${fixture#*|}
    ! fm_operational_input_kind "$message" parsed \
      || fail "legacy $expected fixture leaked into the current parser"
    fm_legacy_operational_input_kind "$message" parsed \
      || fail "legacy $expected fixture was not recognized"
    [ "$parsed" = "$expected" ] \
      || fail "legacy $expected fixture became $parsed"
  done
  pass "operational input: historical prose compatibility is isolated from current parsing"
}

test_genuine_near_misses_remain_unclassified() {
  local marker fixture parsed
  marker=$FM_OPERATIONAL_MARK
  while IFS= read -r fixture || [ -n "$fixture" ]; do
    [ -n "$fixture" ] || continue
    ! fm_operational_input_classify "$fixture" parsed \
      || fail "genuine near miss was classified as $parsed: $fixture"
    [ -z "$(classify_cli "$fixture" || true)" ] \
      || fail "CLI classified a genuine near miss: $fixture"
  done <<EOF
Captain quote: ${FM_OPERATIONAL_PREFIX}v1 watcher
FIRSTMATE_OP: v1 watcher
quoting the terminator label FIRSTMATE_OP_END: v1 watcher
$marker arbitrary captain text
Captain quote: $FM_LEGACY_SESSIONSTART
${FM_LEGACY_SESSIONSTART} Please explain this sentence.
FIRSTMATE WATCHER WAKE: can you explain this phrase?
TURN WOULD END BLIND - can you make this warning friendlier?
Supervisor escalate (1 event(s)): is this wording clear?
[fm-from-firstmate] inspect this visible label
EOF
  pass "operational input: quoted, ASCII-only, arbitrary-U+2063, altered-legacy, and label-only near misses stay genuine"
}

# A delivered message can lose its head. The receiver's away-mode contract reads
# an unmarked message as "the captain returned", so a front-cut escalation that
# no longer carries a machine marker is not merely lost - it stops the daemon
# and discards the decision it was carrying. This drives the two signals apart
# deliberately: the SAME escalation, cut and uncut, must classify differently
# from genuine captain speech and identically to each other in origin.
test_front_truncated_envelope_stays_operational_input() {
  local encoded fragment cut kind body
  fm_operational_input_encode away-supervisor \
    "Supervisor escalate (3 event(s)): c1 needs-decision: retry policy A or B" encoded \
    || fail "could not encode the away fixture"

  # Cut past the leading header AND past the start of the body, the shape the
  # 2026-08-31 delivery produced: only a tail of prose plus the terminator.
  cut=$(( ${#encoded} - 40 ))
  [ "$cut" -gt "${#FM_OPERATIONAL_HEADER_PREFIX}" ] \
    || fail "fixture too short to cut past its own header"
  fragment=${encoded:$cut}
  case "$fragment" in
    "$FM_OPERATIONAL_MARK"*|"$FM_OPERATIONAL_PREFIX"*)
      fail "fragment still starts with a leading marker; the cut proves nothing" ;;
  esac

  # The divergence itself: the fragment is operational input, plain prose is not.
  fm_operational_input_kind "$fragment" kind \
    || fail "front-truncated envelope was not recognized as operational input"
  [ "$kind" = away-supervisor ] \
    || fail "front-truncated away escalation became $kind"
  [ "$(kind_cli "$fragment")" = away-supervisor ] \
    || fail "cross-language CLI lost the front-truncated away escalation"
  fm_operational_input_kind \
    "ettled. (pre-read; re-arm not needed - watcher daemon-managed)" kind \
    && fail "the same tail WITHOUT a terminator classified as operational input"

  # And it is flagged as partial, so no caller mistakes the tail for a body.
  fm_operational_input_is_truncated "$fragment" \
    || fail "front-truncated envelope was not reported as truncated"
  truncated_cli "$fragment" \
    || fail "CLI did not report the front-truncated envelope as truncated"
  fm_operational_input_is_truncated "$encoded" \
    && fail "an intact envelope was reported as truncated"
  truncated_cli "$encoded" \
    && fail "CLI reported an intact envelope as truncated"

  # The surviving text is readable without the terminator bolted onto it.
  fm_operational_input_body "$fragment" body \
    || fail "could not read the surviving fragment text"
  case "$body" in
    *"$FM_OPERATIONAL_MARK"*) fail "fragment text still carries the terminator: $body" ;;
  esac
  [ -n "$body" ] || fail "fragment text came back empty"
  pass "operational input: a front-cut envelope stays typed operational input, flagged partial, while the same prose without a terminator stays captain speech"
}

# A TAIL cut removes the terminator instead. The leading header must still carry
# the classification on its own, so neither end is load-bearing alone.
test_tail_truncated_envelope_stays_operational_input() {
  local encoded head kind
  fm_operational_input_encode watcher "signal: c1 done: PR open" encoded \
    || fail "could not encode the watcher fixture"
  head=${encoded:0:$(( ${#encoded} - 30 ))}
  case "$head" in
    *"$FM_OPERATIONAL_TERMINATOR_PREFIX"*) fail "tail cut did not remove the terminator" ;;
  esac
  fm_operational_input_kind "$head" kind \
    || fail "tail-truncated envelope lost its leading classification"
  [ "$kind" = watcher ] || fail "tail-truncated watcher input became $kind"
  pass "operational input: a tail-cut envelope still classifies from its surviving leading header"
}

test_cross_language_adapter_uses_the_owner() {
  local encoded parsed
  encoded=$(FM_TEST_ROOT="$ROOT" HELPER="$ROOT/.opencode/plugins/lib/fm-operational-input.js" \
    node --input-type=module <<'JS'
import { pathToFileURL } from "node:url";
const { encodeFirstmateOperationalInput } = await import(pathToFileURL(process.env.HELPER).href);
process.stdout.write(await encodeFirstmateOperationalInput(process.env.FM_TEST_ROOT, "watcher", "CROSS_LANGUAGE_BODY"));
JS
  ) || fail "OpenCode cross-language adapter could not invoke the canonical owner"
  fm_operational_input_kind "$encoded" parsed \
    || fail "OpenCode cross-language adapter returned an invalid current envelope"
  [ "$parsed" = watcher ] \
    || fail "OpenCode cross-language adapter changed watcher to $parsed"
  pass "operational input: the OpenCode adapter constructs through the canonical owner"
}

test_invalid_current_encodings_are_rejected() {
  local output
  output=$(printf 'body' | "$OWNER" encode legacy-operational 2>/dev/null) \
    && fail "legacy-operational was accepted as a current producer kind"
  [ -z "$output" ] || fail "invalid current kind printed protocol data"
  output=$(printf '' | "$OWNER" encode watcher 2>/dev/null) \
    && fail "empty current operational body was accepted"
  [ -z "$output" ] || fail "empty current body printed protocol data"
  pass "operational input: current construction rejects legacy kinds and empty bodies"
}

test_current_generic_matrix
test_current_from_firstmate_carrier
test_landed_untyped_prefix_is_explicitly_legacy
test_front_truncated_envelope_stays_operational_input
test_tail_truncated_envelope_stays_operational_input
test_isolated_legacy_matrix
test_genuine_near_misses_remain_unclassified
test_cross_language_adapter_uses_the_owner
test_invalid_current_encodings_are_rejected
