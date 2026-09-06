#!/usr/bin/env bash
# shellcheck source=.fm-lint-parity.JlNK8W/owner-dep.sh
. "/Users/muhammadzahmed/.no-mistakes/worktrees/c3eda0adcf59/01M1VSJPTHWPAVD9E43TNE3KVB/.fm-lint-parity.JlNK8W/owner-dep.sh"
owner_bad() {
  printf '%s\n' "$owner_dependency_value"
  cd "$1"
}
