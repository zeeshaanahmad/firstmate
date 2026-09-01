---
name: upstream-sync-batches
description: >-
  Agent-only procedure for preparing, validating, and merging a fork reconciliation batch whose exact upstream waypoint must remain in ancestry.
user-invocable: false
metadata:
  internal: true
---

# Upstream sync batches

Load this before preparing, validating, or merging a branch that reconciles commits from a separate upstream repository into a fork.
This procedure does not apply to ordinary feature branches or the fast-forward-only `updatefirstmate` workflow.

## Preserve the waypoint

Resolve the batch's exact full upstream waypoint SHA before creating the branch.
Bring the upstream range into the batch with a merge commit, never a rebase, squash, or cherry-pick.
The file tree is not proof of a correct batch because a flattened branch can carry identical content while losing the upstream commit identities from ancestry.

Write that SHA onto the task's durable record as soon as the batch branch exists, so the assertion no longer depends on anyone remembering it at merge time.
`bin/fm-pr-merge.sh` then asserts it against the forge's current PR head and refuses a batch whose waypoint is missing, unreadable, or no longer an ancestor, even when every file and check looks correct.
Merge the batch with `--merge`; the script header owns where the waypoint is read from, the flag that supplies one directly, and what happens when the two disagree.

Only the batch's preparer knows which commit this is, so a batch that never records or passes a waypoint merges unasserted.
Recording it is part of preparing the batch, not an optional extra step.

## Validate while main is held still

Run one upstream sync batch at a time and hold every other merge to its base branch from before validation starts until this batch merges or is abandoned.
Start no-mistakes with its Rebase step skipped so the deliberate merge shape is not rewritten at run start.
Keep the CI step enabled so the resulting pull request retains the pipeline's full attestation.
The cost is explicit fleet serialization for the full validation and landing window.

This quiet-main rule exists because no-mistakes has no designated-branch mode that preserves a merge commit end to end: skipping the Rebase step does not stop the CI step from rebasing the open pull request when the base branch advances.
[`docs/verification/upstream-sync-batches.md`](../../../docs/verification/upstream-sync-batches.md) owns that finding, the versions it was established against, and the commands that re-establish it.
Re-check it before each reconciliation campaign; if a designated-branch mode has shipped, prefer it, keep the waypoint assertion, and delete this serialization rule.

## Review pipeline fixes

Read the complete diff of every fix commit no-mistakes creates before accepting its result.
Never substitute the fix summary for that diff.
If a fix commit changes anything outside its finding, stop the batch and report the exact extra diff.
Do not hand-edit while the run is active because no-mistakes owns every validation fix.
