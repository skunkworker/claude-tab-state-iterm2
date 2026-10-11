#!/bin/bash
# Reflect Claude Code state in the iTerm2 tab via the native TAB COLOR.
# Usage: tab-state.sh {start|green|yellow|reset|idle|failure|session|
#                      agent-start|agent-stop|compact-start|compact-end|schedule}
#
#   start          = a new turn began (opens the turn, then paints busy)
#   green          = Claude is running
#   yellow         = Claude needs you (permission, MCP input, an agent asking)
#   reset          = turn over (Stop); also clears a failed or paused turn
#   idle           = the idle nudge; like reset, but keeps a failure showing
#   failure        = the turn died on an API error (StopFailure)
#   session        = session boundary; also forgets any tracked subagents
#   agent-start    = a subagent was dispatched
#   agent-stop     = a subagent finished
#   compact-start  = compaction began (PreCompact)
#   compact-end    = compaction finished (PostCompact)
#   schedule       = a wake-up was scheduled or cancelled (PostToolUse)
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
# This runs on every PostToolUse, so the cost of a single call is the design
# constraint throughout: guards are ordered cheapest-first and everything below
# them avoids forking where bash can do the job.
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

# Backstop for a subagent whose SubagentStop never arrives (it errored, was
# interrupted, or the session died). Generous: a long research subagent must not
# be swept while it is still working. Session boundaries drain the whole set
# anyway. Seconds for compatibility; `find -mmin` wants minutes, rounded up.
AGENT_TTL_MIN=$(((${TAB_STATE_AGENT_TTL_SEC:-7200} + 59) / 60))

# How long a tab may stay painted busy with nothing refreshing its registry
# record before another tab's turn end clears it. Every tool call rewrites the
# record, so only one very slow tool call goes this quiet mid-turn. Minutes,
# because `find -mmin` is what ages the registry.
BUSY_TTL_MIN="${TAB_STATE_BUSY_TTL_MIN:-30}"

# Backstop for a wake-up token nothing removed. Recurring cron jobs expire after
# 7 days, so a token older than that (plus an hour of grace) is a lost one.
WAKE_TTL_MIN=10140

# ------------------------------------------------------------------ functions

# Sets `dev` (the tty to paint) and `owner` (the first ancestor holding it —
# the `claude` process itself, since hook subprocesses have no controlling
# terminal). Globals rather than stdout: two values, and no subshell fork.
#
# One `ps` per level, asking for every field at once. A single full-table
# `ps -ax` snapshot needs fewer forks but measures ~2x slower: it resolves the
# tty name of every process on the machine. Depth to `claude` is ~3.
#
# A `claude` with no tty is a headless session nested inside another one — a
# `claude -p` run from the Bash tool, whose shell has no tty either. Walking
# past it lands on the parent session's tab, and the nested SessionStart would
# then reset that tab and drop its subagents mid-turn. It has no tab of its
# own, so stop there. (An npm install runs as `node`, which this cannot tell
# apart; that case walks on as before.)
resolve_dev() {
  local pid=$PPID line ppid tty comm
  for _ in 1 2 3 4 5 6 7 8; do
    line=$(ps -o ppid=,tty=,comm= -p "$pid" 2>/dev/null) || return 1
    [ -n "$line" ] || return 1
    read -r ppid tty comm <<<"$line"
    case "$tty" in
      ttys*)
        dev="/dev/$tty"
        owner=$pid
        return 0
        ;;
    esac
    [ "${comm##*/}" = claude ] && return 1
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
register_tty() { # busy|agents|hold|shells|failed|paused|asleep
  printf '%s %s %s\n' "$dev" "$owner" "$1" >"$TTY_RECORD" 2>/dev/null
}
unregister_tty() { rm -f "$TTY_RECORD" 2>/dev/null; }

