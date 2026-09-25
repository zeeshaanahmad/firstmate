#!/usr/bin/env bash
# Live driver: run the REAL bin/fm-dispatch-resolve.sh (typed dispatch
# resolution) against a profile that declares `quota_scope`, with fake curl and
# quota-axi on PATH (no network, no real quota read).
#
# Usage: drive-quota-scope-resolver.sh <repo-root>
#
# Case 1: an `agy` profile declares quota_scope=claude_gpt and the snapshot
#         holds an EXHAUSTED claude_gpt row next to a healthy all_models row.
# Case 2: the same profile declares a whitespace-padded quota_scope.
set -u
REPO=${1:?repo root}
TOOL="$REPO/bin/fm-dispatch-resolve.sh"
[ -x "$TOOL" ] || { echo "no resolver at $TOOL" >&2; exit 1; }

T=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-quota-scope.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/config" "$T/fakebin" "$T/log"
export FM_GATE_REFUSE_BYPASS=1

cat > "$T/brief.md" <<'MD'
# Task
Route this feature to the right harness.
MD

cat > "$T/fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
cat > /dev/null
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '200'
SH
cat > "$T/fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --json ] || exit 2
cat "${QUOTA_AXI_FIXTURE:?}"
SH
chmod +x "$T/fakebin/curl" "$T/fakebin/quota-axi"

cat > "$T/response.json" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "rule_1", "confidence": 0.95,
    "probabilities": { "rule_1": 0.97, "default": 0.03 } } },
  "usage": { "input_tokens": 100, "output_tokens": 10 } }
JSON

cat > "$T/quota.json" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    { "provider": "agy", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 64, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.4 } },
      { "scope": "claude_gpt", "status": "known", "effectivePercentRemaining": 0, "runway": { "status": "exhausted_now" }, "selection": { "spendPriority": -1 } } ] } },
    { "provider": "cursor", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 91, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.3 } } ] } }
  ]
}
JSON

write_rules() { # <quota_scope json value>
  cat > "$T/home/config/crew-dispatch.json" <<JSON
{
  "rules": [
    { "when": "Feature work that suits the Claude/GPT tier on Antigravity.",
      "use": [
        { "harness": "agy", "model": "claude-opus-4-6-thinking", "quota_scope": $1 },
        { "harness": "cursor", "model": "cursor-grok-4.6-medium" }
      ] }
  ]
}
JSON
}

run_case() { # <label> <quota_scope json value>
  local out code
  write_rules "$2"
  out=$(PATH="$T/fakebin:$PATH" FM_HOME="$T/home" TYPESAFE_API_KEY=test-key \
        FAKE_CURL_RESPONSE="$T/response.json" QUOTA_AXI_FIXTURE="$T/quota.json" \
        "$TOOL" "$T/brief.md" --project demo 2>"$T/stderr")
  code=$?
  echo "--- $1 (quota_scope=$2)"
  echo "exit=$code"
  printf '%s\n' "$out" | sed 's/^/  out| /'
  sed 's/^/  err| /' "$T/stderr"
}

echo "repo=$REPO"
run_case "case1: declared tier row is exhausted" '"claude_gpt"'
run_case "case2: whitespace-padded quota_scope" '" claude_gpt "'
