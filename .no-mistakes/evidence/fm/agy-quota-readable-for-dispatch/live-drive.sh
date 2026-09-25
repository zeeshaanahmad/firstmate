#!/usr/bin/env bash
# Live driver for the agy quota_scope change in bin/fm-dispatch-resolve.sh.
#
# Runs the REAL resolver twice per scenario - the base commit's bin/ (before)
# and the worktree's bin/ (after) - against the REAL `quota-axi --json` on this
# machine (live Antigravity quota) and the real jq. The only stub is the
# typesafe.ai HTTP call (no TYPESAFE_API_KEY exists here and the call is an
# external paid service), served by a fake curl on PATH that returns a canned
# rule Choice. FM_HOME is an isolated scratch dir; nothing in the fleet is touched.
set -u
WT=${WT:?worktree path}
BASE=${BASE:?base commit}
OUT=${OUT:?evidence dir}

S=$(mktemp -d "${TMPDIR:-/tmp}/agy-live.XXXXXX")
trap 'rm -rf "$S"' EXIT
mkdir -p "$S/base" "$S/home/config" "$S/fakebin"
git -C "$WT" archive "$BASE" bin | tar -x -C "$S/base"

# fake curl = the typesafe.ai API only (records nothing, answers a canned Choice)
cat > "$S/fakebin/curl" <<'SH'
#!/usr/bin/env bash
out=''
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
cat >/dev/null
cat /dev/fd/3 >/dev/null 2>&1
cp "$FAKE_CURL_RESPONSE" "$out"
printf '200'
SH
chmod +x "$S/fakebin/curl"
printf '# Task\nBuild the agy-routed feature.\n' > "$S/brief.md"

# canned Jev answer: <choice> over N rules (+default)
respond() {  # <choice> <nrules>
  local choice=$1 n=$2 i probs=''
  for i in $(seq 1 "$n"); do probs="$probs\"rule_$i\": 0.01,"; done
  cat > "$S/response.json" <<JSON
{ "model": "jev-1.13.0", "answers": { "rule": { "type": "choice", "choice": "$choice", "confidence": 0.95,
  "probabilities": { $probs "default": $(awk -v n="$n" 'BEGIN{printf "%.2f", 1 - 0.01*n}') } } },
  "usage": { "input_tokens": 100, "output_tokens": 10 } }
JSON
}
export FAKE_CURL_RESPONSE="$S/response.json"

# run <label> <bin-root> [env...]: real resolver, live quota-axi (from PATH, after fakebin which holds curl only)
run_resolver() {  # <root> ; env passes through
  local root=$1
  PATH="$S/fakebin:$PATH" FM_HOME="$S/home" env "${@:2}" "$root/bin/fm-dispatch-resolve.sh" "$S/brief.md" --project pager
}
show() {  # <title> <cfg-file-path> <choice> <nrules>
  local title=$1 cfg=$2 choice=$3 n=$4 code
  printf '%s\n' "$cfg" > "$S/home/config/crew-dispatch.json"
  respond "$choice" "$n"
  echo "################################################################"
  echo "## $title"
  echo "## config: $(jq -c . "$S/home/config/crew-dispatch.json")"
  for side in before after; do
    if [ "$side" = before ]; then root="$S/base"; else root="$WT"; fi
    echo "---- $side ($([ $side = before ] && echo "base $BASE" || echo "worktree HEAD"))"
    run_resolver "$root" TYPESAFE_API_KEY=live-drive-stub-key 2>"$S/err"
    code=$?
    echo "  [exit=$code]"
    [ -s "$S/err" ] && sed 's/^/  [stderr] /' "$S/err"
  done
  echo
}

echo "live quota-axi agy rows at $(date -u +%FT%TZ):"
quota-axi --json | jq -c '.providers[] | select(.provider=="agy") | .quotaSemantics | {status, rows: [.effectiveAvailability[] | {scope, pct: .effectivePercentRemaining, runway: .runway.status, spend: (.selection.spendPriority // .selection.status)}]}'
echo