# Clear a tab we are giving up on and drop every record keyed to it. Takes only
# the tty: every record this drops is keyed by that name, the registry entry
# naming it included.
forget_tty() { # tty
  [ -w "$1" ] && printf '%b' "$RESET_SEQ" >"$1" 2>/dev/null
  local key=${1##*/}
  rm -f "${STATE_DIR}/tty-$key" "${STATE_DIR}/open-$key" "${STATE_DIR}/fail-$key" \
    "${STATE_DIR}/agent-$key-"* "${STATE_DIR}/wake-$key-"* 2>/dev/null
}

# True while the turn is closed. `start` opens it, `reset` closes it — a latch,
# because nothing in the payload can order a PostToolUse green against the Stop
# that races it. No expiry: Claude Code's own post-turn model work (away
# summaries, titling) fires tool hooks minutes later with no `Stop` behind
# them, so any window lets one repaint a finished tab green for good.
#
# The marker records "open", not "closed", so that lost state — a drained state
# dir, a toggle, an upgrade — lands on the safe side. A closed turn that should
# have been open costs a dark tab until the next prompt; the reverse is a tab
# green for good. It also exists only during a turn, so nothing accumulates.
turn_is_closed() { [ ! -e "$OPEN_MARKER" ]; }

# True if any file starts with this path. Fork-free: the hot path only asks
# "any?".
any_match() { # path-prefix
  local f
  for f in "$1"*; do
    [ -e "$f" ] && return 0
    break
  done
  return 1
}

# One token file per outstanding subagent, keyed by the agent_id that both
# SubagentStart and SubagentStop carry. Counting in a shared file would be a
# read-modify-write race between the hook processes of agents that start and
# finish concurrently; a glob has no such problem and needs no locking. The
# file is empty: its mtime is the start time, which is all the sweep reads.
agents_running() { any_match "${1:-$AGENT_GLOB}"; } # [glob-prefix]

# A pending wake-up has one token per kind, because each kind ends differently:
# `once` (ScheduleWakeup, one-shot cron) fires and is gone, so the turn it
# starts removes it, and a loop that goes on re-arms it in that same turn;
# `cron` (recurring) lasts until CronDelete or its 7-day expiry. Claude Code
# sends no hook when a wake-up fires, so the next `start` is the best signal.
wake_pending() { any_match "${STATE_DIR}/wake-$1-"; } # tty-key

# The failure the last turn ended on: `failed` or `paused` (a usage limit,
# which Claude Code can resume by itself), or empty. A file rather than the
# registry, because the idle nudge repaints the tab and must not lose it.
read_failure() { # tty-key -> FAILURE
  FAILURE=""
  [ -e "${STATE_DIR}/fail-$1" ] && read -r FAILURE 2>/dev/null <"${STATE_DIR}/fail-$1"
  return 0
}

# Background shells Claude Code left running are direct children of `claude`,
# and each one starts by sourcing a file from ~/.claude/shell-snapshots. Asking
# the process table is the only reliable count: no hook fires when a shell ends,
# and a foreground command that hits its timeout moves to the background with
# no flag in any payload. One fork, so never on the hot path.
shells_running() { # owner-pid
  pgrep -P "$1" -f shell-snapshots >/dev/null 2>&1
}

# States that legitimately outlive the turn that painted them: an unanswered
# prompt, and every after-turn color for as long as what backs it is still
# there. One predicate for both the foreign sweep and our own tab, so the two
# cannot drift apart. Testing by name rather than sweeping by name is
# deliberate — a state added later ages out like `busy` instead of silently
# becoming un-healable. The backed states are tied to their evidence rather
# than exempt outright, so a lost SubagentStop, a shell that ended with no hook
# to say so, or a lost wake-up ages out instead of holding forever.
outlives_turn() { # state tty-key owner-pid
  case "$1" in
    hold) return 0 ;;
    agents) agents_running "${STATE_DIR}/agent-$2-" ;;
    shells) shells_running "$3" ;;
    failed | paused) [ -e "${STATE_DIR}/fail-$2" ] ;;
    asleep) wake_pending "$2" ;;
    *) return 1 ;;
  esac
}

