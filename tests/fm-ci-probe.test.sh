#!/usr/bin/env bash
# tests/fm-ci-probe.test.sh - fm-ci-probe.sh derives its none/present/unknown
# verdict from the forge's actions/runs answer, never from a hardcoded repo
# name, and never guesses "none" when that answer could not be read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROBE="$ROOT/bin/fm-ci-probe.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-probe)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "$1" in
  repo)
    [ "${FM_TEST_GH_REPOVIEW_FAIL:-0}" = 0 ] || exit 1
    printf '%s\n' "${FM_TEST_GH_REPOVIEW:-owner/repo}"
    ;;
  api)
    [ "${FM_TEST_GH_API_FAIL:-0}" = 0 ] || exit 1
    printf '%s\n' "${FM_TEST_GH_TOTAL:-0}"
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$FAKEBIN/gh"

run_probe() {  # [<owner/repo>]
  : > "$TMP_ROOT/gh.log"
  FM_TEST_GH_LOG="$TMP_ROOT/gh.log" PATH="$FAKEBIN:$PATH" "$PROBE" "$@"
}

# A repo whose forge reports zero Actions runs ever - the ci step's trap
# condition - is excluded: the probe answers "none".
out=$(FM_TEST_GH_TOTAL=0 run_probe agentic/no-checks-repo)
[ "$out" = "none" ] || fail "zero runs did not verdict none (got: $out)"
grep -q 'api repos/agentic/no-checks-repo/actions/runs' "$TMP_ROOT/gh.log" \
  || fail "probe did not query the exact owner/repo it was given"
pass "a repo with zero Actions runs ever verdicts none"

# A repo with real check history is not excluded: the probe answers "present".
out=$(FM_TEST_GH_TOTAL=42 run_probe real/checks-repo)
[ "$out" = "present" ] || fail "nonzero runs did not verdict present (got: $out)"
pass "a repo with Actions run history verdicts present"

# The verdict is read from the forge's answer, not the repo's name: swapping
# which fixture reports zero runs swaps which one verdicts none, proving the
# logic is not hardcoded to any specific project.
out=$(FM_TEST_GH_TOTAL=0 run_probe real/checks-repo)
[ "$out" = "none" ] || fail "verdict did not follow the forge's answer for a renamed fixture (got: $out)"
pass "verdict is derived from the forge's answer, not a hardcoded repo name"

# No argument: the probe resolves owner/repo from the current directory's
# origin remote via `gh repo view`, then asks the same question.
out=$(FM_TEST_GH_REPOVIEW=resolved/via-origin FM_TEST_GH_TOTAL=0 run_probe)
[ "$out" = "none" ] || fail "no-arg resolution did not verdict none (got: $out)"
grep -q 'api repos/resolved/via-origin/actions/runs' "$TMP_ROOT/gh.log" \
  || fail "no-arg probe did not query the repo resolved via gh repo view"
pass "with no argument, the probe resolves the repo from the origin remote"

# The forge's answer could not be read (auth, network, missing repo, API
# error): the probe never guesses "none" - it says so plainly.
out=$(FM_TEST_GH_API_FAIL=1 run_probe owner/unreadable)
[ "$out" = "unknown" ] || fail "an unreadable forge answer did not verdict unknown (got: $out)"
pass "an unreadable actions/runs answer verdicts unknown rather than guessing"

# The origin remote itself could not be resolved: same refusal to guess.
out=$(FM_TEST_GH_REPOVIEW_FAIL=1 run_probe)
[ "$out" = "unknown" ] || fail "an unresolvable origin remote did not verdict unknown (got: $out)"
pass "an unresolvable origin remote verdicts unknown rather than guessing"

echo "ALL TESTS PASSED"
