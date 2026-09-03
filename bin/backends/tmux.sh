#!/usr/bin/env bash
# bin/backends/tmux.sh - the tmux session-provider adapter.
#
# Reference backend (AGENTS.md section 8; data/fm-backend-design-d7). P1 moves
# the tmux command sequences that fm-send.sh, fm-peek.sh, fm-watch.sh,
# fm-spawn.sh, and fm-teardown.sh already ran inline into named functions
# here, running the EXACT same commands in the EXACT same order, so the
# default (tmux, `backend=` absent) path stays byte-identical. Sourced only
# through bin/fm-backend.sh's fm_backend_source, never directly.
#
# Worktree acquisition (running `treehouse get` inside the pane, and polling
# its cwd) is unchanged by this extraction: P1 scopes only the session
# provider, not the worktree provider, so fm-spawn.sh still drives that part
# inline with these same send/current-path primitives.
#
# The verified composer/busy-detection and verify-and-retry-submit primitives
# already live in bin/fm-tmux-lib.sh, shared with the away-mode daemon
# (bin/fm-supervise-daemon.sh); this adapter sources that file and re-exports
# its submit core under the backend's naming convention rather than
# duplicating it, so the two consumers cannot drift apart.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-cursor-lib.sh"

# fm_backend_tmux_bind_socket: pin every subsequent fm_tmux_bin call (this
# adapter and bin/fm-tmux-lib.sh's shared primitives) to the exact server at
# <socket-path>, or unpin back to ambient resolution when <socket-path> is
# empty. A caller that has resolved a task's recorded endpoint binds here
# BEFORE reading or acting on that endpoint's target, so the wrong-server
# doorbell defect (2026-09-04 - a target recorded against one tmux server
# escaping to whatever server ambient PATH/environment happens to resolve
# instead) cannot recur for that caller. See fm_tmux_bin (bin/fm-tmux-lib.sh)
# for the seam this feeds.
fm_backend_tmux_bind_socket() {  # <socket-path-or-empty>
  FM_BACKEND_TMUX_SOCKET=${1:-}
  # A recorded value that is not an absolute path is not a real tmux socket -
  # for instance a real tmux's own #{socket_path} always answers an absolute
  # path, so a fake/stubbed tmux's unrelated placeholder text (several test
  # fixtures' `display-message` case answers a fixed non-path string for any
  # unmatched format, tests/fixtures.sh's fm_test_fake_tmux_spawn among them)
  # can never accidentally get bound as one. Treat it as unbound rather than
  # pinning a caller to a value that could not possibly be a socket, which
  # would otherwise inject an unexpected `-S <value>` into every subsequent
  # tmux invocation and break argument parsing in stubs that assume the
  # subcommand is always $1.
  case "$FM_BACKEND_TMUX_SOCKET" in
    /*) ;;
    *) FM_BACKEND_TMUX_SOCKET= ;;
  esac
  export FM_BACKEND_TMUX_SOCKET
}

# fm_backend_tmux_target_resolves: TRUE only when <target> names a pane or
# window that genuinely exists on the tmux server this call is bound to
# (ambient, or pinned via fm_backend_tmux_bind_socket).
#
# It exists because a `-t` selector naming an ABSENT target does not fail the
# way a caller would expect: tmux answers some reads from the client's
# current/active pane instead of erroring (measured empirically, 2026-09-04:
# `tmux display-message -p -t '%<absent>' '#{pane_tty}'` on a server lacking
# that pane returned EMPTY OUTPUT WITH EXIT 0), so no single-target `-t` read
# in this file can be trusted to prove a target's existence on its own -
# every one of them is exactly as unsafe on the CORRECT server as on a wrong
# one. Enumerating every real pane and window on the bound server with one
# listing and checking exact membership is not subject to that fallback: a
# target that is not in the listing is not resolvable, period.
#
# Accepts the two target shapes this backend's callers pass: a raw pane id
# (`%N`, the away-mode supervisor's own pane) or a `session:window` name (a
# spawned task's recorded endpoint). Anything else refuses to resolve rather
# than guess.
fm_backend_tmux_target_resolves() {  # <target>
  local target=$1 panes
  panes=$(fm_tmux_bin list-panes -a -F '#{pane_id}~#{session_name}:#{window_name}' 2>/dev/null) || return 1
  case "$target" in
    %*)
      printf '%s\n' "$panes" | awk -F'~' -v t="$target" '$1 == t { f = 1 } END { exit(f ? 0 : 1) }'
      ;;
    *:*)
      printf '%s\n' "$panes" | awk -F'~' -v t="$target" '$2 == t { f = 1 } END { exit(f ? 0 : 1) }'
      ;;
    *) return 1 ;;
  esac
}

# fm_backend_tmux_resolve_bare_selector: the live-window-listing fallback for a
# selector that is neither an explicit target nor a task selector routed
# through meta - an ad hoc window name with no recorded task. Mirrors the
# `tmux list-windows -a ... | grep` pipeline that used to live inline in
# fm-send.sh's and fm-peek.sh's own (until now duplicated) resolve().
fm_backend_tmux_resolve_bare_selector() {  # <name>
  local name=$1
  fm_tmux_bin list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$name\$" \
    || { echo "error: no window named $name" >&2; return 1; }
}

# fm_backend_tmux_capture: bounded plain-text pane capture. Mirrors
# fm-peek.sh's and fm-watch.sh's `tmux capture-pane -p -t "$T" -S -"$N"`.
fm_backend_tmux_capture() {  # <target> <lines>
  fm_tmux_bin capture-pane -p -t "$1" -S -"$2"
}

# fm_backend_tmux_send_key: one named key. Mirrors fm-send.sh's --key path:
# `tmux display-message -p -t "$T" '#{pane_id}' >/dev/null`, then
# `tmux send-keys -t "$T" "$2"`.
fm_backend_tmux_send_key() {  # <target> <key>
  fm_tmux_bin display-message -p -t "$1" '#{pane_id}' >/dev/null
  fm_tmux_bin send-keys -t "$1" "$2"
}

# fm_backend_tmux_send_text_submit: type <text> into <target> once, then
# submit with Enter, retried (Enter only, never retyped) until the composer
# clears. The submission itself is fm_tmux_submit_core (bin/fm-tmux-lib.sh),
# used verbatim; see that file for the composer-verification contract and
# echoed verdicts.
#
# This adapter is where tmux ACTS on that verdict - it types into a pane and
# then reports a submit as confirmed - so it owes the corroboration
# bin/fm-composer-lib.sh describes: rendered shape cannot establish who owns a
# pane, and a bare shell prompt reaches the classifier's strongest positive
# verdict (starship's default prompt character is byte-identical to claude's
# empty-composer glyph). A crewmate whose agent had exited to a shell therefore
# answered a steer with a redrawn shell prompt, which read as a cleared
# composer, and the steer was reported delivered after being typed into that
# shell and executed there as a command (2026-08-25;
# docs/verification/runtime-backends.md "Shell panes under an acting caller").
#
# The second, non-rendered signal is the pane's own foreground-process facts,
# whose single owner is fm_backend_tmux_pane_agent_state. It is read twice,
# because the two failures are different: before typing, so a steer is never
# executed by a shell, and again before an `empty` verdict is allowed to mean
# "delivered", which closes the window where an agent exits mid-send.
#
# It refuses on `dead` alone - a readable foreground group that is nothing but
# shells, or an unreadable one whose pane command is a shell - and never on
# `ambiguous` or `unreadable`. That is deliberately weaker than the away-mode
# injector's exact-`alive` requirement (bin/fm-supervise-daemon.sh), because the
# two callers are wrong in opposite directions: the injector types unattended
# into a pane it discovered, where a wrong keystroke is the whole hazard, while
# a steer is a caller-resolved endpoint where a wrong refusal loses a real
# instruction and sends firstmate into recovery on a healthy worker. Only the
# positive contradiction is worth that.
#
# The pane read resolves <target> exactly as the send does, so it always
# describes the pane that receives the keystrokes, including when tmux answers
# an absent target from the client's active window.
fm_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 verdict state
  state=$(fm_backend_tmux_pane_agent_state "$target")
  case "$state" in
    unresolvable)
      # <target> does not exist on the server this call is bound to (see
      # fm_backend_tmux_target_resolves). This is NOT the same fact as
      # `dead` - a dead pane is a proven endpoint with no agent, while an
      # unresolvable one could not be proven to be the task's endpoint at
      # all, on a wrong or absent server. Refusing here, before anything is
      # typed, is what closes the wrong-server doorbell defect for the typed
      # plane the same way it closes it for the ring (bin/fm-task-inbox-lib.sh
      # fm_task_inbox_ring outcome 5).
      printf 'unresolvable'
      return 0
      ;;
    dead)
      printf 'no-agent'
      return 0
      ;;
  esac
  verdict=$(fm_tmux_submit_core "$@")
  if [ "$verdict" = empty ] \
    && [ "$(fm_backend_tmux_pane_agent_state "$target")" = dead ]; then
    printf 'agent-lost'
    return 0
  fi
  printf '%s' "$verdict"
}

# fm_backend_tmux_container_ensure: reuse the current tmux session when
# firstmate itself runs inside tmux, else ensure a dedicated detached
# "firstmate" session exists. Mirrors fm-spawn.sh's container-ensure block;
# prints the resolved session name.
fm_backend_tmux_container_ensure() {
  if [ -n "${TMUX:-}" ]; then
    fm_tmux_bin display-message -p '#S'
  else
    fm_tmux_bin has-session -t firstmate 2>/dev/null || fm_tmux_bin new-session -d -s firstmate
    printf 'firstmate'
  fi
}

# fm_backend_tmux_create_task: create the task's window in <proj-abs>,
# refusing an existing <window-name> in <session>. Mirrors fm-spawn.sh's
# duplicate-check-then-new-window sequence, including the exact error text
# (session:window, matching how fm-spawn.sh composed its own $T). Prints the
# created window's stable window id on stdout for the caller to target.
#
# Robustness (fm-spawn tmux window handling under a non-default captain config):
#   - Capture a STABLE window id with -P -F '#{window_id}', and let tmux append
#     at the next free index by targeting the session with a trailing colon
#     ("$ses:"), so a non-default base-index (e.g. base-index 1) cannot collide.
#   - PIN the window name by disabling automatic-rename and allow-rename on the
#     new window: the captain's tmux may rename the window away from fm-<id> once
#     treehouse cd's into the worktree, which would break name-based targeting.
# The returned window id lets callers target the window even if its name is ever
# lost, so worktree discovery cannot fall back to the active client's window.
fm_backend_tmux_create_task() {  # <session> <window-name> <proj-abs> -> prints window id
  local ses=$1 wname=$2 proj_abs=$3 wid
  if fm_tmux_bin list-windows -t "$ses" -F '#{window_name}' | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  wid=$(fm_tmux_bin new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" -c "$proj_abs") || return 1
  fm_tmux_bin set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
  fm_tmux_bin set-window-option -t "$wid" allow-rename off 2>/dev/null || true
  printf '%s\n' "$wid"
}

# fm_backend_tmux_current_path: the live pane's current working directory, or
# empty on any tmux error. Mirrors fm-spawn.sh's worktree-discovery poll:
# `tmux display-message -p -t "$T" '#{pane_current_path}'`.
fm_backend_tmux_current_path() {  # <target>
  fm_tmux_bin display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

# fm_backend_tmux_send_text_line: send one line of TEXT then Enter, with no
# composer verification - used for the fixed spawn-time commands
# (`treehouse get`, the GOTMPDIR export) that already ran this exact sequence
# inline in fm-spawn.sh. Mirrors `tmux send-keys -t "$T" "<text>" Enter`.
fm_backend_tmux_send_text_line() {  # <target> <text>
  fm_tmux_bin send-keys -t "$1" "$2" Enter
}

# fm_backend_tmux_send_literal: send TEXT as literal bytes with no
# submission - the caller sends Enter separately (fm-spawn.sh's launch-command
# send pauses between the literal send and Enter for the harness to settle).
# Mirrors `tmux send-keys -t "$T" -l "<text>"`.
fm_backend_tmux_send_literal() {  # <target> <text>
  fm_tmux_bin send-keys -t "$1" -l "$2"
}

# fm_backend_tmux_kill: remove one explicitly named task window, best-effort.
# Empty, omitted, and malformed targets return nonzero before invoking tmux so
# tmux can never interpret an empty target as the caller's current window.
fm_backend_tmux_kill() {  # <target>
  local target=${1:-} session window
  case "$target" in
    *:*)
      session=${target%%:*}
      window=${target#*:}
      ;;
    *) return 1 ;;
  esac
  case "$session:$window" in
    :*|*:|*:*:*) return 1 ;;
  esac
  fm_tmux_bin kill-window -t "=$session:=$window" 2>/dev/null || true
}

# fm_backend_tmux_current_command: <target>'s live foreground process name -
# tmux's own `#{pane_current_command}`, already resolved from the pty's
# foreground process group (verified empirically with real tmux 3.6a: a
# harness invoked interactively stays the reported command even while it
# shells out to subcommands that do not take over the pty - e.g. `bash -c
# "sleep 30"` alone reports "sleep" because bash execs directly into it, but
# a persisting parent script running `sleep` as a child reports the PARENT's
# own name throughout; the value reverts to the shell's own name only once
# the foreground command actually exits). Empty on any tmux error.
fm_backend_tmux_current_command() {  # <target>
  fm_tmux_bin display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

# fm_backend_tmux_classify_process_name: the single owner of the process-name
# vocabulary shared by every liveness signal below - `agent` for a verified
# harness, `shell` for an idle login/interactive shell, `other` for anything
# else. Keeping one classifier means the two independent name sources can never
# drift into disagreeing about what a given name means.
fm_backend_tmux_classify_process_name() {  # <path> [argv0] -> agent|shell|other
  local path=$1 argv0=${2:-} base
  base=${path##*/}
  base=${base#-}
  case "$base" in
    # muse is anchored rather than globbed like its neighbours: its installed
    # binary is muse-bin-<version> (the launcher execs it, so the version is the
    # live process name and changes on every auto-update), and unlike `claude` or
    # `codex` the substring `muse` is a common English fragment - a *muse* glob
    # would classify musescore or amuse as a live agent pane. The install path
    # cannot carry it either: ~/.local/bin/muse-bin-<version> has no `muse` path
    # COMPONENT, so the fm_harness_path_name fallback below never fires for it.
    muse|muse-bin-*) printf 'agent' ;;
    *claude*|*codex*|*opencode*|*grok*|*kimi*|pi|pi-signed|pi-launcher|Pi) printf 'agent' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'shell' ;;
    *)
      if fm_harness_path_name "$path" >/dev/null || fm_harness_path_name "$argv0" >/dev/null; then
        printf 'agent'
      # cursor-agent runs as a bundled node script, so tmux reports the pane
      # command as a bare `node` that no name pattern above can own, and its
      # other installed name is the far-too-generic `agent` (verified live on
      # cursor-agent 2026.08.11-e8db854: #{pane_current_command} is `node` while
      # `ps -o comm=` carries the cursor-agent install path). Identity therefore
      # comes from the narrowed structural rule in bin/fm-cursor-lib.sh, which
      # demands Cursor's own name or install tree in the path or argv[0]. An
      # unrelated `node` or `agent` matches nothing here and stays `other`,
      # which the callers above fold into `ambiguous` rather than `dead`, so a
      # stranger's node pane is never reported as an agent-free pane.
      elif fm_cursor_process_matches "${path:-$argv0}" '' "$argv0"; then
        printf 'agent'
      else
        printf 'other'
      fi
      ;;
  esac
}