# Drop every tab's subagent and wake-up tokens older than their TTL. Here
# rather than on the events that write them, because a tab that lost the event
# that removes one may never see another. The fork-free probes first, so a turn
# with neither anywhere costs no `find`.
sweep_tokens() {
  any_match "$STATE_DIR/agent-" || any_match "$STATE_DIR/wake-" || return 0
  find "$STATE_DIR" -maxdepth 1 \( -name 'agent-*' -mmin "+$AGENT_TTL_MIN" \
    -o -name 'wake-*' -mmin "+$WAKE_TTL_MIN" \) -delete 2>/dev/null
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
  sweep_tokens
  for f in "$STATE_DIR"/tty-*; do
    [ -e "$f" ] || continue
    read -r d o s 2>/dev/null <"$f" || continue
    [ "$d" = "$dev" ] && continue # our own tab: the dispatch below owns it
    # A record with no owner predates this format; treat it as unowned. A tty
    # that is gone skips the question entirely — forget_tty writes nothing.
    if [ -w "$d" ] && [ -n "$o" ] && kill -0 "$o" 2>/dev/null; then
      outlives_turn "$s" "${d##*/}" "$o" && continue
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

# What a tab shows once its turn is over, most urgent first: a failure that
# needs you, then the work that outlived the turn, then a wake-up still to
# come, else nothing. Blue outranks a usage-limit pause because subagents may
# still finish, and outranks magenta because a shell may be a server that never
# ends, which would hide the subagent for good.
paint_after_turn() {
  read_failure "$key"
  if [ "$FAILURE" = failed ]; then
    paint failed 190 20 20
  elif agents_running; then
    paint_agents
  elif [ "$FAILURE" = paused ]; then
    paint paused 240 110 0
  elif shells_running "$owner"; then
    paint shells 255 90 220
  elif wake_pending "$key"; then
    paint asleep 110 115 140
  else
    reset_color
  fi
}

# Every way a turn ends: Stop, the idle nudge, StopFailure. Takes any other
# records to drop, so they go in the same `rm`.
end_turn() { # [file...]
  rm -f "$OPEN_MARKER" "$@" 2>/dev/null
  # Once a turn, off the hot path: the only chance a stranded tab in another
  # terminal has of being cleaned up. First, so the stale-token sweep inside it
  # also decides our own color below.
  heal_registry
  # Subagents and background shells outlive the turn that started them, so a
  # finished turn with work still outstanding shows it rather than going dark.
  paint_after_turn
}

# Busy means green normally, blue while subagents are outstanding.
#
# The green re-reads the latch after painting: every caller reaches here by
# testing it first, and a Stop landing between that test and the brushstroke
# leaves our color on top of Stop's with no further hook coming to undo it, so
# this repaints what Stop did. It lives here rather than in one arm so no
# future paint site can forget it; it costs one failed open, and blue is exempt
# because subagents outlive Stop.
paint_busy() {
  if agents_running; then
    paint_agents
  else
    paint busy 0 170 0
    turn_is_closed && paint_after_turn
  fi
}

read_payload() { # -> PAYLOAD
  # Bounded read: an unclosed stdin would otherwise hang until Claude Code's
  # hook timeout and stall the session, and bash reads byte-at-a-time.
  PAYLOAD=""
  [ -t 0 ] || IFS= read -r -d '' -t 2 -n 8192 PAYLOAD || true
}

# A string value, or a bare literal such as `true`, which `schedule` needs.
json_field() { # name -> FIELD, from $PAYLOAD, without forking
  local key="\"$1\"" m=$PAYLOAD
  FIELD=""
  case "$m" in
    *"$key"*) ;;
    *) return 0 ;;
  esac
  m=${m#*"$key"}
  m=${m#*:}
  m=${m#"${m%%[![:space:]]*}"}
  case "$m" in
    \"*)
      m=${m#\"}
      FIELD=${m%%\"*}
      ;;
    *)
      m=${m%%[,\}]*}
      FIELD=${m%"${m##*[![:space:]]}"}
      ;;
  esac
}

# ------------------------------------------------------- guards, cheapest first

case "${1:-}" in
  start | green | yellow | reset | idle | failure | session | agent-start | agent-stop | \
    compact-start | compact-end | schedule)
    state="$1"
    ;;
  *)
    echo "usage: tab-state.sh {start|green|yellow|reset|idle|failure|session|agent-start|agent-stop|compact-start|compact-end|schedule}" >&2
    # Exit 1, never 2: Claude Code reads hook exit 2 as "block this tool call".
    exit 1
    ;;
