#!/bin/bash
# Reflect Claude Code state in the iTerm2 tab via the native TAB COLOR.
# Usage: tab-state.sh {green|yellow|reset}
#
#   green  = Claude is running
#   yellow = Claude needs you (real permission/question prompt)
#   reset  = default tab color (Claude is done / idle)
#
# Source of truth lives in ~/dev/ai_tools/claude-tab-state/. The live path
# ~/.claude/tab-state.sh is a symlink to this file. See README.md.
#
# Tab color is a dedicated channel (Claude Code never writes it), so there is
# no contention and the reset (6;1;bg;*;default) is reliable. With multiple
# tabs the color stays in the individual tab cell. We do NOT touch the tab
# title, so Claude's own topic titles are left alone.
#
# Hooks run in a subprocess with NO controlling terminal, so /dev/tty fails.
# We walk up the process tree to the parent `claude` process's real tty.

state="$1"

# Toggle: if this flag file exists the feature is OFF -> always reset to the
# default tab color (so no tab stays stuck colored) and do nothing else.
DISABLE_FLAG="${HOME}/.claude/tab-state.disabled"

dev=""
pid=$PPID
for _ in 1 2 3 4 5 6 7 8; do
  cand=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
  case "$cand" in
    ttys*) dev="/dev/$cand"; break ;;
  esac
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  { [ -z "$pid" ] || [ "$pid" = "0" ]; } && break
done
[ -n "$dev" ] && [ -w "$dev" ] || exit 0

emit() { printf '%b' "$1" > "$dev" 2>/dev/null; }

set_color() { # r g b
  emit "\033]6;1;bg;red;brightness;$1\007\033]6;1;bg;green;brightness;$2\007\033]6;1;bg;blue;brightness;$3\007"
}
reset_color() { emit "\033]6;1;bg;*;default\007"; }

# Disabled -> ensure the tab is back to default and stop.
if [ -e "$DISABLE_FLAG" ]; then
  reset_color
  exit 0
fi

case "$state" in
  green)
    set_color 0 170 0
    ;;
  yellow)
    # Notification fires for real permission/question prompts AND the idle
    # "waiting for your input" nudge. Only the former marks the tab yellow.
    msg=""
    [ -t 0 ] || msg=$(cat)
    if printf '%s' "$msg" | grep -qi 'waiting for your input'; then
      reset_color
      exit 0
    fi
    set_color 235 190 0
    ;;
  reset)
    reset_color
    ;;
esac
exit 0
