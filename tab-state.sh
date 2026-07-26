#!/bin/bash
# Reflect Claude Code state in the iTerm2 tab via the native TAB COLOR.
# Usage: tab-state.sh {start|green|yellow|reset|session|agent-start|agent-stop}
#
#   start        = a new turn began (opens the turn, then paints busy)
#   green        = Claude is running
#   yellow       = Claude needs you (permission / question prompt)
#   reset        = turn over (Stop)
#   session      = session boundary; also forgets any tracked subagents
#   agent-start  = a subagent was dispatched
#   agent-stop   = a subagent finished
#
# Installed from github.com/skunkworker/claude-tab-state-iterm2.
#
# Tab color is a dedicated channel (Claude Code never writes it), so there is
# no contention and the reset (6;1;bg;*;default) is reliable. With multiple
# tabs the color stays in the individual tab cell. We do NOT touch the tab
# title, so Claude's own topic titles are left alone.
#
# Hooks run in a subprocess with NO controlling terminal, so /dev/tty fails.
# We walk up the process tree to the parent `claude` process's real tty.
#
# This runs on every PreToolUse and PostToolUse, so the cost of a single call
# is the design constraint throughout: guards are ordered cheapest-first and
# everything below them avoids forking where bash can do the job.
#
# Env overrides (mainly for tests and unusual setups):
#   TAB_STATE_DEV    write escapes here instead of resolving a tty
#   TAB_STATE_FORCE  =1 skips the iTerm2 detection guard

set -u

RESET_SEQ='\033]6;1;bg;*;default\007'
DISABLE_FLAG="${HOME:-}/.claude/tab-state.disabled"
STATE_DIR="${HOME:-}/.claude/.tab-state"

# A turn with no `start` (a resumed or compacted session) would otherwise keep
# the tab dark for its whole duration, so the closed turn self-heals after this
# many seconds. It only has to outlast scheduling skew between two hook
# subprocesses, so it is deliberately far larger than that rather than tuned.
STALE_AFTER=60

# Backstop for a subagent whose SubagentStop never arrives (it errored, or the
# session died). Generous: a long research subagent must not be swept while it
# is still working. Session boundaries drain the whole set anyway.
AGENT_STALE_AFTER=7200

# ------------------------------------------------------------------ functions

# One `ps` per level, asking for both fields at once. A single full-table
# `ps -ax` snapshot needs fewer forks but measures ~2x slower: it resolves the
# tty name of every process on the machine. Depth to `claude` is ~3.
resolve_dev() {
  local pid=$PPID line ppid tty
  for _ in 1 2 3 4 5 6 7 8; do
    line=$(ps -o ppid=,tty= -p "$pid" 2>/dev/null) || return 1
    [ -n "$line" ] || return 1
    read -r ppid tty <<<"$line"
    case "$tty" in
      ttys*)
        printf '/dev/%s' "$tty"
        return 0
        ;;
    esac
    [ -n "$ppid" ] && [ "$ppid" != 0 ] || return 1
    pid=$ppid
  done
  return 1
}

emit() { printf '%b' "$1" >"$dev" 2>/dev/null; }

set_color() { # r g b
  emit "\033]6;1;bg;red;brightness;$1\007\033]6;1;bg;green;brightness;$2\007\033]6;1;bg;blue;brightness;$3\007"
}
reset_color() { emit "$RESET_SEQ"; }

# One file per tty rather than one shared list: registration is an idempotent
# write with no read, no dedupe, and no interleaving between the parallel hook
# processes that can run at once. Matches how the other records are keyed.
register_tty() { printf '%s\n' "$dev" >"${STATE_DIR}/tty-${dev##*/}" 2>/dev/null; }

# True while the turn is closed. `reset` closes it, `start` reopens it — a
# latch rather than a timeout, because nothing in the payload can order a
# PostToolUse green against the Stop that races it. The timestamp is only the
# staleness backstop above. Costs zero forks when the marker is absent, which
# is the whole of a normal turn.
turn_is_closed() {
  local stamped now
  # stderr is silenced before the input redirect, not after: redirections are
  # applied left to right, and a missing marker is the normal case.
  read -r stamped 2>/dev/null <"$STOP_MARKER" || return 1
  now=$(date +%s) || return 1
  [ $((now - stamped)) -lt "$STALE_AFTER" ]
}

# One token file per outstanding subagent, keyed by the agent_id that both
# SubagentStart and SubagentStop carry. Counting in a shared file would be a
# read-modify-write race between the hook processes of agents that start and
# finish concurrently; a glob has no such problem and needs no locking.
agents_running() { # fork-free: the hot path only asks "any?"
  local f
  for f in "$AGENT_GLOB"*; do
    [ -e "$f" ] && return 0
    break
  done
  return 1
}