esac

# Feature off: clear anything we painted and get out. Deliberately above
# resolve_dev, which is the most expensive thing this script does and is pure
# waste for a disabled feature. Fork-free once the state has been drained.
#
# Above the terminal guards too: those are about the terminal running this
# hook, while the drain only writes to tabs iTerm2 already showed our color in.
# That is also what lets toggle.sh drain through here from any terminal rather
# than keep a second copy of this loop.
#
# Subagent tokens go too. This arm swallows the SubagentStop that would have
# removed them, so leaving them behind means re-enabling paints blue for an
# agent that finished while the feature was off. Open-turn markers go so that
# every turn is closed on re-enable — the safe side. Failures and wake-ups go
# for the same reason as subagents: the events that clear them are swallowed.
if [ -e "$DISABLE_FLAG" ]; then
  for f in "$STATE_DIR"/tty-*; do
    [ -e "$f" ] || continue
    read -r d _ 2>/dev/null <"$f" || continue
    forget_tty "$d"
  done
  # The loop is a fork-free probe for leftovers no registry entry named; one
  # `rm` then drains every class, rather than one per file.
  for f in "$STATE_DIR"/agent-* "$STATE_DIR"/open-* "$STATE_DIR"/fail-* "$STATE_DIR"/wake-*; do
    [ -e "$f" ] || continue
    rm -f "$STATE_DIR"/agent-* "$STATE_DIR"/open-* "$STATE_DIR"/fail-* "$STATE_DIR"/wake-* 2>/dev/null
    break
  done
  exit 0
fi

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

owner=$PPID              # stands in when TAB_STATE_DEV skips the walk
dev="${TAB_STATE_DEV:-}" # doubles as the initializer resolve_dev may not set
[ -n "$dev" ] || resolve_dev
[ -n "$dev" ] && [ -w "$dev" ] || exit 0

