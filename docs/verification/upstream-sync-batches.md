# Verification: no-mistakes rebase paths during an upstream sync batch

Audience: maintainer verification.

This record supports the quiet-main serialization rule in `.agents/skills/upstream-sync-batches/SKILL.md`.
That rule exists only because no-mistakes has no designated-branch mode that preserves a deliberate merge commit end to end.
The rule becomes obsolete the moment such a mode ships, so the facts below are what must be re-established before each reconciliation campaign.

The required waypoint assertion in `bin/fm-pr-merge.sh` is independent of everything here and stays in force whatever no-mistakes does.

## Why a sync batch needs this at all

A batch branch carries the upstream range as a merge commit so the exact upstream waypoint stays in the branch's ancestry.
Rebasing that branch replaces the merge with cherry-picked commits that carry the same file content under new commit identities, which removes the waypoint from ancestry.
The next sync then computes its merge base against a waypoint that is gone and replays history the fork already carries.
Content inspection does not detect this, because the flattened branch's files are correct; only an explicit ancestry assertion does.

## Command surface: no designated-branch mode exists

Verified 2026-09-01 against no-mistakes v1.60.2 (`eb4e379`, 2026-08-29), the current stable release, inspected as an extracted scratch copy so neither the installed binary nor the shared daemon was touched.
The installed binary at the time was v1.48.0 (`2ac3769`) and exposes the same two knobs.

```
$ ./no-mistakes --version
no-mistakes version v1.60.2 (eb4e379) 2026-08-29T21:51:53Z

$ ./no-mistakes --help
Flags:
  -h, --help          help for no-mistakes
      --skip string   comma-separated pipeline steps to skip for a new run
  -v, --version       version for no-mistakes
  -y, --yes           run setup wizard and accept defaults automatically

$ ./no-mistakes axi run --help
Flags:
  -h, --help            help for run
      --intent string   what the user set out to accomplish (not a description of the diff); used instead of inferring from transcripts (required to start a run)
      --skip string     comma-separated pipeline steps to skip
  -y, --yes             auto-resolve every gate (fix findings, then accept) until a decision point or outcome
```

The whole surface offers `--skip=<steps>` and the `auto_fix.<step>` counts in `~/.no-mistakes/config.yaml`.
No flag, subcommand, or configuration key names a branch, a merge strategy, or a preserve-merges posture.
There is no `no-mistakes config` subcommand to carry one.

## The two rebase paths are independent

`--skip=rebase` skips the named Rebase step at the start of a run.
It does not reach the CI step, which rebases the open pull request on its own when the base branch advances.
Three independent signals in the same v1.60.2 binary establish that second path.

The shipped global configuration documents it as the CI monitor's own behavior:

```
# Maximum time the CI monitor babysits an open PR with no base-branch movement
# before giving up. The monitor watches CI and auto-rebases when the base branch
# advances; each base advance re-arms this timer, so an actively-updated green PR
# keeps its monitor.
ci_timeout: "168h"
```

The binary carries the runtime log line that fires on each base advance:

```
base branch advanced (%s..%s), re-arming CI monitor timeout
```

The binary also carries the CI step's own agent prompts, which instruct a rebase directly:

```
The PR has merge conflicts with the base branch. Rebase onto the base branch and resolve the merge conflicts.
The following CI checks have failed and the PR has merge conflicts with the base branch. Diagnose and fix the CI issues, then rebase onto the base branch and resolve the merge conflicts.
```

Those prompts are delivered through CI auto-fix, which is governed by `auto_fix.ci` and not by `--skip=rebase`.

## Why the remaining knobs are not a substitute

Lowering `auto_fix.ci` is a global or repository setting rather than a per-run one, so it would change every other lane sharing that configuration.
Its documented meaning is `0 = disabled after the initial pass`, which does not establish that the initial CI pass will decline to rebase.
It would also give up automatic fixing of genuine CI failures, which is a capability this fleet relies on.

`--skip=ci` does avoid the second rebase path, but only by giving up the pipeline's CI attestation on the resulting pull request.
That is a different delivery shape, not a configuration of the pipeline, and the skill treats it as such.

## How to re-establish these facts

Re-run the check before each reconciliation campaign, and whenever no-mistakes releases a version whose notes mention rebasing or merge preservation.
Inspect an extracted scratch copy rather than the installed binary, because updating no-mistakes resets the shared daemon and kills other lanes' in-flight runs.

```
curl -sL -o nm.tar.gz https://github.com/kunchenguid/no-mistakes/releases/download/<tag>/no-mistakes-<tag>-<os>-<arch>.tar.gz
tar xzf nm.tar.gz
./no-mistakes --help
./no-mistakes axi run --help
strings ./no-mistakes | grep -iE 'auto-rebas|base branch advanced|rebase onto the base branch'
```

If a designated-branch or preserve-merge mode appears, prefer it, keep the waypoint assertion, and delete the serialization rule from the skill along with this section.
