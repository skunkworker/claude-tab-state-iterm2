#!/bin/bash
# Toggle the Claude Code iTerm2 tab-color signaling on/off.
#
#   toggle.sh           # flip current state
#   toggle.sh on        # force enable
#   toggle.sh off       # force disable
#   toggle.sh status    # print current state
#
# Disabling drops a flag file that tab-state.sh checks; while present, every
# hook call just resets the tab to its default color instead of signaling.

FLAG="${HOME}/.claude/tab-state.disabled"

enable() { rm -f "$FLAG"; echo "tab-state: ON"; }
disable() {
  : > "$FLAG"
  echo "tab-state: OFF"
  # Reset THIS terminal's tab immediately (other tabs reset on their next event).
  { printf '\033]6;1;bg;*;default\007' > /dev/tty; } 2>/dev/null || true
}
status() { [ -e "$FLAG" ] && echo "tab-state: OFF" || echo "tab-state: ON"; }

case "${1:-toggle}" in
  on)     enable ;;
  off)    disable ;;
  status) status ;;
  toggle) [ -e "$FLAG" ] && enable || disable ;;
  *)      echo "usage: toggle.sh [on|off|toggle|status]" >&2; exit 2 ;;
esac