# Every record this tab owns is keyed by its tty name, derived once here.
key=${dev##*/}
TTY_RECORD="${STATE_DIR}/tty-$key"
OPEN_MARKER="${STATE_DIR}/open-$key"
FAIL_MARKER="${STATE_DIR}/fail-$key"
AGENT_GLOB="${STATE_DIR}/agent-$key-"
WAKE_GLOB="${STATE_DIR}/wake-$key-"
[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null

# ------------------------------------------------------------------- dispatch

case "$state" in
  start)
    # UserPromptSubmit: the turn is open by definition. A flag, not a clock:
    # nothing reads its contents, so a bare redirect rather than a `date` fork.
    : >"$OPEN_MARKER" 2>/dev/null
    # A new prompt answers a failure. It also is, or comes before, the turn a
    # one-shot wake-up starts; a loop that goes on re-arms it in this turn. The
    # tests first, so the usual prompt with neither costs no `rm`.
    [ -e "$FAIL_MARKER" ] || [ -e "${WAKE_GLOB}once" ] &&
      rm -f "$FAIL_MARKER" "${WAKE_GLOB}once" 2>/dev/null
    paint_busy
    ;;
  green)
    if turn_is_closed; then
      # A tool hook after the turn ended — Claude Code's own post-turn work.
      # Nothing follows it, so it does not paint; and if the tab is still
      # registered in a state that should not have survived the turn, this is
      # the last hook that will ever visit, so it clears it instead.
      read -r _ _ shown 2>/dev/null <"$TTY_RECORD" &&
        ! outlives_turn "$shown" "$key" "$owner" && reset_color
      exit 0
    fi
    paint_busy
    ;;
  yellow)
    # Wired to Notification's matchers for each kind of "needs you" — a
    # permission prompt, an MCP server's input request, a background agent or
    # teammate asking — so the idle nudge never reaches this arm and no payload
    # parsing is needed to tell them apart. `idle_prompt` is wired to `idle`.
    paint hold 235 190 0
    ;;
  reset)
    # Stop: a turn that ended well answers whatever failure came before it,
    # including a usage-limit pause that Claude Code resumed by itself.
    end_turn "$FAIL_MARKER"
    ;;
  idle)
    # The idle nudge, a minute after a turn. It ends the turn like Stop, but a
    # failure is still unanswered, so it keeps showing.
    end_turn
    ;;
  failure)
    # StopFailure. A usage limit is the one failure that can end by itself —
    # Claude Code resumes when the limit resets — so it is a pause, not a
    # failure. Matching on the payload rather than with hook matchers keeps
    # this to one hook, and an error type added later lands on `failed`.
    read_payload
    json_field error
    if [ "$FIELD" = rate_limit ]; then
      echo paused >"$FAIL_MARKER" 2>/dev/null
    else
      echo failed >"$FAIL_MARKER" 2>/dev/null
    fi
    end_turn
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
      rm -f "$AGENT_GLOB"* "$WAKE_GLOB"* "$OPEN_MARKER" "$FAIL_MARKER" 2>/dev/null
      reset_color
    fi
    heal_registry
    ;;
  compact-start)
    # PreCompact. Mid-turn the tab is already busy; between turns, a manual
    # /compact is work with no turn around it, so it shows as busy until
    # PostCompact. No latch re-check: nothing here races a Stop.
    turn_is_closed && paint busy 0 170 0
    ;;
  compact-end)
    turn_is_closed && paint_after_turn
    ;;
  schedule)
    # PostToolUse, matched to the scheduling tools only, so the payload read
    # stays off the hot path. Nothing paints here: the turn is running, and
    # its end paints the wake-up.
    read_payload
    json_field tool_name
    case "$FIELD" in
      ScheduleWakeup)
        json_field stop
        if [ "$FIELD" = true ]; then
          rm -f "${WAKE_GLOB}once" 2>/dev/null
        else
          : >"${WAKE_GLOB}once" 2>/dev/null
        fi
        ;;
      CronCreate)
        json_field recurring
        if [ "$FIELD" = false ]; then
          : >"${WAKE_GLOB}once" 2>/dev/null
        else
          : >"${WAKE_GLOB}cron" 2>/dev/null
        fi
        ;;
      # Which job it was is not tracked, so this may also clear the tab of a
      # job still pending. A dark tab is the safe side of that guess.
      CronDelete) rm -f "${WAKE_GLOB}cron" 2>/dev/null ;;
    esac
    ;;
  agent-start)
    read_payload
    json_field agent_id
    [ -n "$FIELD" ] || exit 0
    : >"${AGENT_GLOB}${FIELD//[^A-Za-z0-9_-]/_}" 2>/dev/null
    paint_agents
    ;;
  agent-stop)
    read_payload
    json_field agent_id
    [ -n "$FIELD" ] || exit 0
    rm -f "${AGENT_GLOB}${FIELD//[^A-Za-z0-9_-]/_}" 2>/dev/null
    # Hand the tab back to whatever the turn is actually doing.
    if turn_is_closed; then
      paint_after_turn
    else
      paint_busy
    fi
    ;;
esac
exit 0
