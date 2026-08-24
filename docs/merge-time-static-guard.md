# Merge-time static guard and red-default-branch detection

A project's gate validates a pull request against the base it was rebased onto.
Between that gate passing and the merge landing, other work reaches the default branch.
Nothing validates the combination, and where the forge runs no CI nothing ever will.
The two halves described here close that gap from firstmate's side only: no managed project changes.

Firstmate owns both halves because both are merge-path concerns, and both are cheap enough to run every time.

## The two halves

**Prevention** lives in `bin/fm-pr-merge.sh`, immediately before its merge call.
It computes the exact squash result of the PR head onto the current default-branch tip with `git merge-tree --write-tree`, writes that tree out, and runs the project's own pinned static check against it.
A red result refuses the merge and tells the lane to rebase onto current main and re-gate.
A merge that conflicts is refused on the same ground, because a conflicted merge is not a mergeable PR.
The guard runs unconditionally rather than behind a staleness probe: the check's median cost does not pay for the extra branch.

**Detection** lives in `bin/fm-main-guard.sh`, armed once per repository as an ordinary registered watcher check.
When the default branch's SHA moves, it runs the same discovered check against the new tip and wakes firstmate with one line when that tip is red.
It covers what prevention cannot: a merge performed on the forge by hand, and the seconds-wide race between the merge-time check and the merge call.

Both call `bin/fm-static-guard-lib.sh`, the single owner of "discover the project's own static check and run it against one git tree", so prevention and detection can never disagree about what red means.
Each script's own header owns its exact flags, fields, and mechanics.

## Boundaries

**The static class only.**
The guard reports whatever the project's own checker reports - undefined names, imports, formatting, and the rest of that class.
Runtime test failures, type-checker errors, and snapshot drift all pass it.
It is a cheap guard on the one thing the gate never sees, never a substitute for the gate, and it does not claim to be one.

**It does not survive an airgapped site.**
Both halves read the current default-branch tip from the forge, and a checker pinned through a fetching launcher needs the network on a cold cache.
At a sealed site neither is available.
The sealed-site equivalent is a separate question and is deliberately not answered here.

**No verdict is never a pass, and there are two kinds of no verdict.**
Where the guard cannot reach the check at all - nothing discoverable, no reachable forge, no object store, or a git too old to compute a merge result - it says so out loud and lets the merge proceed, rather than implying a check that did not happen or wedging every merge behind an unrelated outage.
Those cases have no next step to offer: the forge is gone, or the project declares no check.

A check that was discovered, launched, and then killed by its budget is a different outcome and refuses the merge.
It measured nothing, and an unmeasured merge result is not a green one - reading it as permission to merge is exactly the conflation this guard exists to remove.
It also has an obvious next step the unreachable cases lack: run it again with room.
The refusal names the budget that was exceeded, the knob that raises it, and the explicit override, so the caller is never left guessing which of the three applies.

The detection half stays silent for both kinds and does not record the tip, so the next poll simply tries again.
It needs no refusal of its own because it authorizes nothing: the worst a killed check costs there is a repeated poll.

**The check budget is a hang bound, not a performance target.**
Its only job is to stop a wedged checker from hanging a merge forever, so it has to clear the slowest check that genuinely finishes.
The first budget was sized against a fast linter and was marginal for a project whose own gate is slower, which is how a green check came to be killed and the merge allowed anyway.
`FM_STATIC_CHECK_TIMEOUT` raises it for one merge, and [`verification/merge-time-static-guard.md`](verification/merge-time-static-guard.md) holds the measurement the current default is sized from.

**There are two deliberate switches, and they answer different questions.**
`FM_MERGE_GUARD=off` skips the merge-time guard entirely and records that it was skipped, for the one case refusing cannot fix: a default branch already red for reasons this PR did not cause, where every merge would otherwise be blocked behind it.
`FM_MERGE_GUARD=allow-timeout` is narrower: it runs the guard, still refuses a red result and a conflict, and merges only past a check that could not finish.
Either is a decision to merge less than fully checked, recorded as such in the task's own record, and neither is a way past an inconvenient red.
Any other value is refused rather than silently ignored, so a misspelled override never becomes a posture nobody chose.

**Firstmate never writes to a project.**
Neither half fetches into a project clone.
Both borrow a project's object store through git alternates into a private throwaway bare repository, and every fetch, index write, and merge computation happens there.

## Where the check command comes from

Discovery reads, in order, `commands.lint` from the project's `.no-mistakes.yaml`, then a `lint:` target in its `Makefile`.
It reads them from the current default-branch tip, never from the tree under test.
A pushed branch therefore cannot weaken, redirect, or disable the guard by editing its own configuration.
The pinned version and the exact command belong to the project; firstmate hard-codes neither.

A project with a different check declares it the same way.
A project with no discoverable check is reported as unguarded at merge time, and refused at arming time - an armed detector that can never reach a verdict is worse than none.

## Arming the detector

`bin/fm-main-guard.sh --help` owns the exact commands.
Arm one check per repository with a stable id, not one per task; the check is an ordinary mode-0700 single-link file bound through the same registrar every custom watcher check uses.
Arming proves the guard can reach a verdict before it writes anything, so a refusal at arming time is the loud failure, at the right time.

The watcher allows `FM_CHECK_TIMEOUT` per check, and the common poll is a single `git ls-remote` on an unchanged branch.
A project whose checker cannot finish inside the poll's own budget needs that budget and the watcher's timeout raised together, or should not be armed at all.

## Verification

`tests/fm-static-guard.test.sh` and `tests/fm-main-guard.test.sh` drive both halves through their executables against a throwaway repository whose pinned checker is a committed script, so neither depends on any real managed project being present.
The fixture is the measured defect: the default branch renames a symbol the PR still uses, each side green alone, only the combination red.
A second fixture variant makes that same checker slower than the budget it is given, so the timeout cases refuse a merge whose result would otherwise be green - and the same variant, given room, merges green, which is what keeps the refusal from passing vacuously.
