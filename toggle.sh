#!/bin/bash
# Toggle the Claude Code iTerm2 tab-color signaling on/off.
#
#   toggle.sh           # flip current state
#   toggle.sh on        # force enable
#   toggle.sh off       # force disable
#   toggle.sh status    # print current state
#
# Disabling drops a flag file that tab-state.sh checks; while present, every
# hook call clears anything we painted instead of signaling.

set -u

FLAG="${HOME}/.claude/tab-state.disabled"
STATE_DIR="${HOME}/.claude/.tab-state"
RESET_SEQ='\033]6;1;bg;*;default\007'

# Clear every tab we have ever painted. Without this, an idle tab keeps its
# color until it happens to see another hook event, which may be never.
reset_registered_ttys() {
  local f dev
  for f in "$STATE_DIR"/tty-*; do
    [ -e "$f" ] || continue
    read -r dev _ 2>/dev/null <"$f" || continue # record is "dev owner state"
    if [ -w "$dev" ]; then
      printf '%b' "$RESET_SEQ" >"$dev" 2>/dev/null
    else
      rm -f "$f" # the tty is gone; drop the record
    fi
  done
}

enable() {
  rm -f "$FLAG"
  echo "tab-state: ON"
}

disable() {
  local f
  mkdir -p "${HOME}/.claude" 2>/dev/null
  : >"$FLAG"
  echo "tab-state: OFF"
  reset_registered_ttys
  # Subagent tokens too: while off, tab-state.sh never sees the SubagentStop
  # that would clear them, so they would strand the tab blue on re-enable.
  for f in "$STATE_DIR"/agent-* "$STATE_DIR"/stopped-*; do
    [ -e "$f" ] && rm -f "$f"
  done
  # The current terminal may not be registered yet (no hook has fired in it).
  { printf '%b' "$RESET_SEQ" >/dev/tty; } 2>/dev/null || true
}

status() {
  if [ -e "$FLAG" ]; then echo "tab-state: OFF"; else echo "tab-state: ON"; fi
}

case "${1:-toggle}" in
  on) enable ;;
  off) disable ;;
  status) status ;;
  toggle)
    if [ -e "$FLAG" ]; then enable; else disable; fi
    ;;
  *)
    echo "usage: toggle.sh [on|off|toggle|status]" >&2
    exit 2
    ;;
esac
