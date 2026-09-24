# Claude titled composer rule captures

These files are replay inputs for the titled-rule cases in `../../fm-composer-lib.test.sh`.
They pin how the shared composer classifier (`bin/fm-composer-lib.sh`) reads a Claude composer whose top rule carries the session's display name.
They are real terminal captures, not evidence that every composed variant in the test was observed live.

## Capture provenance

Every `tmux-*.ansi` file comes from `tmux capture-pane -e -p` output on a private tmux 3.6b socket, 120 columns wide (30 rows), captured on 2026-09-24.
The files that show a Claude composer are the last 20 rows of that output, from Claude Code 2.1.281 running idle, and the composer's `❯` row is row 16 of each 20-row window, which is the cursor row the tmux adapter would pass.
`tmux-exited-to-shell.ansi` and the `tmux-shell-*` files show plain bash with no agent running; they begin at the top of the pane and end at its last non-blank row, so they are shorter than 20 rows, and their cursor rows are given in the table.
The harness driver submitted no prompt to any Claude session; the bash-mode `!` commands in the two scrollback captures are the only input those sessions received, and Claude's replies to them are the assistant text in those transcripts.

| File | How the session was started | Observed shape |
| --- | --- | --- |
| `tmux-plain-idle.ansi` | `claude` | Plain `─` top rule, idle composer |
| `tmux-named-idle.ansi` | `claude --name 'Fresh named'` | Top rule titled `Fresh named`, idle composer |
| `tmux-renamed-idle.ansi` | `claude`, then `/rename Renamed later` | Top rule titled `Renamed later`, idle composer |
| `tmux-named-draft.ansi` | `claude --name 'Fresh named'`, then `draft text not sent` typed without Enter | Top rule titled `Fresh named`, composer holding a draft |
| `tmux-exited-to-shell.ansi` | `claude --model haiku --name 'About to exit'` from a bash prompt, then `/exit` | No composer at all: Claude cleared its screen and left the shell prompt, cursor on row 1 |
| `tmux-named-decorative-scrollback.ansi` | `claude --name 'Fresh named'`, then `!./report.sh` in bash mode | A decorative `──── Summary ─` separator printed into the transcript, idle composer below, cursor row 16 |
| `tmux-named-lookalike-scrollback.ansi` | Same session, then `!./lookalike.sh` | A `──── Results ─` / `❯` / `────` look-alike printed into the transcript, idle composer below, cursor row 16 |
| `tmux-shell-decorative-running.ansi` | bash, no agent, a still-running tool printing to the pane | `build finished`, `──── Results ─`, ` 12 passed, 0 failed`, `──── Summary ─`, ` all green`, cursor row 5 (the blank row below the output) |
| `tmux-shell-lookalike-titled-running.ansi` | bash, no agent, a still-running tool printing to the pane | `build finished`, `──── Results ─`, `❯ `, `────`, cursor row 4 |
| `tmux-shell-lookalike-plain-running.ansi` | Identical to the previous row | The same output with a plain `────` first rule, cursor row 4 |

`herdr-resumed-named-idle.ansi` is the last 8 rows of unchanged `herdr pane read --source recent --format ansi` output from a resumed, named Claude Code 2.1.274 session on herdr 0.9.0, captured the same day.
Its rows keep herdr's trailing carriage returns.
Rows above the window held private transcript text and were not retained.

## What the captures establish

Which sessions draw a title into the composer's top rule and the rule the classifier accepts it under are owned by the [2026-09-24 entry in `runtime-backends.md`](../../../docs/verification/runtime-backends.md#2026-09-24-claude-named-session-title-in-the-composers-top-rule) and by `_fm_composer_titled_rule_row` in `bin/fm-composer-lib.sh`; these captures pin the reads below.
A decorative separator that a tool or a transcript prints (`──── Summary ─`) has the same shape as that titled rule, and the decorative captures show it proves no composer: the bare-shell capture reads `unknown` on every profile, and the named session's real composer below its decorative scrollback still reads `empty` with nothing extracted from the transcript.
The look-alike captures pin one known limitation: on the cursorless read, a bare shell whose tail ends with a separator directly above a `❯` row and a rule reads `empty`, for the titled separator and for the plain one alike, while tmux reads `unknown` because its cursor is not on the glyph row.
