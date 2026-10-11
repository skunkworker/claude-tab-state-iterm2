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
#   session        = session boundary; forgets every record of the tab
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

# Wake-up tokens carry their own expiry, read without `find`. A one-shot is
# believed until this long after it was due: wake-ups fire only while the
# session is idle, so a busy session fires them late. A recurring cron job is
# believed for its 7-day lifetime plus an hour.
WAKE_GRACE_SEC=900
CRON_LIFE_SEC=608400

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
# the tty: every record is named `<kind>-<tty>` or `<kind>-<tty>-<id>`, the
# registry entry included, so two globs reach them all and a kind added later
# needs no edit here. Ids are sanitized to [A-Za-z0-9_-] and never end in a tty
# name, so the globs cannot reach another tab's records.
forget_tty() { # tty
  [ -w "$1" ] && printf '%b' "$RESET_SEQ" >"$1" 2>/dev/null
  local key=${1##*/}
  rm -f "$STATE_DIR"/*-"$key" "$STATE_DIR"/*-"$key"-* 2>/dev/null
}

# The clock, read once per run and only when something needs it: bash 3.2 has
# no builtin for it, so it costs a `date` fork.
read_clock() { [ -n "${NOW:-}" ] || NOW=$(date +%s); }

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
# finish concurrently; a glob has no such problem and needs no locking. Its
# mtime is the start time, and it holds the path of the subagent's own
# transcript (see subagent_ended); both are for the sweep.
agents_running() { any_match "${1:-$AGENT_GLOB}"; } # [glob-prefix]

# One token per pending wake-up, holding "<due> <expires>" in epoch seconds:
# `loop` for the ScheduleWakeup of a /loop (one at a time), `at-<job>` for a
# one-shot cron job, `cron-<job>` for a recurring one (due 0: it never fires
# for the last time on a known date). Claude Code sends no hook when one fires,
# so a one-shot is believed until it is overdue, and the prompt its firing
# starts drops it early (see drop_fired_wakeups).
#
# True while any token has not expired, dropping the ones that have. Forks
# `date` only when a token exists.
wake_pending() { # [glob-prefix]
  local prefix=${1:-$WAKE_GLOB} f due expires pending=1
  any_match "$prefix" || return 1
  read_clock
  for f in "$prefix"*; do
    read -r due expires 2>/dev/null <"$f" || continue
    if [ "${expires:-0}" -gt "$NOW" ] 2>/dev/null; then
      pending=0
    else
      rm -f "$f" 2>/dev/null
    fi
  done
  return $pending
}

# The prompt a one-shot wake-up enqueues arrives as a prompt, so `start` drops
# every one-shot that is due by now. A prompt you type before that leaves it
# alone. Cron jobs may fire up to 90s early, hence the slack.
drop_fired_wakeups() {
  local f due expires
  any_match "$WAKE_GLOB" || return 0
  read_clock
  for f in "$WAKE_GLOB"*; do
    read -r due expires 2>/dev/null <"$f" || continue
    [ "${due:-0}" -gt 0 ] && [ "$NOW" -ge $((due - 90)) ] && rm -f "$f" 2>/dev/null
  done
  return 0
}

# Epoch seconds for a one-shot cron job's pinned "M H DoM Mon *", the next time
# it comes round; empty when the fields are not plain numbers. BSD date first,
# then GNU, so the tests run on Linux too.
cron_due() { # cron-expression -> DUE
  local mi h d mo rest y t
  DUE=""
  read -r mi h d mo rest <<<"$1"
  case "$mi$h$d$mo" in '' | *[!0-9]*) return 0 ;; esac
  read_clock
  y=$(date +%Y)
  for y in "$y" $((y + 1)); do
    t=$(date -j -f '%Y-%m-%d %H:%M:%S' "$y-$mo-$d $h:$mi:00" +%s 2>/dev/null ||
      date -d "$y-$mo-$d $h:$mi:00" +%s 2>/dev/null) || continue
    [ "$t" -ge $((NOW - 90)) ] && DUE=$t && return 0
  done
  return 0
}

# The failure the last turn ended on: `failed` or `paused` (a rate or usage
# limit, which Claude Code may resume by itself), or empty. A file rather than
# the registry, because the idle nudge repaints the tab and must not lose it.
read_failure() { # -> FAILURE
  FAILURE=""
  [ -e "$FAIL_MARKER" ] && read -r FAILURE 2>/dev/null <"$FAIL_MARKER"
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
    asleep) wake_pending "${STATE_DIR}/wake-$2-" ;;
    *) return 1 ;;
  esac
}

# True if a subagent's transcript ends the way a subagent ends when no
# SubagentStop follows: on an API error, or on your interrupt. Of 363
# subagents on one machine, those two endings were the only ones with no
# SubagentStop.
#
# Only the last line counts, so a subagent that went on working after either
# one is not ended. The bounded tail keeps a multi-megabyte last line (a big
# tool result) out of a bash variable. Both patterns are JSON structure, not
# text: inside a JSON string their quotes would be escaped, so a tool result
# that quotes one cannot match.
subagent_ended() { # transcript
  local last
  last=$(tail -c 4096 "$1" 2>/dev/null) || return 1
  case "${last##*$'\n'}" in
    *'"isApiErrorMessage":true'* | \
      *'"content":[{"type":"text","text":"[Request interrupted by user'*) return 0 ;;
  esac
  return 1
}

# Drop every tab's subagent tokens whose subagent has ended without a
# SubagentStop, or that are older than the TTL — the backstop for a subagent
# that hangs, or that ends in a way subagent_ended does not know. Here rather
# than on the agent events because a tab whose SubagentStop never came may
# never see another agent event. The fork-free probe first, so a turn with no
# agents anywhere costs no fork. Then one `tail` per token that names a
# transcript, once per turn end. Wake-up tokens expire by their own contents.
sweep_agents() {
  local f path
  agents_running "$STATE_DIR/agent-" || return 0
  find "$STATE_DIR" -maxdepth 1 -name 'agent-*' -mmin "+$AGENT_TTL_MIN" -delete 2>/dev/null
  for f in "$STATE_DIR"/agent-*; do
    # A token from before this format is empty, and a transcript not yet
    # written says nothing; the TTL alone judges both.
    IFS= read -r path 2>/dev/null <"$f" && [ -f "$path" ] || continue
    subagent_ended "$path" && rm -f "$f" 2>/dev/null
  done
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
  sweep_agents
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

# What a tab shows once its turn is over, most urgent first: a question still
# waiting on you, a failure that needs you, then the work that outlived the
# turn, then a wake-up still to come, else nothing. Blue outranks a pause
# because subagents may still finish, and outranks magenta because a shell may
# be a server that never ends, which would hide the subagent for good.
#
# A question asked after the turn — a background agent's, say — is kept as it
# is: no hook says it was answered, so only the events that settle it (a new
# prompt, a Stop, a StopFailure) repaint over it, and they drop the record first.
paint_after_turn() {
  local shown
  read -r _ _ shown 2>/dev/null <"$TTY_RECORD" && [ "$shown" = hold ] && return 0
  read_failure
  if [ "$FAILURE" = failed ]; then
    paint failed 190 20 20
  elif agents_running; then
    paint_agents
  elif [ "$FAILURE" = paused ]; then
    paint paused 240 110 0
  elif shells_running "$owner"; then
    paint shells 255 90 220
  elif wake_pending; then
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

read_payload() { # [max-bytes] -> PAYLOAD
  # Bounded read: an unclosed stdin would otherwise hang until Claude Code's
  # hook timeout and stall the session, and bash reads byte-at-a-time. 8 KiB
  # reaches every field the hot events read; `schedule` asks for more, because
  # its fields can follow a long prompt.
  PAYLOAD=""
  [ -t 0 ] || IFS= read -r -d '' -t 2 -n "${1:-8192}" PAYLOAD || true
}

# A string value, or a bare literal such as `true`, which `schedule` needs.
# Matching the key with its colon is what tells it from a string value that
# happens to equal the key's name: inside a JSON string the quotes around such
# a value are escaped, so `"stop":` cannot occur there.
json_field() { # name -> FIELD, from $PAYLOAD, without forking
  local key="\"$1\":" m=$PAYLOAD
  FIELD=""
  case "$m" in
    *"$key"*) ;;
    *) return 0 ;;
  esac
  m=${m#*"$key"}
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
# So everything goes, and no kind of record needs naming here.
if [ -e "$DISABLE_FLAG" ]; then
  for f in "$STATE_DIR"/tty-*; do
    [ -e "$f" ] || continue
    read -r d _ 2>/dev/null <"$f" || continue
    forget_tty "$d"
  done
  # The loop is a fork-free probe for leftovers no registry entry named; one
  # `rm` then drains them all, rather than one per file.
  for f in "$STATE_DIR"/*; do
    [ -e "$f" ] || continue
    rm -f "$STATE_DIR"/* 2>/dev/null
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
    # A new prompt answers a failure, and may be the firing of a one-shot
    # wake-up. Both checks are fork-free unless there is something to drop.
    [ -e "$FAIL_MARKER" ] && rm -f "$FAIL_MARKER" 2>/dev/null
    drop_fired_wakeups
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
    # Stop: a turn that ended well answers whatever came before it — a failure,
    # a pause Claude Code resumed by itself, a question. Dropping the record
    # tells paint_after_turn that a showing yellow is settled.
    end_turn "$FAIL_MARKER" "$TTY_RECORD"
    ;;
  idle)
    # The idle nudge, a minute after a turn. It ends the turn like Stop, but a
    # failure is still unanswered, so it keeps showing.
    end_turn
    ;;
  failure)
    # StopFailure. Only for a turn that is open: Claude Code's own post-turn
    # model work (titling, away summaries) runs with no turn around it, and its
    # failure is not yours to answer.
    turn_is_closed && exit 0
    # A rate or usage limit is the one failure that may end by itself — Claude
    # Code can resume when the limit resets — so it is a pause, not a failure.
    # Matching on the payload rather than with hook matchers keeps this to one
    # hook, and an error type added later lands on `failed`.
    read_payload
    json_field error
    if [ "$FIELD" = rate_limit ]; then
      echo paused >"$FAIL_MARKER" 2>/dev/null
    else
      echo failed >"$FAIL_MARKER" 2>/dev/null
    fi
    end_turn "$TTY_RECORD"
    ;;
  session)
    # A compact is not a boundary: `SessionStart` fires for it, but the turn
    # that triggered it is still running. Touching the latch either way is
    # wrong — closing it darkens the rest of that turn, opening it would unlatch
    # a compact that happened between turns — so leave every record alone.
    read_payload
    json_field source
    if [ "$FIELD" != compact ]; then
      # Any other boundary is the one point where nothing can still be running,
      # so every record this tab owns goes, as for a tab another session gave up.
      # That includes wake-ups on /clear: whether Claude Code keeps cron jobs
      # across it is not known, and a dark tab is the safe guess.
      forget_tty "$dev"
    fi
    heal_registry
    ;;
  compact-start)
    # PreCompact. Mid-turn the tab is already busy; between turns, a manual
    # /compact is work with no turn around it, so an idle tab shows as busy
    # until PostCompact. Only an idle one: every other color after a turn says
    # more than green does. If PostCompact never comes — the compact was
    # cancelled — the idle nudge ends it. No latch re-check: nothing here
    # races a Stop.
    turn_is_closed && [ ! -e "$TTY_RECORD" ] && paint busy 0 170 0
    ;;
  compact-end)
    turn_is_closed && paint_after_turn
    ;;
  schedule)
    # PostToolUse, matched to the scheduling tools only, so the payload read
    # stays off the hot path. Nothing paints here: the turn is running, and
    # its end paints the wake-up. Cron tokens are named by job id — CronCreate
    # returns it, CronDelete takes it — so a delete drops exactly its own job.
    read_payload 65536
    json_field tool_name
    tool=$FIELD
    json_field id
    job=${FIELD//[^A-Za-z0-9_-]/_}
    case "$tool" in
      ScheduleWakeup)
        json_field stop
        if [ "$FIELD" = true ]; then
          rm -f "${WAKE_GLOB}loop" 2>/dev/null
        else
          json_field delaySeconds
          case "$FIELD" in '' | *[!0-9]*) FIELD=3600 ;; esac
          read_clock
          due=$((NOW + FIELD))
          echo "$due $((due + WAKE_GRACE_SEC))" >"${WAKE_GLOB}loop" 2>/dev/null
        fi
        ;;
      CronCreate)
        [ -n "$job" ] || exit 0
        json_field recurring
        read_clock
        if [ "$FIELD" = false ]; then
          json_field cron
          cron_due "$FIELD"
          # A schedule cron_due cannot place fires at its next match, which may
          # be soon: count it due now, so the next prompt is the one to drop it.
          due=${DUE:-$NOW}
          echo "$due $((due + WAKE_GRACE_SEC))" >"${WAKE_GLOB}at-$job" 2>/dev/null
        else
          echo "0 $((NOW + CRON_LIFE_SEC))" >"${WAKE_GLOB}cron-$job" 2>/dev/null
        fi
        ;;
      CronDelete)
        [ -n "$job" ] && rm -f "${WAKE_GLOB}cron-$job" "${WAKE_GLOB}at-$job" 2>/dev/null
        ;;
    esac
    ;;
  agent-start)
    read_payload
    json_field agent_id
    [ -n "$FIELD" ] || exit 0
    id=$FIELD
    # Only SubagentStop names the subagent's transcript; SubagentStart has the
    # session's, and the subagent's lives beside it under a fixed name, nested
    # ones included. A path this cannot parse names no file, so the sweep falls
    # back on the TTL.
    json_field transcript_path
    printf '%s\n' "${FIELD:+${FIELD%.jsonl}/subagents/agent-$id.jsonl}" \
      >"${AGENT_GLOB}${id//[^A-Za-z0-9_-]/_}" 2>/dev/null
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