# fm_backend_tmux_foreground_comms: the kernel-side names of every process in
# <target>'s pane tty foreground process group, one full value per line.
# Empty on any failure.
#
# This is the foreground-process-group half of the liveness probe, and it exists
# because `#{pane_current_command}` and `ps -o comm=` expose different name
# fields whose roles vary by platform. On macOS the tmux field can carry a
# harness-rewritten title (Claude Code 2.1.220 reports `2.1.220`) while `comm`
# retains executable identity; the portable Linux regression observes the
# reverse for its version-named executable. Reading both `comm` and argv[0]
# preserves an identifying install path without making either platform's field
# assignment load-bearing.
#
# Scoping to the foreground process group rather than to the pane's descendants
# is what keeps the probe honest in the other direction: a harness-named process
# left running in the background of an otherwise idle pane is deliberately NOT
# reported, so a genuinely agent-free pane still classifies `dead`. It also
# reports every member of a multi-process launcher (the Pi Launcher path runs a
# `pi-signed` wrapper and a `pi` engine in one group), so no launcher needs its
# own special case here.
#
# Like fm_backend_tmux_current_command this is a RAW pane read: tmux answers an
# absent target from the client's active window rather than failing, so callers
# must confirm exact window membership first, exactly as the classifier below
# does, or they will describe some other pane entirely.
fm_backend_tmux_foreground_comms() {  # <target>
  local target=$1 tty pid pgid tpgid comm
  tty=$(fm_tmux_bin display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        printf '%s\n' "$comm"
      done
}

fm_backend_tmux_foreground_argv0s() {  # <target>
  local target=$1 tty pid pgid tpgid comm args argv0
  tty=$(fm_tmux_bin display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
        args=${args#"${args%%[![:space:]]*}"}
        argv0=${args%%[[:space:]]*}
        [ -n "$argv0" ] && printf '%s\n' "$argv0"
      done
}

# fm_backend_tmux_agent_state: recovery-grade harness-agent state for one
# recorded target. See bin/fm-backend.sh's fm_backend_agent_state for the
# shared state vocabulary and docs/tmux-backend.md "Agent liveness probe" for
# the empirical basis. Tmux silently falls back to the active window when a
# named target is absent, so the exact recorded window must appear in a
# successful session inventory before its foreground command can be trusted.
# An omitted window or a definitive missing-session/server response is
# `missing`; any other inventory or pane read failure is `unreadable`, so a
# transient tmux problem never licenses a duplicate.
#
# The verdict combines two independent name sources rather than trusting either
# alone. Either source naming a verified harness is enough for `alive`, because
# a false `dead` is the one outcome that can launch a duplicate agent onto a
# live worktree, while the foreground process group - when it is readable - is
# authoritative for the negative verdicts, since it is the only source that can
# distinguish a truly idle pane from a rewritten process title.
fm_backend_tmux_agent_state() {  # <target>
  local target=$1 session window windows inventory_status
  case "$target" in
    *:*:*|'':*|*:'') printf 'unreadable'; return 0 ;;
    *:*) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  session=${target%%:*}
  window=${target#*:}
  if windows=$(LC_ALL=C fm_tmux_bin list-windows -t "$session" -F '#{window_name}' 2>&1); then
    inventory_status=0
  else
    inventory_status=$?
  fi
  if [ "$inventory_status" -ne 0 ]; then
    case "$windows" in
      *"can't find session:"*|*"no server running on "*|*"error connecting to "*" (No such file or directory)"|*"error connecting to "*" (Connection refused)")
        printf 'missing'
        ;;
      *)
        printf 'unreadable'
        ;;
    esac
    return 0
  fi
  if ! printf '%s\n' "$windows" | grep -Fqx "$window"; then
    printf 'missing'
    return 0
  fi

  fm_backend_tmux_pane_agent_state "$target"
}