# Swept only on the rare agent events, never on the hot path.
sweep_agents() {
  local f stamped now
  now=$(date +%s) || return 0
  for f in "$AGENT_GLOB"*; do
    [ -e "$f" ] || continue
    read -r stamped 2>/dev/null <"$f" || stamped=0
    [ $((now - ${stamped:-0})) -ge "$AGENT_STALE_AFTER" ] && rm -f "$f" 2>/dev/null
  done
}

# Busy means green normally, blue while subagents are outstanding.
paint_busy() {
  register_tty
  if agents_running; then
    set_color 0 150 200
  else
    set_color 0 170 0
  fi
}

read_payload() { # -> PAYLOAD
  # Bounded read: an unclosed stdin would otherwise hang until Claude Code's
  # hook timeout and stall the session, and bash reads byte-at-a-time.
  PAYLOAD=""
  [ -t 0 ] || IFS= read -r -d '' -t 2 -n 8192 PAYLOAD || true
}

json_field() { # name -> FIELD, from $PAYLOAD, without forking
  local key="\"$1\"" m=$PAYLOAD
  FIELD=""
  case "$m" in
    *"$key"*) ;;
    *) return 0 ;;
  esac
  m=${m#*"$key"}
  m=${m#*:}
  m=${m#*\"}
  FIELD=${m%%\"*}
}

# ------------------------------------------------------- guards, cheapest first

case "${1:-}" in
  start | green | yellow | reset | session | agent-start | agent-stop) state="$1" ;;
  *)
    echo "usage: tab-state.sh {start|green|yellow|reset|session|agent-start|agent-stop}" >&2
    # Exit 1, never 2: Claude Code reads hook exit 2 as "block this tool call".
    exit 1
    ;;
esac

# Unsupported terminals render OSC 6 as literal garbage in the scrollback, so
# stay silent unless we know we are talking to iTerm2.
if [ "${TAB_STATE_FORCE:-}" != 1 ] &&
  [ "${LC_TERMINAL:-}" != "iTerm2" ] && [ "${TERM_PROGRAM:-}" != "iTerm.app" ]; then
  exit 0
fi

# Under tmux/screen the escape reaches the multiplexer, not the tab. Passthrough
# wrapping was tried and removed: every pane shares one iTerm2 tab, so the
# signal cannot mean what it means everywhere else.
[ -n "${TMUX:-}${STY:-}" ] && exit 0

# Feature off: clear anything we painted and get out. Deliberately above
# resolve_dev, which is the most expensive thing this script does and is pure
# waste for a disabled feature. Fork-free once the registry has been drained.
if [ -e "$DISABLE_FLAG" ]; then
  for f in "$STATE_DIR"/tty-*; do
    [ -e "$f" ] || continue
    read -r d 2>/dev/null <"$f" || continue
    [ -w "$d" ] && printf '%b' "$RESET_SEQ" >"$d" 2>/dev/null
    rm -f "$f" 2>/dev/null
  done
  exit 0
fi

dev="${TAB_STATE_DEV:-$(resolve_dev)}"
[ -n "$dev" ] && [ -w "$dev" ] || exit 0

STOP_MARKER="${STATE_DIR}/stopped-${dev##*/}"
AGENT_GLOB="${STATE_DIR}/agent-${dev##*/}-"
[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null

# ------------------------------------------------------------------- dispatch

case "$state" in
  start | green)
    # `start` reopens the turn; both then paint the same busy color.
    [ "$state" = start ] && rm -f "$STOP_MARKER" 2>/dev/null
    turn_is_closed && exit 0
    paint_busy
    ;;
  yellow)
    # Wired to Notification's `permission_prompt` matcher, so the idle nudge
    # never reaches this arm and no payload parsing is needed to tell them
    # apart. `idle_prompt` is wired to `reset` instead.
    register_tty
    set_color 235 190 0
    ;;
  reset)
    date +%s >"$STOP_MARKER" 2>/dev/null
    # Subagents outlive the turn that dispatched them, so a finished turn with
    # work still outstanding stays blue rather than going dark.
    if agents_running; then
      register_tty
      set_color 0 150 200
    else
      reset_color
    fi
    ;;
  session)
    # A session boundary is the one point where nothing can still be running.
    rm -f "$AGENT_GLOB"* 2>/dev/null
    date +%s >"$STOP_MARKER" 2>/dev/null
    reset_color
    ;;
  agent-start)
    read_payload
    json_field agent_id
    [ -n "$FIELD" ] || exit 0
    sweep_agents
    date +%s >"${AGENT_GLOB}${FIELD//[^A-Za-z0-9_-]/_}" 2>/dev/null
    register_tty
    set_color 0 150 200
    ;;
  agent-stop)
    read_payload
    json_field agent_id
    [ -n "$FIELD" ] || exit 0
    rm -f "${AGENT_GLOB}${FIELD//[^A-Za-z0-9_-]/_}" 2>/dev/null
    sweep_agents
    # Hand the tab back to whatever the turn is actually doing.
    if agents_running; then
      register_tty
      set_color 0 150 200
    elif turn_is_closed; then
      reset_color
    else
      paint_busy
    fi
    ;;
esac
exit 0