# S1: declared tiers against the live snapshot
show "S1 declared quota_scope on rule profiles (claude_gpt exhausted live, gemini healthy live, gone_tier absent)" \
  '{"rules":[{"when":"New feature work on the app.","use":[
     {"harness":"agy","model":"claude-opus-4-6-thinking","quota_scope":"claude_gpt"},
     {"harness":"agy","model":"gemini-3-pro","quota_scope":"gemini"},
     {"harness":"agy","model":"gemini-3-flash","quota_scope":"gone_tier"}]}]}' rule_1 1

# S2: undeclared agy profile keeps exactly the old behaviour (no model-name inference)
show "S2 agy profile WITHOUT quota_scope (backward compatible: nothing inferred from the model name)" \
  '{"rules":[{"when":"New feature work on the app.","use":[
     {"harness":"agy","model":"claude-opus-4-6-thinking"},
     {"harness":"agy","model":"gemini-3-pro"}]}]}' rule_1 1

# S3: only blocked tier available -> must not be dispatched
show "S3 only the exhausted claude_gpt tier is offered (must not clear)" \
  '{"rules":[{"when":"New feature work on the app.","use":{"harness":"agy","model":"claude-sonnet-4-6","quota_scope":"claude_gpt"}}]}' rule_1 1

# S4: blocked tier vs healthy tier + a second provider: routes to the non-blocked one
show "S4 blocked claude_gpt tier alongside healthy gemini tier: blocked one is ineligible, healthy one stays eligible (unranked: live spendPriority is unknown)" \
  '{"rules":[{"when":"New feature work on the app.","use":[
     {"harness":"agy","model":"claude-opus-4-6-thinking","quota_scope":"claude_gpt"},
     {"harness":"agy","model":"gemini-3-pro","quota_scope":"gemini"}]}]}' rule_1 1

# S5: default-profile path
show "S5 declared quota_scope on a default profile (no rule matches)" \
  '{"rules":[{"when":"New feature work on the app.","use":{"harness":"codex"}}],"default":[
     {"harness":"agy","model":"claude-opus-4-6-thinking","quota_scope":"claude_gpt"},
     {"harness":"agy","model":"gemini-3-pro","quota_scope":"gemini"}]}' default 1

# S6: adversarial - malformed quota_scope values are rejected (exit 2) before any network call
for bad in '""' '" gemini"' '"gemini\n"' '5' '["gemini"]' 'null'; do
  show "S6 malformed quota_scope=$bad on a rule profile" \
    "{\"rules\":[{\"when\":\"x\",\"use\":{\"harness\":\"agy\",\"quota_scope\":$bad}}]}" rule_1 1
done
show "S6 malformed quota_scope on a default profile" \
  '{"rules":[{"when":"x","use":{"harness":"codex"}}],"default":{"harness":"agy","quota_scope":""}}' default 1

# S8: mixed providers - blocked agy tier + unranked agy tier + a live-ranked codex candidate -> clear on the ranked one
show "S8 blocked claude_gpt tier + healthy-but-unranked gemini tier + live-ranked codex: clear pick is codex, blocked tier shown ineligible" \
  '{"rules":[{"when":"New feature work on the app.","use":[
     {"harness":"agy","model":"claude-opus-4-6-thinking","quota_scope":"claude_gpt"},
     {"harness":"agy","model":"gemini-3-pro","quota_scope":"gemini"},
     {"harness":"codex","model":"gpt-5.5"}]}]}' rule_1 1

# S7: opt-in gate - with no key the resolver is off even with quota_scope configured
printf '%s\n' '{"rules":[{"when":"x","use":{"harness":"agy","quota_scope":"claude_gpt"}}]}' > "$S/home/config/crew-dispatch.json"
echo "################################################################"
echo "## S7 no TYPESAFE_API_KEY: resolver is off, prints nothing on stdout"
out=$(PATH="$S/fakebin:$PATH" FM_HOME="$S/home" env -u TYPESAFE_API_KEY "$WT/bin/fm-dispatch-resolve.sh" "$S/brief.md" --project pager 2>"$S/err"); code=$?
echo "  [exit=$code] stdout=[$out]"; sed 's/^/  [stderr] /' "$S/err"