# fm_backend_tmux_pane_agent_state: the PROCESS-EVIDENCE half of the verdict
# above, for a target the caller has ALREADY established resolves to the exact
# endpoint it means. Prints alive|dead|ambiguous|unreadable|unresolvable -
# never `missing`, because establishing that the endpoint exists is the
# caller's half.
#
# It exists because the window-inventory guard above only accepts a
# `session:window` target, while the away-mode supervisor pane is normally a
# raw pane id (`$TMUX_PANE`, e.g. `%3`) that no `list-windows` inventory can
# name. Splitting the two halves keeps ONE copy of the name-source combination
# logic rather than a second, drifting one for pane-id callers.
#
# `unresolvable` is checked first, ahead of every other read, but ONLY for a
# caller that has bound an explicit server (fm_backend_tmux_bind_socket):
# every raw `-t`-addressed query below (display-message, ps against the
# resolved tty) shares the SAME wrong-server/absent-target fallback hazard
# documented on fm_backend_tmux_target_resolves, so answering from those reads
# before confirming the target's own existence would describe whatever pane
# tmux fell back to, not the one this call means. An UNBOUND caller (every
# caller that has not opted in, including every existing fake-tmux test
# fixture that predates this check and has no `list-panes` of its own) skips
# the existence read entirely and keeps its exact prior ambient behavior -
# there is no bound server to prove the target against, so this stays exactly
# as permissive as it was before this fix.
#
# The evidence rule is unchanged: either name source naming a verified harness
# is enough for `alive`, and a readable foreground process group is what settles
# the negative verdicts, so only a group that is nothing but shells is
# confidently agent-free.
fm_backend_tmux_pane_agent_state() {  # <target>
  local target=$1 comm foreground argv0s name fg_seen=0 fg_shell=0 fg_other=0
  # The existence check is gated on an explicitly BOUND server: it is the
  # binding (fm_backend_tmux_bind_socket) that turns "does this target exist"
  # into an answerable question with a server to check against. An unbound
  # caller is asking nothing new versus before this fix - unchanged ambient
  # behavior, byte-identical to every caller (and every fake-tmux test
  # fixture across the suite, none of which implement list-panes) that has
  # never opted into pinning a server.
  if [ -n "${FM_BACKEND_TMUX_SOCKET:-}" ]; then
    fm_backend_tmux_target_resolves "$target" || { printf 'unresolvable'; return 0; }
  fi
  foreground=$(fm_backend_tmux_foreground_comms "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    fg_seen=1
    case "$(fm_backend_tmux_classify_process_name "$name")" in
      agent) printf 'alive'; return 0 ;;
      shell) fg_shell=1 ;;
      *) fg_other=1 ;;
    esac
  done <<EOF
