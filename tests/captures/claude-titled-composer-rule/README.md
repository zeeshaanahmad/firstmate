# Claude titled composer rule captures

These files are replay inputs for the titled-rule cases in `../../fm-composer-lib.test.sh`.
They pin how the shared composer classifier (`bin/fm-composer-lib.sh`) reads a Claude composer whose top rule carries the session's display name.
They are real terminal captures, not evidence that every composed variant in the test was observed live.

## Capture provenance

Every `tmux-*.ansi` file is the last 20 rows of unchanged `tmux capture-pane -e -p` output from Claude Code 2.1.281 running idle on a private tmux 3.6b socket, 120 columns wide, captured on 2026-09-24.
The composer's `❯` row is row 16 of each 20-row window, which is the cursor row the tmux adapter would pass.
No prompt was submitted to any session.

| File | How the session was started | Observed shape |
| --- | --- | --- |
| `tmux-plain-idle.ansi` | `claude` | Plain `─` top rule, idle composer |
| `tmux-named-idle.ansi` | `claude --name 'Fresh named'` | Top rule titled `Fresh named`, idle composer |
| `tmux-renamed-idle.ansi` | `claude`, then `/rename Renamed later` | Top rule titled `Renamed later`, idle composer |
| `tmux-named-draft.ansi` | `claude --name 'Fresh named'`, then `draft text not sent` typed without Enter | Top rule titled `Fresh named`, composer holding a draft |
| `tmux-exited-to-shell.ansi` | `claude --name 'About to exit'` from a bash prompt, then `/exit` | No composer at all: Claude cleared its screen and left the shell prompt, cursor on row 1 |

`herdr-resumed-named-idle.ansi` is the last 8 rows of unchanged `herdr pane read --source recent --format ansi` output from a resumed, named Claude Code 2.1.274 session on herdr 0.9.0, captured the same day.
Its rows keep herdr's trailing carriage returns.
Rows above the window held private transcript text and were not retained.

## What the captures establish

Claude draws the session name into the composer's top rule for every named session, not only a resumed one: a fresh `--name` launch and a fresh unnamed session renamed with `/rename` both draw it.
The title sits at the right end as `<rule glyphs> <name> ─`.
A name long enough to fill the row is not truncated to keep the rule: at 200 columns a 240-character name left no leading rule glyph at all, which the classifier deliberately does not accept as a rule.
