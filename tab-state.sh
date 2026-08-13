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
#   TAB_STATE_DEV            write escapes here instead of resolving a tty
#   TAB_STATE_FORCE          =1 skips the iTerm2 detection guard
#   TAB_STATE_BUSY_TTL_MIN   minutes before a quiet busy tab is cleared (30)
#   TAB_STATE_AGENT_TTL_SEC  seconds before a subagent token is disbelieved (7200)

set -u

RESET_SEQ='\033]6;1;bg;*;default\007'
DISABLE_FLAG="${HOME:-}/.claude/tab-state.disabled"
STATE_DIR="${HOME:-}/.claude/.tab-state"

# Backstop for a subagent whose SubagentStop never arrives (it errored, or the
# session died). Generous: a long research subagent must not be swept while it
# is still working. Session boundaries drain the whole set anyway.
AGENT_STALE_AFTER="${TAB_STATE_AGENT_TTL_SEC:-7200}"

# How long a tab may stay painted busy with nothing refreshing its registry
# record before another tab's turn end clears it. Every tool call rewrites the
# record, so only one very slow tool call goes this quiet mid-turn. Minutes,
# because `find -mmin` is what ages the registry.
BUSY_TTL_MIN="${TAB_STATE_BUSY_TTL_MIN:-30}"

# ------------------------------------------------------------------ functions

# Sets `dev` (the tty to paint) and `owner` (the first ancestor holding it —
# the `claude` process itself, since hook subprocesses have no controlling
# terminal). Globals rather than stdout: two values, and no subshell fork.
#
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
        dev="/dev/$tty"
        owner=$pid
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
reset_color() {
  emit "$RESET_SEQ"
  unregister_tty
}

# The registry is the set of tabs currently painted: one file per tty, added on
# paint and removed the moment the tab goes back to default. One file rather
# than a shared list because registration is then an idempotent write with no
# read, no dedupe, and no interleaving between the parallel hook processes that
# can run at once. Matches how the other records are keyed.
#
# A foreign sweep judges the record (see heal_registry); its mtime is the "last
# seen busy" clock — free, versus a `date` fork on the hot path.
register_tty() { # busy|agents|hold
  printf '%s %s %s\n' "$dev" "$owner" "$1" >"$TTY_RECORD" 2>/dev/null
}
unregister_tty() { rm -f "$TTY_RECORD" 2>/dev/null; }