$foreground
EOF

  argv0s=$(fm_backend_tmux_foreground_argv0s "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$(fm_backend_tmux_classify_process_name '' "$name")" = agent ]; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$argv0s
EOF

  comm=$(fm_backend_tmux_current_command "$target") || {
    printf 'unreadable'
    return 0
  }
  if [ "$(fm_backend_tmux_classify_process_name "$comm")" = agent ]; then
    printf 'alive'
    return 0
  fi

  # A readable foreground process group settles the negative verdicts: only a
  # group that is nothing but shells is confidently agent-free.
  if [ "$fg_seen" -eq 1 ]; then
    if [ "$fg_other" -eq 0 ] && [ "$fg_shell" -eq 1 ]; then
      printf 'dead'
    else
      printf 'ambiguous'
    fi
    return 0
  fi

  case "$comm" in
    '') printf 'unreadable'; return 0 ;;
  esac
  case "$(fm_backend_tmux_classify_process_name "$comm")" in
    shell) printf 'dead' ;;
    *) printf 'ambiguous' ;;
  esac
}

# Backward-compatible three-state view for callers that only need a yes/no
# agent verdict. The detailed state contract is owned by fm_backend_agent_state.
fm_backend_tmux_agent_alive() {  # <target>
  case "$(fm_backend_tmux_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}
