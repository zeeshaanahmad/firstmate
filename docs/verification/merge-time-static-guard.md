# Verification: merge-time static guard cost and budget

Records the measurements the merge-time guard's check budget is sized from, and the guarantee that a check which cannot finish refuses the merge.
[`../merge-time-static-guard.md`](../merge-time-static-guard.md) owns the design; `bin/fm-static-guard-lib.sh` and `bin/fm-pr-merge.sh` own the mechanics.

## Where the guard's time goes

Measured 2026-08-24 on macOS 25.5.0 (darwin, arm64), against this repository at `4fecafb`, driving `bin/fm-static-guard-lib.sh` phase by phase.
The discovered check was `.no-mistakes.yaml: bin/fm-lint.sh`, which materialises without a git directory and therefore lints the full canonical set (306 files under `bin/*.sh bin/backends/*.sh tests/*.sh`) with ShellCheck 0.11.0.

| Phase | Seconds |
| --- | --- |
| scratch directory | 0.23 |
| private object store (`git clone --bare --shared`) | 0.41 |
| remote selection | 0.41 |
| incremental fetch of the base branch | 3.00 |
| `git merge-tree --write-tree` | 0.39 |
| check discovery | 0.30 |
| materialise the merge-result tree | 0.49 |
| **the check itself** | **506.85** |
| total | 512.08 |

A second run of the same check on the same machine took 439s, so the observed run-to-run spread is about 15 percent.
Both runs exited 0: the merge result was green, and the 180s budget in force at the time killed a check that would have passed.

Two conclusions the numbers settle:

- **The budget must clear a slow project's own gate.** Everything except the check totals 5.2s. A budget sized against a fast linter (ruff, about 2s) is marginal the first time it meets a slower gate. The default is 900s, about 1.8x the slower observed run.
- **Caching or warming the object store is not worth building.** The whole fetch-and-materialise path is 4.9s of a 512s run, so the most an object-store cache could recover is under one percent. It was measured before being considered, and declined on the measurement.

Refresh these numbers when this repository's lint file set grows materially, or when the default budget is next questioned.

## Regression coverage

`tests/fm-static-guard.test.sh` drives `bin/fm-pr-merge.sh` end to end against a throwaway project whose committed checker sleeps past the budget it is given:

- an unfinished check refuses the merge, records `merge_guard=timeout: ...`, calls no merge, and names both the budget and the two ways forward
- the same slow project merges green when the budget gives its check room, so the refusal above is the timeout and not a fixture that can never pass
- `FM_MERGE_GUARD=allow-timeout` merges past the unfinished check and records `merge_guard=timeout-allowed: ...`, distinguishing an operator's override from a default
- that override still refuses a red merge result, so it is not a second off switch
- an unrecognised `FM_MERGE_GUARD` value is refused rather than silently ignored

Each of those assertions was confirmed non-vacuous by restoring the pre-fix behavior - mapping a killed check back onto the `unguarded` verdict - and observing every one of them fail.
