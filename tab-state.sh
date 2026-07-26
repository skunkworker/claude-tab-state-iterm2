#!/bin/bash
# Reflect Claude Code state in the iTerm2 tab via the native TAB COLOR.
# Usage: tab-state.sh {start|green|yellow|reset}
#
#   start  = new turn began (clears the stop marker, then green)
#   green  = Claude is running
#   yellow = Claude needs you (real permission/question prompt)
#   reset  = default tab color (Claude is done / idle / session over)
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
# Env overrides (mainly for tests and unusual setups):
#   TAB_STATE_DEV    write escapes here instead of resolving a tty
#   TAB_STATE_FORCE  =1 skips the iTerm2 detection guard
#   TAB_STATE_TMUX   =1 enables tmux passthrough wrapping

set -u

usage() {
  echo "usage: tab-state.sh {start|green|yellow|reset}" >&2
  # Exit 1, never 2: Claude Code treats hook exit 2 as "block this tool call".
  exit 1
}

state="${1:-}"
case "$state" in
  start | green | yellow | reset) ;;
  *) usage ;;
esac

DISABLE_FLAG="${HOME:-}/.claude/tab-state.disabled"
STATE_DIR="${HOME:-}/.claude/.tab-state"

# Unsupported terminals render OSC 6 as literal garbage in the scrollback, so
# stay silent unless we know we are talking to iTerm2.
if [ "${TAB_STATE_FORCE:-}" != 1 ] &&
  [ "${LC_TERMINAL:-}" != "iTerm2" ] && [ "${TERM_PROGRAM:-}" != "iTerm.app" ]; then
  exit 0
fi

# tmux/screen swallow OSC 6 unless passthrough is enabled, and the escape would
# reach the multiplexer rather than the tab. Opt in explicitly.
if [ -n "${TMUX:-}${STY:-}" ] && [ "${TAB_STATE_TMUX:-}" != 1 ]; then
  exit 0
fi

# Resolve the owning tty by walking $PPID up the process tree. One ps snapshot
# plus one awk pass: O(procs) work but O(1) forks, versus two forks per level.
# This runs on every PostToolUse, so the fork count matters.
resolve_dev() {
  local name
  name=$(ps -axo pid=,ppid=,tty= 2>/dev/null | awk -v start="$PPID" '
    { ppid[$1] = $2; tty[$1] = $3 }
    END {
      p = start
      # Cap the climb so a cycle or a bogus table cannot spin forever.
      for (i = 0; i < 32; i++) {
        if (p == "" || p == "0") break
        if (tty[p] ~ /^ttys/) { print tty[p]; exit }
        p = ppid[p]
      }
    }')
  [ -n "$name" ] && printf '/dev/%s' "$name"
}

dev="${TAB_STATE_DEV:-$(resolve_dev)}"
[ -n "$dev" ] && [ -w "$dev" ] || exit 0

STOP_MARKER="${STATE_DIR}/stopped-${dev##*/}"
TTY_REGISTRY="${STATE_DIR}/ttys"

emit() { # $1 = one or more OSC sequences, as literal \033...\007 text
  local seq="$1"
  if [ -n "${TMUX:-}" ]; then
    # tmux passthrough: wrap in DCS and double every ESC in the payload.
    # Needs `set -g allow-passthrough on` in the tmux config.
    seq="\033Ptmux;$(printf '%s' "$seq" | sed 's/\\033/\\033\\033/g')\033\\\\"
  fi
  printf '%b' "$seq" >"$dev" 2>/dev/null
}

set_color() { # r g b
  emit "\033]6;1;bg;red;brightness;$1\007\033]6;1;bg;green;brightness;$2\007\033]6;1;bg;blue;brightness;$3\007"
}
reset_color() { emit "\033]6;1;bg;*;default\007"; }

# Disabled -> ensure the tab is back to default and stop.
if [ -e "$DISABLE_FLAG" ]; then
  reset_color
  exit 0
fi

[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null

# Record this tty so `toggle.sh off` can clear every tab we have ever colored,
# not just the current one. Read in bash to keep the hot path fork-free.
register_tty() {
  local line
  if [ -e "$TTY_REGISTRY" ]; then
    while IFS= read -r line; do
      [ "$line" = "$dev" ] && return 0
    done <"$TTY_REGISTRY"
  fi
  printf '%s\n' "$dev" >>"$TTY_REGISTRY" 2>/dev/null
}

# True if a reset landed in the last couple of seconds. Parallel tool calls can
# deliver a PostToolUse green *after* Stop's reset, which would strand the tab
# green; `start` clears the marker so a genuine new turn is never suppressed.
stop_is_recent() {
  [ -e "$STOP_MARKER" ] || return 1
  local now mtime
  now=$(date +%s 2>/dev/null) || return 1
  mtime=$(stat -f %m "$STOP_MARKER" 2>/dev/null) ||
    mtime=$(stat -c %Y "$STOP_MARKER" 2>/dev/null) || return 1
  [ $((now - mtime)) -lt 2 ]
}

# Pull the notification text out of the hook payload. Matching the whole JSON
# would false-positive on a cwd or file path containing the idle wording.
notif_message() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r '.message // ""' 2>/dev/null && return 0
  fi
  printf '%s' "$1" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

case "$state" in
  start)
    rm -f "$STOP_MARKER" 2>/dev/null
    register_tty
    set_color 0 170 0
    ;;
  green)
    stop_is_recent && exit 0
    register_tty
    set_color 0 170 0
    ;;
  yellow)
    # Notification fires for real permission/question prompts AND the idle
    # "waiting for your input" nudge. Only the former marks the tab yellow.
    # Bounded read: an unclosed stdin would otherwise hang until Claude Code's
    # hook timeout and stall the session.
    payload=""
    [ -t 0 ] || IFS= read -r -d '' -t 2 payload || true
    # Unparseable payload falls through to yellow — erring toward "tell me".
    if printf '%s' "$(notif_message "$payload")" | grep -qi 'waiting for your input'; then
      reset_color
      exit 0
    fi
    register_tty
    set_color 235 190 0
    ;;
  reset)
    : >"$STOP_MARKER" 2>/dev/null
    reset_color
    ;;
esac
exit 0