# Clear a tab we are giving up on and drop every record keyed to it. Takes only
# the tty: every record this drops is keyed by that name, the registry entry
# naming it included.
forget_tty() { # tty
  [ -w "$1" ] && printf '%b' "$RESET_SEQ" >"$1" 2>/dev/null
  local key=${1##*/}
  rm -f "${STATE_DIR}/tty-$key" "${STATE_DIR}/stopped-$key" "${STATE_DIR}/agent-$key-"* 2>/dev/null
}

# True while the turn is closed. `reset` closes it, `start` reopens it — a
# latch, because nothing in the payload can order a PostToolUse green against
# the Stop that races it. No expiry: Claude Code's own post-turn model work
# (away summaries, titling) fires tool hooks minutes later with no `Stop`
# behind them, so any window lets one repaint a finished tab green for good.
turn_is_closed() { [ -e "$STOP_MARKER" ]; }

# States that legitimately outlive the turn that painted them: a subagent and an
# unanswered permission prompt are both long-lived. One predicate for both the
# foreign sweep and our own tab, so the two cannot drift apart. Testing by name
# rather than sweeping by name is deliberate — a state added later ages out like
# `busy` instead of silently becoming un-healable.
outlives_turn() { [ "$1" = agents ] || [ "$1" = hold ]; }

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

# Swept only on the rare agent events, never on the hot path. The fork-free
# "any?" first, so an empty set costs no `date`.
sweep_agents() {
  local f stamped now
  agents_running || return 0
  now=$(date +%s 2>/dev/null) || return 0
  for f in "$AGENT_GLOB"*; do
    [ -e "$f" ] || continue
    read -r stamped 2>/dev/null <"$f" || stamped=0
    [ $((now - ${stamped:-0})) -ge "$AGENT_STALE_AFTER" ] && rm -f "$f" 2>/dev/null
  done
  return 0
}

# Clear tabs no hook will ever come back for, and drop what they left behind.
#
# Every in-tab recovery path needs an event in that tab's own tty, so a session
# that stops delivering them — killed, crashed, or its hook config rewritten
# underneath it mid-session — stays painted forever, and other tabs are the only
# ones left to notice. Clearing a tab that turns out to still be working costs
# nothing: its next tool call repaints and re-registers it.
heal_registry() {
  local f d o s stale=""
  for f in "$STATE_DIR"/tty-*; do
    [ -e "$f" ] || continue
    read -r d o s 2>/dev/null <"$f" || continue
    [ "$d" = "$dev" ] && continue # our own tab: the dispatch below owns it
    # A record with no owner predates this format; treat it as unowned. A tty
    # that is gone skips the question entirely — forget_tty writes nothing.
    if [ -w "$d" ] && [ -n "$o" ] && kill -0 "$o" 2>/dev/null; then
      outlives_turn "$s" && continue
      # One fork for the whole sweep, and only once a live-owner record has
      # actually asked. `-mmin` lists the aged records, so the test itself stays
      # fork-free; the newline sentinels make an empty result non-empty, which
      # doubles as the "already ran" flag so this cannot fork twice.
      [ -n "$stale" ] ||
        stale=$'\n'$(find "$STATE_DIR" -maxdepth 1 -name 'tty-*' -mmin "+$BUSY_TTL_MIN" 2>/dev/null)$'\n'
      [[ $stale == *$'\n'"$f"$'\n'* ]] || continue
    fi
    forget_tty "$d"
  done
}

# Every paint registers what it painted in the same breath, so the record a
# foreign sweep reads cannot disagree with the color on the tab.
paint() { # state r g b
  register_tty "$1"
  set_color "$2" "$3" "$4"
}
paint_agents() { paint agents 0 150 200; }

# Busy means green normally, blue while subagents are outstanding.
#
# The green re-reads the latch after painting: every caller reaches here by
# testing it first, and a Stop landing between that test and the brushstroke
# leaves our color on top of its reset with no further hook coming to undo it.
# It lives here rather than in one arm so no future paint site can forget it;
# it costs one failed open, and blue is exempt because subagents outlive Stop.
paint_busy() {
  if agents_running; then
    paint_agents
  else
    paint busy 0 170 0
    turn_is_closed && reset_color
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
# waste for a disabled feature. Fork-free once the state has been drained.
#
# Subagent tokens go too. This arm swallows the SubagentStop that would have
# removed them, so leaving them behind means re-enabling paints blue for an
# agent that finished while the feature was off.
if [ -e "$DISABLE_FLAG" ]; then
  for f in "$STATE_DIR"/tty-*; do
    [ -e "$f" ] || continue
    read -r d _ 2>/dev/null <"$f" || continue
    forget_tty "$d"
  done
  # The loop is a fork-free probe for leftovers no registry entry named; one
  # `rm` then drains both classes, rather than one per file.
  for f in "$STATE_DIR"/agent-* "$STATE_DIR"/stopped-*; do
    [ -e "$f" ] || continue
    rm -f "$STATE_DIR"/agent-* "$STATE_DIR"/stopped-* 2>/dev/null
    break
  done
  exit 0
fi

owner=$PPID              # stands in when TAB_STATE_DEV skips the walk
dev="${TAB_STATE_DEV:-}" # doubles as the initializer resolve_dev may not set
[ -n "$dev" ] || resolve_dev
[ -n "$dev" ] && [ -w "$dev" ] || exit 0

# Every record this tab owns is keyed by its tty name, derived once here.
key=${dev##*/}
TTY_RECORD="${STATE_DIR}/tty-$key"
STOP_MARKER="${STATE_DIR}/stopped-$key"
AGENT_GLOB="${STATE_DIR}/agent-$key-"
[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null

# ------------------------------------------------------------------- dispatch

case "$state" in
  start)
    # UserPromptSubmit: the turn is open by definition, so reopen the latch.
    rm -f "$STOP_MARKER" 2>/dev/null
    paint_busy
    ;;
  green)
    if turn_is_closed; then
      # A tool hook after the turn ended — Claude Code's own post-turn work.
      # Nothing follows it, so it does not paint; and if the tab is still
      # registered in a state that should not have survived the turn, this is
      # the last hook that will ever visit, so it clears it instead.
      read -r _ _ shown 2>/dev/null <"$TTY_RECORD" &&
        ! outlives_turn "$shown" && reset_color
      exit 0
    fi
    paint_busy
    ;;
  yellow)
    # Wired to Notification's `permission_prompt` matcher, so the idle nudge
    # never reaches this arm and no payload parsing is needed to tell them
    # apart. `idle_prompt` is wired to `reset` instead.
    paint hold 235 190 0
    ;;
  reset)
    # The marker is a flag, not a clock: nothing reads its contents, so it is
    # written with a bare redirect rather than a `date` fork.
    : >"$STOP_MARKER" 2>/dev/null
    # Subagents outlive the turn that dispatched them, so a finished turn with
    # work still outstanding stays blue rather than going dark.
    if agents_running; then
      paint_agents
    else
      reset_color
    fi
    # Once a turn, off the hot path: the only chance a stranded tab in another
    # terminal has of being cleaned up.
    heal_registry
    ;;
  session)
    # A compact is not a boundary: `SessionStart` fires for it, but the turn
    # that triggered it is still running. Touching the latch either way is
    # wrong — closing it darkens the rest of that turn, opening it would unlatch
    # a compact that happened between turns — so leave every record alone.
    read_payload
    json_field source
    if [ "$FIELD" != compact ]; then
      # Any other boundary is the one point where nothing can still be running.
      rm -f "$AGENT_GLOB"* 2>/dev/null
      : >"$STOP_MARKER" 2>/dev/null
      reset_color
    fi
    heal_registry
    ;;
  agent-start)
    read_payload
    json_field agent_id
    [ -n "$FIELD" ] || exit 0
    sweep_agents
    date +%s >"${AGENT_GLOB}${FIELD//[^A-Za-z0-9_-]/_}" 2>/dev/null
    paint_agents
    ;;
  agent-stop)
    read_payload
    json_field agent_id
    [ -n "$FIELD" ] || exit 0
    rm -f "${AGENT_GLOB}${FIELD//[^A-Za-z0-9_-]/_}" 2>/dev/null
    sweep_agents
    # Hand the tab back to whatever the turn is actually doing.
    if agents_running; then
      paint_agents
    elif turn_is_closed; then
      reset_color
    else
      paint_busy
    fi
    ;;
esac
exit 0
