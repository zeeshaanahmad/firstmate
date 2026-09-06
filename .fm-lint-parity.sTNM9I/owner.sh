#!/usr/bin/env bash
# shellcheck source=.fm-lint-parity.sTNM9I/owner-dep.sh
. "/Users/muhammadzahmed/.no-mistakes/worktrees/c3eda0adcf59/01M1VMQB5B0JKZ0N9V7JYD2BAV/.fm-lint-parity.sTNM9I/owner-dep.sh"
owner_bad() {
  printf '%s\n' "$owner_dependency_value"
  cd "$1"
}
